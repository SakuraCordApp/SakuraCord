import CoreAudio
import DiscordProtocol
import Foundation
import MediaPipeline
import MessageRendering
import OSLog
import SakuraCordModels
import SakuraCordPersistence
import UniformTypeIdentifiers

extension AppModel {
    func isChannelUnread(_ channelID: ChannelID) -> Bool {
        readState.unread(channelID: channelID)
    }

    func channelNotificationOverride(
        for channel: Channel
    ) -> ChannelNotificationOverride? {
        readState.notificationOverride(
            channelID: channel.id,
            guildID: channel.guildID
        )
    }

    func isChannelMuted(_ channel: Channel) -> Bool {
        readState.isChannelMuted(channel)
    }

    func usesAllMessagesUnreadSetting(_ channel: Channel) -> Bool {
        readState[channel.id].map(readState.usesAllMessagesUnreadSetting(for:)) ?? false
    }

    func inheritedChannelNotificationLevel(
        for channel: Channel
    ) -> MessageNotificationLevel {
        readState.inheritedNotificationLevel(for: channel)
    }

    func isChannelNotificationMutationPending(_ channelID: ChannelID) -> Bool {
        channelNotificationMutationTasks[channelID] != nil
            || categoryCollapseMutationTasks[channelID] != nil
    }

    func guildNotificationSettings(for guild: Guild) -> GuildNotificationSettings {
        readState.notificationSettings(guildID: guild.id)
            ?? GuildNotificationSettings(
                guildID: guild.id,
                messageNotifications: guild.defaultMessageNotifications
            )
    }

    func isGuildNotificationMutationPending(_ guildID: GuildID) -> Bool {
        guildNotificationMutationTasks[guildID] != nil
            || guildAcknowledgementTasks[guildID] != nil
    }

    func isForumNotificationMutationPending(_ postID: ChannelID) -> Bool {
        forumNotificationMutationTasks[postID] != nil
    }

    func inheritedForumPostNotificationLevel(
        _ post: ForumPost
    ) -> MessageNotificationLevel {
        guard let parentID = post.thread.parentID,
              let parent = messagePresentationChannel(parentID)
        else { return .onlyMentions }
        if let configured = channelNotificationOverride(for: parent)?
            .messageNotifications,
           configured != .inherit
        {
            return configured
        }
        return inheritedChannelNotificationLevel(for: parent)
    }

    func shouldEmphasizeForumPost(_ post: ForumPost) -> Bool {
        readState.isForumPostUnread(channelID: post.id) == true
    }

    /// Discord's card footer counts new replies only in an unread post the
    /// account has opened, never more than its replies, so an unread starter
    /// alone shows zero.
    func forumUnreadMessageCount(_ post: ForumPost) -> Int? {
        guard shouldEmphasizeForumPost(post),
              readState[post.id]?.trackedAcknowledgedMessageID != nil
        else { return nil }
        return min(readState.unreadMessageCount(channelID: post.id), max(0, post.thread.messageCount))
    }

    func deliverNativeNotification(for message: Message, isMention: Bool = false) {
        // Keep synthetic performance events away from Notification Center's XPC queue.
        guard !runsChatPerformanceBenchmark, currentStatus != .dnd, !isMessageSuppressed(message) else { return }
        // A call announces itself by ringing, not with a banner for its message.
        guard message.type != .call else { return }
        let channel = snapshot?.channels.first { $0.id == message.channelID }
            ?? visibleChannels.first { $0.id == message.channelID }
        guard let currentUserID = snapshot?.currentUser.id else { return }
        let event = NotificationEventContext.message(
            message,
            channel: channel,
            isMention: isMention,
            currentUserID: currentUserID
        )
        guard notificationPreferences.allows(
            event,
            isCurrentConversation: readState.isActivelyPresentedAtNewest(message.channelID)
        ) else { return }
        if applicationIsActive || !notificationPreferences.isEnabled {
            if notificationPreferences.playsSound { soundPlayer.play(.message) }
            return
        }
        let guildID = message.guildID ?? channel?.guildID
        let guild = guildID.flatMap { serverRailGuildsByID[$0] }
        let accountID = readState.accountID ?? "offline"
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            guard model.isCurrentAccountSession(account), !Task.isCancelled,
                  model.currentStatus != .dnd, !model.isMessageSuppressed(message)
            else { return }
            var presented = message
            presented.author = model.privateConversationUser(message.author, in: guildID)
            let presentation = NotificationContentPresentation.make(
                message: presented,
                channel: channel,
                guild: guild,
                style: model.notificationPreferences.previewStyle,
                mentionLabel: { model.notificationMentionLabel($0, message: message) }
            )
            await model.notificationService.deliverMessage(
                message: message,
                channel: channel,
                guild: guild,
                accountID: accountID,
                presentation: presentation,
                preferences: model.notificationPreferences
            )
        }
    }

    private func notificationMentionLabel(_ mention: RenderedMention, message: Message) -> String {
        let guildID = message.guildID
            ?? snapshot?.channels.first { $0.id == message.channelID }?.guildID
        switch mention.kind {
        case .guildNavigation: return GuildNavigationMention(rawValue: mention.id)?.title ?? mention.rawToken
        case .user:
            let userID = UserID(mention.id)
            let member = userID.flatMap { id in guildID.flatMap { membersByGuildID[$0]?[id] } }
            let user = message.mentionedUsers.first { $0.id == userID }
                ?? userID.flatMap { knownMentionMembers[$0]?.user }
                ?? (snapshot?.currentUser.id == userID ? snapshot?.currentUser : nil)
            let friendNickname = guildID == nil ? userID.flatMap(friendNickname(for:)) : nil
            return "@\(friendNickname ?? member?.user.displayName ?? user?.displayName ?? "unknown-user")"
        case .role:
            let roles = guildID.flatMap { guildRolesByGuildID[$0] }
                ?? (guildID == selectedGuildID ? guildRoles : [])
            return "@\(roles.first { String($0.id.rawValue) == mention.id }?.name ?? "unknown-role")"
        case .channel, .channelLink:
            let id = ChannelID(mention.id)
            let channel = snapshot?.channels.first { $0.id == id }
                ?? visibleChannels.first { $0.id == id }
            return "#\(channel?.name ?? "unknown-channel")"
        case .message:
            return "Message link"
        }
    }

    func cancelNativeNotifications(channelID: ChannelID) {
        guard !runsChatPerformanceBenchmark,
              notificationPreferences.clearsWhenRead
        else { return }
        let accountID = readState.accountID ?? "offline"
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            await model.notificationService.cancel(
                accountID: accountID,
                channelID: channelID
            )
        }
    }
}
