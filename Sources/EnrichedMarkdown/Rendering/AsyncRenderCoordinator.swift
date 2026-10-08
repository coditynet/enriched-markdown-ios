import Foundation
import UIKit

final class AsyncRenderCoordinator {
    var blockAsyncRender = false

    private let queue: DispatchQueue
    private var currentRenderId: UInt = 0

    /// `currentRenderId` as the render queue sees it. A render that is
    /// already superseded when its turn comes is skipped: under a stream of
    /// updates (one per token) the queue would otherwise work through every
    /// stale one.
    private let latestRenderIdLock = NSLock()
    private var latestRenderId: UInt = 0

    init(queueLabel: String = "com.swmansion.enriched.markdown.render") {
        queue = DispatchQueue(label: queueLabel)
    }

    func scheduleRender(
        _ render: @escaping () -> NSAttributedString?,
        apply: @escaping (NSAttributedString) -> Void
    ) {
        scheduleRender(render, applying: apply)
    }

    func scheduleRender<Result>(
        _ render: @escaping () -> Result?,
        applying apply: @escaping (Result) -> Void
    ) {
        if blockAsyncRender {
            return
        }

        currentRenderId += 1
        let renderId = currentRenderId
        setLatestRenderId(renderId)

        queue.async { [weak self] in
            guard let self, renderId == self.latestRenderIdValue() else { return }
            guard let result = render() else { return }

            DispatchQueue.main.async {
                guard renderId == self.currentRenderId else { return }
                apply(result)
            }
        }
    }

    func invalidate() {
        currentRenderId += 1
        setLatestRenderId(currentRenderId)
    }

    private func setLatestRenderId(_ id: UInt) {
        latestRenderIdLock.lock()
        latestRenderId = id
        latestRenderIdLock.unlock()
    }

    private func latestRenderIdValue() -> UInt {
        latestRenderIdLock.lock()
        defer { latestRenderIdLock.unlock() }
        return latestRenderId
    }
}
