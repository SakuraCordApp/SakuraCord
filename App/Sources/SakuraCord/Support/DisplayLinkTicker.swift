import AppKit
import QuartzCore

extension CAFrameRateRange {
    /// Every frame the screen can show, up to 120 Hz on ProMotion, and never
    /// fewer than 60 (or 80 on ProMotion): a lower minimum lets the system
    /// halve the rate under load.
    static func fullRate(on screen: NSScreen?) -> Self {
        let rate = Float(screen?.maximumFramesPerSecond ?? 60)
        return CAFrameRateRange(minimum: min(rate, 80), maximum: rate, preferred: rate)
    }
}

@MainActor
final class DisplayLinkTicker: NSObject {
    var displayLink: CADisplayLink?
    var tick: (() -> Void)?

    func start(on view: NSView, frameRate: CAFrameRateRange? = nil, tick: @escaping () -> Void) {
        stop()
        self.tick = tick
        let displayLink = view.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        displayLink.preferredFrameRateRange = frameRate ?? .fullRate(on: view.window?.screen)
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        tick = nil
    }

    @objc
    func displayLinkDidFire(_ displayLink: CADisplayLink) {
        tick?()
    }
}
