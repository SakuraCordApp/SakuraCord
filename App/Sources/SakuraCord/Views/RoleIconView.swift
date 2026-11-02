import AppKit
import SakuraCordModels
import SwiftUI

struct RoleIconView: View {
    let role: GuildRole
    var size: CGFloat = InterfaceScale.metric(16)

    var body: some View {
        if let iconURL = role.iconURL {
            AnimatedRemoteImage(
                url: iconURL,
                animates: false,
                maximumPixelDimension: 48,
                usesSwiftUIRendering: true
            )
            .frame(width: size, height: size)
        } else if let emoji = role.unicodeEmoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
        }
    }
}

struct RoleIconPopoverView: View {
    let role: GuildRole

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            RoleIconView(role: role, size: InterfaceScale.metric(16))
            Text(role.name)
                .font(.interface(.body).weight(.semibold))
                .foregroundStyle(roleColor)
        }
        .padding(.horizontal, InterfaceScale.metric(10))
        .padding(.vertical, InterfaceScale.metric(6))
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.95),
            in: RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
    }

    private var roleColor: Color {
        if SakuraCordAccentColor.usesAccentFallback(forRoleColorHex: role.colorHex) {
            return .primary
        }
        return SakuraCordAccentColor.color(forRoleColorHex: role.colorHex)
    }
}
