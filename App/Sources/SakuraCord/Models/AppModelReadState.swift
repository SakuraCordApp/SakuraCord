import DiscordProtocol
import Foundation
import OSLog
import SakuraCordModels
import UserNotifications

extension AppModel {
    /// Gives the media viewer first refusal on Escape before any underlying
    /// conversation surface interprets the same key as "jump to present".
    @discardableResult
    func consumeEscapeForMediaViewer() -> Bool {
        guard mediaViewerPresentation != nil else { return false }
        mediaViewerPresentation = nil
        return true
    }

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
        if channelID == selectedChannelID, hasMoreLaterMessages {
            let account = accountSession()
            startAccountChildTask(account: account) { model, account in
                guard await model.loadNewestMessageWindow(account: account),
                      model.isCurrentAccountSession(account),
                      model.selectedChannelID == channelID
                else { return }
                model.completeConversationReadingAndAdvance(channelID: channelID)
            }
            return
        }
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
        scheduleAutomaticAcknowledgement(channelID: channelID, messageID: target)
    }

    func acknowledgeForumVisitIfNeeded(channelID: ChannelID, now: Date = .now) {
        guard !runsChatPerformanceBenchmark,
              chatSettings.readAcknowledgementMode == .automatic
        else { return }
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
        guard !runsChatPerformanceBenchmark else { return }
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

    func scheduleAutomaticAcknowledgement(
        channelID: ChannelID,
        messageID: MessageID
    ) {
        guard chatSettings.readAcknowledgementMode == .automatic else { return }
        scheduleAcknowledgement(channelID: channelID, messageID: messageID)
    }

    func cancelScheduledAutomaticAcknowledgements() {
        for (channelID, task) in acknowledgementTasks {
            task.cancel()
            if let pending = readState.entries[channelID]?.pendingAcknowledgementID {
                readState.failAcknowledgement(
                    channelID: channelID,
                    messageID: pending
                )
            }
        }
        acknowledgementTasks.removeAll()
        refreshUnreadPresentation()
    }

    func enqueueAcknowledgement(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        guard !runsChatPerformanceBenchmark else { return }
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
        guard !runsChatPerformanceBenchmark else { return }
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
        guard !runsChatPerformanceBenchmark else { return }
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
            } catch let partial as PartialBulkReadAcknowledgementError {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.acknowledgementGeneration
                else { return }
                self.resolvePartialBulkAcknowledgement(partial, targets: targets)
                self.errorMessage =
                    "Discord accepted part of the server read-state update, but not the remaining updates."
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
            self.refreshServerRailPresentation(guildID: guildID)
        }
        refreshServerRailPresentation(guildID: guildID)
    }

    func markCategoryRead(categoryID: ChannelID, guildID: GuildID) {
        guard !runsChatPerformanceBenchmark else { return }
        guard categoryAcknowledgementTasks[categoryID] == nil else { return }
        let targets = readState.bulkAcknowledgements(
            for: categoryID,
            guildID: guildID
        )
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
        categoryAcknowledgementTasks[categoryID] = Task { [weak self] in
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
            } catch let partial as PartialBulkReadAcknowledgementError {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.acknowledgementGeneration
                else { return }
                self.resolvePartialBulkAcknowledgement(partial, targets: targets)
                self.errorMessage =
                    "Discord accepted part of the category read-state update, but not the remaining updates."
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
                self.errorMessage = "Discord did not accept the category read-state update."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.acknowledgementGeneration
            else { return }
            self.refreshUnreadPresentation()
            self.categoryAcknowledgementTasks[categoryID] = nil
        }
    }

    private func resolvePartialBulkAcknowledgement(
        _ partial: PartialBulkReadAcknowledgementError,
        targets: [BulkReadStateAcknowledgement]
    ) {
        let acceptedByChannelID = Dictionary(
            partial.acceptedReadStates.map { ($0.channelID, $0.messageID) },
            uniquingKeysWith: { _, later in later }
        )
        for target in targets {
            if acceptedByChannelID[target.channelID] == target.messageID {
                readState.completeAcknowledgement(
                    channelID: target.channelID,
                    messageID: target.messageID,
                    token: nil
                )
            } else {
                readState.failAcknowledgement(
                    channelID: target.channelID,
                    messageID: target.messageID
                )
            }
        }
    }

    func setGuildNotificationLevel(
        _ level: MessageNotificationLevel,
        for guild: Guild
    ) {
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
            self.refreshServerRailPresentation(guildID: guildID)
        }
        refreshServerRailPresentation(guildID: guildID)
    }

    func setGuildMute(
        _ isMuted: Bool,
        until: Date?,
        for guild: Guild
    ) {
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
            self.refreshServerRailPresentation(guildID: guildID)
        }
        refreshServerRailPresentation(guildID: guildID)
    }

    func setGuildNotificationToggle(
        _ toggle: GuildNotificationToggle,
        isEnabled: Bool,
        for guild: Guild
    ) {
        guard guildNotificationMutationTasks[guild.id] == nil else { return }
        let guildID = guild.id
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        guildNotificationMutationTasks[guildID] = Task { [weak self] in
            do {
                try await activeProvider.updateGuildNotificationToggle(
                    guildID: guildID,
                    toggle: toggle,
                    isEnabled: isEnabled
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalGuildNotificationSettings(guild: guild) {
                    $0.set(toggle, isEnabled: isEnabled)
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
            self.refreshServerRailPresentation(guildID: guildID)
        }
        refreshServerRailPresentation(guildID: guildID)
    }

    func setChannelNotificationLevel(
        _ level: MessageNotificationLevel,
        for channel: Channel
    ) {
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

    func setCategoryNotificationLevel(
        _ level: MessageNotificationLevel,
        guildID: GuildID,
        categoryID: ChannelID
    ) {
        guard channelNotificationMutationTasks[categoryID] == nil else { return }
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        channelNotificationMutationTasks[categoryID] = Task { [weak self] in
            do {
                try await activeProvider.updateCategoryNotificationLevel(
                    guildID: guildID,
                    categoryID: categoryID,
                    level: level
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalChannelNotificationOverride(
                    guildID: guildID,
                    channelID: categoryID
                ) { $0.messageNotifications = level }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.errorMessage = "Discord did not accept the category notification setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration
            else { return }
            self.channelNotificationMutationTasks[categoryID] = nil
        }
    }

    func setCategoryMute(
        _ isMuted: Bool,
        until: Date?,
        guildID: GuildID,
        categoryID: ChannelID
    ) {
        guard channelNotificationMutationTasks[categoryID] == nil else { return }
        let generation = channelNotificationMutationGeneration
        let session = accountSession()
        let activeProvider = session.provider
        channelNotificationMutationTasks[categoryID] = Task { [weak self] in
            do {
                try await activeProvider.updateCategoryMute(
                    guildID: guildID,
                    categoryID: categoryID,
                    isMuted: isMuted,
                    until: until
                )
                guard let self,
                      self.isCurrentAccountSession(session),
                      generation == self.channelNotificationMutationGeneration
                else { return }
                self.updateLocalChannelNotificationOverride(
                    guildID: guildID,
                    channelID: categoryID
                ) {
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
                self.errorMessage = "Discord did not accept the category mute setting."
            }
            guard let self,
                  self.isCurrentAccountSession(session),
                  generation == self.channelNotificationMutationGeneration
            else { return }
            self.channelNotificationMutationTasks[categoryID] = nil
        }
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

    func setForumPostNotificationLevel(
        _ level: MessageNotificationLevel,
        for post: ForumPost
    ) {
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
        var override =
            settings.channelOverrides.last { $0.channelID == channelID }
            ?? ChannelNotificationOverride(channelID: channelID)
        mutation(&override)
        settings.channelOverrides.removeAll { $0.channelID == channelID }
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
        refreshServerRailPresentation(guildID: guild.id)
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
