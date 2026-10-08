import SwiftUI
import UIKit

/// A rendered document's original markdown paired with the parse flags it
/// was rendered with — one value, so consumers can never pair a source with
/// the wrong flags.
struct RenderedSource: Equatable {
    let markdown: String
    let flags: Md4cFlags
}

@MainActor
final class MarkdownRenderStore: ObservableObject {
    @Published private(set) var attributedText = NSAttributedString()
    // Published together with `attributedText` so consumers never pair a new
    // source with a stale render result.
    @Published private(set) var source: RenderedSource?
    /// Set while streaming: lets the view apply `attributedText` as an edit
    /// of the previous one (see `StreamingLineage`).
    @Published private(set) var lineage: StreamingLineage?

    /// The caller's markdown as last scheduled. A schedule for the same base
    /// re-renders `currentMarkdown` instead — toggles survive style/flag
    /// re-renders — while a new base always wins.
    private var baseMarkdown: String?

    /// `baseMarkdown` plus any checkbox toggles applied since, tracked
    /// synchronously (unlike `source`, which waits for the render).
    private var currentMarkdown: String?

    /// Ordinals (see `SpoilerInteraction.spoilerRanges`) of spoilers revealed
    /// since the markdown last changed. Re-applied after a re-render of the
    /// same source (a theme change, say) so a revealed spoiler does not snap
    /// shut; a new source starts concealed.
    private var revealedSpoilers: Set<Int> = []

    private let coordinator = AsyncRenderCoordinator()

    /// The incremental renderer of the current stream, and the inputs it
    /// renders with — any other input change starts a new session.
    private var streamingSession: StreamingRenderSession?
    private var streamingSessionKey: StreamingSessionKey?

    func schedule(
        markdown: String,
        config: MarkdownStyleConfig,
        flags: Md4cFlags = .commonMark,
        imageRequestHeaders: [String: String] = [:],
        plugins: [any MarkdownRenderPlugin] = [],
        streaming: MarkdownStreamingOptions? = nil
    ) {
        if isBlank(markdown) {
            coordinator.invalidate()
            attributedText = NSAttributedString()
            source = nil
            lineage = nil
            baseMarkdown = nil
            currentMarkdown = nil
            revealedSpoilers = []
            if streaming == nil {
                streamingSession = nil
                streamingSessionKey = nil
            }
            return
        }
        let resolved = markdown == baseMarkdown ? (currentMarkdown ?? markdown) : markdown
        if markdown != baseMarkdown {
            revealedSpoilers = []
        }
        baseMarkdown = markdown
        currentMarkdown = resolved
        // render adjusts the flags itself; the source keeps the adjusted ones for copying.
        let effectiveFlags = MarkdownRenderer.effectiveFlags(flags, plugins: plugins)
        let inputs = StreamingRenderSession.Inputs(
            config: config,
            flags: flags,
            imageRequestHeaders: imageRequestHeaders,
            plugins: plugins
        )
        let sessionKey = StreamingSessionKey(inputs)

        if let streaming {
            if streamingSession == nil || streamingSessionKey != sessionKey {
                streamingSession = StreamingRenderSession(inputs: inputs)
                streamingSessionKey = sessionKey
            }
            scheduleStreamingRender(resolved, options: streaming, flags: effectiveFlags)
            return
        }

        if let session = streamingSession {
            streamingSession = nil
            let sameInputs = streamingSessionKey == sessionKey
            streamingSessionKey = nil
            if sameInputs {
                scheduleFinalStreamingRender(resolved, session: session, inputs: inputs, flags: effectiveFlags)
                return
            }
        }

        coordinator.scheduleRender {
            MarkdownRenderer.render(
                resolved,
                config: config,
                flags: flags,
                imageRequestHeaders: imageRequestHeaders,
                plugins: plugins
            )
        } apply: { [weak self] result in
            guard let self else { return }
            attributedText = SpoilerInteraction.revealing(in: result, ordinals: revealedSpoilers) ?? result
            source = RenderedSource(markdown: resolved, flags: effectiveFlags)
            lineage = nil
        }
    }

    private func scheduleStreamingRender(_ markdown: String, options: MarkdownStreamingOptions, flags: Md4cFlags) {
        guard let session = streamingSession else { return }
        coordinator.scheduleRender {
            session.render(markdown, options: options)
        } applying: { [weak self] result in
            self?.publish(result, flags: flags)
        }
    }

    /// The last update of a stream renders the markdown as written. It is
    /// checked against a plain render — the guarantee that a streamed answer
    /// ends exactly as a non-streamed one — and kept as an edit of the
    /// streamed text when they match, so the view does not rebuild.
    private func scheduleFinalStreamingRender(
        _ markdown: String,
        session: StreamingRenderSession,
        inputs: StreamingRenderSession.Inputs,
        flags: Md4cFlags
    ) {
        coordinator.scheduleRender {
            let streamed = session.render(markdown, options: MarkdownStreamingOptions(), isFinal: true)
            let full = MarkdownRenderer.render(
                markdown,
                config: inputs.config,
                flags: inputs.flags,
                imageRequestHeaders: inputs.imageRequestHeaders,
                plugins: inputs.plugins
            )
            if AttributedTextDiff.isEquivalent(streamed.text, full) {
                return streamed
            }
            return StreamingRenderSession.Result(text: full, source: markdown, lineage: nil)
        } applying: { [weak self] result in
            self?.publish(result, flags: flags)
        }
    }

    private func publish(_ result: StreamingRenderSession.Result, flags: Md4cFlags) {
        if revealedSpoilers.isEmpty {
            attributedText = result.text
            lineage = result.lineage
        } else {
            // Revealing rewrites runs anywhere in the document.
            attributedText = SpoilerInteraction.revealing(in: result.text, ordinals: revealedSpoilers) ?? result.text
            lineage = nil
        }
        source = RenderedSource(markdown: result.source, flags: flags)
    }

    /// Shows the concealed spoiler covering `range` in place.
    func revealSpoiler(in range: NSRange) {
        guard let ordinal = SpoilerInteraction.spoilerRanges(in: attributedText)
            .firstIndex(where: { NSLocationInRange(range.location, $0) }),
            let revealed = SpoilerInteraction.revealing(in: attributedText, ordinals: [ordinal])
        else { return }
        attributedText = revealed
        lineage = nil
        revealedSpoilers.insert(ordinal)
    }

    /// Flips one task item's checked state in place: rendered text and
    /// tracked source, no re-parse. Drops any in-flight render so a stale
    /// result can't revert the toggle.
    func applyTaskListToggle(index: Int, checked: Bool, config: MarkdownStyleConfig) {
        guard let toggled = TaskListInteraction.togglingItem(
            in: attributedText,
            index: index,
            checked: checked,
            config: config
        ) else { return }

        coordinator.invalidate()
        attributedText = toggled
        lineage = nil
        if let markdown = currentMarkdown {
            let updatedSource = TaskListInteraction.togglingSource(markdown, index: index, checked: checked)
            currentMarkdown = updatedSource
            if let flags = source?.flags {
                source = RenderedSource(markdown: updatedSource, flags: flags)
            }
        }
    }

    func invalidate() {
        coordinator.invalidate()
    }

    private func isBlank(_ markdown: String) -> Bool {
        markdown.isEmpty || markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The render inputs a streaming session is bound to, besides the markdown.
private struct StreamingSessionKey: Equatable {
    let config: MarkdownStyleConfig
    let flags: Md4cFlags
    let imageRequestHeaders: [String: String]
    let pluginTypes: [ObjectIdentifier]

    init(_ inputs: StreamingRenderSession.Inputs) {
        config = inputs.config
        flags = inputs.flags
        imageRequestHeaders = inputs.imageRequestHeaders
        pluginTypes = inputs.plugins.map { ObjectIdentifier(type(of: $0)) }
    }
}
