import DiscordProtocol
import Foundation
import MessageRendering
import SakuraCordModels
import UserNotifications

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
        isNotificationMutationPending(.channel(channelID))
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
        isNotificationMutationPending(.guild(guildID))
            || guildAcknowledgementTasks[guildID] != nil
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
        let channel = knownRootChannel(message.channelID)
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
        case .game:
            return gameMentions.gamesByID[mention.id]?.name ?? MentionPresentation.fallback(for: mention).label
        case .broadcast, .command, .timestamp:
            return MentionPresentation.fallback(for: mention).label
        case .channel, .channelLink:
            let id = ChannelID(mention.id)
            let channel = id.flatMap(knownRootChannel)
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

    func requestNotificationPermission() async throws -> Bool {
        try await notificationService.requestAuthorization()
    }

    func requestNotificationPermissionIfNeeded() async {
        guard notificationPreferences.isEnabled,
              await notificationService.authorizationStatus() == .notDetermined
        else { return }
        _ = try? await notificationService.requestAuthorization()
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await notificationService.authorizationStatus()
    }

    func refreshDockBadge() {
        let count: Int? = switch notificationPreferences.dockBadgeStyle {
        case .mentions:
            AppPerformanceSignposts.measureSync("UnreadDockBadgeProjection") {
                readState.totalMentions
            }
        case .unreadConversations:
            readState.unreadPresentationProjection().unreadConversationCount
        case .off: nil
        }
        notificationService.setDockBadge(
            count ?? 0,
            enabled: count != nil
        )
    }

    func setGuildNotificationLevel(
        _ level: MessageNotificationLevel,
        for guild: Guild
    ) {
        let guildID = guild.id
        let started = runNotificationMutation(.guild(guildID), failureMessage: "Discord did not accept the server notification setting.") {
            try await $0.updateGuildNotificationLevel(guildID: guildID, level: level)
        } apply: { model in
            model.updateLocalGuildNotificationSettings(guild: guild) { $0.messageNotifications = level }
        } finish: { model in
            model.refreshServerRailPresentation(guildID: guildID)
        }
        if started { refreshServerRailPresentation(guildID: guildID) }
    }

    func setGuildMute(
        _ isMuted: Bool,
        until: Date?,
        for guild: Guild
    ) {
        let guildID = guild.id
        let started = runNotificationMutation(.guild(guildID), failureMessage: "Discord did not accept the server mute setting.") {
            try await $0.updateGuildMute(guildID: guildID, isMuted: isMuted, until: until)
        } apply: { model in
            model.updateLocalGuildNotificationSettings(guild: guild) { $0.setMuted(isMuted, until: until) }
        } finish: { model in
            model.refreshServerRailPresentation(guildID: guildID)
        }
        if started { refreshServerRailPresentation(guildID: guildID) }
    }

    func setGuildNotificationToggle(
        _ toggle: GuildNotificationToggle,
        isEnabled: Bool,
        for guild: Guild
    ) {
        let guildID = guild.id
        let settingsRevision = guildNotificationSettingsRevisions[guildID, default: 0]
        let started = runNotificationMutation(.guild(guildID), failureMessage: "Discord did not accept the server notification setting.") {
            try await $0.updateGuildNotificationToggle(guildID: guildID, toggle: toggle, isEnabled: isEnabled)
        } apply: { model in
            // A Gateway echo and a newer change from another client may
            // both arrive before HTTP completes. Keep that newer value.
            if model.guildNotificationSettingsRevisions[guildID, default: 0] == settingsRevision {
                model.updateLocalGuildNotificationSettings(guild: guild) {
                    $0.set(toggle, isEnabled: isEnabled)
                }
            }
        } finish: { model in
            model.refreshServerRailPresentation(guildID: guildID)
        }
        if started { refreshServerRailPresentation(guildID: guildID) }
    }

    func setChannelNotificationLevel(
        _ level: MessageNotificationLevel,
        for channel: Channel
    ) {
        let guildID = channel.guildID
        let channelID = channel.id
        runNotificationMutation(.channel(channelID), failureMessage: "Discord did not accept the channel notification setting.") {
            try await $0.updateChannelNotificationLevel(guildID: guildID, channelID: channelID, level: level)
        } apply: { model in
            model.updateLocalChannelNotificationOverride(channel: channel) { $0.messageNotifications = level }
        }
    }

    func setChannelMute(
        _ isMuted: Bool,
        until: Date?,
        for channel: Channel
    ) {
        let guildID = channel.guildID
        let channelID = channel.id
        runNotificationMutation(.channel(channelID), failureMessage: "Discord did not accept the channel mute setting.") {
            try await $0.updateChannelMute(guildID: guildID, channelID: channelID, isMuted: isMuted, until: until)
        } apply: { model in
            model.updateLocalChannelNotificationOverride(channel: channel) { $0.setMuted(isMuted, until: until) }
        }
    }

    func setCategoryNotificationLevel(
        _ level: MessageNotificationLevel,
        guildID: GuildID,
        categoryID: ChannelID
    ) {
        runNotificationMutation(.channel(categoryID), failureMessage: "Discord did not accept the category notification setting.") {
            try await $0.updateCategoryNotificationLevel(guildID: guildID, categoryID: categoryID, level: level)
        } apply: { model in
            model.updateLocalChannelNotificationOverride(guildID: guildID, channelID: categoryID) {
                $0.messageNotifications = level
            }
        }
    }

    func setCategoryMute(
        _ isMuted: Bool,
        until: Date?,
        guildID: GuildID,
        categoryID: ChannelID
    ) {
        runNotificationMutation(.channel(categoryID), failureMessage: "Discord did not accept the category mute setting.") {
            try await $0.updateCategoryMute(guildID: guildID, categoryID: categoryID, isMuted: isMuted, until: until)
        } apply: { model in
            model.updateLocalChannelNotificationOverride(guildID: guildID, channelID: categoryID) { $0.setMuted(isMuted, until: until) }
        }
    }

    /// Whether a notification change already holds `slot`; one runs at a
    /// time per server, per channel or category, and per forum post.
    func isNotificationMutationPending(_ slot: NotificationMutationSlot) -> Bool {
        notificationMutationTasks[slot] != nil
    }

    /// Sends one notification change in `slot`, or returns false while the
    /// slot already holds one. `apply` updates local state once Discord
    /// accepts it, and a failure shows `failureMessage`. Either way the slot
    /// frees and `finish` runs, unless the account changed or notification
    /// mutations were reset meanwhile.
    @discardableResult
    func runNotificationMutation(
        _ slot: NotificationMutationSlot,
        failureMessage: String,
        send: @escaping (any ChatProvider) async throws -> Void,
        apply: @escaping (AppModel) -> Void,
        finish: @escaping (AppModel) -> Void = { _ in }
    ) -> Bool {
        guard !isNotificationMutationPending(slot) else { return false }
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        let task = Task { [weak self] in
            do {
                try await send(activeProvider)
                guard let self, self.isCurrentNotificationMutation(generation: generation, session: session)
                else { return }
                apply(self)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrentNotificationMutation(generation: generation, session: session)
                else { return }
                self.errorMessage = failureMessage
            }
            guard let self, self.isCurrentNotificationMutation(generation: generation, session: session)
            else { return }
            self.notificationMutationTasks[slot] = nil
            finish(self)
        }
        notificationMutationTasks[slot] = task
        return true
    }

    private func isCurrentNotificationMutation(generation: Int, session: AppModelAccountSession) -> Bool {
        isCurrentAccountSession(session) && channelNotificationMutationGeneration == generation
    }

    func setCategoryCollapsed(
        _ isCollapsed: Bool,
        guildID: GuildID,
        categoryID: ChannelID
    ) {
        optimisticCategoryCollapsedByID[categoryID] = isCollapsed

        if var mutation = categoryCollapseMutationStates[categoryID] {
            mutation.desiredCollapsed = isCollapsed
            categoryCollapseMutationStates[categoryID] = mutation
            return
        }

        categoryCollapseMutationStates[categoryID] = CategoryCollapseMutationState(
            guildID: guildID,
            confirmedCollapsed: readState.isCategoryCollapsed(
                categoryID: categoryID,
                guildID: guildID
            ),
            desiredCollapsed: isCollapsed
        )
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        categoryCollapseMutationTasks[categoryID] = Task { [weak self] in
            while let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration,
                  let mutation = self.categoryCollapseMutationStates[categoryID]
            {
                if mutation.desiredCollapsed == mutation.confirmedCollapsed {
                    self.finishCategoryCollapseMutation(categoryID: categoryID)
                    return
                }

                let sentValue = mutation.desiredCollapsed
                do {
                    try await activeProvider.updateCategoryCollapsed(
                        guildID: mutation.guildID,
                        categoryID: categoryID,
                        isCollapsed: sentValue
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isCurrentAccountSession(session),
                          generation == self.channelNotificationMutationGeneration,
                          let current = self.categoryCollapseMutationStates[categoryID]
                    else { return }
                    self.updateLocalChannelNotificationOverride(
                        guildID: current.guildID,
                        channelID: categoryID
                    ) { $0.isCollapsed = current.confirmedCollapsed }
                    self.errorMessage = "Discord did not accept the category collapse setting."
                    self.finishCategoryCollapseMutation(categoryID: categoryID)
                    return
                }

                guard self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration,
                      var current = self.categoryCollapseMutationStates[categoryID]
                else { return }
                current.confirmedCollapsed = sentValue
                self.categoryCollapseMutationStates[categoryID] = current
                self.updateLocalChannelNotificationOverride(
                    guildID: current.guildID,
                    channelID: categoryID
                ) { $0.isCollapsed = sentValue }
            }
        }
    }

    private func finishCategoryCollapseMutation(categoryID: ChannelID) {
        categoryCollapseMutationStates[categoryID] = nil
        optimisticCategoryCollapsedByID[categoryID] = nil
        categoryCollapseMutationTasks[categoryID] = nil
    }

    func updateLocalForumPostNotificationSettings(
        postID: ChannelID,
        mutation: (inout ThreadNotificationSettings) -> Void
    ) {
        guard let index = forumCatalogueIndexByID[postID] else { return }
        var post = forumCataloguePosts[index]
        var settings = post.thread.notificationSettings ?? ThreadNotificationSettings()
        mutation(&settings)
        post.thread.notificationSettings = settings
        forumCataloguePosts[index] = post
        readState.merge(thread: post.thread)
        updateForumPresentation(with: post)
        if openThread?.id == postID {
            openThread?.notificationSettings = settings
        }
    }

    func updateLocalChannelNotificationOverride(
        channel: Channel,
        mutation: (inout ChannelNotificationOverride) -> Void
    ) {
        updateLocalChannelNotificationOverride(
            guildID: channel.guildID,
            channelID: channel.id,
            mutation: mutation
        )
    }

    func updateLocalChannelNotificationOverride(
        guildID: GuildID?,
        channelID: ChannelID,
        mutation: (inout ChannelNotificationOverride) -> Void
    ) {
        var settings =
            readState.notificationSettings(guildID: guildID)
            ?? GuildNotificationSettings(
                guildID: guildID,
                messageNotifications: .inherit
            )
        settings.updateChannelOverride(channelID, mutation)
        applyNotificationSettings(settings)
        refreshUnreadPresentation()
    }

    func updateLocalGuildNotificationSettings(
        guild: Guild,
        mutation: (inout GuildNotificationSettings) -> Void
    ) {
        var settings =
            readState.notificationSettings(guildID: guild.id)
            ?? GuildNotificationSettings(
                guildID: guild.id,
                messageNotifications: guild.defaultMessageNotifications
            )
        mutation(&settings)
        applyNotificationSettings(settings)
        refreshServerRailPresentation(guildID: guild.id)
        refreshUnreadPresentation()
    }

    func applyRemoteNotificationSettings(_ settings: GuildNotificationSettings) {
        if let guildID = settings.guildID {
            guildNotificationSettingsRevisions[guildID, default: 0] &+= 1
        }
        applyNotificationSettings(settings)
    }

    func applyNotificationSettings(_ settings: GuildNotificationSettings) {
        readState.apply(settings)
        guard var value = snapshot else { return }
        value.notificationSettings.removeAll { $0.guildID == settings.guildID }
        value.notificationSettings.append(settings)
        snapshot = value
        // Muting a ringing conversation silences it.
        reconcilePrivateCallSounds()
    }
}

/// What a notification change holds while it is in flight.
nonisolated enum NotificationMutationSlot: Hashable, Sendable {
    case guild(GuildID)
    /// A channel, category or direct message.
    case channel(ChannelID)
    case forumPost(ChannelID)
}
