import UIKit

/// Extension seam for custom elements, used by optional sibling modules
/// (EnrichedMarkdownLaTeX) and apps alike; install one on a view hierarchy
/// with `.markdownRenderPlugin(_:)`. Plugins are consulted before the
/// built-in renderers, in installation order.
///
/// A renderer can claim only some nodes of its type through
/// `NodeRenderer.canRender(_:)`; declined nodes fall through to the next
/// plugin and finally the built-ins. The parser passes what that decision
/// usually needs as node attributes: `language` and `info` (the full info
/// string) on fenced `.codeBlock`s, `admonitionType` on `.admonition`s —
/// lowercase for the GitHub alert types, the tag as written for any other
/// `> [!TAG]` (requires `Md4cFlags.admonitions`, see `adjustFlags(_:)`).
public protocol MarkdownRenderPlugin {
    /// A renderer for `type`, or nil to leave it to the next plugin or the
    /// built-ins. Called once per node type per render; the result is cached.
    func renderer(for type: NodeType, config: MarkdownStyleConfig) -> NodeRenderer?

    /// Adjusts parser flags before parsing, e.g. enabling the md4c extension
    /// whose nodes the plugin renders.
    func adjustFlags(_ flags: inout Md4cFlags)

    /// Node types the parser emits bare at document root (promoted isolated
    /// display math, for instance) that should render wrapped in a synthetic
    /// paragraph; `RenderContext.rendersPluginBlock` is true while it renders.
    var rootBlockNodeTypes: Set<NodeType> { get }

    /// Margins for a `rootBlockNodeTypes` member's synthetic paragraph; unset
    /// ones keep the paragraph style's.
    func blockMargins(for type: NodeType, config: MarkdownStyleConfig) -> BlockMargins

    /// The plugin's element defaults, layered directly above
    /// `MarkdownTheme.default` and below the app's themes.
    var defaultTheme: MarkdownTheme? { get }
}

public extension MarkdownRenderPlugin {
    func adjustFlags(_ flags: inout Md4cFlags) {}

    var rootBlockNodeTypes: Set<NodeType> { [] }

    func blockMargins(for type: NodeType, config: MarkdownStyleConfig) -> BlockMargins { BlockMargins() }

    var defaultTheme: MarkdownTheme? { nil }
}

/// Block spacing overriding the paragraph style's, per set property.
public struct BlockMargins: Equatable, Sendable {
    public var marginTop: CGFloat?
    public var marginBottom: CGFloat?

    public init(marginTop: CGFloat? = nil, marginBottom: CGFloat? = nil) {
        self.marginTop = marginTop
        self.marginBottom = marginBottom
    }
}

/// Adopted by plugin-created attachments so base components can handle them
/// without knowing their concrete types. VoiceOver reads the attachment's
/// `accessibilityLabel`.
public protocol MarkdownPluginAttachment: NSTextAttachment {
    /// Source with markdown syntax restored, for Copy as Markdown.
    func markdownText() -> String
    /// Standalone block; wrapped in blank lines by Copy as Markdown.
    var isBlock: Bool { get }
    /// The text the parser's text nodes carry for the attachment's source
    /// range, so a verbatim copy slice can be validated against it.
    var literalText: String { get }
    /// Syntax immediately outside the tagged source range (a block delimiter
    /// may sit on its own line), consumed when a copy slice ends on the
    /// attachment; nil when there is none.
    var sourceDelimiters: (opening: String, closing: String)? { get }
}

public extension MarkdownPluginAttachment {
    var sourceDelimiters: (opening: String, closing: String)? { nil }
}
