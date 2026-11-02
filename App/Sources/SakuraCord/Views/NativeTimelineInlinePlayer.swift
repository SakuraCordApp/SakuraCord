import AppKit
import AVKit

/// A video attachment playing in place over its tile, filling it like its
/// thumbnail, with the system's inline controls: play and pause, scrubbing,
/// volume and full screen.
/// Open in Viewer is in its context menu.
@MainActor
final class NativeTimelineInlinePlayer: NSView, AVPlayerViewDelegate {
    struct Key: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        /// The attachment's ID, or the media component's.
        let mediaID: String
    }

    /// The video playing, which identifies it against its tile's media.
    let url: URL
    private let playerView = AVPlayerView()
    /// AVKit collapses its inline controls in a small gallery tile. Laid out
    /// at least this large and scaled down to the tile, it keeps all of them.
    private static let controlsLayoutSize = CGSize(width: 360, height: 240)
    private let scaler = NSView()
    private let openInViewer: () -> Void
    /// The timeline keeps scrolling under the pointer: AVKit's controls
    /// would otherwise take the wheel to scrub or change the volume.
    private var scrollMonitor: Any?

    init(url: URL, frame: CGRect, openInViewer: @escaping () -> Void) {
        self.url = url
        self.openInViewer = openInViewer
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = DiscordRichMessageMetrics.px(8)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        // Fills the tile like its thumbnail; full screen shows the whole frame.
        playerView.videoGravity = .resizeAspectFill
        playerView.delegate = self
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open in Viewer"), action: #selector(openViewer), keyEquivalent: "").target = self
        playerView.menu = menu
        scaler.addSubview(playerView)
        addSubview(scaler)
        layoutPlayer()
        let player = AVPlayer(url: url)
        playerView.player = player
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPlayer()
    }

    private func layoutPlayer() {
        guard !bounds.isEmpty else { return }
        let scale = min(1, bounds.width / Self.controlsLayoutSize.width, bounds.height / Self.controlsLayoutSize.height)
        scaler.frame = bounds
        scaler.bounds.size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        // Back from full screen, the player returns to whatever frame AVKit left.
        if playerView.superview === scaler { playerView.frame = scaler.bounds }
    }

    func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
        playerView.videoGravity = .resizeAspect
    }

    func playerViewDidExitFullScreen(_ playerView: AVPlayerView) {
        playerView.videoGravity = .resizeAspectFill
        layoutPlayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Only wheel input that would reach this player: a dialog, which
            // sits beside the content view, or a viewer above it keeps its
            // own scrolling.
            guard let self, let window, event.window === window,
                  WindowModalCoordinator.allowsInput(for: self),
                  window.contentView?.hitTest(event.locationInWindow)?.isDescendant(of: self) == true,
                  let superview
            else { return event }
            superview.scrollWheel(with: event)
            return nil
        }
    }

    @objc private func openViewer() {
        pause()
        openInViewer()
    }

    func pause() {
        playerView.player?.pause()
    }

    func stop() {
        pause()
        playerView.player = nil
    }
}
