import Foundation

/// Finds where a streamed document can be cut so the blocks before the cut
/// parse — and render — the same alone as within the whole document, now
/// and after any text is appended.
///
/// A cut sits at the start of a line that follows a blank line and opens a
/// block at column 0 that cannot continue an earlier one: no indentation
/// (list item content, indented code), no list marker (another item of the
/// same list), not inside a fence. Conservative by design: a missed cut only
/// costs re-rendering a longer tail.
enum StreamingBlockSplitter {
    struct Scan: Equatable {
        /// Byte offset of the last cut, if any.
        var lastCut: Int?
        /// A link reference definition can resolve links anywhere in the
        /// document, so no part of it renders alone.
        var hasLinkReferenceDefinition = false
    }

    static func scan(_ bytes: some Collection<UInt8>) -> Scan {
        let bytes = Array(bytes)
        var result = Scan()
        var fence: (character: UInt8, length: Int)?
        var previousLineBlank = false
        var lineStart = 0

        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: newline) ?? bytes.count
            let line = bytes[lineStart..<lineEnd]

            if let open = fence {
                if let marker = fenceMarker(in: line), marker.character == open.character,
                   marker.length >= open.length, marker.infoIsBlank {
                    fence = nil
                }
                previousLineBlank = false
                lineStart = lineEnd + 1
                continue
            }

            if isLinkReferenceDefinition(line) {
                result.hasLinkReferenceDefinition = true
            }
            // Raw HTML blocks like `<!--` or `<pre>` run across blank lines.
            if startsRawHTML(line) {
                return result
            }
            if lineStart > 0, previousLineBlank, canStartIndependentBlock(line) {
                result.lastCut = lineStart
            }
            if let marker = fenceMarker(in: line) {
                fence = (marker.character, marker.length)
            }
            previousLineBlank = isBlank(line)
            lineStart = lineEnd + 1
        }
        return result
    }

    private static let newline = UInt8(ascii: "\n")

    private static func isBlank(_ line: ArraySlice<UInt8>) -> Bool {
        line.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
    }

    private static func canStartIndependentBlock(_ line: ArraySlice<UInt8>) -> Bool {
        guard let first = line.first else { return false }
        switch first {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"),
             UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             // `[` may turn out to be a link reference definition, `<` an HTML block.
             UInt8(ascii: "["), UInt8(ascii: "<"):
            return false
        default:
            return true
        }
    }

    private struct FenceMarker {
        let character: UInt8
        let length: Int
        let infoIsBlank: Bool
    }

    /// A fence run at any indentation, after any quote or list markers — a
    /// line-based scan has no container context, and reading a line as a
    /// fence only ever makes the scan more cautious.
    private static func fenceMarker(in line: ArraySlice<UInt8>) -> FenceMarker? {
        var index = line.startIndex
        while index < line.endIndex,
              [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: ">")].contains(line[index]) {
            index += 1
        }
        guard index < line.endIndex else { return nil }
        let character = line[index]
        guard character == UInt8(ascii: "`") || character == UInt8(ascii: "~") else { return nil }
        var end = index
        while end < line.endIndex, line[end] == character {
            end += 1
        }
        guard end - index >= 3 else { return nil }
        let info = line[end...]
        if character == UInt8(ascii: "`"), info.contains(UInt8(ascii: "`")) {
            return nil
        }
        return FenceMarker(character: character, length: end - index, infoIsBlank: isBlank(info))
    }

    /// `[label]: destination` after at most 3 spaces.
    private static func isLinkReferenceDefinition(_ line: ArraySlice<UInt8>) -> Bool {
        var index = line.startIndex
        while index < line.endIndex, index - line.startIndex < 3, line[index] == UInt8(ascii: " ") {
            index += 1
        }
        guard index < line.endIndex, line[index] == UInt8(ascii: "[") else { return false }
        guard let close = line[index...].firstIndex(of: UInt8(ascii: "]")), close > index + 1 else { return false }
        return close + 1 < line.endIndex && line[close + 1] == UInt8(ascii: ":")
    }

    private static let rawHTMLOpeners = ["<!--", "<?", "<![CDATA[", "<pre", "<script", "<style", "<textarea"]
        .map { Array($0.utf8) }

    private static func startsRawHTML(_ line: ArraySlice<UInt8>) -> Bool {
        let content = line.drop { $0 == UInt8(ascii: " ") }
        guard content.first == UInt8(ascii: "<") else { return false }
        let lowered = content.prefix(9).map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 + 32 : $0 }
        return rawHTMLOpeners.contains { lowered.starts(with: $0) }
    }
}
