import AppKit
import QuartzCore
import SwiftUI

nonisolated enum SkeletonShimmerStyle {
    static let duration = 1.4
    static let minimumFrameInterval = 1.0 / 30.0
    static let idlePollInterval = 0.1
    static let bandWidthFraction = 0.72
    static let startingOffsetFraction = -0.68
    static let travelFraction = 1.58
    /// The resting fill of every placeholder shape, as an opacity of the label color.
    static let baseOpacity: CGFloat = 0.09
    /// The highlight band's opacity over an opaque shape at each of
    /// `highlightLocations`: the old 0 / 18 / 92 / 18 / 0% band scaled by `baseOpacity`.
    static let highlightOpacities: [CGFloat] = [0, 0.016, 0.083, 0.016, 0]
    static let highlightLocations: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]

    static func baseColor(scale: CGFloat = 1) -> NSColor {
        NSColor.labelColor.withAlphaComponent(baseOpacity * scale)
    }

    static func highlightColors(_ color: NSColor = .labelColor, scale: CGFloat = 1) -> [CGColor] {
        highlightOpacities.map { color.withAlphaComponent($0 * scale).cgColor }
    }

    static func phase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
    }
}

private extension EnvironmentValues {
    @Entry var skeletonShimmerEnabled = false
}

/// Supplies a static environment value. Only the compositor advances the shimmer;
/// the loading view hierarchy does not need a SwiftUI update every animation frame.
struct SkeletonShimmerTimeline<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.skeletonShimmerEnabled, !reduceMotion)
    }
}

/// Shared by SwiftUI placeholders and the native history canvas. Its mask and
/// geometry change only when the placeholder changes, never on animation ticks.
final class SkeletonShimmer {
    let layer = CALayer()
    private let gradient = CAGradientLayer()

    init() {
        layer.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(gradient)
    }

    func update(frame: CGRect, color: NSColor, animates: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let changedWidth = layer.bounds.width != frame.width
        layer.frame = frame
        layer.isHidden = !animates || frame.isEmpty
        gradient.frame = CGRect(
            x: frame.width * SkeletonShimmerStyle.startingOffsetFraction,
            y: 0,
            width: frame.width * SkeletonShimmerStyle.bandWidthFraction,
            height: frame.height
        )
        gradient.colors = SkeletonShimmerStyle.highlightColors(color)
        CATransaction.commit()
        if changedWidth || layer.isHidden {
            gradient.removeAnimation(forKey: "shimmer")
        }
        guard !layer.isHidden, gradient.animation(forKey: "shimmer") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = frame.width * SkeletonShimmerStyle.travelFraction
        animation.duration = SkeletonShimmerStyle.duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        // Match the phase across independently mounted placeholders.
        let time = gradient.convertTime(CACurrentMediaTime(), from: nil)
        animation.beginTime = time - time.truncatingRemainder(dividingBy: SkeletonShimmerStyle.duration)
        gradient.add(animation, forKey: "shimmer")
    }
}

private struct SkeletonShimmerOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> SkeletonShimmerView {
        SkeletonShimmerView()
    }

    func updateNSView(_ view: SkeletonShimmerView, context: Context) {}
}

private final class SkeletonShimmerView: NSView {
    private let shimmer = SkeletonShimmer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(shimmer.layer)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateShimmer),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateShimmer),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateShimmer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShimmer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateShimmer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateShimmer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShimmer()
    }

    @objc private func updateShimmer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shimmer.update(
                frame: bounds, color: .labelColor,
                animates: !isHiddenOrHasHiddenAncestor
                    && window?.occlusionState.contains(.visible) == true
                    && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        }
    }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }
}

private struct SkeletonShimmerModifier<Mask: Shape>: ViewModifier {
    @Environment(\.skeletonShimmerEnabled) private var enabled
    let mask: Mask

    func body(content: Content) -> some View {
        content.overlay {
            if enabled {
                SkeletonShimmerOverlay()
                    .mask(mask)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Sweeps the shimmer across `mask`. The mask is opaque, so the highlight is
    /// not attenuated by the translucent resting fill underneath.
    func skeletonShimmer(mask: some Shape) -> some View {
        modifier(SkeletonShimmerModifier(mask: mask))
    }
}
