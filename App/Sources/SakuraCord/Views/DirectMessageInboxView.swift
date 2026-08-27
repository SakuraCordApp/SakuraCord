import SakuraCordModels
import SwiftUI

struct DirectMessageInboxView: View {
    let model: AppModel
    let channels: [Channel]
    let membersByID: [UserID: Member]
    let privateCallsByChannel: [ChannelID: PrivateCall]
    let animatesAvatars: Bool
    @Binding var selection: ChannelID?
    let bottomContentInset: CGFloat

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(directMessages) { channel in
                    DirectMessageInboxRow(
                        model: model,
                        channel: channel,
                        member: DirectMessageInboxPolicy.recipientMember(
                            for: channel,
                            membersByID: membersByID
                        ),
                        call: privateCallsByChannel[channel.id],
                        animatesAvatar: animatesAvatars
                    )
                        .tag(channel.id)
                }

                SidebarBottomScrollSpacer(height: bottomContentInset)
            } header: {
                Text("Direct Messages")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollClipDisabled()
        .padding(.top, ChatChromeMetrics.channelListTopPadding)
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

    static func callStatus(for call: PrivateCall?) -> String? {
        guard call?.ongoingRings.isEmpty == false else { return nil }
        return "Ringing"
    }
}

private struct DirectMessageInboxRow: View {
    let model: AppModel
    let channel: Channel
    let member: Member?
    let call: PrivateCall?
    let animatesAvatar: Bool

    var body: some View {
        HStack(spacing: 10) {
            DirectMessageAvatar(
                channel: channel,
                size: 32,
                status: channel.kind == .directMessage ? member?.status ?? .offline : nil,
                animates: animatesAvatar
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .fontWeight(
                        channel.unreadCount > 0 && !isMuted
                            ? .semibold
                            : .regular
                    )
                    .foregroundStyle(
                        isMuted
                            ? Color.primary.opacity(0.35)
                            : Color.primary
                    )
                    .lineLimit(1)
                if let callStatus =
                    DirectMessageInboxPolicy.callStatus(for: call)
                {
                    Label(callStatus, systemImage: "bell.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: 0x23A55A))
                    .lineLimit(1)
                } else if let secondaryText =
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
        .overlay {
            ChannelContextMenuBridge(
                isSelected: model.selectedChannelID == channel.id,
                isUnread: channel.unreadCount > 0,
                isMutationPending:
                    model.isChannelNotificationMutationPending(channel.id),
                directOverride: model.channelNotificationOverride(for: channel),
                inheritedLevel:
                    model.inheritedChannelNotificationLevel(for: channel),
                inheritanceSource: .directMessages,
                markRead: {
                    model.markConversationRead(channelID: channel.id)
                },
                mute: { duration in
                    model.setChannelMute(
                        true,
                        until: duration.endDate(),
                        for: channel
                    )
                },
                unmute: {
                    model.setChannelMute(false, until: nil, for: channel)
                },
                setNotificationLevel: { level in
                    model.setChannelNotificationLevel(level, for: channel)
                },
                copyChannelID: {
                    ChannelContextMenuValue.copy(channel.id.description)
                },
                copyLink: {
                    ChannelContextMenuValue.copy(
                        ChannelContextMenuValue.link(
                            guildID: nil,
                            channelID: channel.id
                        )
                    )
                }
            )
        }
    }

    private var isMuted: Bool {
        model.isChannelMuted(channel)
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
    let animates: Bool

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
            AvatarView(name: channel.name, url: iconURL, size: size, animates: animates)
        } else if channel.kind == .directMessage, let recipient = channel.recipients.first {
            AvatarView(
                name: recipient.displayName,
                url: recipient.avatarURL,
                size: size,
                animates: animates
            )
        } else {
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(SakuraCordAccentColor.color.gradient, in: Circle())
                .accessibilityLabel("\(channel.name) group avatar")
        }
    }
}
