import SakuraCordModels
import SwiftUI

struct DirectMessageInboxView: View {
    let model: AppModel
    let channels: [Channel]
    let membersByID: [UserID: Member]
    let privateCallsByChannel: [ChannelID: PrivateCall]
    let animatesAvatars: Bool
    @Binding var selection: DirectMessageSidebarSelection?
    let bottomContentInset: CGFloat

    var body: some View {
        let pinnedChannelIDs = model.pinnedDirectMessageIDs
        let directMessages = DirectMessageInboxPolicy.conversations(
            in: channels,
            pinnedChannelIDs: pinnedChannelIDs
        )

        let messageRequests = model.messageRequestChannels

        List(selection: $selection) {
            DirectMessageHomeRow(
                title: "Friends", systemImage: "person.2.fill", countedItem: "friend request",
                count: model.incomingFriendRequestCount, isSelected: selection == .friends
            )
            .tag(DirectMessageSidebarSelection.friends)
            .pointerStyle(.link)
            .overlay { ChannelRowHoverBridge(isSelected: selection == .friends) }

            // Discord shows the row only while requests or spam wait; its
            // badge counts requests alone.
            if !messageRequests.isEmpty {
                DirectMessageHomeRow(
                    title: "Message Requests", systemImage: "envelope.fill", countedItem: "message request",
                    count: messageRequests.count { $0.messageRequest == .pending },
                    isSelected: selection == .messageRequests
                )
                .tag(DirectMessageSidebarSelection.messageRequests)
                .pointerStyle(.link)
                .overlay { ChannelRowHoverBridge(isSelected: selection == .messageRequests) }
            }

            Section {
                ForEach(directMessages) { channel in
                    DirectMessageInboxRow(
                        model: model,
                        channel: channel,
                        isSelected: selection == .channel(channel.id),
                        isPinned: pinnedChannelIDs.contains(channel.id),
                        member: DirectMessageInboxPolicy.recipientMember(
                            for: channel,
                            membersByID: membersByID
                        ),
                        call: privateCallsByChannel[channel.id],
                        animatesAvatar: animatesAvatars
                    )
                    .tag(DirectMessageSidebarSelection.channel(channel.id))
                    .pointerStyle(.link)
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
}

/// A Direct Messages home destination above the conversations.
private struct DirectMessageHomeRow: View {
    let title: String
    let systemImage: String
    let countedItem: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: systemImage)
                .font(.interfaceSystem(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
            Text(title)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if count > 0 {
                Text(count, format: .number)
                    .font(.interface(.caption2).bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, InterfaceScale.metric(6))
                    .padding(.vertical, InterfaceScale.metric(2))
                    .background(Color(hex: 0xF23F43), in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(count == 0 ? "" : count == 1 ? "1 pending \(countedItem)" : "\(count) pending \(countedItem)s")
    }
}

nonisolated enum DirectMessageInboxPolicy {
    static func conversations(
        in channels: [Channel],
        pinnedChannelIDs: Set<ChannelID> = []
    ) -> [Channel] {
        let conversations = channels.filter {
            ($0.kind == .directMessage || $0.kind == .groupDirectMessage) && $0.messageRequest == nil
        }
        let pinned = conversations.filter { pinnedChannelIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let leftActivity = lhs.lastMessageID?.createdAt ?? lhs.id.createdAt
                let rightActivity = rhs.lastMessageID?.createdAt ?? rhs.id.createdAt
                return leftActivity > rightActivity
            }
        return pinned + conversations.filter { !pinnedChannelIDs.contains($0.id) }
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
    let isSelected: Bool
    let isPinned: Bool
    let member: Member?
    let call: PrivateCall?
    let animatesAvatar: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            DirectMessageAvatar(
                channel: channel,
                size: InterfaceScale.metric(32),
                status: channel.kind == .directMessage ? member?.status ?? .offline : nil,
                isMobile: member?.showsMobileIndicator ?? false,
                animates: animatesAvatar,
                isHovered: isHovered
            )
            .opacity(suppression != nil ? 0.5 : dimsMutedConversation ? 0.3 : 1)

            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                Text(channel.name)
                    .accessibilityLabel(isMuted ? "\(channel.name), Muted" : channel.name)
                    .fontWeight(
                        channel.unreadCount > 0 && !isMuted && suppression == nil
                            ? .semibold
                            : .regular
                    )
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                if suppression == nil, let callStatus =
                    DirectMessageInboxPolicy.callStatus(for: call)
                {
                    Label(callStatus, systemImage: "bell.fill")
                    .font(.interface(.caption))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: 0x23A55A))
                    .lineLimit(1)
                } else if channel.kind == .groupDirectMessage {
                    Text("\(channel.recipients.count + 1) members")
                        .font(.interfaceSystem(size: 12))
                        .foregroundStyle(.secondary)
                        .opacity(dimsMutedConversation ? 0.65 : 1)
                        .lineLimit(1)
                } else if suppression == nil, let secondaryText =
                    DirectMessageInboxPolicy.secondaryText(for: channel, member: member)
                {
                    ProfileStatusTextView(
                        source: secondaryText,
                        isExpanded: false,
                        fontSize: 12,
                        usesSecondaryColor: true
                    )
                        .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(14), maxHeight: InterfaceScale.metric(16), alignment: .leading)
                        .lineLimit(1)
                        .opacity(dimsMutedConversation ? 0.65 : 1)
                        .allowsHitTesting(false)
                }
            }

            Spacer(minLength: 0)

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned direct message")
            }

            if channel.mentionCount > 0 {
                Text(channel.mentionCount, format: .number)
                    .font(.interface(.caption2).bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, InterfaceScale.metric(6))
                    .padding(.vertical, InterfaceScale.metric(2))
                    .background(Color(hex: 0xF23F43), in: Capsule())
            } else if channel.unreadCount > 0 {
                Circle()
                    .fill(.primary)
                    .frame(width: InterfaceScale.metric(7), height: InterfaceScale.metric(7))
                    .accessibilityLabel("Unread")
            }

            if let suppression {
                Image(systemName: suppression.systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .onModalHover { isHovered = $0 }
        .overlay {
            ChannelContextMenuBridge(
                isSelected: isSelected,
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
                },
                pinAction: .available(isPinned: isPinned, toggle: {
                    model.toggleDirectMessagePin(channel.id)
                }),
                userMenu: {
                    guard channel.kind == .directMessage, let recipient = channel.recipients.first else { return nil }
                    return UserContextMenu.make(for: recipient, context: .init(channelID: channel.id, ignoreLocation: .directMessage), model: model)
                },
                groupActions: model.offersGroupDirectMessageActions(channel)
                    ? GroupDirectMessageMenuActions(
                        edit: { model.presentGroupDirectMessageEditor(for: channel.id) },
                        leave: { model.presentLeaveGroupDirectMessage(for: channel.id) }
                    )
                    : nil,
                closeDirectMessage: model.offersCloseDirectMessage(channel)
                    ? { model.closeDirectMessage(channel) }
                    : nil
            )
        }
    }

    private var suppression: UserContentSuppression? {
        guard channel.kind == .directMessage, let recipient = channel.recipients.first else { return nil }
        return model.userSuppressionReason(recipient.id)
    }

    private var isMuted: Bool {
        model.isChannelMuted(channel)
    }

    private var dimsMutedConversation: Bool {
        isMuted && !isSelected
    }

    private var nameColor: Color {
        if suppression != nil { return .primary.opacity(0.45) }
        if isSelected { return .primary }
        if isMuted { return .primary.opacity(0.3) }
        return channel.unreadCount > 0 ? .primary : .secondary
    }

    private var accessibilityValue: String {
        var states: [String] = suppression.map { [$0.rawValue.capitalized] } ?? []
        if channel.mentionCount > 0 {
            states.append(channel.mentionCount == 1
                ? "1 unread mention"
                : "\(channel.mentionCount) unread mentions")
        } else if channel.unreadCount > 0 {
            states.append("Unread")
        }
        return states.joined(separator: ", ")
    }
}

struct DirectMessageAvatar: View {
    let channel: Channel
    let size: CGFloat
    let status: PresenceStatus?
    var isMobile = false
    let animates: Bool
    var isHovered: Bool?
    @State private var isPointerInside = false

    var body: some View {
        content
            .onModalHover { isPointerInside = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if let status {
            AvatarPresenceView(
                status: status,
                avatarSize: size,
                indicatorSize: size * 0.3,
                isMobile: isMobile
            ) {
                avatar
            }
        } else {
            avatar
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let iconURL = channel.iconURL {
            AvatarView(name: channel.name, url: iconURL, size: size, animates: animates, isHovered: isHovered ?? isPointerInside)
        } else if channel.kind == .directMessage, let recipient = channel.recipients.first {
            AvatarView(
                name: recipient.displayName,
                url: recipient.avatarURL,
                size: size,
                animates: animates,
                isHovered: isHovered ?? isPointerInside
            )
        } else if channel.kind == .groupDirectMessage,
                  channel.recipients.count >= 2
        {
            GroupDirectMessageAvatar(
                first: channel.recipients[0],
                second: channel.recipients[1],
                name: channel.name,
                size: size,
                animates: animates,
                isHovered: isHovered ?? isPointerInside
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

private struct GroupDirectMessageAvatar: View {
    let first: User
    let second: User
    let name: String
    let size: CGFloat
    let animates: Bool
    let isHovered: Bool

    private var backSize: CGFloat { size * 0.68 }
    private var frontSize: CGFloat { size * 0.75 }
    private var frontOrigin: CGFloat { size - frontSize }
    private var clearance: CGFloat { size * 0.05 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AvatarView(
                name: first.displayName,
                url: first.avatarURL,
                size: backSize,
                animates: animates,
                isHovered: isHovered
            )
            .mask {
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: backSize, height: backSize))
                    path.addEllipse(in: CGRect(
                        x: frontOrigin - clearance,
                        y: frontOrigin - clearance,
                        width: frontSize + 2 * clearance,
                        height: frontSize + 2 * clearance
                    ))
                }
                .fill(.white, style: FillStyle(eoFill: true))
            }

            AvatarView(
                name: second.displayName,
                url: second.avatarURL,
                size: frontSize,
                animates: animates,
                isHovered: isHovered
            )
            .offset(x: frontOrigin, y: frontOrigin)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) group avatar")
    }
}
