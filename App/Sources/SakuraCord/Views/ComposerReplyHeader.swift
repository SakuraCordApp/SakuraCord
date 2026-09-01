import SwiftUI

struct ComposerReplyHeader: View {
    let authorName: String
    let avatarURL: URL?
    let roleColorHex: UInt32?
    let mentionsAuthor: Bool
    let canMentionAuthor: Bool
    let toggleMention: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text("Replying to")
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                AvatarView(
                    name: authorName,
                    url: avatarURL,
                    size: 18,
                    maximumPixelDimension: 36,
                    animates: false
                )
                Text(authorName)
                    .fontWeight(.semibold)
                    .foregroundStyle(authorColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if canMentionAuthor {
                ComposerReplyMentionButton(
                    mentionsAuthor: mentionsAuthor,
                    action: toggleMention
                )
            }

            HoverCloseButton(
                help: "Cancel reply",
                accessibilityIdentifier: "composer-reply-close",
                diameter: 30,
                iconSize: 13,
                action: cancel
            )
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(.primary.opacity(0.035))
    }

    private var authorColor: Color {
        roleColorHex.map(Color.init(hex:)) ?? .primary
    }
}

private struct ComposerReplyMentionButton: View {
    let mentionsAuthor: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "at")
                Text(mentionsAuthor ? "ON" : "OFF")
            }
            .font(.callout.weight(.bold))
            .foregroundStyle(mentionsAuthor ? Color.accentColor : .secondary)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(Capsule())
            .background {
                Capsule()
                    .fill(.primary.opacity(isHovered ? 0.09 : 0.001))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .help(
            mentionsAuthor
                ? "Disable reply notification"
                : "Enable reply notification"
        )
        .accessibilityLabel("Reply notification")
        .accessibilityValue(mentionsAuthor ? "On" : "Off")
    }
}
