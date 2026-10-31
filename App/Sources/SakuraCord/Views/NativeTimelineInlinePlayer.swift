import AppKit
import AVKit

/// A video attachment playing in place over its tile, with the system's
/// inline controls: play and pause, scrubbing, volume and full screen.
/// Open in Viewer is in its context menu.
@MainActor
final class NativeTimelineInlinePlayer: NSView {
    struct Key: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        /// The attachment's ID, or the media component's.
        let mediaID: String
    }

    let url: URL
    private let playerView = AVPlayerView()
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
        playerView.videoGravity = .resizeAspect
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open in Viewer"), action: #selector(openViewer), keyEquivalent: "").target = self
        playerView.menu = menu
        playerView.frame = bounds
        playerView.autoresizingMask = [.width, .height]
        addSubview(playerView)
        let player = AVPlayer(url: url)
        playerView.player = player
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Only wheel input that would reach this player: a modal or a
            // viewer above it keeps its own scrolling.
            guard let self, let window, event.window === window,
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
        playerView.player?.pause()
        playerView.player = nil
    }
}
