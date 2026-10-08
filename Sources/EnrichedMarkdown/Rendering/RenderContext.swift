import UIKit

enum BlockType {
    case none
    case paragraph
    case heading
    case codeBlock
    case blockquote
    case orderedList
    case unorderedList
}

enum ListType: Int {
    case unordered = 0
    case ordered = 1
}

package struct BlockStyle {
    package var font: UIFont
    package var color: UIColor
    var headingLevel: Int
}

enum MarkdownAttribute {
    static let inlineCode = NSAttributedString.Key("EnrichedMarkdownInlineCode")
    static let codeBlock = NSAttributedString.Key("EnrichedMarkdownCodeBlock")
    static let headingLevel = NSAttributedString.Key("EnrichedMarkdownHeadingLevel")
    static let strong = NSAttributedString.Key("EnrichedMarkdownStrong")
    static let emphasis = NSAttributedString.Key("EnrichedMarkdownEmphasis")
    static let superscript = NSAttributedString.Key("EnrichedMarkdownSuperscript")
    static let `subscript` = NSAttributedString.Key("EnrichedMarkdownSubscript")
    static let highlight = NSAttributedString.Key("EnrichedMarkdownHighlight")
    /// `true` on concealed `||spoiler||` text, `false` once revealed.
    static let spoiler = NSAttributedString.Key("EnrichedMarkdownSpoiler")
    /// Colors a concealed run had, restored on reveal.
    static let spoilerOriginalColors = NSAttributedString.Key("EnrichedMarkdownSpoilerOriginalColors")
    /// The `.link` value of a concealed run. Removed from `.link` so UIKit,
    /// VoiceOver, and menus see no link until the spoiler is revealed.
    static let spoilerLink = NSAttributedString.Key("EnrichedMarkdownSpoilerLink")
    static let blockquoteDepth = NSAttributedString.Key("EnrichedMarkdownBlockquoteDepth")
    static let blockquoteBackgroundColor = NSAttributedString.Key("EnrichedMarkdownBlockquoteBackgroundColor")
    /// Leading inset of a quote's bars and fill, set on quote paragraphs
    /// that sit inside a list item (the item's text column).
    static let blockquoteBarOffset = NSAttributedString.Key("EnrichedMarkdownBlockquoteBarOffset")
    /// Present on blockquote paragraphs inside a GitHub admonition: the bar
    /// color of each nesting level, outermost first.
    static let blockquoteBarColors = NSAttributedString.Key("EnrichedMarkdownBlockquoteBarColors")
    /// Present on an admonition's title paragraph; the value is the type's
    /// raw string. The title's head indent reserves the icon column.
    static let admonitionHeader = NSAttributedString.Key("EnrichedMarkdownAdmonitionHeader")
    static let listDepth = NSAttributedString.Key("EnrichedMarkdownListDepth")
    static let listType = NSAttributedString.Key("EnrichedMarkdownListType")
    static let listItemNumber = NSAttributedString.Key("EnrichedMarkdownListItemNumber")
    /// Present on the first paragraph of a GFM task-list item; the value is
    /// the checked state as a boolean.
    static let taskListItem = NSAttributedString.Key("EnrichedMarkdownTaskListItem")
    /// Present on every own paragraph of a GFM task-list item; the value is
    /// the item's 0-based index in document order.
    static let taskListIndex = NSAttributedString.Key("EnrichedMarkdownTaskListIndex")
    /// UTF-8 byte range into the original markdown source that produced this
    /// run (`NSValue`-wrapped `NSRange`; not a range into the rendered
    /// string). Absent when the run's text is not contiguous in the source.
    static let sourceRange = NSAttributedString.Key("EnrichedMarkdownSourceRange")
}

/// Per-render state handed to every `NodeRenderer`: the enclosing block's
/// text style and nesting, and the entry points for rendering nested nodes.
public final class RenderContext {
    private weak var factory: RendererFactory?
    private(set) var currentBlockType: BlockType = .none
    private(set) var currentBlockStyle: BlockStyle?

    /// The enclosing blockquotes, outermost first: each level's admonition
    /// type, or nil for a plain quote.
    private(set) var blockquoteLevels: [AdmonitionType?] = []
    var blockquoteDepth: Int { blockquoteLevels.count }
    var listDepth = 0
    var listType: ListType = .unordered
    var listItemNumber = 0
    var taskItemIndex = 0
    var rendersBlockImage = false
    /// Set while rendering the synthetic paragraph around a bare root-level
    /// plugin block node (see `MarkdownRenderPlugin.rootBlockNodeTypes`).
    var pluginBlockMargins: BlockMargins?
    /// True while a plugin node renders as a block of its own (see
    /// `renderBlock(_:margins:into:)`), false when it sits in running text.
    public var rendersPluginBlock: Bool { pluginBlockMargins != nil }

    private static let blockSpacerTemplate: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        return style
    }()

    init(factory: RendererFactory? = nil) {
        self.factory = factory
    }

    /// Renders `node` as the document would here: the first plugin renderer
    /// claiming it, else the built-in. A renderer must not pass its own node
    /// back unchanged; decline it in `canRender(_:)` instead.
    public func render(_ node: MarkdownASTNode, into output: NSMutableAttributedString) {
        factory?.render(node, into: output, context: self)
    }

    /// Renders `node`'s children in order, as built-in container renderers do.
    public func renderChildren(of node: MarkdownASTNode, into output: NSMutableAttributedString) {
        factory?.renderChildren(of: node, into: output, context: self)
    }

    /// Renders `node` as its own block — on a fresh line, with the paragraph
    /// style's margins overridden by `margins`, and indented like a
    /// paragraph inside lists and quotes. `node`'s renderer runs again inside
    /// with `rendersPluginBlock` true; call this when it is false.
    public func renderBlock(
        _ node: MarkdownASTNode,
        margins: BlockMargins = BlockMargins(),
        into output: NSMutableAttributedString
    ) {
        let previous = pluginBlockMargins
        pluginBlockMargins = margins
        render(MarkdownASTNode(type: .paragraph, children: [node]), into: output)
        pluginBlockMargins = previous
    }

    func reset() {
        currentBlockType = .none
        currentBlockStyle = nil
        blockquoteLevels = []
        listDepth = 0
        listType = .unordered
        listItemNumber = 0
        taskItemIndex = 0
        rendersBlockImage = false
        pluginBlockMargins = nil
    }

    func setBlockStyle(
        font: UIFont,
        color: UIColor,
        blockType: BlockType = .paragraph,
        headingLevel: Int = 0
    ) {
        currentBlockType = blockType
        currentBlockStyle = BlockStyle(font: font, color: color, headingLevel: headingLevel)
    }

    func enterBlockquote(admonition: AdmonitionType?) {
        blockquoteLevels.append(admonition)
    }

    func exitBlockquote() {
        blockquoteLevels.removeLast()
    }

    func clearBlockStyle() {
        currentBlockType = .none
        currentBlockStyle = nil
    }

    package func getBlockStyle() -> BlockStyle? {
        currentBlockStyle
    }

    /// Font and color of the enclosing block's text; inline renderers start
    /// from these.
    public func getTextAttributes() -> [NSAttributedString.Key: Any] {
        guard let blockStyle = currentBlockStyle else {
            return [:]
        }
        return [
            .font: blockStyle.font,
            .foregroundColor: blockStyle.color
        ]
    }

    func spacerStyle(height: CGFloat, spacing: CGFloat = 0) -> NSMutableParagraphStyle {
        guard let style = Self.blockSpacerTemplate.mutableCopy() as? NSMutableParagraphStyle else {
            return NSMutableParagraphStyle()
        }
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.paragraphSpacing = spacing
        return style
    }

    static func shouldPreserveColors(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        MarkdownAttributeValue.sourceLink(in: attributes) != nil || attributes[MarkdownAttribute.inlineCode] != nil
    }

    /// Recolors `range` to `color`, leaving links and inline code on their own colors.
    static func applyForegroundColor(_ color: UIColor, to output: NSMutableAttributedString, in range: NSRange) {
        output.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            guard !shouldPreserveColors(attributes) else { return }
            if (attributes[.foregroundColor] as? UIColor) != color {
                output.addAttribute(.foregroundColor, value: color, range: subrange)
            }
        }
    }

    static func rangeForRenderedContent(in output: NSMutableAttributedString, start: Int) -> NSRange {
        let length = output.length - start
        guard length > 0 else { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: length)
    }

    static func calculateStrongColor(configColor: UIColor?, blockColor: UIColor) -> UIColor? {
        guard let configColor, !configColor.isEqual(blockColor) else {
            return nil
        }
        return configColor
    }
}
