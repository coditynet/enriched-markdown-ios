import XCTest
@testable import EnrichedMarkdown

final class StreamingBlockSplitterTests: XCTestCase {
    private func lastCut(_ markdown: String) -> String? {
        StreamingBlockSplitter.scan(markdown.utf8).lastCut.map {
            String(decoding: Array(markdown.utf8)[$0...], as: UTF8.self)
        }
    }

    func testCutsBeforeABlockAfterABlankLine() {
        XCTAssertEqual(lastCut("# Title\n\nFirst paragraph.\n\nSecond"), "Second")
        XCTAssertEqual(lastCut("Para\n\n| A |"), "| A |")
        XCTAssertEqual(lastCut("Para\n\n```swift\ncode"), "```swift\ncode")
    }

    func testNoCutWithoutABlankLine() {
        XCTAssertNil(lastCut("Line one\nLine two"))
        XCTAssertNil(lastCut("Only a paragraph"))
    }

    /// The next item of a list, indented content, or anything that could
    /// still turn into one continues the block before.
    func testNoCutBeforeWhatMayContinueTheBlockBefore() {
        XCTAssertNil(lastCut("- one\n\n- two"))
        XCTAssertNil(lastCut("1. one\n\n2"))
        XCTAssertNil(lastCut("- one\n\n  continued"))
        XCTAssertNil(lastCut("Para\n\n    indented code"))
        XCTAssertEqual(lastCut("- one\n\nAfter the list"), "After the list")
    }

    func testNoCutInsideAFence() {
        XCTAssertNil(lastCut("```\ncode\n\nmore code"))
        XCTAssertEqual(lastCut("```\ncode\n\nmore\n```\n\nAfter"), "After")
    }

    func testRawHTMLStopsCutting() {
        XCTAssertEqual(lastCut("A\n\nB\n\n<!-- note\n\nC"), "B\n\n<!-- note\n\nC")
    }

    func testLinkReferenceDefinitionIsReported() {
        XCTAssertTrue(StreamingBlockSplitter.scan("See [x].\n\n[x]: https://example.com".utf8).hasLinkReferenceDefinition)
        XCTAssertFalse(StreamingBlockSplitter.scan("See [x](https://example.com).".utf8).hasLinkReferenceDefinition)
    }
}
