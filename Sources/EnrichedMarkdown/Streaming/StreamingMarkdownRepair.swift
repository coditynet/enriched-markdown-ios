import Foundation

/// Repairs the unfinished end of a streamed answer so raw syntax never
/// flashes: `**bold` renders bold, `` `code`` as code, `[text](ur` as plain
/// "text", and an unclosed `$x^` stays hidden until it closes. A Swift port
/// of the rules of remend (vercel/streamdown), adapted to md4c.
///
/// Only the last paragraph (heading, list item, or table cell) is touched:
/// inline syntax cannot span paragraphs, so an unmatched `**` in a finished
/// one stays literal, as it will in the final render. Repairs only append
/// closers or drop the incomplete trailing construct — they never edit text
/// that is already final, so the streamed view converges on the final one.
enum StreamingMarkdownRepair {
    /// The md4c extensions whose syntax is live.
    struct Syntax: Equatable {
        var latexMath = false
        var highlight = false

        init(latexMath: Bool = false, highlight: Bool = false) {
            self.latexMath = latexMath
            self.highlight = highlight
        }

        init(flags: Md4cFlags) {
            self.init(latexMath: flags.latexMathEnabled, highlight: flags.highlight)
        }
    }

    static func repair(_ markdown: String, syntax: Syntax = Syntax()) -> String {
        var text = Array(markdown.unicodeScalars)
        // Inside an unclosed fence everything is code, and the code block
        // streams as it is — but for its closing fence arriving.
        if let fence = FenceScan.openFence(in: text) {
            return String(String.UnicodeScalarView(removingPartialCloser(of: fence, from: text)))
        }

        text = removingTrailingMarkerLine(text)
        let scopeStart = inlineScopeStart(in: text)
        var scopeEnd = text.count
        while scopeEnd > scopeStart, isWhitespace(text[scopeEnd - 1]) {
            scopeEnd -= 1
        }

        var scope = Array(text[scopeStart..<scopeEnd])
        if syntax.latexMath {
            scope = truncatingUnclosedMath(scope)
        }
        scope = healingTrailingLinks(scope)
        scope = droppingTrailingOpeners(scope)
        while let last = scope.last, isWhitespace(last) {
            scope.removeLast()
        }

        var result = String.UnicodeScalarView()
        result.append(contentsOf: text[..<scopeStart])
        result.append(contentsOf: scope)
        result.append(contentsOf: closers(for: scope, syntax: syntax))
        result.append(contentsOf: text[scopeEnd...])
        return String(result)
    }

    // MARK: - Block-level trimming

    /// Drops a last line that holds only block syntax — a list bullet, a
    /// heading's `#`s, quote markers, or the start of a setext underline or
    /// fence — which would otherwise render as an empty block (or turn the
    /// previous line into a heading) for a token or two.
    static func removingTrailingMarkerLine(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let lineStart = (text.lastIndex(of: "\n") ?? -1) + 1
        let line = text[lineStart...]
        guard line.contains(where: { !isWhitespace($0) }) else { return text }

        var remainder = Array(text[skippingQuoteMarkers(in: text, from: lineStart)...])
        while let last = remainder.last, isWhitespace(last) {
            remainder.removeLast()
        }
        let isMarkerOnly: Bool
        if remainder.isEmpty {
            isMarkerOnly = true
        } else if remainder.count == 1, "-*+".unicodeScalars.contains(remainder[0]) {
            isMarkerOnly = true
        } else if let marker = remainder.first, "#=-`~".unicodeScalars.contains(marker),
                  remainder.allSatisfy({ $0 == marker }) {
            // `###` is an empty heading; `==`/`--` a setext underline in the
            // making; ``` `` ``` an unfinished fence. Three dashes are
            // already a complete thematic break.
            let limit = marker == "#" ? 6 : 2
            isMarkerOnly = remainder.count <= limit
        } else {
            isMarkerOnly = orderedListMarkerLength(remainder, at: 0) == remainder.count
        }
        return isMarkerOnly ? Array(text[..<lineStart]) : text
    }

    /// A last line holding only the start of the fence's closing run.
    private static func removingPartialCloser(of fence: FenceScan.OpenFence, from text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let lineStart = (text.lastIndex(of: "\n") ?? -1) + 1
        let run = text[skippingQuoteMarkers(in: text, from: lineStart)...].drop(while: { $0 == " " })
        guard !run.isEmpty, run.count < fence.length, run.allSatisfy({ $0 == fence.character }) else { return text }
        return Array(text[..<lineStart])
    }

    /// The start of the last paragraph: walks up from the last line while
    /// lines continue it. In a table row it is the last cell.
    static func inlineScopeStart(in text: [Unicode.Scalar]) -> Int {
        let lineStarts = [0] + text.indices.filter { text[$0] == "\n" }.map { $0 + 1 }
        var line = lineStarts.count - 1

        let lastLineContent = skippingQuoteMarkers(in: text, from: lineStarts[line])
        if lastLineContent < text.count, text[lastLineContent] == "|" {
            let spans = SpanScan(text, from: lineStarts[line])
            var cellStart = lineStarts[line]
            for index in lineStarts[line]..<text.count
            where text[index] == "|" && spans.isProse(index) && !isEscaped(text, index) {
                cellStart = index + 1
            }
            return cellStart
        }

        while line > 0 {
            let current = lineStarts[line]
            let previous = lineStarts[line - 1]
            if startsBlock(text, lineStart: current)
                || isBlankLine(text, lineStart: previous)
                || endsBlock(text, lineStart: previous) {
                break
            }
            line -= 1
        }
        return lineStarts[line]
    }

    private static func startsBlock(_ text: [Unicode.Scalar], lineStart: Int) -> Bool {
        var index = skippingQuoteMarkers(in: text, from: lineStart)
        while index < text.count, text[index] == " " || text[index] == "\t" {
            index += 1
        }
        guard index < text.count else { return false }
        if listMarkerEnd(text, at: index) != nil || text[index] == "|" {
            return true
        }
        return startsHeadingOrFence(text, at: index)
    }

    private static func endsBlock(_ text: [Unicode.Scalar], lineStart: Int) -> Bool {
        var index = skippingQuoteMarkers(in: text, from: lineStart)
        while index < text.count, text[index] == " " || text[index] == "\t" {
            index += 1
        }
        guard index < text.count else { return false }
        if text[index] == "|" || startsHeadingOrFence(text, at: index) {
            return true
        }
        return isHorizontalRule(text, markerIndex: index, marker: text[index])
    }

    private static func startsHeadingOrFence(_ text: [Unicode.Scalar], at index: Int) -> Bool {
        let marker = text[index]
        guard marker == "#" || marker == "`" || marker == "~" else { return false }
        var end = index
        while end < text.count, text[end] == marker {
            end += 1
        }
        if marker == "#" {
            return end - index <= 6 && (end == text.count || isWhitespace(text[end]))
        }
        return end - index >= 3
    }

    private static func isBlankLine(_ text: [Unicode.Scalar], lineStart: Int) -> Bool {
        var index = skippingQuoteMarkers(in: text, from: lineStart)
        while index < text.count, text[index] != "\n" {
            if !isWhitespace(text[index]) {
                return false
            }
            index += 1
        }
        return true
    }

    private static func skippingQuoteMarkers(in text: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while true {
            var probe = index
            while probe < text.count, text[probe] == " " {
                probe += 1
            }
            guard probe < text.count, text[probe] == ">" else { return index }
            index = probe + 1
        }
    }

    /// One past a bullet or ordered list marker and its space, or nil.
    private static func listMarkerEnd(_ text: [Unicode.Scalar], at index: Int) -> Int? {
        var end = index
        if "-*+".unicodeScalars.contains(text[index]) {
            end += 1
        } else if let length = orderedListMarkerLength(text, at: index) {
            end += length
        } else {
            return nil
        }
        if end == text.count || text[end] == "\n" {
            return end
        }
        return text[end] == " " || text[end] == "\t" ? end + 1 : nil
    }

    private static func orderedListMarkerLength(_ text: [Unicode.Scalar], at index: Int) -> Int? {
        var end = index
        while end < text.count, end - index < 9, ("0"..."9").contains(text[end]) {
            end += 1
        }
        guard end > index, end < text.count, text[end] == "." || text[end] == ")" else { return nil }
        return end + 1 - index
    }

    // MARK: - Truncation

    /// Hides an unclosed math span from its opening `$`, as md4c would pair
    /// it: an opener sits at a line start or after whitespace or
    /// punctuation, a closer before them, and a closer takes the most recent
    /// opener of the same length. A lone `$` only counts as an opener when
    /// math-like text follows it — not a digit (`$5`) or a space (`5 $ und`).
    static func truncatingUnclosedMath(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let spans = SpanScan(text)
        var openers: [(index: Int, length: Int)] = []
        var index = 0
        while index < text.count {
            guard text[index] == "$", spans.isProse(index), !isEscaped(text, index) else {
                index += 1
                continue
            }
            var end = index
            while end < text.count, text[end] == "$" {
                end += 1
            }
            let length = end - index
            defer { index = end }
            guard length <= 2 else { continue }

            let canOpen = index == 0 || text[index - 1] == "\n"
                || isWhitespace(text[index - 1]) || isPunctuation(text[index - 1])
            let canClose = end == text.count || text[end] == "\n"
                || isWhitespace(text[end]) || isPunctuation(text[end])
            if canClose, let top = openers.last, top.length == length {
                openers.removeAll()
                continue
            }
            if canOpen {
                openers.append((index, length))
            }
        }

        guard let open = openers.last else { return text }
        if open.length == 1 {
            let next = open.index + 1
            guard next < text.count, !isWhitespace(text[next]), !("0"..."9").contains(text[next]) else {
                return text
            }
        }
        return Array(text[..<open.index])
    }

    /// Incomplete links show their text only (`[text](ur` → `text`) until
    /// the URL closes, and incomplete images nothing.
    static func healingTrailingLinks(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var current = text
        // Dropping an incomplete image can expose another one before it;
        // bounded so an adversarial tail cannot make healing quadratic.
        for _ in 0..<32 {
            let next = healingTrailingLink(current)
            if next == current {
                return next
            }
            current = next
        }
        return current
    }

    private static func healingTrailingLink(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let spans = SpanScan(text)

        if let paren = lastIndex(of: ["]", "("], in: text), spans.isProse(paren),
           !text[(paren + 2)...].contains(")"),
           let open = matchingOpeningBracket(in: text, closingAt: paren), spans.isProse(open) {
            if open > 0, text[open - 1] == "!" {
                return Array(text[..<(open - 1)])
            }
            return Array(text[..<open]) + Array(text[(open + 1)..<paren])
        }

        var index = text.lastIndex(of: "[")
        while let open = index {
            defer { index = text[..<open].lastIndex(of: "[") }
            guard spans.isProse(open), !isEscaped(text, open) else { continue }
            guard matchingClosingBracket(in: text, openingAt: open) == nil else { continue }
            if open > 0, text[open - 1] == "!" {
                return Array(text[..<(open - 1)])
            }
            let first = firstIncompleteBracket(in: text, spans: spans) ?? open
            return Array(text[..<first]) + Array(text[(first + 1)...])
        }

        // `[text]` at the very end is most likely a link whose `(url)` is
        // next; its brackets would flash for a token.
        if text.last == "]", spans.isProse(text.count - 1),
           let open = matchingOpeningBracket(in: text, closingAt: text.count - 1),
           spans.isProse(open), !isEscaped(text, open), !isTaskCheckbox(text, open: open) {
            if open > 0, text[open - 1] == "!" {
                return Array(text[..<(open - 1)])
            }
            return Array(text[..<open]) + Array(text[(open + 1)..<(text.count - 1)])
        }
        return text
    }

    /// The first `[` left without a `]`, skipping complete links.
    private static func firstIncompleteBracket(in text: [Unicode.Scalar], spans: SpanScan) -> Int? {
        var index = 0
        while index < text.count {
            defer { index += 1 }
            guard text[index] == "[", spans.isProse(index), !isEscaped(text, index) else { continue }
            if index > 0, text[index - 1] == "!" {
                continue
            }
            guard let close = matchingClosingBracket(in: text, openingAt: index) else {
                return index
            }
            if close + 1 < text.count, text[close + 1] == "(",
               let urlEnd = text[(close + 2)...].firstIndex(of: ")") {
                index = urlEnd
            }
        }
        return nil
    }

    /// `- [ ]` / `- [x]`: the brackets are a checkbox, not a link.
    private static func isTaskCheckbox(_ text: [Unicode.Scalar], open: Int) -> Bool {
        guard text.count - open == 3, " xX".unicodeScalars.contains(text[open + 1]) else { return false }
        let lineStart = (text[..<open].lastIndex(of: "\n") ?? -1) + 1
        var index = lineStart
        while index < open, text[index] == " " {
            index += 1
        }
        guard index < open, let markerEnd = listMarkerEnd(text, at: index) else { return false }
        return text[markerEnd..<open].allSatisfy(isWhitespace)
    }

    private static func matchingOpeningBracket(in text: [Unicode.Scalar], closingAt close: Int) -> Int? {
        var depth = 1
        var index = close - 1
        while index >= 0 {
            if text[index] == "]" {
                depth += 1
            } else if text[index] == "[" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index -= 1
        }
        return nil
    }

    private static func matchingClosingBracket(in text: [Unicode.Scalar], openingAt open: Int) -> Int? {
        var depth = 1
        for index in (open + 1)..<max(open + 1, text.count) {
            if text[index] == "[" {
                depth += 1
            } else if text[index] == "]" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    /// A run of delimiters at the very end with nothing after it opens
    /// nothing yet (`Hello **`); md4c would show it raw, so it waits for the
    /// next token.
    static func droppingTrailingOpeners(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = text.count
        while start > 0, "*_~`=|".unicodeScalars.contains(text[start - 1]) {
            start -= 1
        }
        guard start < text.count, start == 0 || isWhitespace(text[start - 1]) else { return text }
        let spans = SpanScan(text)
        guard spans.isProse(start) || spans.openSpan?.start == start, !isEscaped(text, start) else { return text }
        return Array(text[..<start])
    }

    // MARK: - Closers

    private struct Closer {
        /// Where the construct opens; closers nest, so later openers close first.
        let opener: Int
        let text: String
        /// The text already ends with the first part of this closer.
        let completesTrailingRun: Bool
    }

    /// Closers for every construct still open at the end of `text`, in
    /// nesting order. Each rule sees the text with the earlier rules'
    /// closers appended, as remend's handler chain does.
    private static func closers(for text: [Unicode.Scalar], syntax: Syntax) -> String.UnicodeScalarView {
        var rules: [(InlineText) -> Closer?] = [
            boldItalicCloser, boldCloser, doubleUnderscoreCloser, singleAsteriskCloser,
            singleUnderscoreCloser, inlineCodeCloser,
            { doubleMarkerCloser($0, marker: "~") },
            { doubleMarkerCloser($0, marker: "|") }
        ]
        if syntax.highlight {
            rules.append { doubleMarkerCloser($0, marker: "=") }
        }

        var virtual = text
        var closers: [Closer] = []
        for rule in rules {
            guard let closer = rule(InlineText(virtual, latexMath: syntax.latexMath)) else { continue }
            closers.append(closer)
            virtual.append(contentsOf: closer.text.unicodeScalars)
        }

        let ordered = closers.filter(\.completesTrailingRun)
            + closers.filter { !$0.completesTrailingRun }.sorted { $0.opener > $1.opener }
        var result = String.UnicodeScalarView()
        for closer in ordered {
            result.append(contentsOf: closer.text.unicodeScalars)
        }
        return result
    }

    private static func boldItalicCloser(_ text: InlineText) -> Closer? {
        let scalars = text.scalars
        if scalars.count >= 4, scalars.allSatisfy({ $0 == "*" }) {
            return nil
        }
        guard let match = text.trailingRun(of: "*", length: 3),
              text.isProse(match.marker),
              !isMarkersOnly(scalars[match.content]),
              !isWhitespace(scalars[match.marker + 3]),
              !isHorizontalRule(scalars, markerIndex: match.marker, marker: "*"),
              text.countTripleAsterisks() % 2 == 1
        else { return nil }
        // `**bold and *italic***` closes both with one run.
        if text.countDoublePairs(of: "*") % 2 == 0, text.countSingleAsterisks() % 2 == 0 {
            return nil
        }
        return Closer(opener: match.marker, text: "***", completesTrailingRun: false)
    }

    private static func boldCloser(_ text: InlineText) -> Closer? {
        let scalars = text.scalars
        // `**content*` is the closing run arriving.
        if let match = text.trailingBold(), scalars.last == "*", match.content.count > 1 {
            guard text.isProse(match.marker),
                  !shouldSkipCompletion(text, match: match, marker: "*"),
                  text.countDoublePairs(of: "*") % 2 == 1
            else { return nil }
            return Closer(opener: match.marker, text: "*", completesTrailingRun: true)
        }
        // The opener is the last unpaired `**`, wherever later constructs
        // opened (`**bold with *ital` closes both).
        let pairs = text.doublePairs(of: "*")
        guard pairs.count % 2 == 1, let marker = pairs.last else { return nil }
        let match = InlineText.Match(marker: marker, content: (marker + 2)..<scalars.count)
        guard !shouldSkipCompletion(text, match: match, marker: "*") else { return nil }
        return Closer(opener: marker, text: "**", completesTrailingRun: false)
    }

    private static func doubleUnderscoreCloser(_ text: InlineText) -> Closer? {
        if let match = text.trailingRun(of: "_", length: 2) {
            guard text.isProse(match.marker),
                  !shouldSkipCompletion(text, match: match, marker: "_"),
                  text.hasUnmatchedDoubleUnderscore()
            else { return nil }
            return Closer(opener: match.marker, text: "__", completesTrailingRun: false)
        }
        // `__content_` is the closing run arriving.
        guard let match = text.halfCompleteRun(of: "_"),
              text.isProse(match.marker),
              text.hasUnmatchedDoubleUnderscore()
        else { return nil }
        return Closer(opener: match.marker, text: "_", completesTrailingRun: true)
    }

    private static func singleAsteriskCloser(_ text: InlineText) -> Closer? {
        let scalars = text.scalars
        guard scalars.contains("*"),
              let first = text.firstSingleAsteriskIndex(),
              text.isProse(first),
              !isMarkersOnly(scalars[(first + 1)...]),
              text.countSingleAsterisks() % 2 == 1
        else { return nil }
        return Closer(opener: first, text: "*", completesTrailingRun: false)
    }

    private static func singleUnderscoreCloser(_ text: InlineText) -> Closer? {
        let scalars = text.scalars
        guard scalars.contains("_"),
              let first = text.firstSingleUnderscoreIndex(),
              !isMarkersOnly(scalars[(first + 1)...]),
              text.isProse(first),
              text.countSingleUnderscores() % 2 == 1
        else { return nil }
        return Closer(opener: first, text: "_", completesTrailingRun: false)
    }

    /// A span opened by N backticks closes only on exactly N.
    private static func inlineCodeCloser(_ text: InlineText) -> Closer? {
        guard let span = text.spans.openSpan else { return nil }
        let scalars = text.scalars
        guard !isMarkersOnly(scalars[(span.start + span.runLength)...]) else { return nil }
        var trailingRun = 0
        while trailingRun < scalars.count, scalars[scalars.count - 1 - trailingRun] == "`" {
            trailingRun += 1
        }
        // A run at least as long as the opener is literal inside the span.
        guard trailingRun < span.runLength else { return nil }
        return Closer(
            opener: span.start,
            text: String(repeating: "`", count: span.runLength - trailingRun),
            completesTrailingRun: trailingRun > 0
        )
    }

    /// `~~strike`, `==highlight`, `||spoiler`.
    private static func doubleMarkerCloser(_ text: InlineText, marker: Unicode.Scalar) -> Closer? {
        let scalars = text.scalars
        if let match = text.trailingRun(of: marker, length: 2) {
            guard !isMarkersOnly(scalars[match.content]),
                  !isWhitespace(scalars[match.marker + 2]),
                  text.isProse(match.marker),
                  text.countDoublePairs(of: marker) % 2 == 1
            else { return nil }
            let closer = String(repeating: Character(marker), count: 2)
            return Closer(opener: match.marker, text: closer, completesTrailingRun: false)
        }
        guard let match = text.halfCompleteRun(of: marker),
              text.isProse(match.marker),
              text.countDoublePairs(of: marker) % 2 == 1
        else { return nil }
        return Closer(opener: match.marker, text: String(Character(marker)), completesTrailingRun: true)
    }

    private static func shouldSkipCompletion(_ text: InlineText, match: InlineText.Match, marker: Unicode.Scalar) -> Bool {
        let scalars = text.scalars
        let content = scalars[match.content]
        if isMarkersOnly(content) {
            return true
        }
        // A delimiter followed by whitespace cannot open (`** text`); a
        // closer appended to it would show raw.
        if isWhitespace(scalars[match.content.lowerBound]) {
            return true
        }
        let lineStart = (scalars[..<match.marker].lastIndex(of: "\n") ?? -1) + 1
        let beforeMarker = scalars[lineStart..<match.marker]
        if isBareListMarker(beforeMarker), content.contains("\n") {
            return true
        }
        return isHorizontalRule(scalars, markerIndex: match.marker, marker: marker)
    }

    // MARK: - Character classes

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    /// Letters, digits, and `_`, in any script.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Unicode punctuation and symbols, as md4c's flanking rules read them.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// Empty, or nothing but whitespace and emphasis markers.
    private static func isMarkersOnly(_ content: ArraySlice<Unicode.Scalar>) -> Bool {
        content.allSatisfy { isWhitespace($0) || "_~*`".unicodeScalars.contains($0) }
    }

    /// `- ` / `1. ` and whitespace only.
    private static func isBareListMarker(_ line: ArraySlice<Unicode.Scalar>) -> Bool {
        let trimmed = line.drop(while: isWhitespace)
        guard let first = trimmed.first else { return false }
        let rest: ArraySlice<Unicode.Scalar>
        if "-*+".unicodeScalars.contains(first) {
            rest = trimmed.dropFirst()
        } else {
            let digits = trimmed.prefix(while: { ("0"..."9").contains($0) })
            guard !digits.isEmpty else { return false }
            let afterDigits = trimmed.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return false }
            rest = afterDigits.dropFirst()
        }
        return !rest.isEmpty && rest.allSatisfy(isWhitespace)
    }

    /// The marker's line holds 3+ markers and nothing but whitespace.
    static func isHorizontalRule(_ text: [Unicode.Scalar], markerIndex: Int, marker: Unicode.Scalar) -> Bool {
        let lineStart = (text[..<markerIndex].lastIndex(of: "\n") ?? -1) + 1
        let lineEnd = text[markerIndex...].firstIndex(of: "\n") ?? text.count
        var count = 0
        for scalar in text[lineStart..<lineEnd] {
            if scalar == marker {
                count += 1
            } else if scalar != " " && scalar != "\t" {
                return false
            }
        }
        return count >= 3
    }

    static func isEscaped(_ text: [Unicode.Scalar], _ index: Int) -> Bool {
        var backslashes = 0
        var probe = index - 1
        while probe >= 0, text[probe] == "\\" {
            backslashes += 1
            probe -= 1
        }
        return backslashes % 2 == 1
    }

    private static func lastIndex(of pair: [Unicode.Scalar], in text: [Unicode.Scalar]) -> Int? {
        guard text.count >= 2 else { return nil }
        var index = text.count - 2
        while index >= 0 {
            if text[index] == pair[0], text[index + 1] == pair[1] {
                return index
            }
            index -= 1
        }
        return nil
    }
}
