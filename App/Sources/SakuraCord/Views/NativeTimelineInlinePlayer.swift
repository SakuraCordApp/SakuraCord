import AppKit
import AVKit

/// A video attachment playing in place over its tile, with the system's
/// inline controls: play and pause, scrubbing, volume and full screen.
@MainActor
final class NativeTimelineInlinePlayer: NSView {
    struct Key: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        /// The attachment's ID, or the media component's.
        let mediaID: String
    }

    private let playerView = AVPlayerView()

    init(url: URL, frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = DiscordRichMessageMetrics.px(8)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
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

    /// The timeline keeps scrolling under the pointer: AVKit's controls
    /// would otherwise take the wheel to scrub or change the volume.
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let superview
            else { return event }
            superview.scrollWheel(with: event)
            return nil
        }
    }

    func pause() {
        playerView.player?.pause()
    }

    func stop() {
        playerView.player?.pause()
        playerView.player = nil
    }
}
