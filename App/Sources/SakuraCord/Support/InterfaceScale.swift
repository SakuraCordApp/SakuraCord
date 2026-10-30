import AppKit
import Observation
import SwiftUI
import Synchronization

/// The app-wide Interface Size preference (#175).
///
/// macOS text styles have fixed point sizes and ignore Dynamic Type, so
/// SakuraCord scales its own fonts and layout metrics from this one value.
/// Reads are thread-safe for off-main timeline layout and are tracked by
/// Observation, so SwiftUI bodies, including AppKit-hosted popovers, update
/// when the factor changes. AppKit-drawn surfaces are invalidated by their
/// owners. At the default factor every helper returns its input unchanged.
nonisolated final class InterfaceScale: Observable, Sendable {
    static let shared = InterfaceScale()

    static let defaultFactor = 1.0
    static let range = 0.8 ... 1.4
    static let step = 0.1

    private let registrar = ObservationRegistrar()
    private let storage = Mutex(InterfaceScale.defaultFactor)

    var factor: Double {
        registrar.access(self, keyPath: \.factor)
        return storage.withLock { $0 }
    }

    func update(_ proposedFactor: Double) {
        let value = Self.normalized(proposedFactor)
        guard storage.withLock({ $0 }) != value else { return }
        registrar.withMutation(of: self, keyPath: \.factor) {
            storage.withLock { $0 = value }
        }
    }

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFactor }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return ((clamped / step).rounded() * step * 100).rounded() / 100
    }
}

nonisolated extension InterfaceScale {
    static var factor: CGFloat { CGFloat(shared.factor) }

    /// Scales a layout length, keeping it on the half-point grid so edges
    /// stay crisp on Retina displays.
    static func metric(_ value: CGFloat) -> CGFloat {
        let factor = factor
        guard factor != 1 else { return value }
        return (value * factor * 2).rounded() / 2
    }

    /// Reduced text stays at least this large, unless it started smaller.
    static let legibilityFloor: CGFloat = 9

    /// Scales a font point size. Reduced sizes keep the legibility floor.
    static func fontSize(_ value: CGFloat) -> CGFloat {
        let factor = factor
        guard factor != 1 else { return value }
        let scaled = (value * factor * 2).rounded() / 2
        return factor < 1 ? max(scaled, min(value, legibilityFloor)) : scaled
    }

    /// A scaled minimum length for window content that keeps the whole window,
    /// including its title bar and toolbar, within the screen's visible area.
    @MainActor
    static func windowLength(_ value: CGFloat, axis: Axis) -> CGFloat {
        let scaled = metric(value)
        guard let visible = NSScreen.main?.visibleFrame.size else { return scaled }
        return axis == .horizontal
            ? min(scaled, visible.width)
            : min(scaled, visible.height - windowChromeHeight)
    }

    /// The title bar and toolbar height above SwiftUI content, measured from
    /// the app's visible windows; before any window exists, the height of a
    /// unified toolbar title bar.
    @MainActor
    private static var windowChromeHeight: CGFloat {
        NSApp.windows.lazy
            .filter { $0.isVisible && $0.styleMask.contains(.titled) && $0.toolbar != nil }
            .map { $0.frame.height - $0.contentLayoutRect.height }
            .max() ?? 52
    }

    /// Shifts a native control size by the interface size tier.
    static func controlSize(_ base: ControlSize) -> ControlSize {
        let sizes: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
        let factor = factor
        let shift = factor < 0.95 ? -1 : factor > 1.15 ? 1 : 0
        guard shift != 0, let index = sizes.firstIndex(of: base) else { return base }
        return sizes[min(max(index + shift, 0), sizes.count - 1)]
    }
}

/// macOS base metrics for SwiftUI text styles, matching
/// `NSFont.preferredFont(forTextStyle:)`.
private nonisolated func interfaceBaseMetrics(
    _ style: Font.TextStyle
) -> (size: CGFloat, weight: Font.Weight) {
    switch style {
    case .largeTitle: (26, .regular)
    case .title: (22, .regular)
    case .title2: (17, .regular)
    case .title3: (15, .regular)
    case .headline: (13, .bold)
    case .subheadline: (11, .regular)
    case .callout: (12, .regular)
    case .footnote, .caption: (10, .regular)
    case .caption2: (10, .medium)
    default: (13, .regular)
    }
}

nonisolated extension Font {
    /// A text style that follows the Interface Size preference.
    static func interface(
        _ style: Font.TextStyle,
        design: Font.Design? = nil,
        weight: Font.Weight? = nil
    ) -> Font {
        guard InterfaceScale.factor != 1 else {
            return .system(style, design: design, weight: weight)
        }
        let base = interfaceBaseMetrics(style)
        return .system(
            size: InterfaceScale.fontSize(base.size),
            weight: weight ?? base.weight,
            design: design
        )
    }

    /// A fixed-size system font that follows the Interface Size preference.
    static func interfaceSystem(
        size: CGFloat,
        weight: Font.Weight? = nil,
        design: Font.Design? = nil
    ) -> Font {
        .system(size: InterfaceScale.fontSize(size), weight: weight, design: design)
    }
}

nonisolated extension NSFont {
    static func interfaceSystemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        .systemFont(ofSize: InterfaceScale.fontSize(size), weight: weight)
    }

    static func interfaceMonospacedDigitSystemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight
    ) -> NSFont {
        .monospacedDigitSystemFont(ofSize: InterfaceScale.fontSize(size), weight: weight)
    }

    static func interfacePreferredFont(forTextStyle style: NSFont.TextStyle) -> NSFont {
        let font = NSFont.preferredFont(forTextStyle: style)
        guard InterfaceScale.factor != 1 else { return font }
        return font.withSize(InterfaceScale.fontSize(font.pointSize))
    }
}

private extension EnvironmentValues {
    @Entry var interfaceScaleRootApplied = false
}

/// Applies the interface size to a content root: an explicit default font for
/// unstyled text and controls, and a matching control size. At the default
/// size it leaves the environment untouched, and nested roots are no-ops.
private struct InterfaceScaleRootModifier: ViewModifier {
    @Environment(\.interfaceScaleRootApplied) private var isNested

    func body(content: Content) -> some View {
        let isDefault = InterfaceScale.factor == 1 || isNested
        content
            .environment(\.interfaceScaleRootApplied, true)
            .transformEnvironment(\.font) { font in
                if !isDefault, font == nil { font = .interface(.body) }
            }
            .transformEnvironment(\.controlSize) { size in
                if !isDefault { size = InterfaceScale.controlSize(size) }
            }
            .transformEnvironment(\.sidebarRowSize) { size in
                if !isDefault, InterfaceScale.factor < 0.95 { size = .small }
            }
    }
}

extension View {
    func interfaceScaleRoot() -> some View {
        modifier(InterfaceScaleRootModifier())
    }

    /// Sets `font` only away from the default size, for system-styled
    /// containers (sidebar rows and headers) that ignore inherited fonts.
    func interfaceFontOverride(_ font: Font) -> some View {
        let isDefault = InterfaceScale.factor == 1
        return transformEnvironment(\.font) { value in
            if !isDefault { value = font }
        }
    }

    /// A control size that shifts with the interface size.
    func interfaceControlSize(_ size: ControlSize) -> some View {
        controlSize(InterfaceScale.controlSize(size))
    }
}

nonisolated extension NSAttributedString {
    /// A copy with fonts and dimensional typography (paragraph metrics,
    /// baseline offsets and kerning) resized by `ratio`. Fonts reduced with
    /// `keepingLegibility` stop at the legibility floor.
    func scalingTypography(by ratio: CGFloat, keepingLegibility: Bool = false) -> NSAttributedString {
        guard ratio != 1, length > 0 else { return self }
        let scaled = NSMutableAttributedString(attributedString: self)
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                let size = font.pointSize * ratio
                let floor = keepingLegibility ? min(font.pointSize, InterfaceScale.legibilityFloor) : 0
                scaled.addAttribute(.font, value: font.withSize(max(size, floor)), range: range)
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                scaled.addAttribute(.paragraphStyle, value: style.scaled(by: ratio), range: range)
            }
            for key in [NSAttributedString.Key.baselineOffset, .kern] {
                if let value = attributes[key] as? NSNumber {
                    scaled.addAttribute(key, value: CGFloat(value.doubleValue) * ratio, range: range)
                }
            }
        }
        return scaled
    }
}

private nonisolated extension NSParagraphStyle {
    func scaled(by ratio: CGFloat) -> NSParagraphStyle {
        guard let style = mutableCopy() as? NSMutableParagraphStyle else { return self }
        style.minimumLineHeight *= ratio
        style.maximumLineHeight *= ratio
        style.lineSpacing *= ratio
        style.paragraphSpacing *= ratio
        style.paragraphSpacingBefore *= ratio
        style.headIndent *= ratio
        style.firstLineHeadIndent *= ratio
        style.tailIndent *= ratio
        style.defaultTabInterval *= ratio
        style.tabStops = tabStops.map {
            NSTextTab(textAlignment: $0.alignment, location: $0.location * ratio, options: $0.options)
        }
        return style
    }
}
