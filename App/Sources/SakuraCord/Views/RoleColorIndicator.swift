import AppKit
import SwiftUI

@MainActor
enum RoleColorIndicatorRenderer {
    static func draw(colorHex: UInt32?, in rect: CGRect) {
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
        } else {
            color.setFill()
            circle.fill()
        }
    }
}

struct RoleColorIndicator: View {
    let colorHex: UInt32?
    let size: CGFloat

    var body: some View {
        let color = SakuraCordAccentColor.color(forRoleColorHex: colorHex)
        let usesAccentFallback = SakuraCordAccentColor.usesAccentFallback(
            forRoleColorHex: colorHex
        )

        Circle()
            .fill(usesAccentFallback ? color.opacity(0.14) : color)
            .overlay {
                if usesAccentFallback {
                    Circle()
                        .stroke(color, lineWidth: max(1.25, size * 0.16))
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
