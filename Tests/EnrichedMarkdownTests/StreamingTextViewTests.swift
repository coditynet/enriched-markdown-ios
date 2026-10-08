import UIKit
import XCTest
@testable import EnrichedMarkdown

@MainActor
final class StreamingTextViewTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func makeTextView() -> MarkdownTextView {
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 600, height: 2000)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 2000))
        window.addSubview(textView)
        window.isHidden = false
        self.window = window
        return textView
    }

    private func makeSession() -> StreamingRenderSession {
        StreamingRenderSession(inputs: .init(
            config: StreamingFixtures.config(),
            flags: .commonMark,
            imageRequestHeaders: [:],
            plugins: []
        ))
    }

    /// TextKit normalizes what it stores (attribute-less newlines gain a
    /// default paragraph style), so the reference is the same text assigned
    /// whole, not the rendered string itself.
    func testStreamingEditsMatchAssigningTheWholeText() {
        let textView = makeTextView()
        let reference = MarkdownTextView()
        let session = makeSession()
        for prefix in StreamingFixtures.chunks(of: StreamingFixtures.answer) {
            let result = session.render(prefix, options: MarkdownStreamingOptions())
            textView.setMarkdownAttributedText(result.text, lineage: result.lineage)
            reference.setMarkdownAttributedText(result.text)
            XCTAssertTrue(
                AttributedTextDiff.isEquivalent(textView.textStorage, reference.textStorage),
                "storage diverged after \(prefix.suffix(20).debugDescription)"
            )
        }
    }

    func testStreamingEditsReplaceOnlyTheTail() {
        let textView = makeTextView()
        let session = makeSession()
        let first = session.render("First paragraph.\n\nSecond paragraph", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(first.text, lineage: first.lineage)

        let storage = textView.textStorage
        var edits: [NSRange] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                edits.append(storage.editedRange)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let second = session.render("First paragraph.\n\nSecond paragraph grows", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(second.text, lineage: second.lineage)

        let firstParagraphEnd = (second.text.string as NSString).range(of: "Second").location
        XCTAssertEqual(edits.count, 1)
        XCTAssertGreaterThanOrEqual(edits.first?.location ?? 0, firstParagraphEnd)
    }

    func testSelectionSurvivesStreamingEdits() {
        let textView = makeTextView()
        let session = makeSession()
        let first = session.render("First paragraph.\n\nSecond", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(first.text, lineage: first.lineage)
        _ = textView.becomeFirstResponder()
        let selection = (first.text.string as NSString).range(of: "First")
        textView.selectedRange = selection

        let second = session.render("First paragraph.\n\nSecond paragraph and more", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(second.text, lineage: second.lineage)

        XCTAssertEqual(textView.selectedRange, selection)
    }

    func testFadeLeavesTheTextStorageAlone() {
        let textView = makeTextView()
        let session = makeSession()
        let first = session.render("Hello", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(first.text, lineage: first.lineage, fadesIn: true)
        let second = session.render("Hello world, this is new", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(second.text, lineage: second.lineage, fadesIn: true)

        // Text-storage colors are the real ones; the fade is drawing-only.
        let newText = (second.text.string as NSString).range(of: "this is new")
        let storageColor = textView.textStorage.attribute(.foregroundColor, at: newText.location, effectiveRange: nil)
        let renderedColor = second.text.attribute(.foregroundColor, at: newText.location, effectiveRange: nil)
        XCTAssertEqual(storageColor as? UIColor, renderedColor as? UIColor)
    }

    /// The fade must reach the screen: freshly streamed text starts
    /// invisible and ends fully drawn.
    func testFadedTextIsDrawnTransparentThenOpaque() {
        let textView = makeTextView()
        let session = makeSession()
        let first = session.render("Hello", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(first.text, lineage: first.lineage)
        let second = session.render("Hello WWWWWWWW", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(second.text, lineage: second.lineage, fadesIn: true)
        textView.layoutIfNeeded()

        let tail = (second.text.string as NSString).range(of: "WWWWWWWW")
        guard let start = textView.position(from: textView.beginningOfDocument, offset: tail.location),
              let end = textView.position(from: start, offset: tail.length),
              let range = textView.textRange(from: start, to: end)
        else { return XCTFail("no text range") }
        let tailRect = textView.firstRect(for: range).insetBy(dx: 1, dy: 1)

        XCTAssertLessThan(darkPixelCount(in: textView, rect: tailRect), 5, "new text starts transparent")
        let helloRect = CGRect(x: 0, y: tailRect.minY, width: tailRect.minX - 4, height: tailRect.height)
        XCTAssertGreaterThan(darkPixelCount(in: textView, rect: helloRect), 20, "earlier text stays drawn")

        RunLoop.main.run(until: Date().addingTimeInterval(TailFadeAnimator.duration + 0.15))
        XCTAssertGreaterThan(darkPixelCount(in: textView, rect: tailRect), 20, "new text ends drawn")
    }

    private func darkPixelCount(in view: UIView, rect: CGRect) -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { context in
            UIColor.white.setFill()
            context.fill(rect)
            view.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return 0 }
        var count = 0
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                if Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) < 300 {
                    count += 1
                }
            }
        }
        return count
    }

    func testTextWithoutLineageReplacesTheDocument() {
        let textView = makeTextView()
        let session = makeSession()
        let streamed = session.render("Streamed **answer", options: MarkdownStreamingOptions())
        textView.setMarkdownAttributedText(streamed.text, lineage: streamed.lineage)

        let plain = MarkdownRenderer.render("Something else", config: StreamingFixtures.config())
        textView.setMarkdownAttributedText(plain)
        XCTAssertEqual(textView.textStorage.string, plain.string)
    }
}

final class AttributedTextDiffTests: XCTestCase {
    func testAppendIsAnInsertion() {
        let old = NSAttributedString(string: "Hello wor\n")
        let new = NSAttributedString(string: "Hello world\n")
        let diff = AttributedTextDiff(from: old, to: new)
        XCTAssertEqual(diff.replacedRange, NSRange(location: 9, length: 0))
        XCTAssertEqual(diff.replacementRange, NSRange(location: 9, length: 2))
        XCTAssertEqual(diff.insertedRange, NSRange(location: 9, length: 2))
    }

    func testRestyledTextIsReplacedButNotInserted() {
        let old = NSAttributedString(string: "plain text")
        let new = NSMutableAttributedString(string: "plain text")
        new.addAttribute(.foregroundColor, value: UIColor.red, range: NSRange(location: 6, length: 4))
        let diff = AttributedTextDiff(from: old, to: new)
        XCTAssertEqual(diff.replacedRange, NSRange(location: 6, length: 4))
        XCTAssertEqual(diff.insertedRange.length, 0)
    }

    func testEqualTextIsEmpty() {
        let text = NSAttributedString(string: "same", attributes: [.font: UIFont.systemFont(ofSize: 14)])
        XCTAssertTrue(AttributedTextDiff(from: text, to: NSAttributedString(attributedString: text)).isEmpty)
    }

    func testRerenderedAttachmentsCompareByContent() {
        let config = StreamingFixtures.config()
        let markdown = "| A | B |\n|---|---|\n| 1 | 2 |"
        let first = MarkdownRenderer.render(markdown, config: config)
        let second = MarkdownRenderer.render(markdown, config: config)
        XCTAssertTrue(AttributedTextDiff.isEquivalent(first, second))
        let changed = MarkdownRenderer.render(markdown + "\n| 3 | 4 |", config: config)
        XCTAssertFalse(AttributedTextDiff.isEquivalent(first, changed))
    }
}
