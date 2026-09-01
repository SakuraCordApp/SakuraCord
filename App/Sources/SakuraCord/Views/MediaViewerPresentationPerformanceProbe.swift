import AppKit
import OSLog

@MainActor
final class MediaViewerPresentationPerformanceProbe {
    static let shared = MediaViewerPresentationPerformanceProbe()

    private struct PendingPresentation {
        let interval: OSSignpostIntervalState
        let startedAt: TimeInterval
        let mediaWidth: Int
        let mediaHeight: Int
        var sourcePreparedAt: TimeInterval?
        var overlayAttachedAt: TimeInterval?
        var animationTransactionStartedAt: TimeInterval?
        var sourceWidth = 0
        var sourceHeight = 0
        var visibleSourceRatio = 0.0
        var hasTransitionSource = false
    }

    private static let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "MediaViewerPerformance"
    )
    private static let signposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )
    private static let isEnabled =
        ProcessInfo.processInfo.environment[
            "SAKURACORD_MEDIA_VIEWER_BENCHMARK"
        ] == "1"

    private var pending: PendingPresentation?
    private var displayLinkTicker: NativeTimelineDisplayLinkTicker?

    func begin(mediaWidth: Int?, mediaHeight: Int?) {
        guard Self.isEnabled else { return }
        finishPending(outcome: "superseded")
        pending = PendingPresentation(
            interval: Self.signposter.beginInterval(
                "MediaViewerInputToFirstAnimationFrame"
            ),
            startedAt: ProcessInfo.processInfo.systemUptime,
            mediaWidth: mediaWidth ?? 0,
            mediaHeight: mediaHeight ?? 0
        )
    }

    func reportSourcePrepared(
        imageSize: CGSize?,
        visibleSourceRatio: Double,
        hasTransitionSource: Bool
    ) {
        guard var pending else { return }
        pending.sourcePreparedAt = ProcessInfo.processInfo.systemUptime
        pending.sourceWidth = Int(imageSize?.width.rounded() ?? 0)
        pending.sourceHeight = Int(imageSize?.height.rounded() ?? 0)
        pending.visibleSourceRatio = visibleSourceRatio
        pending.hasTransitionSource = hasTransitionSource
        self.pending = pending
        Self.signposter.emitEvent("MediaViewerSourcePrepared")
    }

    func reportOverlayAttached(to view: NSView) {
        guard var pending else { return }
        pending.overlayAttachedAt = ProcessInfo.processInfo.systemUptime
        self.pending = pending
        Self.signposter.emitEvent("MediaViewerOverlayAttached")

        let ticker = NativeTimelineDisplayLinkTicker()
        displayLinkTicker = ticker
        ticker.start(on: view) { [weak self] in
            self?.displayLinkDidFire()
        }
    }

    func reportAnimationTransactionStarted() {
        guard var pending else { return }
        pending.animationTransactionStartedAt =
            ProcessInfo.processInfo.systemUptime
        self.pending = pending
        Self.signposter.emitEvent(
            "MediaViewerAnimationTransactionStarted"
        )
    }

    private func displayLinkDidFire() {
        guard pending?.animationTransactionStartedAt != nil else { return }
        finishPending(outcome: "displayed")
    }

    private func finishPending(outcome: String) {
        guard let pending else { return }
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let inputToFrameMilliseconds =
            max(0, finishedAt - pending.startedAt) * 1_000
        let sourcePreparationMilliseconds = pending.sourcePreparedAt.map {
            max(0, $0 - pending.startedAt) * 1_000
        } ?? 0
        let overlayAttachmentMilliseconds = pending.overlayAttachedAt.map {
            max(0, $0 - pending.startedAt) * 1_000
        } ?? 0
        let animationTransactionMilliseconds =
            pending.animationTransactionStartedAt.map {
                max(0, $0 - pending.startedAt) * 1_000
            } ?? 0
        let overlayToTransactionMilliseconds =
            pending.overlayAttachedAt.flatMap { overlayAttachedAt in
                pending.animationTransactionStartedAt.map {
                    max(0, $0 - overlayAttachedAt) * 1_000
                }
            } ?? 0
        let transactionToFrameMilliseconds =
            pending.animationTransactionStartedAt.map {
                max(0, finishedAt - $0) * 1_000
            } ?? 0

        Self.signposter.endInterval(
            "MediaViewerInputToFirstAnimationFrame",
            pending.interval
        )
        Self.logger.info(
            """
            Media viewer presentation benchmark \
            outcome=\(outcome, privacy: .public) \
            input_to_frame_ms=\(inputToFrameMilliseconds, format: .fixed(precision: 3)) \
            source_prepare_ms=\(sourcePreparationMilliseconds, format: .fixed(precision: 3)) \
            overlay_attach_ms=\(overlayAttachmentMilliseconds, format: .fixed(precision: 3)) \
            animation_transaction_ms=\(animationTransactionMilliseconds, format: .fixed(precision: 3)) \
            overlay_to_transaction_ms=\(overlayToTransactionMilliseconds, format: .fixed(precision: 3)) \
            transaction_to_frame_ms=\(transactionToFrameMilliseconds, format: .fixed(precision: 3)) \
            media_width=\(pending.mediaWidth) \
            media_height=\(pending.mediaHeight) \
            source_width=\(pending.sourceWidth) \
            source_height=\(pending.sourceHeight) \
            visible_source_ratio=\(pending.visibleSourceRatio, format: .fixed(precision: 3)) \
            has_transition_source=\(pending.hasTransitionSource)
            """
        )
        self.pending = nil
        displayLinkTicker?.stop()
        displayLinkTicker = nil
    }
}
