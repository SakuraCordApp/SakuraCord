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
                contentMode: .fit,
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
