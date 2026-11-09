import SwiftUI

struct ComposerReplyHeader: View {
    @Environment(\.roleColorDisplay) private var roleColorDisplay
    var authorFontID: Int?
    let authorName: String
    let avatarURL: URL?
    let roleColorHex: UInt32?
    var roleSecondaryColorHex: UInt32?
    var roleTertiaryColorHex: UInt32?
    let mentionsAuthor: Bool
    let canMentionAuthor: Bool
    let toggleMention: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(5)) {
            Text("Replying to")
                .foregroundStyle(.secondary)
            HStack(spacing: InterfaceScale.metric(4)) {
                AvatarView(
                    name: authorName,
                    url: avatarURL,
                    size: InterfaceScale.metric(18),
                    maximumPixelDimension: 36,
                    animates: false
                )
                NameRoleColorIndicator(
                    colorHex: roleColorHex,
                    secondaryColorHex: roleSecondaryColorHex,
                    tertiaryColorHex: roleTertiaryColorHex
                )
                Text(authorName)
                    .displayNameFont(authorFontID, textStyle: .callout)
                    .foregroundStyle(authorStyle)
                    .lineLimit(1)
            }

            Spacer(minLength: InterfaceScale.metric(8))

            if canMentionAuthor {
                ComposerReplyMentionButton(
                    mentionsAuthor: mentionsAuthor,
                    action: toggleMention
                )
            }

            HoverCloseButton(
                help: "Cancel reply",
                accessibilityIdentifier: "composer-reply-close",
                diameter: InterfaceScale.metric(30),
                iconSize: 13,
                action: cancel
            )
        }
        .font(.interface(.callout))
        .padding(.leading, InterfaceScale.metric(12))
        .padding(.trailing, InterfaceScale.metric(8))
        .padding(.vertical, InterfaceScale.metric(2))
        .background(.primary.opacity(0.035))
    }

    private var authorStyle: AnyShapeStyle {
        guard roleColorDisplay == .inNames else { return AnyShapeStyle(.primary) }
        if let gradient = LinearGradient.role(roleColorHex, roleSecondaryColorHex, roleTertiaryColorHex) {
            return AnyShapeStyle(gradient)
        }
        return AnyShapeStyle(roleColorHex.map(Color.init(hex:)) ?? .primary)
    }
}

private struct ComposerReplyMentionButton: View {
    let mentionsAuthor: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(2)) {
                Image(systemName: "at")
                Text(mentionsAuthor ? "ON" : "OFF")
            }
            .font(.interface(.callout).weight(.bold))
            .foregroundStyle(
                mentionsAuthor ? SakuraCordAccentColor.color : .secondary
            )
            .padding(.horizontal, InterfaceScale.metric(7))
            .frame(height: InterfaceScale.metric(28))
            .contentShape(Capsule())
            .background {
                Capsule()
                    .fill(.primary.opacity(isHovered ? 0.09 : 0.001))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onModalHover { isHovered = $0 }
        .help(
            mentionsAuthor
                ? "Disable reply notification"
                : "Enable reply notification"
        )
        .accessibilityLabel("Reply notification")
        .accessibilityValue(mentionsAuthor ? "On" : "Off")
    }
}
