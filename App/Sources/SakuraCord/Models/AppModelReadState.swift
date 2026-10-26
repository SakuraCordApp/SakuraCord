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

    func jumpToUnreadBoundary(channelID: ChannelID) {
        guard isConversationPresented(channelID) else { return }
        let isThread = openThread?.id == channelID
        startConversationNavigation { model, account in
            var glides = true
            var previousOldestID: MessageID?
            while !Task.isCancelled,
                  model.isCurrentAccountSession(account),
                  model.isConversationPresented(channelID),
                  (model.openThread?.id == channelID) == isThread
            {
                let messages = isThread ? model.threadMessages : model.messages
                let summary = model.presentedUnreadSummary(channelID: channelID)
                model.preserveUnreadDividerIfNeeded(channelID: channelID)
                // The visual divider survives acknowledgements. Jump to the
                // current unread run without moving that retained divider.
                if let summary, !summary.isLowerBound {
                    model.messageNavigationRequestID &+= 1
                    model.messageNavigationRequest = MessageNavigationRequest(
                        requestID: model.messageNavigationRequestID,
                        channelID: channelID,
                        messageID: summary.firstUnreadMessageID,
                        glides: glides,
                        isUnreadBoundary: true
                    )
                    return
                }
                guard summary != nil,
                      let oldestMessageID = messages.first?.id,
                      previousOldestID.map({ oldestMessageID < $0 }) ?? true
                else { return }
                previousOldestID = oldestMessageID
                // Keep history contiguous. Existing loaders own permissions,
                // pagination errors and account/selection guards.
                if isThread {
                    await model.loadEarlierThread(account: account)
                } else {
                    await model.loadEarlier(account: account)
                }
                glides = false
            }
        }
    }

    /// Jumps to the newest message as soon as a send appends its local row.
    /// Returns false on an older page (reloading would replace the local row)
    /// or before the initial position (a backlog hold can still appear); those
    /// sends advance on confirmation instead.
    func advanceTimelineForLocalSend(channelID: ChannelID) -> Bool {
        guard channelID == selectedChannelID || channelID == openThread?.id,
              !(channelID == selectedChannelID && hasMoreLaterMessages),
              readState.presentations[channelID]?.initialPositionEstablished == true
        else { return false }
        // Sending is an explicit move to the newest message, so it releases a
        // held backlog the way scrolling does, and, as Discord's own-message
        // acknowledgement, Mark Unread's hold too.
        releaseHeldVisit(channelID: channelID)
        requestNewestMessagePresentation(channelID: channelID)
        return true
    }

    func completeConfirmedSend(channelID: ChannelID, advancedLocally: Bool) {
        if advancedLocally {
            acknowledgeConfirmedLocalSend(channelID: channelID)
        } else {
            completeConversationReadingAndAdvance(channelID: channelID)
        }
    }

    /// A send that already jumped neither moves the viewport nor loads history
    /// on confirmation, and acknowledges only at the read boundary, so messages
    /// that arrived out of view stay unread.
    private func acknowledgeConfirmedLocalSend(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id,
              readState.canAcknowledge(channelID)
        else { return }
        markConversationRead(channelID: channelID)
        unreadDividerMessageIDs[channelID] = nil
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
        if channelID == openThread?.id, isThreadWindowAwayFromNewest {
            let account = accountSession()
            startAccountChildTask(account: account) { model, account in
                guard await model.loadNewestThreadWindow(account: account),
                      model.isCurrentAccountSession(account),
                      model.openThread?.id == channelID
                else { return }
                model.completeConversationReadingAndAdvance(channelID: channelID)
            }
            return
        }
        if channelID == openThread?.id { supersedeThreadWindowRequests() }
        markConversationRead(channelID: channelID)
        unreadDividerMessageIDs[channelID] = nil
        requestNewestMessagePresentation(channelID: channelID)
    }

    /// A message that arrives while the newest edge is on screen in the
    /// active window is read on arrival; it must not plant a NEW divider that
    /// survives the acknowledgement that follows.
    func preserveUnreadDividerUnlessReadOnArrival(channelID: ChannelID) {
        guard !readState.canAcknowledge(channelID) else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
    }

    func preserveUnreadDividerIfNeeded(channelID: ChannelID) {
        guard unreadDividerMessageIDs[channelID] == nil,
              let summary = presentedUnreadSummary(channelID: channelID),
              !summary.isLowerBound
        else { return }
        unreadDividerMessageIDs[channelID] = summary.firstUnreadMessageID
    }

    /// True while a long backlog's first unread row is not loaded, so the
    /// timeline can show only its loaded tail.
    func hasUnresolvedUnreadBoundary(channelID: ChannelID) -> Bool {
        // Without a usable acknowledged boundary (READY can carry a
        // non-snowflake such as -11) no scroll reaches the unread start.
        // Holding it would keep every visit unread, so nothing would ever ACK.
        guard readState[channelID]?.lastAcknowledgedMessageID != nil,
              let summary = presentedUnreadSummary(channelID: channelID),
              summary.isLowerBound
        else { return false }
        guard let divider = unreadDividerMessageIDs[channelID] else { return true }
        let loaded = channelID == openThread?.id ? threadMessages : messages
        return !loaded.contains { $0.id == divider }
    }

    private func presentedUnreadSummary(
        channelID: ChannelID
    ) -> AccountReadStateModel.TimelineUnreadSummary? {
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
            return nil
        }
        return readState.timelineUnreadSummary(
            channelID: channelID,
            messages: conversationMessages,
            hasMoreBefore: hasMoreBefore
        )
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
        // Discord (module 439147, build 649389) targets the nearest older
        // loaded message, else the previous millisecond. Its read state
        // compares timestamps, so a boundary inside the selected message's
        // own millisecond would leave that message read.
        let millisecond = message.id.rawValue >> 22
        let target = conversationMessages.lazy.map(\.id).filter { $0 < message.id }.max()
            ?? MessageID(rawValue: millisecond > 0 ? (millisecond - 1) << 22 : 0)
        guard !isOutsideAcknowledgementScope(channelID) else { return }
        let thread = channelID == openThread?.id ? openThread.map(currentThreadSummary) : nil
        // The same action (E10) reopens an archived thread and joins an
        // unjoined one, then posts `manual` and the mention count at once,
        // outside the read queue. Read state changes only when its manual
        // Gateway event arrives.
        startAccountChildTask(account: accountSession()) { model, account in
            if let thread {
                guard await model.prepareThreadForMarkUnread(thread, account: account) else { return }
            }
            guard model.isCurrentAccountSession(account) else { return }
            do {
                _ = try await account.provider.acknowledge(
                    channelID: channelID, messageID: target, token: nil,
                    manual: true, mentionCount: mentionCount, flags: nil, lastViewed: nil
                )
            } catch {
                Self.unreadDiagnosticsLogger.error(
                    "Mark Unread failed c=\(channelID.rawValue, privacy: .public) m=\(target.rawValue, privacy: .public)"
                )
            }
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
        case .mentions: readState.totalMentions
        case .unreadConversations:
            readState.unreadPresentationProjection().unreadConversationCount
        case .off: nil
        }
        notificationService.setDockBadge(
            count ?? 0,
            enabled: count != nil
        )
    }

    func acknowledgeIfEligible(channelID: ChannelID) {
        let isPresented = isConversationPresented(channelID)
        // Only a shown conversation acknowledges. Recording one never shown,
        // as each arriving message would, marks an unopened post as opened.
        guard isPresented || readState[presentation: channelID] != nil,
              let target = readState.updatePresentation(
                  channelID: channelID,
                  isPresented: isPresented
              )
        else { return }
        scheduleAcknowledgement(channelID: channelID, messageID: target)
    }

    func acknowledgeForumVisitIfNeeded(channelID: ChannelID, now: Date = .now) {
        guard !runsChatPerformanceBenchmark else { return }
        guard selectedChannelID == channelID,
              isConversationPresented(channelID),
              selectedChannel?.kind == .forum,
              readState.shouldAcknowledgeForumVisit(channelID: channelID)
        else { return }
        let target = MessageID(timestamp: now)
        readState.acknowledge(channelID: channelID, messageID: target)
        refreshUnreadPresentation(readChangedChannelID: channelID)
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(channelID: channelID, messageID: target)
        )
    }

    /// The conversation shows a window that ends before its newest message,
    /// or a thread withheld while its access is resolved, so viewing it
    /// cannot acknowledge the newest message.
    func isDetachedFromNewest(_ channelID: ChannelID) -> Bool {
        (channelID == openThread?.id && (isThreadWindowAwayFromNewest || openThreadResolution != nil))
            || (channelID == selectedChannelID && hasMoreLaterMessages)
    }

    /// DEBUG Inbox verification confines account acknowledgements to one server.
    func isOutsideAcknowledgementScope(_ channelID: ChannelID) -> Bool {
        #if DEBUG
            if let scope = ProcessInfo.processInfo.environment["SAKURACORD_INBOX_VERIFICATION_GUILD_ID"] {
                return readState[channelID]?.guildID?.description != scope
            }
        #endif
        return false
    }

    /// Discord's `clearOutgoingAck` (E11): drops a read still in its debounce.
    /// A read past it is already sent in Discord's terms, even while
    /// SakuraCord's account queue holds it.
    func cancelDebouncedAcknowledgement(for channelID: ChannelID) {
        acknowledgementTasks[channelID]?.cancel()
        acknowledgementTasks[channelID] = nil
    }

    /// Drops any debounced or queued read for the channel, which a newer
    /// explicit read replaces. Read state already shows it.
    func discardPendingAcknowledgement(for channelID: ChannelID) {
        cancelDebouncedAcknowledgement(for: channelID)
        queuedAcknowledgements.removeAll { $0.channelID == channelID }
    }

    func scheduleAcknowledgement(channelID: ChannelID, messageID: MessageID) {
        guard !runsChatPerformanceBenchmark, !isDetachedFromNewest(channelID) else { return }
        acknowledgementTasks[channelID]?.cancel()
        readState.acknowledge(channelID: channelID, messageID: messageID)
        Self.unreadDiagnosticsLogger.info(
            "Read acknowledgement scheduled; channel=\(channelID.rawValue, privacy: .public), target=\(messageID.rawValue, privacy: .public)"
        )
        refreshUnreadPresentation(readChangedChannelID: channelID)
        cancelNativeNotifications(channelID: channelID)
        let debounce = readAcknowledgementTiming.debounce
        acknowledgementTasks[channelID] = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                guard let self, !Task.isCancelled else { return }
                self.enqueueAcknowledgement(
                    channelID: channelID,
                    mutation: self.readStateMutation(channelID: channelID, messageID: messageID)
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
        guard !runsChatPerformanceBenchmark, !isOutsideAcknowledgementScope(channelID) else { return }
        // The most recent read replaces an unsent one.
        if let index = queuedAcknowledgements.firstIndex(where: { $0.channelID == channelID }) {
            queuedAcknowledgements[index].mutation = mutation
        } else {
            queuedAcknowledgements.append((channelID, mutation))
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
              !queuedAcknowledgements.isEmpty
        {
            let (channelID, mutation) = queuedAcknowledgements.removeFirst()
            let token = readState.acknowledgementToken
            do {
                logReadAcknowledgementSending(channelID: channelID, mutation: mutation)
                let response = try await session.provider.acknowledge(
                    channelID: channelID,
                    messageID: mutation.messageID,
                    token: token,
                    manual: false,
                    mentionCount: nil,
                    flags: mutation.flags,
                    lastViewed: mutation.lastViewed
                )
                guard !Task.isCancelled,
                      generation == acknowledgementGeneration,
                      isCurrentAccountSession(session)
                else { return }
                readState.completeAcknowledgement(token: response.token, sentWith: token)
                logReadAcknowledgementAccepted(channelID: channelID, mutation: mutation)
            } catch is CancellationError {
                return
            } catch {
                // As in Discord, a failure changes no read state.
                logReadAcknowledgementFailed(channelID: channelID, mutation: mutation)
            }
        }
        if generation == acknowledgementGeneration,
           isCurrentAccountSession(session)
        {
            acknowledgementProcessorTask = nil
        }
    }

    /// Discord enables a forum's own Mark as Read only for its unread posts,
    /// never for its new-post count, and acknowledges the forum up to now. A
    /// post's own is enabled by `isForumPostUnread`, joined or not.
    func canMarkConversationRead(channelID: ChannelID) -> Bool {
        if readState[channelID]?.kind == .forum {
            return readState.hasUnreadForumPosts(channelID: channelID)
        }
        return readState.isForumPostUnread(channelID: channelID)
            ?? readState.unread(channelID: channelID)
    }

    func markConversationRead(channelID: ChannelID) {
        guard !runsChatPerformanceBenchmark else { return }
        guard canMarkConversationRead(channelID: channelID),
              let target = readState[channelID].flatMap({
                  AccountReadStateModel.acknowledgementTarget(for: $0, now: .now)
              })
        else { return }
        markRead(channelID: channelID, through: target)
        refreshUnreadPresentation(readChangedChannelID: channelID)
    }

    private func markRead(channelID: ChannelID, through target: MessageID) {
        preserveUnreadDividerIfNeeded(channelID: channelID)
        discardPendingAcknowledgement(for: channelID)
        readState.unblockAutomaticAcknowledgement(channelID: channelID)
        readState.acknowledge(channelID: channelID, messageID: target)
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(channelID: channelID, mutation: readStateMutation(channelID: channelID, messageID: target))
    }

    func markGuildRead(_ guildID: GuildID) {
        guard !runsChatPerformanceBenchmark else { return }
        guard guildAcknowledgementTasks[guildID] == nil else { return }
        let targets = readState.allServerAcknowledgements(in: [guildID])
        guard !targets.isEmpty else { return }

        for target in targets {
            preserveUnreadDividerIfNeeded(channelID: target.channelID)
            discardPendingAcknowledgement(for: target.channelID)
            readState.unblockAutomaticAcknowledgement(channelID: target.channelID)
            readState.acknowledge(channelID: target.channelID, messageID: target.messageID)
            cancelNativeNotifications(channelID: target.channelID)
        }
        refreshUnreadPresentation()

        let generation = acknowledgementGeneration
        let session = accountSession()
        let activeProvider = session.provider
        guildAcknowledgementTasks[guildID] = Task { [weak self] in
            // As in Discord, a failed batch is dropped silently.
            try? await activeProvider.acknowledgeBulk(targets)
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentAccountSession(session),
                  generation == self.acknowledgementGeneration
            else { return }
            self.guildAcknowledgementTasks[guildID] = nil
            self.refreshServerRailPresentation(guildID: guildID)
        }
        refreshServerRailPresentation(guildID: guildID)
    }

    /// Discord's category Mark as Read sends each conversation its own
    /// channel acknowledgement, as an explicit read does.
    func markCategoryRead(categoryID: ChannelID, guildID: GuildID) {
        guard !runsChatPerformanceBenchmark else { return }
        for target in readState.categoryAcknowledgements(for: categoryID, guildID: guildID) {
            markRead(channelID: target.channelID, through: target.messageID)
        }
        refreshUnreadPresentation()
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
        let settingsRevision = guildNotificationSettingsRevisions[guildID, default: 0]
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
                // A Gateway echo and a newer change from another client may
                // both arrive before HTTP completes. Keep that newer value.
                if self.guildNotificationSettingsRevisions[guildID, default: 0] == settingsRevision {
                    self.updateLocalGuildNotificationSettings(guild: guild) {
                        $0.set(toggle, isEnabled: isEnabled)
                    }
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
        for post: ForumPost,
        reportErrorInAlert: Bool = false
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
                let message = "Discord did not accept the notification setting."
                if reportErrorInAlert { self.errorMessage = message } else { self.forumActionError = message }
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
        for post: ForumPost,
        reportErrorInAlert: Bool = false
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
                let message = "Discord did not accept the mute setting."
                if reportErrorInAlert { self.errorMessage = message } else { self.forumActionError = message }
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
