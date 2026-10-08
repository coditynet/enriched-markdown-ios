import EnrichedMarkdown
import UIKit
import XCTest

// Written against the public API only (no @testable import), the way an app
// writes a plugin.

final class DemoAttachment: NSTextAttachment, MarkdownPluginAttachment {
    let code: String
    let isBlock: Bool

    init(code: String, isBlock: Bool) {
        self.code = code
        self.isBlock = isBlock
        super.init(data: nil, ofType: nil)
        accessibilityLabel = "Demo"
        bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func markdownText() -> String {
        "```demo\n" + code + "```"
    }

    var literalText: String { code }

    var sourceDelimiters: (opening: String, closing: String)? {
        ("```demo", "```")
    }
}

/// Claims fenced code blocks tagged `demo` and renders each as a block
/// attachment; every other code block falls through to the built-in.
final class DemoCodeBlockRenderer: NodeRenderer {
    func canRender(_ node: MarkdownASTNode) -> Bool {
        node.attribute("language") == "demo"
    }

    func render(node: MarkdownASTNode, into output: NSMutableAttributedString, context: RenderContext) {
        guard context.rendersPluginBlock else {
            context.renderBlock(node, margins: BlockMargins(marginBottom: 12), into: output)
            return
        }
        var attributes = context.getTextAttributes()
        attributes[.attachment] = DemoAttachment(code: node.flattenedText(), isBlock: true)
        SourceOffsetAnnotator.tagSourceRange(in: &attributes, of: node)
        output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
    }
}

/// Renders `> [!MERKE]` admonitions as a titled quote.
final class MerkeRenderer: NodeRenderer {
    func canRender(_ node: MarkdownASTNode) -> Bool {
        node.attribute("admonitionType")?.lowercased() == "merke"
    }

    func render(node: MarkdownASTNode, into output: NSMutableAttributedString, context: RenderContext) {
        let title = MarkdownASTNode(type: .paragraph, children: [
            MarkdownASTNode(type: .strong, children: [MarkdownASTNode(type: .text, content: "Merke")])
        ])
        context.render(MarkdownASTNode(type: .blockquote, children: [title] + node.children), into: output)
    }
}

struct DemoPlugin: MarkdownRenderPlugin {
    func renderer(for type: NodeType, config: MarkdownStyleConfig) -> NodeRenderer? {
        switch type {
        case .codeBlock: return DemoCodeBlockRenderer()
        case .admonition: return MerkeRenderer()
        default: return nil
        }
    }

    func adjustFlags(_ flags: inout Md4cFlags) {
        flags.admonitions = true
    }
}

final class PublicRenderPluginTests: XCTestCase {
    private func render(_ markdown: String, plugins: [any MarkdownRenderPlugin] = [DemoPlugin()]) -> NSAttributedString {
        MarkdownRenderer.render(
            markdown,
            config: .baseline(),
            flags: .commonMark,
            imageRequestHeaders: [:],
            plugins: plugins
        )
    }

    private func demoAttachments(in rendered: NSAttributedString) -> [DemoAttachment] {
        var found: [DemoAttachment] = []
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let attachment = value as? DemoAttachment {
                found.append(attachment)
            }
        }
        return found
    }

    func testParserExposesCodeBlockInfoString() {
        let codeBlock = Parser.shared.parseMarkdown("```demo size=2\nx\n```").first(ofType: .codeBlock)
        XCTAssertEqual(codeBlock?.attribute("language"), "demo")
        XCTAssertEqual(codeBlock?.attribute("info"), "demo size=2")
    }

    func testPluginClaimsDemoCodeBlocks() {
        let rendered = render("before\n\n```demo\nhello\n```\n\nafter")

        let attachments = demoAttachments(in: rendered)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.code, "hello\n")
        XCTAssertFalse(rendered.string.contains("hello"))
        XCTAssertTrue(rendered.string.contains("before"))
        XCTAssertTrue(rendered.string.contains("after"))

        let index = (rendered.string as NSString).range(of: "\u{FFFC}").location
        let style = rendered.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacing, 12)
    }

    func testOtherCodeBlocksUseBuiltInRenderer() {
        let source = "```swift\nlet x = 1\n```\n\n```\nplain\n```\n\n```demo\nhello\n```"
        let withPlugin = render(source)
        let withoutPlugin = render(source, plugins: [])

        XCTAssertEqual(demoAttachments(in: withPlugin).count, 1)
        for code in ["let x = 1", "plain"] {
            let range = (withPlugin.string as NSString).range(of: code)
            XCTAssertNotEqual(range.location, NSNotFound, code)
            let font = withPlugin.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            let builtInRange = (withoutPlugin.string as NSString).range(of: code)
            let builtInFont = withoutPlugin.attribute(.font, at: builtInRange.location, effectiveRange: nil) as? UIFont
            XCTAssertEqual(font, builtInFont, code)
        }
    }

    func testDemoBlockInsideListAndQuoteRendersAsAttachment() {
        XCTAssertEqual(demoAttachments(in: render("- item\n\n  ```demo\n  a\n  ```")).count, 1)
        XCTAssertEqual(demoAttachments(in: render("> ```demo\n> a\n> ```")).count, 1)
    }

    func testCustomAdmonitionReachesPlugin() {
        let admonition = Parser.shared.parseMarkdown("> [!MERKE]\n> body", flags: Md4cFlags(admonitions: true))
            .first(ofType: .admonition)
        XCTAssertEqual(admonition?.attribute("admonitionType"), "MERKE")

        let rendered = render("> [!MERKE]\n> body")
        XCTAssertTrue(rendered.string.hasPrefix("Merke\nbody"), rendered.string)
    }

    func testUnclaimedCustomAdmonitionRendersAsPlainQuote() {
        let rendered = MarkdownRenderer.render("> [!FOO]\n> body", config: .baseline(), flags: Md4cFlags(admonitions: true))
        XCTAssertTrue(rendered.string.hasPrefix("[!FOO]\nbody"), rendered.string)
    }

    func testGitHubAlertsStillUseBuiltIns() {
        let rendered = render("> [!NOTE]\n> body")
        XCTAssertTrue(rendered.string.hasPrefix("Note\nbody"), rendered.string)
    }
}
