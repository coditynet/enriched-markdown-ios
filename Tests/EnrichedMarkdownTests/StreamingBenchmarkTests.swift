import UIKit
import XCTest
@testable import EnrichedMarkdown

/// Streams a long answer a few characters at a time through both paths and
/// prints the cost per update: a full render and document replacement (what
/// every update cost before streaming support) against the incremental
/// session and tail edit. Render runs off the main thread in the app; apply
/// (text storage update plus the SwiftUI height measurement) on it.
@MainActor
final class StreamingBenchmarkTests: XCTestCase {
    private struct Timings {
        var render: [Double] = []
        var apply: [Double] = []

        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            let mean = values.reduce(0, +) / Double(values.count)
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            return String(format: "mean %6.2f ms  p95 %6.2f ms  max %6.2f ms", mean, p95, sorted.last ?? 0)
        }

        func report(_ label: String) -> String {
            """
            \(label) render: \(summary(render))
            \(label) apply:  \(summary(apply))
            \(label) total:  \(summary(zip(render, apply).map(+)))
            """
        }
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        body()
        return (CACurrentMediaTime() - start) * 1000
    }

    private func makeTextView(width: CGFloat) -> (MarkdownTextView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1000))
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        window.addSubview(textView)
        window.isHidden = false
        return (textView, window)
    }

    func testStreamingLongAnswer() {
        let config = StreamingFixtures.config()
        let markdown = StreamingFixtures.longAnswer(characters: 8000)
        let updates = StreamingFixtures.chunks(of: markdown, sizes: [6, 14, 9, 21, 11, 4, 17])
        let width: CGFloat = 700

        var before = Timings()
        let (fullView, fullWindow) = makeTextView(width: width)
        for prefix in updates {
            var text = NSAttributedString()
            before.render.append(Self.milliseconds {
                text = MarkdownRenderer.render(prefix, config: config)
            })
            before.apply.append(Self.milliseconds {
                fullView.setMarkdownAttributedText(text)
                _ = fullView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            })
        }
        fullWindow.isHidden = true

        var after = Timings()
        let session = StreamingRenderSession(inputs: .init(config: config, flags: .commonMark, imageRequestHeaders: [:], plugins: []))
        let (streamView, streamWindow) = makeTextView(width: width)
        for prefix in updates {
            var result: StreamingRenderSession.Result?
            after.render.append(Self.milliseconds {
                result = session.render(prefix, options: MarkdownStreamingOptions())
            })
            guard let result else { continue }
            after.apply.append(Self.milliseconds {
                streamView.setMarkdownAttributedText(result.text, lineage: result.lineage)
                _ = streamView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            })
        }

        let final = session.render(markdown, options: MarkdownStreamingOptions(), isFinal: true)
        streamView.setMarkdownAttributedText(final.text, lineage: final.lineage)
        let streamedHeight = streamView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let fullHeight = fullView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        streamWindow.isHidden = true

        print("""
        Streaming \(markdown.count) characters in \(updates.count) updates:
        \(before.report("before"))
        \(after.report("after "))
        """)

        XCTAssertTrue(AttributedTextDiff.isEquivalent(final.text, MarkdownRenderer.render(markdown, config: config)))
        XCTAssertTrue(AttributedTextDiff.isEquivalent(streamView.textStorage, fullView.textStorage))
        XCTAssertEqual(streamedHeight, fullHeight, accuracy: 0.5)
    }
}
