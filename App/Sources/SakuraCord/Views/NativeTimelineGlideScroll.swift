import AppKit

/// Carries the reader to a row that is already loaded instead of cutting to
/// it, so a jump keeps its sense of place: replies, search results, links,
/// and reply navigation all glide there.
nonisolated enum NativeTimelineGlideScrollPolicy {
    /// A trip longer than this many screens starts this far from the
    /// destination; a faster glide over everything in between only blurs.
    static let maximumGlideScreens: CGFloat = 2.5
    static let minimumDuration: TimeInterval = 0.32
    static let maximumDuration: TimeInterval = 0.62

    static let curve = NativeTimelineGlideCurve(
        x1: 0.22, y1: 1, x2: 0.36, y2: 1, duration: maximumDuration
    )

    /// Short hops settle quickly; a couple of screens takes a little longer.
    static func duration(distance: CGFloat, viewportHeight: CGFloat) -> TimeInterval {
        let screens = Double(distance / max(1, viewportHeight))
        let fraction = min(1, screens / Double(maximumGlideScreens))
        return minimumDuration + (maximumDuration - minimumDuration) * fraction.squareRoot()
    }

    /// Where a glide begins: here, or close enough to the target to read.
    static func startY(from currentY: CGFloat, to targetY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let reach = viewportHeight * maximumGlideScreens
        let distance = targetY - currentY
        guard abs(distance) > reach else { return currentY }
        return targetY - (distance < 0 ? -reach : reach)
    }
}

@MainActor
final class NativeTimelineGlideScroll {
    let ticker = NativeTimelineDisplayLinkTicker()
    let target: MessageTimelineScrollRequest.Target
    let startUptime = ProcessInfo.processInfo.systemUptime
    let duration: TimeInterval
    var startY: CGFloat
    var lastAppliedY: CGFloat

    init(target: MessageTimelineScrollRequest.Target, startY: CGFloat, duration: TimeInterval) {
        self.target = target
        self.startY = startY
        self.duration = duration
        lastAppliedY = startY
    }
}

extension NativeMessageTimelineCoordinator {
    /// Starts a glide to `target`. Returns `false` while the target's row is
    /// not laid out, so the request is retried after the next update.
    func glide(
        to target: MessageTimelineScrollRequest.Target,
        in scrollView: NSScrollView
    ) -> Bool {
        guard let targetY = documentY(for: target, in: scrollView) else { return false }
        cancelGlide()
        let viewportHeight = scrollView.contentView.bounds.height
        let currentY = scrollView.contentView.bounds.minY
        let startY = NativeTimelineGlideScrollPolicy.startY(
            from: currentY,
            to: targetY,
            viewportHeight: viewportHeight
        )
        if startY != currentY {
            scroll(toDocumentY: startY, scrollView: scrollView)
        }
        let distance = abs(targetY - scrollView.contentView.bounds.minY)
        guard distance >= 1 else {
            scroll(toDocumentY: targetY, scrollView: scrollView)
            return true
        }
        let glide = NativeTimelineGlideScroll(
            target: target,
            startY: scrollView.contentView.bounds.minY,
            duration: NativeTimelineGlideScrollPolicy.duration(
                distance: distance,
                viewportHeight: viewportHeight
            )
        )
        activeGlide = glide
        canvas?.dismissHoverPresentationForScroll()
        glide.ticker.start(on: scrollView) { [weak self] in
            self?.advanceGlide()
        }
        return true
    }

    func cancelGlide() {
        activeGlide?.ticker.stop()
        activeGlide = nil
    }

    private func advanceGlide() {
        guard let glide = activeGlide, let scrollView else {
            cancelGlide()
            return
        }
        // Rows that load, resize, or arrive keep their place on screen by
        // shifting the clip view. Carry the glide's start with them so the
        // motion stays continuous and the target is re-resolved each frame.
        let currentY = scrollView.contentView.bounds.minY
        glide.startY += currentY - glide.lastAppliedY
        guard let targetY = documentY(for: glide.target, in: scrollView) else {
            cancelGlide()
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - glide.startUptime
        let fraction = elapsed / glide.duration
        let progress = NativeTimelineGlideScrollPolicy.curve.progress(at: fraction)
        scroll(
            toDocumentY: glide.startY + (targetY - glide.startY) * progress,
            scrollView: scrollView
        )
        glide.lastAppliedY = scrollView.contentView.bounds.minY
        if fraction >= 1 {
            cancelGlide()
            // Report the settled reading offset, which intermediate frames
            // within the same top message do not publish.
            reportScrollState(force: true)
        }
    }
}
