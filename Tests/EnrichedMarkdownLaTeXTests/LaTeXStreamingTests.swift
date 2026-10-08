import UIKit
import XCTest
@testable import EnrichedMarkdown
@testable import EnrichedMarkdownLaTeX

final class LaTeXStreamingTests: XCTestCase {
    private let markdown = """
    Die Fläche eines Kreises ist $A = \\pi r^2$, sein Umfang $U = 2\\pi r$.

    $$
    \\int_0^1 x^2 \\, dx = \\frac{1}{3}
    $$

    Ein Heft kostet 3$ und ein Stift 2 $ pro Stück.

    Für $x_1 = 2$ gilt $$x_1^2 = 4$$ — fertig.
    """

    private func makeSession(config: MarkdownStyleConfig) -> StreamingRenderSession {
        StreamingRenderSession(inputs: .init(
            config: config,
            flags: .commonMark,
            imageRequestHeaders: [:],
            plugins: [LaTeXRenderPlugin()]
        ))
    }

    func testStreamedMathEndsIdenticalToANonStreamedRender() {
        let config = MarkdownStyleConfig.baseline()
        let session = makeSession(config: config)
        var index = markdown.startIndex
        while index < markdown.endIndex {
            index = markdown.index(index, offsetBy: 4, limitedBy: markdown.endIndex) ?? markdown.endIndex
            let prefix = String(markdown[..<index])
            let streamed = session.render(prefix, options: MarkdownStreamingOptions(), isFinal: true)
            let full = MarkdownRenderer.render(
                prefix,
                config: config,
                flags: .commonMark,
                imageRequestHeaders: [:],
                plugins: [LaTeXRenderPlugin()]
            )
            XCTAssertTrue(AttributedTextDiff.isEquivalent(streamed.text, full), "prefix \(prefix.debugDescription)")
        }
    }

    /// Half-written LaTeX never reaches the typesetter: no `$` and no
    /// partial formula shows.
    func testUnclosedMathStaysHidden() {
        let session = makeSession(config: .baseline())
        let inline = session.render("Die Fläche ist $A = \\pi r^", options: MarkdownStreamingOptions())
        XCTAssertEqual(inline.text.string.trimmingCharacters(in: .whitespacesAndNewlines), "Die Fläche ist")
        let block = session.render("Die Fläche ist\n\n$$\n\\int_0^1 x", options: MarkdownStreamingOptions())
        XCTAssertFalse(block.text.string.contains("$"))
        XCTAssertFalse(block.text.string.contains("int"))
    }

    func testPricesStayText() {
        let session = makeSession(config: .baseline())
        let result = session.render("Ein Heft kostet 3$ und ein Stift 2 $ pro", options: MarkdownStreamingOptions())
        XCTAssertTrue(result.text.string.contains("3$ und ein Stift 2 $ pro"))
    }
}
