import UIKit

/// Fades newly streamed text in where it lands. Text fades through TextKit 2
/// rendering attributes — drawing-only overrides that leave the text storage
/// untouched, so selection, links, copy, and VoiceOver see the real text
/// throughout and no layout is redone per frame. Attachment views (tables,
/// math) fade through their alpha.
///
/// Each update starts its own fade and earlier ones keep running, so text
/// arriving faster than the fade lasts still fades fully instead of popping.
@MainActor
final class TailFadeAnimator {
    static let duration: CFTimeInterval = 0.2

    private struct Fade {
        let start: CFTimeInterval
        /// The faded runs and their real colors.
        var runs: [(range: NSRange, color: UIColor)]
    }

    private weak var textView: UITextView?
    private var fades: [Fade] = []
    private var displayLink: CADisplayLink?
    /// Attachments whose views should fade in once TextKit installs them.
    private var pendingAttachments: Set<ObjectIdentifier> = []

    init(textView: UITextView) {
        self.textView = textView
    }

    var isAnimating: Bool { !fades.isEmpty }

    /// Fades `range` of the text view's (already updated) text in.
    func fadeIn(_ range: NSRange) {
        guard range.length > 0, !UIAccessibility.isReduceMotionEnabled,
              let textView, textView.textLayoutManager != nil
        else { return }
        let storage = textView.textStorage
        guard NSMaxRange(range) <= storage.length else { return }

        var runs: [(range: NSRange, color: UIColor)] = []
        storage.enumerateAttributes(in: range) { attributes, runRange, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                pendingAttachments.insert(ObjectIdentifier(attachment))
                return
            }
            let color = attributes[.foregroundColor] as? UIColor ?? .label
            runs.append((runRange, color))
        }
        fades.append(Fade(start: CACurrentMediaTime(), runs: runs))
        apply(progress: 0, to: runs)
        redraw(runs)
        startDisplayLink()
    }

    /// The text from `location` on was replaced: fades of the old text there
    /// no longer apply.
    func textDidChange(from location: Int) {
        guard !fades.isEmpty else { return }
        for index in fades.indices {
            fades[index].runs = fades[index].runs.compactMap { run in
                guard run.range.location < location else { return nil }
                let end = min(NSMaxRange(run.range), location)
                return (NSRange(location: run.range.location, length: end - run.range.location), run.color)
            }
        }
        fades.removeAll { $0.runs.isEmpty }
        if let textView, let textLayoutManager = textView.textLayoutManager, location < textView.textStorage.length {
            let tail = NSRange(location: location, length: textView.textStorage.length - location)
            if let textRange = textRange(for: tail, in: textLayoutManager) {
                textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
            }
        }
        if fades.isEmpty {
            stopDisplayLink()
        }
    }

    /// Ends every fade at full opacity.
    func finish() {
        for fade in fades {
            clear(fade.runs)
            redraw(fade.runs)
        }
        fades.removeAll()
        pendingAttachments.removeAll()
        stopDisplayLink()
    }

    /// Called from the text view's layout pass, once attachment views exist.
    func fadeInstalledAttachmentViews() {
        guard !pendingAttachments.isEmpty, let textLayoutManager = textView?.textLayoutManager else { return }
        textLayoutManager.enumerateTextLayoutFragments(from: textLayoutManager.documentRange.location) { fragment in
            for provider in fragment.textAttachmentViewProviders {
                guard let attachment = provider.textAttachment,
                      pendingAttachments.remove(ObjectIdentifier(attachment)) != nil,
                      let view = provider.view
                else { continue }
                view.alpha = 0
                UIView.animate(withDuration: Self.duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    view.alpha = 1
                }
            }
            return !self.pendingAttachments.isEmpty
        }
        // An attachment never laid out (the provider-less ones draw as
        // images) has nothing to fade.
        pendingAttachments.removeAll()
    }

    // MARK: - Frames

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func step() {
        let now = CACurrentMediaTime()
        var changed: [(range: NSRange, color: UIColor)] = []
        fades.removeAll { fade in
            changed += fade.runs
            let progress = min((now - fade.start) / Self.duration, 1)
            if progress >= 1 {
                clear(fade.runs)
                return true
            }
            apply(progress: progress, to: fade.runs)
            return false
        }
        redraw(changed)
        if fades.isEmpty {
            stopDisplayLink()
        }
    }

    private func apply(progress: Double, to runs: [(range: NSRange, color: UIColor)]) {
        guard let textLayoutManager = textView?.textLayoutManager else { return }
        // Ease out: quick to become legible, gentle at the end.
        let eased = 1 - (1 - progress) * (1 - progress)
        for run in runs {
            guard let textRange = textRange(for: run.range, in: textLayoutManager) else { continue }
            var alpha: CGFloat = 0
            run.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            textLayoutManager.addRenderingAttribute(
                .foregroundColor,
                value: run.color.withAlphaComponent(alpha * eased),
                for: textRange
            )
        }
    }

    private func clear(_ runs: [(range: NSRange, color: UIColor)]) {
        guard let textLayoutManager = textView?.textLayoutManager else { return }
        for run in runs {
            guard let textRange = textRange(for: run.range, in: textLayoutManager) else { continue }
            textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
        }
    }

    private func textRange(for range: NSRange, in textLayoutManager: NSTextLayoutManager) -> NSTextRange? {
        textLayoutManager.textContentManager.flatMap { TextLayoutHelpers.textRange(range, in: $0) }
    }

    /// Rendering attributes change no layout, and UIKit's fragment views do
    /// not redraw for them on their own: mark what covers the runs dirty.
    private func redraw(_ runs: [(range: NSRange, color: UIColor)]) {
        guard let textView, let first = runs.map(\.range.location).min(),
              let end = runs.map({ NSMaxRange($0.range) }).max()
        else { return }
        var dirty = CGRect.null
        TextLayoutHelpers.enumerateSegmentFrames(of: NSRange(location: first, length: end - first), in: textView) { frame, _ in
            dirty = dirty.union(frame)
        }
        guard !dirty.isNull else { return }
        Self.setNeedsDisplay(in: dirty.insetBy(dx: -2, dy: -2), of: textView, below: textView)
    }

    private static func setNeedsDisplay(in rect: CGRect, of root: UIView, below view: UIView) {
        for subview in view.subviews where !(subview is MarkdownDecorationView) {
            let local = root.convert(rect, to: subview).intersection(subview.bounds)
            guard !local.isNull, !local.isEmpty else { continue }
            subview.setNeedsDisplay(local)
            setNeedsDisplay(in: rect, of: root, below: subview)
        }
    }
}

/// CADisplayLink retains its target; this keeps it from retaining the animator.
private final class DisplayLinkTarget: NSObject {
    private weak var animator: TailFadeAnimator?

    init(_ animator: TailFadeAnimator) {
        self.animator = animator
    }

    @MainActor @objc func step(_ link: CADisplayLink) {
        guard let animator else {
            link.invalidate()
            return
        }
        animator.step()
    }
}
