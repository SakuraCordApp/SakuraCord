import AppKit
import QuartzCore
import SwiftUI

/// Discord's three-dot wave for every pending interaction: a command being
/// sent, an app thinking, an activated button or select, a submitting modal,
/// and command or option lists still loading.
///
/// Core Animation runs the loop in the render server, so a visible indicator
/// never redraws the timeline or wakes the main thread.
final class InteractionLoadingDots: NSView {
    nonisolated enum Tone: Equatable, Sendable {
        /// Inline with message text.
        case content
        /// On a filled button background.
        case onFill
    }

    // Discord's Dots: radius 3.5, centres 2.5 radii apart, a 1.2 s wave whose
    // dots trail one another by 0.15 s (doubled under Reduce Motion).
    static var dotRadius: CGFloat { InterfaceScale.metric(3.5) }
    static var size: CGSize { CGSize(width: dotRadius * 7, height: dotRadius * 2) }
    private static let cycle: CFTimeInterval = 1.2
    private static let phases: [CFTimeInterval] = [0, 1.05, 0.9]

    var tone: Tone = .content {
        didSet { if tone != oldValue { updateColors() } }
    }

    private let dots = (0 ..< 3).map { _ in CALayer() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        for dot in dots {
            dot.cornerRadius = Self.dotRadius
            dot.opacity = 0.32
            dot.transform = CATransform3DMakeScale(0.8, 0.8, 1)
            layer?.addSublayer(dot)
        }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let origin = CGPoint(
            x: (bounds.width - Self.size.width) / 2,
            y: (bounds.height - Self.size.height) / 2
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: Self.dotRadius * 2, height: Self.dotRadius * 2)
            dot.position = CGPoint(
                x: origin.x + Self.dotRadius * (1 + 2.5 * CGFloat(index)),
                y: origin.y + Self.dotRadius
            )
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dots.forEach { $0.removeAllAnimations() }
        } else {
            updateColors()
            startAnimating()
        }
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (tone == .content ? NSColor.labelColor : NSColor.white).cgColor
            dots.forEach { $0.backgroundColor = color }
        }
    }

    private func startAnimating() {
        let duration = Self.cycle
            * (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 2 : 1)
        for (index, dot) in dots.enumerated() {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.32, 1, 0.32, 0.32]
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.8, 1, 0.8, 0.8]
            let pulse = CAAnimationGroup()
            pulse.animations = [opacity, scale]
            for animation in [opacity, scale] {
                animation.keyTimes = [0, 0.25, 0.5, 1]
                animation.duration = duration
            }
            pulse.repeatOnMediaClock(cycle: duration, lead: Self.phases[index] / Self.cycle * duration)
            dot.add(pulse, forKey: "pulse")
        }
    }
}

extension CAAnimation {
    /// Repeats forever in step with the shared media clock, `lead` seconds
    /// into its cycle, so separate indicators pulse together and a rebuilt
    /// view never restarts the loop.
    func repeatOnMediaClock(cycle: CFTimeInterval, lead: CFTimeInterval) {
        duration = cycle
        repeatCount = .infinity
        let phase = (CACurrentMediaTime() + lead).truncatingRemainder(dividingBy: cycle)
        timeOffset = phase < 0 ? phase + cycle : phase
    }
}

/// The same dots for SwiftUI interaction surfaces such as modals and pickers.
struct InteractionLoadingDotsView: NSViewRepresentable {
    var tone: InteractionLoadingDots.Tone = .content

    func makeNSView(context _: Context) -> InteractionLoadingDots {
        InteractionLoadingDots(frame: CGRect(origin: .zero, size: InteractionLoadingDots.size))
    }

    func updateNSView(_ view: InteractionLoadingDots, context _: Context) {
        view.tone = tone
    }

    func sizeThatFits(_: ProposedViewSize, nsView _: InteractionLoadingDots, context _: Context) -> CGSize? {
        InteractionLoadingDots.size
    }
}
