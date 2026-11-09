import AppKit
import SwiftUI

@MainActor
enum RoleColorIndicatorRenderer {
    static func draw(
        colorHex: UInt32?,
        secondaryColorHex: UInt32? = nil,
        tertiaryColorHex: UInt32? = nil,
        in rect: CGRect
    ) {
        let color = SakuraCordAccentColor.nsColor(
            forRoleColorHex: colorHex
        )
        let usesAccentFallback = SakuraCordAccentColor.usesAccentFallback(
            forRoleColorHex: colorHex
        )
        let circle = NSBezierPath(ovalIn: rect)
        if usesAccentFallback {
            color.withAlphaComponent(0.14).setFill()
            circle.fill()
            color.setStroke()
            circle.lineWidth = max(1.25, rect.width * 0.16)
            circle.stroke()
        } else if let secondaryColorHex, let context = NSGraphicsContext.current?.cgContext {
            let colors = [colorHex, secondaryColorHex, tertiaryColorHex].compactMap { $0 }
                .map { SakuraCordAccentColor.nsColor(forRoleColorHex: $0) }
            RoleGradientPaint.fillDot(colors, in: rect, context: context)
        } else {
            color.setFill()
            circle.fill()
        }
    }
}

struct RoleColorIndicator: View {
    let colorHex: UInt32?
    let secondaryColorHex: UInt32?
    let tertiaryColorHex: UInt32?
    let size: CGFloat

    init(
        colorHex: UInt32?,
        secondaryColorHex: UInt32? = nil,
        tertiaryColorHex: UInt32? = nil,
        size: CGFloat
    ) {
        self.colorHex = colorHex
        self.secondaryColorHex = secondaryColorHex
        self.tertiaryColorHex = tertiaryColorHex
        self.size = size
    }

    var body: some View {
        let color = SakuraCordAccentColor.color(forRoleColorHex: colorHex)
        let usesAccentFallback = SakuraCordAccentColor.usesAccentFallback(
            forRoleColorHex: colorHex
        )

        Group {
            if !usesAccentFallback, let gradient = LinearGradient.role(colorHex, secondaryColorHex, tertiaryColorHex) {
                Circle().fill(gradient)
            } else {
                Circle()
                    .fill(usesAccentFallback ? color.opacity(0.14) : color)
                    .overlay {
                        if usesAccentFallback {
                            Circle()
                                .stroke(color, lineWidth: max(1.25, size * 0.16))
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension LinearGradient {
    /// A role's gradient, returning to its first colour as Discord's does.
    @MainActor static func role(_ primary: UInt32?, _ secondary: UInt32?, _ tertiary: UInt32?) -> LinearGradient? {
        guard let primary, let secondary else { return nil }
        let colors = [primary, secondary] + (tertiary.map { [$0] } ?? []) + [primary]
        return LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing)
    }
}

extension EnvironmentValues {
    @Entry var roleColorDisplay: RoleColorDisplay = .inNames
}

struct NameRoleColorIndicator: View {
    let colorHex: UInt32?
    var secondaryColorHex: UInt32?
    var tertiaryColorHex: UInt32?
    @Environment(\.roleColorDisplay) private var display

    var body: some View {
        if display == .nextToNames, let colorHex, colorHex != 0 {
            RoleColorIndicator(
                colorHex: colorHex,
                secondaryColorHex: secondaryColorHex,
                tertiaryColorHex: tertiaryColorHex,
                size: InterfaceScale.metric(8)
            )
        }
    }
}
