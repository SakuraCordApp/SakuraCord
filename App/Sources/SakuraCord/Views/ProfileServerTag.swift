import SakuraCordModels
import SwiftUI

nonisolated enum ServerTagAppearance {
    static var height: CGFloat { InterfaceScale.metric(18) }
    static var badgeSize: CGFloat { InterfaceScale.metric(12) }
    static let fontSize: CGFloat = 11
    static var spacing: CGFloat { InterfaceScale.metric(4) }
    static var horizontalPadding: CGFloat { InterfaceScale.metric(5) }
    static var cornerRadius: CGFloat { InterfaceScale.metric(5) }
    static let backgroundOpacity = 0.1
    static let highlightedBackgroundOpacity = 0.15
}

struct AppIdentityBadge: View {
    var isVerified = false

    var body: some View {
        HStack(spacing: ServerTagAppearance.spacing) {
            if isVerified {
                Image(systemName: "checkmark").accessibilityHidden(true)
            }
            Text("APP")
        }
        .font(.interfaceSystem(size: ServerTagAppearance.fontSize, weight: .bold))
        .padding(.horizontal, ServerTagAppearance.horizontalPadding)
        .frame(height: ServerTagAppearance.height)
        .foregroundStyle(.white)
        .background(
            isVerified ? Color(hex: DiscordBuiltInCommands.clydeAccent) : .indigo,
            in: .rect(cornerRadius: ServerTagAppearance.cornerRadius)
        )
        .accessibilityLabel(isVerified ? "Verified App" : "App")
    }
}

struct ProfileServerTag: View {
    let identity: PrimaryGuildIdentity?
    var showsDisclosure = false
    var isHighlighted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ServerTagAppearance.spacing) {
            if let identity, let tag = identity.tag {
                Text(tag)
                    .overlay(alignment: .leading) {
                        if let badgeURL = identity.badgeURL {
                            StaticRemoteImage(url: badgeURL, maximumPixelDimension: 32)
                                .frame(width: ServerTagAppearance.badgeSize, height: ServerTagAppearance.badgeSize)
                                .offset(x: -(ServerTagAppearance.badgeSize + ServerTagAppearance.spacing))
                        }
                    }
                    .padding(.leading, identity.badgeURL == nil ? 0 : ServerTagAppearance.badgeSize + ServerTagAppearance.spacing)
            } else {
                Text("Server Tag", bundle: #bundle).italic().foregroundStyle(.secondary)
            }
            if showsDisclosure {
                Image(systemName: "chevron.down").font(.interface(.caption2))
            }
        }
        .font(.interfaceSystem(size: ServerTagAppearance.fontSize, weight: .medium)).lineLimit(1)
        .padding(.horizontal, ServerTagAppearance.horizontalPadding)
        .frame(height: ServerTagAppearance.height)
        .background(
            .primary.opacity(isHighlighted ? ServerTagAppearance.highlightedBackgroundOpacity : ServerTagAppearance.backgroundOpacity),
            in: .rect(cornerRadius: ServerTagAppearance.cornerRadius)
        )
        .contentShape(.rect(cornerRadius: ServerTagAppearance.cornerRadius))
    }
}
