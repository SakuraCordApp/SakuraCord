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
        } else if let secondaryColorHex,
                  let context = NSGraphicsContext.current?.cgContext
        {
            let secondary = SakuraCordAccentColor.nsColor(forRoleColorHex: secondaryColorHex)
            let tertiary = tertiaryColorHex.map { SakuraCordAccentColor.nsColor(forRoleColorHex: $0) }
            let colors = [color, secondary] + (tertiary.map { [$0] } ?? [])
            let cgColors = colors.map(\.cgColor) as CFArray
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let count = colors.count
            let locations: [CGFloat] = count == 3 ? [0.0, 0.5, 1.0] : [0.0, 1.0]
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: locations) {
                context.saveGState()
                context.addEllipse(in: rect)
                context.clip()
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.minX, y: 0),
                    end: CGPoint(x: rect.maxX, y: 0),
                    options: []
                )
                context.restoreGState()
            } else {
                color.setFill()
                circle.fill()
            }
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
            if !usesAccentFallback, let secondaryColorHex {
                let secondary = SakuraCordAccentColor.color(forRoleColorHex: secondaryColorHex)
                let tertiary = tertiaryColorHex.map { SakuraCordAccentColor.color(forRoleColorHex: $0) }
                let colors = [color, secondary] + (tertiary.map { [$0] } ?? [])
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
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
