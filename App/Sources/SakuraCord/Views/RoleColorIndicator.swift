import SwiftUI

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
