import SakuraCordModels
import SwiftUI

struct DirectMessageInboxView: View {
    let channels: [Channel]
    let membersByID: [UserID: Member]
    @Binding var selection: ChannelID?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(directMessages) { channel in
                    DirectMessageInboxRow(
                        channel: channel,
                        member: DirectMessageInboxPolicy.recipientMember(
                            for: channel,
                            membersByID: membersByID
                        )
                    )
                        .tag(channel.id)
                }
            } header: {
                Text("Direct Messages")
                    .padding(.top, ChatChromeMetrics.channelListTopPadding)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .clipped()
        .overlay {
            if directMessages.isEmpty {
                ContentUnavailableView(
                    "No direct messages",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Your existing conversations will appear here.")
                )
                .allowsHitTesting(false)
            }
        }
    }

    private var directMessages: [Channel] {
        DirectMessageInboxPolicy.conversations(in: channels)
    }
}

nonisolated enum DirectMessageInboxPolicy {
    static func conversations(in channels: [Channel]) -> [Channel] {
        channels.filter {
            $0.kind == .directMessage || $0.kind == .groupDirectMessage
        }
    }

    static func recipientMember(
        for channel: Channel,
        membersByID: [UserID: Member]
    ) -> Member? {
        guard channel.kind == .directMessage,
              let recipient = channel.recipients.first
        else { return nil }
        return membersByID[recipient.id]
    }

    static func secondaryText(for channel: Channel, member: Member? = nil) -> String? {
        if channel.kind == .groupDirectMessage {
            return "\(channel.recipients.count + 1) members"
        }
        guard channel.kind == .directMessage else { return nil }
        guard let rawStatus = member?.customStatus else { return nil }
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty
        else { return nil }
        return status
    }
}

private struct DirectMessageInboxRow: View {
    let channel: Channel
    let member: Member?

    var body: some View {
        HStack(spacing: 10) {
            DirectMessageAvatar(
                channel: channel,
                size: 32,
                status: channel.kind == .directMessage ? member?.status ?? .offline : nil
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .fontWeight(channel.unreadCount > 0 ? .semibold : .regular)
                    .lineLimit(1)
                if let secondaryText =
                    DirectMessageInboxPolicy.secondaryText(for: channel, member: member)
                {
                    ProfileStatusTextView(
                        source: secondaryText,
                        isExpanded: false,
                        fontSize: 12,
                        usesSecondaryColor: true
                    )
                        .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 16, alignment: .leading)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }

            Spacer(minLength: 0)

            if channel.mentionCount > 0 {
                Text(channel.mentionCount, format: .number)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            } else if channel.unreadCount > 0 {
                Circle()
                    .fill(.primary)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unread")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if channel.mentionCount > 0 {
            return channel.mentionCount == 1
                ? "1 unread mention"
                : "\(channel.mentionCount) unread mentions"
        }
        return channel.unreadCount > 0 ? "Unread" : ""
    }
}

struct DirectMessageAvatar: View {
    let channel: Channel
    let size: CGFloat
    let status: PresenceStatus?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatar
            if let status {
                PresenceIndicator(status: status, size: size * 0.3)
                    .overlay(
                        Circle().stroke(
                            Color(nsColor: .controlBackgroundColor),
                            lineWidth: 2
                        )
                    )
                    .offset(x: 1, y: 1)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let iconURL = channel.iconURL {
            AvatarView(name: channel.name, url: iconURL, size: size)
        } else if channel.kind == .directMessage, let recipient = channel.recipients.first {
            AvatarView(name: recipient.displayName, url: recipient.avatarURL, size: size)
        } else {
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.accentColor.gradient, in: Circle())
                .accessibilityLabel("\(channel.name) group avatar")
        }
    }
}
