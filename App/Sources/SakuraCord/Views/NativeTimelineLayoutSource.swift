import Foundation
import MessageRendering
import SakuraCordModels

/// The invite entry fields consumed by geometry, without its observable store.
struct NativeTimelineInviteEntry {
    let invite: ServerInvite?
    let adaptiveColor: UInt32?
    let error: String?
    let isUnavailable: Bool
    let isLoading: Bool
}

extension AppModel {
    var messageSpacing: Double { appearanceSettings.messageSpacing }
    var roleColorDisplay: RoleColorDisplay { accessibilitySettings.roleColorDisplay }
    var currentUserID: UserID? { currentUser?.id }
    var supportsComponents: Bool { supportsCapability(.components) }
    var supportsRemoteComponentChoices: Bool { supportsCapability(.remoteComponentChoices) }

    func bubbleContext(for message: Message) -> NativeTimelineBubbleLayout.Context {
        let isEnabled =
            messageAppearance(for: message.channelID) == .bubbles
                && !message.type.hasGeneratedContent
        // Standard message layout never consumes bubble identity. Avoid an
        // account-wide channel search for every newly paginated message.
        guard isEnabled else {
            return NativeTimelineBubbleLayout.Context(isEnabled: false, isOutgoing: false, showsAvatar: true)
        }
        let selectedChannel = self.selectedChannel
        let channel = selectedChannel?.id == message.channelID
            ? selectedChannel
            : messagePresentationChannelsByID[message.channelID]
        return NativeTimelineBubbleLayout.Context(
            isEnabled: isEnabled,
            isOutgoing: isEnabled
                && message.author.id == currentUser?.id,
            showsAvatar: NativeTimelineBubbleLayout.showsAvatar(in: channel)
        )
    }

    func mentionUser(_ userID: UserID, in message: Message?) -> User? {
        AppModelMentionResolver(model: self, message: message).user(userID)
    }

    func mentionRole(_ roleID: RoleID, in message: Message?) -> GuildRole? {
        AppModelMentionResolver(model: self, message: message).role(roleID)
    }

    func mentionPresentation(_ mention: RenderedMention, in message: Message?) -> MentionPresentation {
        AppModelMentionResolver(model: self, message: message).presentation(mention)
    }

    func mentionAvatarURL(_ mention: RenderedMention, in message: Message?) -> URL? {
        AppModelMentionResolver(model: self, message: message).avatarURL(mention)
    }

    func inviteEntry(for reference: ServerInviteReference) -> NativeTimelineInviteEntry? {
        serverInvites.entries[reference].map {
            NativeTimelineInviteEntry(
                invite: $0.invite, adaptiveColor: $0.adaptiveColor, error: $0.error,
                isUnavailable: $0.isUnavailable, isLoading: $0.isLoading
            )
        }
    }

    func isInviteExpanded(_ reference: ServerInviteReference) -> Bool {
        serverInvites.expanded.contains(reference)
    }

    func isLeavingInviteGuild(_ guildID: GuildID) -> Bool {
        serverInvites.leaving.contains(guildID)
    }

    func isJoiningInviteGuild(_ guildID: GuildID) -> Bool {
        serverInvites.joining.contains(guildID)
    }

    func presentationGuild(_ guildID: GuildID) -> Guild? {
        serverRailGuildsByID[guildID]
    }

    func forwardedSourceChannel(_ channelID: ChannelID) -> Channel? {
        messagePresentationChannelsByID[channelID]
    }
}

private struct AppModelMentionResolver {
    let model: AppModel
    let message: Message?

    init(model: AppModel, message: Message? = nil) {
        self.model = model
        self.message = message
    }

    private func member(_ id: UserID) -> Member? {
        sourceGuildID.flatMap { model.membersByGuildID[$0]?[id] }
            ?? (sourceGuildID == model.selectedGuildID ? model.membersByID[id] ?? model.knownMentionMembers[id] : nil)
    }

    func user(_ userID: UserID) -> User? {
        member(userID)?.user
            ?? message?.mentionedUsers.first { $0.id == userID }
            ?? model.messages.first { $0.author.id == userID }?.author
            ?? model.threadMessages.first { $0.author.id == userID }?.author
            ?? (model.currentUser?.id == userID ? model.currentUser : nil)
    }

    func presentation(_ mention: RenderedMention) -> MentionPresentation {
        switch mention.kind {
        case .guildNavigation: guildNavigationPresentation(mention)
        case .user: userPresentation(mention)
        case .role: rolePresentation(mention)
        case .channel: channelPresentation(mention)
        case .channelLink: channelLinkPresentation(mention)
        case .message: messagePresentation(mention)
        }
    }

    /// Media discovery only needs the avatar carried by user mentions. Going
    /// through the complete presentation switch for channel, role, and
    /// message mentions performs unrelated channel/role lookups even though
    /// those presentations can never contribute a media key.
    func avatarURL(_ mention: RenderedMention) -> URL? {
        guard mention.kind == .user,
              let userID = UserID(mention.id)
        else { return nil }
        let member = member(userID)
        return member?.guildAvatarURL ?? user(userID)?.avatarURL
    }

    private func userPresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let userID = UserID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let member = member(userID)
        let value = user(userID)
        let topColor = member.flatMap {
            MessageAuthorPresentation.topRoleColor(in: $0.roles)
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: "@\((sourceGuildID == nil ? model.friendNickname(for: userID) : nil) ?? member?.user.displayName ?? value?.displayName ?? "unknown-user")",
            target: .user(userID),
            avatarURL: member?.guildAvatarURL ?? value?.avatarURL,
            colorHex: topColor
        )
    }

    func role(_ roleID: RoleID) -> GuildRole? {
        let roles = sourceGuildID.flatMap { model.guildRolesByGuildID[$0] }
            ?? (sourceGuildID == model.selectedGuildID ? model.guildRoles : [])
        return roles.first { $0.id == roleID }
    }

    private func rolePresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let roleID = RoleID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let role = role(roleID)
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: "@\(role?.name ?? "unknown-role")",
            target: .role(roleID),
            colorHex: role?.colorHex
        )
    }

    private func guildNavigationPresentation(_ mention: RenderedMention) -> MentionPresentation {
        var presentation = MentionPresentation.fallback(for: mention)
        if let destination = GuildNavigationMention(rawValue: mention.id),
           let guildID = sourceGuildID,
           model.hasGuildNavigationDestination(destination, in: guildID) {
            presentation = MentionPresentation(
                rawToken: mention.rawToken, label: destination.title,
                target: .guildNavigation(guildID: guildID, destination: destination),
                systemImage: presentation.systemImage
            )
        }
        return presentation
    }

    private func channelPresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let channelID = ChannelID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let channel = channel(channelID)
        if channel == nil, let thread = model.messagePresentationThread(channelID) {
            return threadPresentation(thread, mention: mention)
        }
        let guildName = channel?.guildID.flatMap { model.serverRailGuildsByID[$0]?.name }
        let label = if crossesGuild(targetGuildID: channel?.guildID),
                       let guildName,
                       let channel
        {
            "\(guildName) / \(channel.name)"
        } else {
            channel?.name ?? "unknown-channel"
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: label,
            target: .channel(channelID),
            systemImage: ChannelIconPresentation.systemImage(
                for: channel?.kind ?? .unknown,
                isHidden: false
            )
        )
    }

    private func channelLinkPresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let channelID = ChannelID(mention.id) else {
            return MentionPresentation.fallback(for: mention)
        }
        let guildID = mention.messageGuildID.flatMap(GuildID.init)
        if let channel = channel(channelID) {
            let guildName = channel.guildID.flatMap { model.serverRailGuildsByID[$0]?.name }
            let label = if crossesGuild(targetGuildID: channel.guildID), let guildName {
                "\(guildName) / \(channel.name)"
            } else {
                channel.name
            }
            return MentionPresentation(
                rawToken: mention.rawToken,
                label: label,
                target: .channel(channelID),
                systemImage: ChannelIconPresentation.systemImage(
                    for: channel.kind,
                    isHidden: false
                )
            )
        }
        if let thread = model.messagePresentationThread(channelID) {
            return threadPresentation(thread, mention: mention, linkGuildID: guildID)
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: MentionPresentation.unknownChannelLinkLabel,
            target: .linkedChannel(guildID: guildID, channelID: channelID),
            systemImage: ChannelIconPresentation.systemImage(for: .unknown, isHidden: false)
        )
    }

    /// A known thread or forum post, which opens like a thread link.
    private func threadPresentation(
        _ thread: MessageThreadSummary,
        mention: RenderedMention,
        linkGuildID: GuildID? = nil
    ) -> MentionPresentation {
        let guildID = thread.guildID ?? linkGuildID
        let label = if crossesGuild(targetGuildID: guildID),
                       let guildName = guildID.flatMap({ model.serverRailGuildsByID[$0]?.name })
        {
            "\(guildName) / \(thread.name)"
        } else {
            thread.name
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: label,
            target: .linkedChannel(guildID: guildID, channelID: thread.id),
            systemImage: ChannelIconPresentation.systemImage(forThreadInForum: model.isForumPost(thread))
        )
    }

    private func messagePresentation(_ mention: RenderedMention) -> MentionPresentation {
        guard let rawChannelID = mention.messageChannelID,
              let channelID = ChannelID(rawChannelID),
              let messageID = MessageID(mention.id)
        else {
            return MentionPresentation.fallback(for: mention)
        }
        let guildID = mention.messageGuildID.flatMap(GuildID.init)
        // A message in a thread or forum post is labeled with that thread.
        let name = channel(channelID)?.name ?? model.messagePresentationThread(channelID)?.name
        let guildName = guildID.flatMap { model.serverRailGuildsByID[$0]?.name }
        let channelLabel = if crossesGuild(targetGuildID: guildID),
                              let guildName,
                              let name
        {
            "\(guildName) / \(name) ›"
        } else {
            "\(name ?? MentionPresentation.unknownChannelLinkLabel) ›"
        }
        return MentionPresentation(
            rawToken: mention.rawToken,
            label: channelLabel,
            target: .message(
                guildID: guildID,
                channelID: channelID,
                messageID: messageID
            ),
            systemImage: "bubble.left.fill"
        )
    }

    private func channel(_ channelID: ChannelID) -> Channel? {
        model.messagePresentationChannel(channelID)
    }

    private var sourceGuildID: GuildID? {
        if let guildID = message?.guildID { return guildID }
        // REST thread messages, such as a forum card's starter, omit their guild.
        if let channelID = message?.channelID {
            return channel(channelID)?.guildID ?? model.messagePresentationThread(channelID)?.guildID
        }
        return model.selectedGuildID
    }

    private func crossesGuild(targetGuildID: GuildID?) -> Bool {
        guard let targetGuildID, let sourceGuildID else { return false }
        return targetGuildID != sourceGuildID
    }
}
