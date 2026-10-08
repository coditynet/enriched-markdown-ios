import SwiftUI

/// How `EnrichedMarkdownText` renders markdown that is still arriving, e.g.
/// an LLM answer re-assigned in full on every token.
public struct MarkdownStreamingOptions: Equatable, Sendable {
    /// How a table at the end of the stream shows while it is written.
    public enum TableMode: Equatable, Sendable {
        /// Row by row once the delimiter row has arrived; a half-written
        /// last row is held back.
        case progressive
        /// Not at all until a blank line follows the table.
        case hidden
    }

    /// How a fenced code block shows before its closing fence arrives.
    public enum CodeBlockMode: Equatable, Sendable {
        /// Line by line as the code arrives.
        case progressive
        /// Not at all until the closing fence arrives.
        case hidden
    }

    public var tables: TableMode
    public var codeBlocks: CodeBlockMode
    /// Fades newly arrived text in at the end of the document. Off under
    /// Reduce Motion regardless.
    public var fadesInText: Bool

    public init(
        tables: TableMode = .progressive,
        codeBlocks: CodeBlockMode = .progressive,
        fadesInText: Bool = true
    ) {
        self.tables = tables
        self.codeBlocks = codeBlocks
        self.fadesInText = fadesInText
    }
}

private struct MarkdownStreamingKey: EnvironmentKey {
    static let defaultValue: MarkdownStreamingOptions? = nil
}

public extension EnvironmentValues {
    /// Non-nil while the markdown is streaming.
    var markdownStreaming: MarkdownStreamingOptions? {
        get { self[MarkdownStreamingKey.self] }
        set { self[MarkdownStreamingKey.self] = newValue }
    }
}

public extension View {
    /// Marks the markdown as streaming in. While `isStreaming` is true each
    /// new string that extends the previous one re-renders only its last,
    /// still-open block; unclosed syntax (`**bold`, `` `code``, `[link](ur`)
    /// renders as if closed instead of flashing raw, unfinished tables, code
    /// blocks, and math follow `tables` and `codeBlocks`, and new text fades
    /// in. When it turns false the text renders exactly as a non-streamed
    /// `EnrichedMarkdownText` would.
    func markdownStreaming(
        _ isStreaming: Bool,
        tables: MarkdownStreamingOptions.TableMode = .progressive,
        codeBlocks: MarkdownStreamingOptions.CodeBlockMode = .progressive,
        fadesInText: Bool = true
    ) -> some View {
        environment(
            \.markdownStreaming,
            isStreaming
                ? MarkdownStreamingOptions(tables: tables, codeBlocks: codeBlocks, fadesInText: fadesInText)
                : nil
        )
    }
}
