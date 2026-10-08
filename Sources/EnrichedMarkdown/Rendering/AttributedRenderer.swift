import UIKit

final class AttributedRenderer {
    private let config: MarkdownStyleConfig
    private let factory: RendererFactory
    /// Root-level plugin block node types and the margins each declares.
    private let rootBlockMargins: [NodeType: BlockMargins]

    init(
        config: MarkdownStyleConfig,
        imageRequestHeaders: [String: String] = [:],
        plugins: [any MarkdownRenderPlugin] = []
    ) {
        self.config = config
        self.factory = RendererFactory(
            config: config,
            imageRequestHeaders: imageRequestHeaders,
            plugins: plugins
        )
        self.rootBlockMargins = plugins.reduce(into: [:]) { margins, plugin in
            for type in plugin.rootBlockNodeTypes where margins[type] == nil {
                margins[type] = plugin.blockMargins(for: type, config: config)
            }
        }
    }

    func renderRoot(_ root: MarkdownASTNode) -> NSMutableAttributedString {
        let context = makeRootContext()
        let output = NSMutableAttributedString()
        renderBlocks(root.children, into: output, context: context)
        context.clearBlockStyle()
        finishBlocks(in: output, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// A context as the document's first root block sees it.
    func makeRootContext() -> RenderContext {
        let context = RenderContext(factory: factory)
        let paragraphFont = config.paragraph.font ?? UIFont.preferredFont(forTextStyle: .body)
        let paragraphColor = config.paragraph.foregroundColor ?? UIColor.label
        context.setBlockStyle(font: paragraphFont, color: paragraphColor)
        return context
    }

    /// Renders root-level blocks after whatever `output` already holds;
    /// streaming renders a document in runs of blocks this way.
    func renderBlocks(_ blocks: [MarkdownASTNode], into output: NSMutableAttributedString, context: RenderContext) {
        for child in blocks {
            // A synthetic paragraph gives bare plugin block nodes their
            // block margins and alignment.
            if let margins = rootBlockMargins[child.type] {
                context.pluginBlockMargins = margins
                let paragraph = MarkdownASTNode(type: .paragraph, children: [child])
                factory.render(paragraph, into: output, context: context)
                context.pluginBlockMargins = nil
                continue
            }
            factory.render(child, into: output, context: context)
        }
    }

    /// The passes that run over finished blocks: exactly once per character.
    func finishBlocks(in output: NSMutableAttributedString, range: NSRange) {
        BaselineShiftRenderer.applyShifts(to: output, in: range, config: config)
        SpoilerConcealment.conceal(output, in: range)
    }
}
