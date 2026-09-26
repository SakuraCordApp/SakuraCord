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

    func isForumPostUnread(_ post: ForumPost) -> Bool {
        readState.entries[post.id]?.isUnread ?? post.isUnread
    }

    func isForumNotificationMutationPending(_ postID: ChannelID) -> Bool {
        forumNotificationMutationTasks[postID] != nil
    }

    func inheritedForumPostNotificationLevel(
        _ post: ForumPost
    ) -> MessageNotificationLevel {
        guard let parentID = post.thread.parentID,
              let parent =
              snapshot?.channels.first(where: { $0.id == parentID })
                ?? visibleChannels.first(where: { $0.id == parentID })
        else { return .onlyMentions }
        if let configured = channelNotificationOverride(for: parent)?
            .messageNotifications,
           configured != .inherit
        {
            return configured
        }
        return inheritedChannelNotificationLevel(for: parent)
    }

    func isForumPostNew(_ post: ForumPost) -> Bool {
        readState.isNewForumPost(post)
    }

    func shouldEmphasizeForumPost(_ post: ForumPost) -> Bool {
        isForumPostUnread(post) || readState.isUnopenedForumPost(post)
    }

    func forumUnreadMessageCount(_ post: ForumPost) -> Int {
        guard isForumPostUnread(post) else { return 0 }
        return readState.unreadMessageCount(channelID: post.id)
    }

    func deliverNativeNotification(for message: Message, isMention: Bool = false) {
        // Keep synthetic performance events away from Notification Center's XPC queue.
        guard !runsChatPerformanceBenchmark else { return }
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
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            let presentation = NotificationContentPresentation.make(
                message: message,
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
        case .user:
            let userID = UserID(mention.id)
            let member = userID.flatMap { id in guildID.flatMap { membersByGuildID[$0]?[id] } }
            let user = message.mentionedUsers.first { $0.id == userID }
                ?? userID.flatMap { knownMentionMembers[$0]?.user }
                ?? (snapshot?.currentUser.id == userID ? snapshot?.currentUser : nil)
            return "@\(member?.user.displayName ?? user?.displayName ?? "unknown-user")"
        case .role:
            let roles = guildID.flatMap { guildRolesByGuildID[$0] }
                ?? (guildID == selectedGuildID ? guildRoles : [])
            return "@\(roles.first { String($0.id.rawValue) == mention.id }?.name ?? "unknown-role")"
        case .game:
            return gameMentionsByID[mention.id]?.name ?? "Game"
        case .broadcast:
            return mention.rawToken
        case .timestamp:
            return DiscordTimestampToken(rawToken: mention.rawToken)?.formatted() ?? mention.rawToken
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

    func deliverIncomingCallNotification(_ call: PrivateCall) {
        guard !runsChatPerformanceBenchmark,
              let currentUserID = snapshot?.currentUser.id
        else { return }
        guard notificationPreferences.allows(
            .incomingCall,
            isCurrentConversation: readState.isActivelyPresentedAtNewest(call.channelID)
        ) else { return }
        guard notificationPreferences.isEnabled, !applicationIsActive else { return }
        let channel = snapshot?.channels.first { $0.id == call.channelID }
            ?? visibleChannels.first { $0.id == call.channelID }
        let callerID = call.ongoingRings.first { $0.recipientID == currentUserID }?.senderID
        let caller = callerID.flatMap { id in
            channel?.recipients.first { $0.id == id }
                ?? snapshot?.members.first { $0.user.id == id }?.user
        }
        let accountID = readState.accountID ?? "offline"
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            await model.notificationService.deliverIncomingCall(
                call: call,
                channel: channel,
                caller: caller,
                accountID: accountID,
                preferences: model.notificationPreferences
            )
        }
    }

    func cancelIncomingCallNotification(channelID: ChannelID) {
        guard !runsChatPerformanceBenchmark else { return }
        let accountID = readState.accountID ?? "offline"
        let account = accountSession()
        startAccountChildTask(account: account) { model, account in
            guard model.isCurrentAccountSession(account), !Task.isCancelled else { return }
            await model.notificationService.cancelIncomingCall(
                accountID: accountID,
                channelID: channelID
            )
        }
    }
}
