import UIKit

/// Appends one AST node's rendering to the output. Built-in and plugin
/// renderers alike; plugin renderers render nested content through
/// `RenderContext.renderChildren(of:into:)`.
public protocol NodeRenderer: AnyObject {
    /// Whether this renderer takes `node`; declined nodes go to the next
    /// plugin's renderer for the type, then the built-in one. Defaults to
    /// true.
    func canRender(_ node: MarkdownASTNode) -> Bool

    func render(node: MarkdownASTNode, into output: NSMutableAttributedString, context: RenderContext)
}

public extension NodeRenderer {
    func canRender(_ node: MarkdownASTNode) -> Bool { true }
}

final class ChildrenOnlyRenderer: NodeRenderer {
    private unowned let factory: RendererFactory

    init(factory: RendererFactory) {
        self.factory = factory
    }

    func render(node: MarkdownASTNode, into output: NSMutableAttributedString, context: RenderContext) {
        factory.renderChildren(of: node, into: output, context: context)
    }
}
