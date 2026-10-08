import UIKit
import XCTest
@testable import EnrichedMarkdown

final class StreamingRenderSessionTests: XCTestCase {
    private var config: MarkdownStyleConfig!

    override func setUp() {
        super.setUp()
        config = StreamingFixtures.config()
    }

    private func makeSession(flags: Md4cFlags = .commonMark) -> StreamingRenderSession {
        StreamingRenderSession(inputs: .init(config: config, flags: flags, imageRequestHeaders: [:], plugins: []))
    }

    private func fullRender(_ markdown: String, flags: Md4cFlags = .commonMark) -> NSAttributedString {
        MarkdownRenderer.render(markdown, config: config, flags: flags)
    }

    private func assertEquivalent(
        _ lhs: NSAttributedString,
        _ rhs: NSAttributedString,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !AttributedTextDiff.isEquivalent(lhs, rhs) else { return }
        let diff = AttributedTextDiff(from: lhs, to: rhs)
        XCTFail(
            "\(message): differs at \(diff.replacedRange) — \(lhs.string.debugDescription) vs \(rhs.string.debugDescription)",
            file: file,
            line: line
        )
    }

    /// The core invariant: rendering the blocks of a document in runs, as
    /// streaming does, matches rendering it whole — at every point of the
    /// stream, not just the end.
    func testEveryPrefixRendersAsTheWholeDocumentWould() {
        let session = makeSession()
        for prefix in StreamingFixtures.chunks(of: StreamingFixtures.answer) {
            let streamed = session.render(prefix, options: MarkdownStreamingOptions(), isFinal: true)
            assertEquivalent(streamed.text, fullRender(prefix), "prefix of \(prefix.count) characters")
            XCTAssertEqual(streamed.source, prefix)
        }
    }

    func testStreamEndsIdenticalToANonStreamedRender() {
        let session = makeSession()
        let markdown = StreamingFixtures.answer
        for prefix in StreamingFixtures.chunks(of: markdown) {
            _ = session.render(prefix, options: MarkdownStreamingOptions())
        }
        let final = session.render(markdown, options: MarkdownStreamingOptions(), isFinal: true)
        assertEquivalent(final.text, fullRender(markdown), "final render")
    }

    func testFinishedBlocksAreKeptAcrossUpdates() {
        let session = makeSession()
        var previous: StreamingRenderSession.Result?
        var sawStableBlocks = false
        for prefix in StreamingFixtures.chunks(of: StreamingFixtures.answer) {
            let result = session.render(prefix, options: MarkdownStreamingOptions())
            guard let lineage = result.lineage else { return XCTFail("streaming results carry a lineage") }
            if let previous, let previousLineage = previous.lineage {
                XCTAssertEqual(lineage.session, previousLineage.session, "one session for an extending stream")
                XCTAssertGreaterThanOrEqual(lineage.stableLength, previousLineage.stableLength)
                let stable = NSRange(location: 0, length: previousLineage.stableLength)
                XCTAssertTrue(
                    result.text.attributedSubstring(from: stable).isEqual(previous.text.attributedSubstring(from: stable)),
                    "finished blocks never change"
                )
            }
            sawStableBlocks = sawStableBlocks || lineage.stableLength > 0
            previous = result
        }
        XCTAssertTrue(sawStableBlocks)
    }

    func testUnfinishedSyntaxNeverShowsRaw() {
        let session = makeSession()
        let result = session.render("Intro\n\nThis is **bold and `co", options: MarkdownStreamingOptions())
        XCTAssertEqual(result.text.string.trimmingCharacters(in: .newlines), "Intro\nThis is bold and co")
    }

    /// The fixture's final render holds none of these characters, so any
    /// one showing mid-stream is syntax flashing raw.
    func testNoPrefixShowsRawSyntax() {
        let session = makeSession()
        for prefix in StreamingFixtures.chunks(of: StreamingFixtures.answer, sizes: [1]) {
            let text = session.render(prefix, options: MarkdownStreamingOptions()).text.string
            for syntax in ["**", "`", "~~", "[", "]", "|", "\n-\n", "\n=\n"] {
                XCTAssertFalse(text.contains(syntax), "\(syntax.debugDescription) shows raw after \(prefix.suffix(30).debugDescription)")
            }
        }
    }

    func testHiddenTableAppearsWhenComplete() {
        let session = makeSession()
        let options = MarkdownStreamingOptions(tables: .hidden)
        let table = "| A | B |\n|---|---|\n| 1 | 2 |"
        let partial = session.render("Intro\n\n" + table, options: options)
        XCTAssertFalse(containsTable(partial.text))
        let complete = session.render("Intro\n\n" + table + "\n\nAfter", options: options)
        XCTAssertTrue(containsTable(complete.text))
    }

    func testMarkdownThatDoesNotExtendStartsANewLineage() {
        let session = makeSession()
        let first = session.render("First answer.\n\nSecond paragraph", options: MarkdownStreamingOptions())
        let second = session.render("A different answer", options: MarkdownStreamingOptions())
        XCTAssertNotEqual(first.lineage?.session, second.lineage?.session)
        assertEquivalent(
            session.render("A different answer", options: MarkdownStreamingOptions(), isFinal: true).text,
            fullRender("A different answer"),
            "after a restart"
        )
    }

    /// A reference definition resolves links in earlier blocks, so those
    /// cannot render on their own.
    func testLinkReferenceDefinitionsRenderWhole() {
        let session = makeSession()
        let markdown = "See [the docs][docs].\n\nMore text.\n\n[docs]: https://example.com"
        for prefix in StreamingFixtures.chunks(of: markdown) {
            _ = session.render(prefix, options: MarkdownStreamingOptions())
        }
        let final = session.render(markdown, options: MarkdownStreamingOptions(), isFinal: true)
        assertEquivalent(final.text, fullRender(markdown), "reference links")
    }

    func testSourceRangesIndexTheWholeDocument() {
        let session = makeSession()
        let markdown = "First paragraph.\n\nSecond **bold** one."
        let result = session.render(markdown, options: MarkdownStreamingOptions(), isFinal: true)
        let boldLocation = (result.text.string as NSString).range(of: "bold").location
        let value = result.text.attribute(MarkdownAttribute.sourceRange, at: boldLocation, effectiveRange: nil) as? NSValue
        let byteRange = try? XCTUnwrap(value).rangeValue
        let expected = (markdown as NSString).range(of: "bold").location
        XCTAssertEqual(byteRange?.location, expected)
    }

    private func containsTable(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value is TableAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}

@MainActor
final class StreamingRenderStoreTests: XCTestCase {
    private let config = StreamingFixtures.config()

    private func waitForSource(_ store: MarkdownRenderStore, _ markdown: String) {
        let applied = expectation(description: "render applied")
        let cancellable = store.$source
            .filter { $0?.markdown == markdown }
            .sink { _ in applied.fulfill() }
        wait(for: [applied], timeout: 5)
        cancellable.cancel()
    }

    func testStreamPublishesLineageAndEndsAsAPlainRender() {
        let store = MarkdownRenderStore()
        let markdown = StreamingFixtures.answer
        let prefix = String(markdown.prefix(600))
        store.schedule(markdown: prefix, config: config, streaming: MarkdownStreamingOptions())
        let streamed = expectation(description: "streamed render applied")
        let cancellable = store.$lineage.compactMap { $0 }.sink { _ in streamed.fulfill() }
        wait(for: [streamed], timeout: 5)
        cancellable.cancel()
        let streamingSession = store.lineage?.session

        store.schedule(markdown: markdown, config: config)
        waitForSource(store, markdown)

        XCTAssertTrue(AttributedTextDiff.isEquivalent(store.attributedText, MarkdownRenderer.render(markdown, config: config)))
        // Kept as an edit of the streamed text rather than a new document.
        XCTAssertEqual(store.lineage?.session, streamingSession)
    }
}
