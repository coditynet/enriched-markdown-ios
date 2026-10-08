import UIKit

/// Ties a published text to the streaming session that produced it: texts
/// of one session share their first `stableLength` characters (the session's
/// finished blocks, which only ever grow), so a view can apply the next one
/// as an edit of its tail instead of replacing the document.
struct StreamingLineage: Equatable {
    let session: UInt64
    let stableLength: Int
}

/// Renders a streamed document incrementally. The document is cut into runs
/// of finished blocks (see `StreamingBlockSplitter`), each parsed and
/// rendered once and kept; every update re-parses and re-renders only the
/// open tail after the last cut — filtered and repaired, so unfinished
/// syntax never shows raw.
///
/// Not thread-safe: use it from one serial queue.
final class StreamingRenderSession {
    struct Inputs {
        let config: MarkdownStyleConfig
        let flags: Md4cFlags
        let imageRequestHeaders: [String: String]
        let plugins: [any MarkdownRenderPlugin]
    }

    struct Result {
        let text: NSAttributedString
        /// The markdown `text` was rendered from: finished blocks as written,
        /// the tail as filtered and repaired. Source ranges index into it.
        let source: String
        let lineage: StreamingLineage?
    }

    private static var nextID: UInt64 = 0
    private static let idLock = NSLock()

    /// Changes whenever the finished blocks are dropped, so a lineage never
    /// spans texts that do not share them.
    private(set) var id: UInt64
    private let inputs: Inputs
    private let effectiveFlags: Md4cFlags

    /// The finished blocks: their markdown, its UTF-8 length, their output,
    /// and the render state after them.
    private var stableSource = ""
    private var stableByteCount = 0
    private let stableOutput = NSMutableAttributedString()
    private var boundary = RenderContext.BoundaryState.documentStart

    /// Set once the document holds anything that makes its blocks depend on
    /// each other; from then on every update renders it whole.
    private var rendersWhole: Bool

    init(inputs: Inputs) {
        id = Self.makeID()
        self.inputs = inputs
        self.effectiveFlags = MarkdownRenderer.effectiveFlags(inputs.flags, plugins: inputs.plugins)
        // Blank-line nodes count the lines between blocks, which a cut splits.
        self.rendersWhole = effectiveFlags.preserveBlankLines
    }

    /// Renders `markdown` mid-stream. `isFinal` renders it as written, with
    /// no filtering or repair: what a non-streamed render produces.
    func render(_ markdown: String, options: MarkdownStreamingOptions, isFinal: Bool = false) -> Result {
        if !markdown.utf8.starts(with: stableSource.utf8) {
            resetStableBlocks()
        }

        var tail = String(markdown.utf8.dropFirst(stableByteCount)) ?? ""
        if !rendersWhole {
            let scan = StreamingBlockSplitter.scan(tail.utf8)
            if scan.hasLinkReferenceDefinition {
                rendersWhole = true
                resetStableBlocks()
                tail = markdown
            } else if let cut = scan.lastCut {
                let utf8 = Array(tail.utf8)
                let finished = String(decoding: utf8[..<cut], as: UTF8.self)
                appendStableBlocks(finished)
                tail = String(decoding: utf8[cut...], as: UTF8.self)
            }
        }

        let renderedTail = isFinal ? tail : Self.renderable(tail, options: options, flags: effectiveFlags)
        let tailOutput = renderChunk(renderedTail, byteOffset: stableByteCount, state: boundary).output

        let text = NSMutableAttributedString(attributedString: stableOutput)
        text.append(tailOutput)
        return Result(
            text: text,
            source: stableSource + renderedTail,
            lineage: StreamingLineage(session: id, stableLength: stableOutput.length)
        )
    }

    /// The tail as it can render mid-stream.
    static func renderable(_ markdown: String, options: MarkdownStreamingOptions, flags: Md4cFlags) -> String {
        let filtered = StreamingMarkdownFilter.renderable(markdown, options: options, latexMath: flags.latexMathEnabled)
        return StreamingMarkdownRepair.repair(filtered, syntax: StreamingMarkdownRepair.Syntax(flags: flags))
    }

    private static func makeID() -> UInt64 {
        idLock.lock()
        defer { idLock.unlock() }
        nextID += 1
        return nextID
    }

    private func resetStableBlocks() {
        id = Self.makeID()
        stableSource = ""
        stableByteCount = 0
        stableOutput.setAttributedString(NSAttributedString())
        boundary = .documentStart
    }

    private func appendStableBlocks(_ markdown: String) {
        let chunk = renderChunk(markdown, byteOffset: stableByteCount, state: boundary)
        stableOutput.append(chunk.output)
        boundary = chunk.state
        stableSource += markdown
        stableByteCount += markdown.utf8.count
    }

    /// Renders `markdown` as the blocks that follow `stableOutput`, exactly
    /// as they would render inside the whole document.
    private func renderChunk(
        _ markdown: String,
        byteOffset: Int,
        state: RenderContext.BoundaryState
    ) -> (output: NSAttributedString, state: RenderContext.BoundaryState) {
        let ast = Parser.shared.parseMarkdown(markdown, flags: effectiveFlags)
        guard !ast.children.isEmpty else { return (NSAttributedString(), state) }
        let annotated = SourceOffsetAnnotator.annotate(ast, source: markdown)
        let renderer = AttributedRenderer(
            config: inputs.config,
            imageRequestHeaders: inputs.imageRequestHeaders,
            plugins: inputs.plugins
        )

        // Block renderers look at what precedes them — whether the output is
        // empty, whether it ends a line — so the last finished character
        // stands in for the document before.
        let output = NSMutableAttributedString()
        if stableOutput.length > 0 {
            output.append(stableOutput.attributedSubstring(from: NSRange(location: stableOutput.length - 1, length: 1)))
        }
        let seedLength = output.length

        let context = renderer.makeRootContext()
        context.restore(state)
        renderer.renderBlocks(annotated.children, into: output, context: context)
        let endState = context.boundaryState
        renderer.finishBlocks(in: output, range: NSRange(location: seedLength, length: output.length - seedLength))
        output.deleteCharacters(in: NSRange(location: 0, length: seedLength))

        if byteOffset > 0 {
            Self.shiftSourceRanges(in: output, by: byteOffset)
        }
        return (output, endState)
    }

    /// Source ranges index the chunk; make them index the document.
    private static func shiftSourceRanges(in output: NSMutableAttributedString, by offset: Int) {
        let range = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(MarkdownAttribute.sourceRange, in: range) { value, runRange, _ in
            guard let sourceRange = (value as? NSValue)?.rangeValue else { return }
            let shifted = NSRange(location: sourceRange.location + offset, length: sourceRange.length)
            output.addAttribute(MarkdownAttribute.sourceRange, value: NSValue(range: shifted), range: runRange)
        }
    }
}

extension RenderContext {
    /// What a root-level block inherits from the blocks before it. Every
    /// other field is back at its default between root blocks.
    struct BoundaryState {
        var blockType: BlockType
        var blockStyle: BlockStyle?
        var taskItemIndex: Int

        /// Marks a fresh `makeRootContext()`; restoring it changes nothing.
        static let documentStart = BoundaryState(blockType: .none, blockStyle: nil, taskItemIndex: -1)
    }

    var boundaryState: BoundaryState {
        BoundaryState(blockType: currentBlockType, blockStyle: currentBlockStyle, taskItemIndex: taskItemIndex)
    }

    func restore(_ state: BoundaryState) {
        guard state.taskItemIndex >= 0 else { return }
        if let style = state.blockStyle {
            setBlockStyle(font: style.font, color: style.color, blockType: state.blockType, headingLevel: style.headingLevel)
        } else {
            clearBlockStyle()
        }
        taskItemIndex = state.taskItemIndex
    }
}
