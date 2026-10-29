import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class NativeTimelineInlineVideoOverlay: NSView {
    var player: AVQueuePlayer?
    var playerLayer: AVPlayerLayer?
    var looper: AVPlayerLooper?
    var url: URL?
    var requestedPlayback = false
    var preparationTask: Task<Void, Never>?
    /// Discord's preview of the video, shown beneath the player until its
    /// first frame covers it.
    var placeholder: NSImage? {
        didSet {
            guard placeholder !== oldValue else { return }
            layer?.contents = placeholder?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        updateColorsForEffectiveAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColorsForEffectiveAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorsForEffectiveAppearance()
    }

    private func updateColorsForEffectiveAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NativeTimelineSemanticColor.opacity(
                .secondaryLabelColor,
                0.10
            ).cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizePlayerLayerFrame()
    }

    override func layout() {
        super.layout()
        synchronizePlayerLayerFrame()
    }

    func synchronizePlayerLayerFrame() {
        guard let playerLayer else { return }
        // AVPlayerLayer otherwise implicitly animates bounds/position changes.
        // During the transition, the canvas' rounded loading placeholder shows
        // through below the shorter presentation layer as a gray footer.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func display(_ url: URL, plays: Bool) {
        if self.url != url {
            stop()
            self.url = url
            requestedPlayback = plays
            schedulePreparation(for: url)
            return
        }
        requestedPlayback = plays
        if plays, let player, looper != nil {
            player.playImmediately(atRate: 1)
        } else {
            player?.pause()
        }
    }

    private func schedulePreparation(for url: URL) {
        preparationTask = Task { @MainActor [weak self] in
            let interval = AppPerformanceSignposts.signposter.beginInterval(
                "TimelineInlineVideoPreparation"
            )
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    "TimelineInlineVideoPreparation",
                    interval
                )
            }
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.url == url
            else { return }
            let player = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoPlayerCreation"
            ) {
                let player = AVQueuePlayer()
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                return player
            }
            self.player = player

            await Task.yield()
            guard !Task.isCancelled, self.url == url else { return }
            let playerLayer = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoLayerCreation"
            ) {
                let playerLayer = AVPlayerLayer(player: player)
                playerLayer.videoGravity = .resizeAspectFill
                playerLayer.actions = [
                    "bounds": NSNull(),
                    "position": NSNull(),
                ]
                playerLayer.autoresizingMask = [
                    .layerWidthSizable,
                    .layerHeightSizable,
                ]
                return playerLayer
            }
            self.playerLayer = playerLayer
            self.layer?.addSublayer(playerLayer)
            self.synchronizePlayerLayerFrame()

            await Task.yield()
            guard !Task.isCancelled, self.url == url else { return }
            let item = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoItemCreation"
            ) {
                AVPlayerItem(url: url)
            }

            await Task.yield()
            guard !Task.isCancelled, self.url == url else { return }
            self.looper = AppPerformanceSignposts.measureSync(
                "TimelineInlineVideoLooperCreation"
            ) {
                AVPlayerLooper(player: player, templateItem: item)
            }
            self.preparationTask = nil
            if self.requestedPlayback {
                player.playImmediately(atRate: 1)
            }
        }
    }

    func stop() {
        preparationTask?.cancel()
        preparationTask = nil
        player?.pause()
        player?.removeAllItems()
        looper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        url = nil
        requestedPlayback = false
    }

    func pauseForScroll() {
        requestedPlayback = false
        player?.pause()
    }

    deinit {
        preparationTask?.cancel()
        player?.pause()
        player?.removeAllItems()
    }
}
