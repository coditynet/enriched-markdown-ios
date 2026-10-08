import Foundation

/// Trims the trailing blocks of a streamed answer that cannot render well
/// yet: a table missing its delimiter row or ending in a half-written row, an
/// unclosed fenced code block (hidden mode), and an unclosed `$$` block.
///
/// Runs on the open tail of the document only (see `StreamingRenderSession`),
/// so earlier, finished blocks are never inspected again.
enum StreamingMarkdownFilter {
    static func renderable(
        _ markdown: String,
        options: MarkdownStreamingOptions,
        latexMath: Bool
    ) -> String {
        let lines = Lines(markdown)
        guard let fenceLine = openFenceLineIndex(in: lines) else {
            return removePendingTablesAndMath(lines, tables: options.tables, latexMath: latexMath)
        }

        // Everything after an unclosed fence is code; only the part before it
        // can hold a pending table or math block.
        let head = Lines(String(markdown[..<lines.start(of: fenceLine)]))
        let filteredHead = removePendingTablesAndMath(head, tables: options.tables, latexMath: latexMath)
        switch options.codeBlocks {
        case .hidden:
            return filteredHead
        case .progressive:
            return filteredHead + markdown[lines.start(of: fenceLine)...]
        }
    }

    // MARK: - Lines

    /// The `\n`-separated lines of a string, with their start indices.
    struct Lines {
        let text: String
        let lines: [Substring]

        init(_ text: String) {
            self.text = text
            self.lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        }

        var count: Int { lines.count }

        subscript(index: Int) -> Substring { lines[index] }

        func start(of index: Int) -> String.Index {
            lines[index].startIndex
        }

        /// The text before line `index`.
        func prefix(before index: Int) -> String {
            String(text[..<start(of: index)])
        }
    }

    // MARK: - Fenced code

    struct FenceMarker: Equatable {
        let character: Character
        let length: Int
        let info: Substring
    }

    /// A ``` or ~~~ run of 3+ after at most 3 spaces; backtick fences may
    /// not carry a backtick in the info string.
    static func fenceMarker(in line: Substring) -> FenceMarker? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " ", indent < 3 {
            index = line.index(after: index)
            indent += 1
        }
        guard index < line.endIndex else { return nil }
        let character = line[index]
        guard character == "`" || character == "~" else { return nil }

        var length = 0
        while index < line.endIndex, line[index] == character {
            index = line.index(after: index)
            length += 1
        }
        guard length >= 3 else { return nil }
        let info = line[index...]
        if character == "`", info.contains("`") {
            return nil
        }
        return FenceMarker(character: character, length: length, info: info)
    }

    static func openFenceLineIndex(in lines: Lines) -> Int? {
        var open: (index: Int, marker: FenceMarker)?
        for index in 0..<lines.count {
            guard let marker = fenceMarker(in: lines[index]) else { continue }
            if let current = open {
                if marker.character == current.marker.character,
                   marker.length >= current.marker.length,
                   isBlank(marker.info) {
                    open = nil
                }
            } else {
                open = (index, marker)
            }
        }
        return open?.index
    }

    // MARK: - Tables and block math

    private static func removePendingTablesAndMath(
        _ lines: Lines,
        tables: MarkdownStreamingOptions.TableMode,
        latexMath: Bool
    ) -> String {
        var lines = lines
        if latexMath, let mathLine = unclosedMathBlockLineIndex(in: lines) {
            lines = Lines(lines.prefix(before: mathLine))
        }
        return removePendingTable(lines, mode: tables)
    }

    /// The opening line of a `$$` block (a line holding only `$$`) whose
    /// closing line has not arrived — math renders all at once or not at all.
    private static func unclosedMathBlockLineIndex(in lines: Lines) -> Int? {
        var open: Int?
        for index in 0..<lines.count where trimmed(lines[index]) == "$$" {
            open = open == nil ? index : nil
        }
        return open
    }

    private static func removePendingTable(_ lines: Lines, mode: MarkdownStreamingOptions.TableMode) -> String {
        guard let lastContent = (0..<lines.count).last(where: { !isBlank(lines[$0]) }) else {
            return lines.text
        }
        // Followed by a blank line, the block is complete.
        if lastContent + 1 < lines.count - 1 {
            return lines.text
        }

        var blockStart = lastContent
        while blockStart > 0, !isBlank(lines[blockStart - 1]) {
            blockStart -= 1
        }
        guard (blockStart...lastContent).allSatisfy({ looksLikeTableRow(lines[$0]) }) else {
            return lines.text
        }

        switch mode {
        case .hidden:
            return lines.prefix(before: blockStart)
        case .progressive:
            let rowCount = lastContent - blockStart + 1
            // A header without its delimiter row is still a paragraph.
            if rowCount < 2 || !looksLikeTableSeparator(lines[blockStart + 1]) {
                return lines.prefix(before: blockStart)
            }
            if rowCount > 2 {
                let lastRow = lines[lastContent]
                if !trimmed(lastRow).hasSuffix("|") || pipeCount(lastRow) < pipeCount(lines[blockStart]) {
                    return lines.prefix(before: lastContent)
                }
            }
            return lines.text
        }
    }

    private static func looksLikeTableRow(_ line: Substring) -> Bool {
        trimmed(line).hasPrefix("|")
    }

    private static func looksLikeTableSeparator(_ line: Substring) -> Bool {
        let row = trimmed(line)
        guard row.first == "|" else { return false }
        var dashRun = 0
        var hasTripleDash = false
        for character in row {
            if character == "-" {
                dashRun += 1
                hasTripleDash = hasTripleDash || dashRun >= 3
            } else {
                dashRun = 0
                if character != "|", character != ":", character != " " {
                    return false
                }
            }
        }
        return hasTripleDash
    }

    private static func pipeCount(_ line: Substring) -> Int {
        line.reduce(0) { $1 == "|" ? $0 + 1 : $0 }
    }

    private static func trimmed(_ line: Substring) -> Substring {
        line.trimmingCharacters(in: .whitespaces)[...]
    }

    static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }
}
