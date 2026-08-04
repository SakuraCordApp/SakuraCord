import DiscordProtocol
import Foundation
import OSLog
import SakuraCordModels
import UserNotifications

extension AppModel {
    func channelMentionCount(_ channelID: ChannelID) -> Int {
        readState.mentions(channelID: channelID)
    }

    var directMessageUnread: Bool {
        readState.directMessageUnread()
    }

    var directMessageMentionCount: Int {
        readState.directMessageMentions
    }

    func unreadDividerMessageID(channelID: ChannelID) -> MessageID? {
        unreadDividerMessageIDs[channelID]
    }

    func completeConversationReadingAndAdvance(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        markConversationRead(channelID: channelID)
        unreadDividerMessageIDs[channelID] = nil
        conversationNewestRequestID &+= 1
        conversationNewestRequest = ConversationNewestRequest(
            requestID: conversationNewestRequestID,
            channelID: channelID
        )
    }

    func preserveUnreadDividerIfNeeded(channelID: ChannelID) {
        guard unreadDividerMessageIDs[channelID] == nil else { return }
        let conversationMessages: [Message]
        let hasMoreBefore: Bool
        if channelID == openThread?.id {
            conversationMessages = threadMessages
            hasMoreBefore = hasMoreThreadMessages
                || (isLoadingThread && !threadMessages.isEmpty)
        } else if channelID == selectedChannelID {
            conversationMessages = messages
            hasMoreBefore = hasMoreMessages
                || (isLoadingMessages && !messages.isEmpty)
        } else {
            return
        }
        guard let summary = readState.timelineUnreadSummary(
            channelID: channelID,
            messages: conversationMessages,
            hasMoreBefore: hasMoreBefore
        ), !summary.isLowerBound
        else { return }
        unreadDividerMessageIDs[channelID] = summary.firstUnreadMessageID
    }

    func markMessageAndFollowingUnread(_ message: Message) {
        guard !runsChatPerformanceBenchmark else { return }
        let channelID = message.channelID
        guard channelID == selectedChannelID || channelID == openThread?.id,
              message.id.rawValue > 0,
              let currentUserID = snapshot?.currentUser.id
        else { return }
        let conversationMessages =
            channelID == openThread?.id ? threadMessages : messages
        let mentionCount = readState.mentionCountForManualUnread(
            channelID: channelID,
            messages: conversationMessages,
            startingAt: message.id,
            currentUserID: currentUserID
        )
        let target = MessageID(rawValue: message.id.rawValue - 1)
        acknowledgementTasks[channelID]?.cancel()
        acknowledgementTasks[channelID] = nil
        queuedAcknowledgements[channelID] = nil
        acknowledgementQueueOrder.removeAll { $0 == channelID }
        readState.markUnread(
            channelID: channelID,
            after: target,
            mentionCount: mentionCount
        )
        // "Mark Unread" identifies the exact first-new row. Publish that
        // anchor in the same transaction instead of waiting for a later
        // timeline geometry callback to infer it from read state.
        unreadDividerMessageIDs[channelID] = message.id
        refreshUnreadPresentation()
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: true,
                mentionCount: mentionCount
            )
        )
    }

    func requestNotificationPermission() async -> Bool {
        (try? await notificationService.requestAuthorization()) ?? false
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
        notificationService.setDockBadge(
            readState.totalMentions,
            enabled: notificationPreferences.showsDockBadge
        )
    }

    func acknowledgeIfEligible(channelID: ChannelID) {
        guard let target = readState.updatePresentation(channelID: channelID) else { return }
        scheduleAcknowledgement(channelID: channelID, messageID: target)
    }

    func acknowledgeForumVisitIfNeeded(channelID: ChannelID, now: Date = .now) {
        guard !runsChatPerformanceBenchmark else { return }
        guard selectedChannelID == channelID,
              selectedChannel?.kind == .forum,
              readState.shouldAcknowledgeForumVisit(channelID: channelID),
              let target = Self.forumAcknowledgementBoundary(at: now)
        else { return }
        readState.markAcknowledgementPending(channelID: channelID, messageID: target)
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: false,
                mentionCount: nil
            )
        )
    }

    nonisolated static func forumAcknowledgementBoundary(at date: Date) -> MessageID? {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
        guard milliseconds >= ClientNonce.discordEpochMilliseconds else { return nil }
        return MessageID(
            rawValue: (milliseconds - ClientNonce.discordEpochMilliseconds) << 22
        )
    }

    func scheduleAcknowledgement(channelID: ChannelID, messageID: MessageID) {
        guard !runsChatPerformanceBenchmark, !presentsCachedStartup else { return }
        if let pending = readState.entries[channelID]?.pendingAcknowledgementID,
           pending >= messageID
        {
            return
        }
        acknowledgementTasks[channelID]?.cancel()
        readState.markAcknowledgementPending(channelID: channelID, messageID: messageID)
        Self.unreadDiagnosticsLogger.info(
            "Read acknowledgement scheduled; channel=\(channelID.rawValue, privacy: .public), target=\(messageID.rawValue, privacy: .public)"
        )
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        let debounce = readAcknowledgementTiming.debounce
        acknowledgementTasks[channelID] = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                guard let self, !Task.isCancelled else { return }
                self.enqueueAcknowledgement(
                    channelID: channelID,
                    mutation: self.readStateMutation(
                        channelID: channelID,
                        messageID: messageID,
                        manual: false,
                        mentionCount: nil
                    )
                )
                self.acknowledgementTasks[channelID] = nil
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func enqueueAcknowledgement(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        guard !runsChatPerformanceBenchmark, !presentsCachedStartup else { return }
        if let queued = queuedAcknowledgements[channelID] {
            if mutation.manual || !queued.manual {
                queuedAcknowledgements[channelID] =
                    mutation.manual
                    ? mutation
                    : ReadStateMutation(
                        messageID: max(queued.messageID, mutation.messageID),
                        manual: false,
                        mentionCount: nil,
                        flags: mutation.flags,
                        lastViewed: mutation.lastViewed
                    )
            }
        } else {
            queuedAcknowledgements[channelID] = mutation
            acknowledgementQueueOrder.append(channelID)
        }
        guard acknowledgementProcessorTask == nil else { return }
        let generation = acknowledgementGeneration
        acknowledgementProcessorTask = Task { [weak self] in
            await self?.drainAcknowledgementQueue(generation: generation)
        }
    }

    func drainAcknowledgementQueue(generation: Int) async {
        let session = accountSession()
        while !Task.isCancelled,
              generation == acknowledgementGeneration,
              isCurrentAccountSession(session),
              let channelID = acknowledgementQueueOrder.first
        {
            acknowledgementQueueOrder.removeFirst()
            guard let mutation = queuedAcknowledgements.removeValue(forKey: channelID) else {
                continue
            }
            do {
                logReadAcknowledgementSending(channelID: channelID, mutation: mutation)
                let response = try await session.provider.acknowledge(
                    channelID: channelID,
                    messageID: mutation.messageID,
                    token: readState.acknowledgementToken,
                    manual: mutation.manual,
                    mentionCount: mutation.mentionCount,
                    flags: mutation.flags,
                    lastViewed: mutation.lastViewed
                )
                guard !Task.isCancelled,
                      generation == acknowledgementGeneration,
                      isCurrentAccountSession(session)
                else { return }
                readState.completeAcknowledgement(
                    channelID: channelID,
                    messageID: mutation.messageID,
                    token: response.token
                )
                logReadAcknowledgementAccepted(channelID: channelID, mutation: mutation)
            } catch is CancellationError {
                return
            } catch {
                guard generation == acknowledgementGeneration,
                      isCurrentAccountSession(session)
                else { return }
                readState.failAcknowledgement(
                    channelID: channelID,
                    messageID: mutation.messageID
                )
                logReadAcknowledgementFailed(channelID: channelID, mutation: mutation)
                refreshUnreadPresentation()
                if mutation.manual {
                    errorMessage = "Discord did not accept the read-state update."
                }
            }
        }
        if generation == acknowledgementGeneration,
           isCurrentAccountSession(session)
        {
            acknowledgementProcessorTask = nil
        }
    }

    func markConversationRead(channelID: ChannelID) {
        guard !runsChatPerformanceBenchmark, !presentsCachedStartup else { return }
        guard readState.unread(channelID: channelID),
              let target = readState.entries[channelID]?.latestKnownMessageID
        else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        acknowledgementTasks[channelID]?.cancel()
        acknowledgementTasks[channelID] = nil
        queuedAcknowledgements[channelID] = nil
        acknowledgementQueueOrder.removeAll { $0 == channelID }
        readState.unblockAutomaticAcknowledgement(channelID: channelID)
        readState.markAcknowledgementPending(channelID: channelID, messageID: target)
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: false,
                mentionCount: nil
            )
        )
    }

    func markGuildRead(_ guildID: GuildID) {
        guard !runsChatPerformanceBenchmark, !presentsCachedStartup else { return }
        guard guildAcknowledgementTasks[guildID] == nil else { return }
        let targets = readState.bulkAcknowledgements(for: guildID)
        guard !targets.isEmpty else { return }

        for target in targets {
            preserveUnreadDividerIfNeeded(channelID: target.channelID)
            acknowledgementTasks[target.channelID]?.cancel()
            acknowledgementTasks[target.channelID] = nil
            queuedAcknowledgements[target.channelID] = nil
            acknowledgementQueueOrder.removeAll { $0 == target.channelID }
            readState.unblockAutomaticAcknowledgement(channelID: target.channelID)
            readState.markAcknowledgementPending(
                channelID: target.channelID,
                messageID: target.messageID
            )
            cancelNativeNotifications(channelID: target.channelID)
        }
        refreshUnreadPresentation()

        let generation = acknowledgementGeneration
        let session = accountSession()
        let activeProvider = session.provider
        guildAcknowledgementTasks[guildID] = Task { [weak self] in
            do {
                try await activeProvider.acknowledgeBulk(targets)
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.acknowledgementGeneration
                else { return }
                for target in targets {
                    self.readState.completeAcknowledgement(
                        channelID: target.channelID,
                        messageID: target.messageID,
                        token: nil
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.acknowledgementGeneration
                else { return }
                for target in targets {
                    self.readState.failAcknowledgement(
                        channelID: target.channelID,
                        messageID: target.messageID
                    )
                }
                self.errorMessage = "Discord did not accept the server read-state update."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.acknowledgementGeneration
            else { return }
            self.refreshUnreadPresentation()
            self.guildAcknowledgementTasks[guildID] = nil
        }
    }

    func setGuildNotificationLevel(
        _ level: MessageNotificationLevel,
        for guild: Guild
    ) {
        guard !presentsCachedStartup else { return }
        guard guildNotificationMutationTasks[guild.id] == nil else { return }
        let guildID = guild.id
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        guildNotificationMutationTasks[guildID] = Task { [weak self] in
            do {
                try await activeProvider.updateGuildNotificationLevel(
                    guildID: guildID,
                    level: level
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalGuildNotificationSettings(guild: guild) {
                    $0.messageNotifications = level
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.errorMessage = "Discord did not accept the server notification setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration
            else { return }
            self.guildNotificationMutationTasks[guildID] = nil
        }
    }

    func setGuildMute(
        _ isMuted: Bool,
        until: Date?,
        for guild: Guild
    ) {
        guard !presentsCachedStartup else { return }
        guard guildNotificationMutationTasks[guild.id] == nil else { return }
        let guildID = guild.id
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        guildNotificationMutationTasks[guildID] = Task { [weak self] in
            do {
                try await activeProvider.updateGuildMute(
                    guildID: guildID,
                    isMuted: isMuted,
                    until: until
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalGuildNotificationSettings(guild: guild) {
                    $0.isMuted = isMuted
                    $0.muteConfiguration =
                        isMuted ? DiscordMuteConfiguration(endTime: until) : nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.errorMessage = "Discord did not accept the server mute setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration
            else { return }
            self.guildNotificationMutationTasks[guildID] = nil
        }
    }

    func setChannelNotificationLevel(
        _ level: MessageNotificationLevel,
        for channel: Channel
    ) {
        guard !presentsCachedStartup else { return }
        guard channelNotificationMutationTasks[channel.id] == nil
        else { return }
        let guildID = channel.guildID
        let channelID = channel.id
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        channelNotificationMutationTasks[channelID] = Task { [weak self] in
            do {
                try await activeProvider.updateChannelNotificationLevel(
                    guildID: guildID,
                    channelID: channelID,
                    level: level
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalChannelNotificationOverride(channel: channel) {
                    $0.messageNotifications = level
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.errorMessage = "Discord did not accept the channel notification setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration
            else { return }
            self.channelNotificationMutationTasks[channelID] = nil
        }
    }

    func setChannelMute(
        _ isMuted: Bool,
        until: Date?,
        for channel: Channel
    ) {
        guard !presentsCachedStartup else { return }
        guard channelNotificationMutationTasks[channel.id] == nil
        else { return }
        let guildID = channel.guildID
        let channelID = channel.id
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        channelNotificationMutationTasks[channelID] = Task { [weak self] in
            do {
                try await activeProvider.updateChannelMute(
                    guildID: guildID,
                    channelID: channelID,
                    isMuted: isMuted,
                    until: until
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalChannelNotificationOverride(channel: channel) {
                    $0.isMuted = isMuted
                    $0.muteConfiguration =
                        isMuted ? DiscordMuteConfiguration(endTime: until) : nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.errorMessage = "Discord did not accept the channel mute setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration
            else { return }
            self.channelNotificationMutationTasks[channelID] = nil
        }
    }

    func setForumPostNotificationLevel(
        _ level: MessageNotificationLevel,
        for post: ForumPost
    ) {
        guard !presentsCachedStartup else { return }
        guard forumNotificationMutationTasks[post.id] == nil else { return }
        let generation = forumNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        forumNotificationMutationTasks[post.id] = Task { [weak self] in
            do {
                try await activeProvider.updateForumPostNotificationLevel(
                    post,
                    level: level
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.forumNotificationMutationGeneration
                else { return }
                self.updateLocalForumPostNotificationSettings(postID: post.id) {
                    $0.flags = $0.flags(setting: level)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.forumNotificationMutationGeneration
                else { return }
                self.forumActionError =
                    "Discord did not accept the post notification setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.forumNotificationMutationGeneration
            else { return }
            self.forumNotificationMutationTasks[post.id] = nil
        }
    }

    func setForumPostMute(
        _ isMuted: Bool,
        until: Date?,
        for post: ForumPost
    ) {
        guard !presentsCachedStartup else { return }
        guard forumNotificationMutationTasks[post.id] == nil else { return }
        let generation = forumNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        forumNotificationMutationTasks[post.id] = Task { [weak self] in
            do {
                try await activeProvider.updateForumPostMute(
                    post,
                    isMuted: isMuted,
                    until: until
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.forumNotificationMutationGeneration
                else { return }
                self.updateLocalForumPostNotificationSettings(postID: post.id) {
                    $0.isMuted = isMuted
                    $0.muteConfiguration =
                        isMuted ? DiscordMuteConfiguration(endTime: until) : nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.forumNotificationMutationGeneration
                else { return }
                self.forumActionError = "Discord did not accept the post mute setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.forumNotificationMutationGeneration
            else { return }
            self.forumNotificationMutationTasks[post.id] = nil
        }
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
        var settings =
            readState.notificationSettings(guildID: channel.guildID)
            ?? GuildNotificationSettings(
                guildID: channel.guildID,
                messageNotifications: .inherit
            )
        var override =
            settings.channelOverrides.last { $0.channelID == channel.id }
            ?? ChannelNotificationOverride(channelID: channel.id)
        mutation(&override)
        settings.channelOverrides.removeAll { $0.channelID == channel.id }
        settings.channelOverrides.append(override)
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
        refreshUnreadPresentation()
    }

    func applyNotificationSettings(_ settings: GuildNotificationSettings) {
        readState.apply(settings)
        guard var value = snapshot else { return }
        value.notificationSettings.removeAll { $0.guildID == settings.guildID }
        value.notificationSettings.append(settings)
        snapshot = value
    }
}
