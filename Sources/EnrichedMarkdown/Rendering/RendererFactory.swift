import UIKit

final class RendererFactory {
    private let config: MarkdownStyleConfig
    private let imageRequestHeaders: [String: String]
    private let plugins: [any MarkdownRenderPlugin]
    /// Per type, the plugins' renderers in order, then the built-in one.
    private var cache: [NodeType: [NodeRenderer]] = [:]
    private lazy var childrenOnlyRenderer = ChildrenOnlyRenderer(factory: self)

    init(
        config: MarkdownStyleConfig,
        imageRequestHeaders: [String: String] = [:],
        plugins: [any MarkdownRenderPlugin] = []
    ) {
        self.config = config
        self.imageRequestHeaders = imageRequestHeaders
        self.plugins = plugins
    }

    /// The first renderer for the node's type that claims it.
    func renderer(for node: MarkdownASTNode) -> NodeRenderer {
        let candidates = renderers(for: node.type)
        if candidates.count == 1 {
            return candidates[0]
        }
        return candidates.first { $0.canRender(node) } ?? childrenOnlyRenderer
    }

    func render(_ node: MarkdownASTNode, into output: NSMutableAttributedString, context: RenderContext) {
        renderer(for: node).render(node: node, into: output, context: context)
    }

    func renderChildren(
        of node: MarkdownASTNode,
        into output: NSMutableAttributedString,
        context: RenderContext
    ) {
        for child in node.children {
            render(child, into: output, context: context)
        }
    }

    private func renderers(for type: NodeType) -> [NodeRenderer] {
        if let cached = cache[type] {
            return cached
        }

        var renderers = plugins.compactMap { $0.renderer(for: type, config: config) }
        renderers.append(createBuiltInRenderer(for: type))
        cache[type] = renderers
        return renderers
    }

    private func createBuiltInRenderer(for type: NodeType) -> NodeRenderer {
        if let renderer = createInlineRenderer(for: type) {
            return renderer
        }
        if let renderer = createBlockRenderer(for: type) {
            return renderer
        }
        #if DEBUG
        print("[EnrichedMarkdown] No renderer for node type '\(type)'; rendering its children only.")
        #endif
        return childrenOnlyRenderer
    }

    private func createInlineRenderer(for type: NodeType) -> NodeRenderer? {
        switch type {
        case .text:
            return TextRenderer()
        case .strong:
            return StrongRenderer(factory: self, config: config)
        case .emphasis:
            return EmphasisRenderer(factory: self, config: config)
        case .strikethrough:
            return StrikethroughRenderer(factory: self, config: config)
        case .underline:
            return UnderlineRenderer(factory: self, config: config)
        case .superscript:
            return BaselineShiftRenderer(factory: self, attributeKey: MarkdownAttribute.superscript)
        case .subscript:
            return BaselineShiftRenderer(factory: self, attributeKey: MarkdownAttribute.subscript)
        case .highlight:
            return HighlightRenderer(factory: self, config: config)
        case .spoiler:
            return SpoilerRenderer(factory: self)
        case .link:
            return LinkRenderer(factory: self, config: config)
        case .lineBreak:
            return LineBreakRenderer()
        case .softBreak:
            return SoftBreakRenderer()
        case .code:
            return CodeRenderer(factory: self, config: config)
        case .image:
            return ImageRenderer(config: config, requestHeaders: imageRequestHeaders)
        default:
            return nil
        }
    }

    private func createBlockRenderer(for type: NodeType) -> NodeRenderer? {
        switch type {
        case .paragraph:
            return ParagraphRenderer(factory: self, config: config)
        case .heading:
            return HeadingRenderer(factory: self, config: config)
        case .thematicBreak:
            return ThematicBreakRenderer(config: config)
        case .blankLine:
            return BlankLineRenderer(config: config)
        case .codeBlock:
            return CodeBlockRenderer(factory: self, config: config)
        case .blockquote, .admonition:
            return BlockquoteRenderer(factory: self, config: config)
        case .unorderedList:
            return ListRenderer(factory: self, config: config, isOrdered: false)
        case .orderedList:
            return ListRenderer(factory: self, config: config, isOrdered: true)
        case .listItem:
            return ListItemRenderer(factory: self, config: config)
        case .table:
            return TableRenderer(factory: self, config: config)
        default:
            return nil
        }
    }
}
