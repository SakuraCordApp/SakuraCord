import DiscordProtocol
import Foundation
import OSLog
import SakuraCordModels

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

    func jumpToUnreadBoundary(channelID: ChannelID) {
        guard isConversationPresented(channelID) else { return }
        let isThread = openThread?.id == channelID
        startConversationNavigation { model, account in
            @MainActor func isPresented() -> Bool {
                !Task.isCancelled
                    && model.isCurrentAccountSession(account)
                    && model.isConversationPresented(channelID)
                    && (model.openThread?.id == channelID) == isThread
            }
            guard isPresented() else { return }
            var glides = true
            var summary = model.presentedUnreadSummary(channelID: channelID)
            model.preserveUnreadDividerIfNeeded(channelID: channelID)
            if summary?.isLowerBound == true {
                // Discord reads one window around the last acknowledged
                // message instead of paging toward it.
                if let acknowledged = model.readState[channelID]?.lastAcknowledgedMessageID,
                   acknowledged.rawValue > 0
                {
                    let loaded = isThread
                        ? await model.loadThreadWindow(around: acknowledged, session: account)
                        : await model.loadSelectedMessageWindow(
                            around: acknowledged,
                            channelID: channelID,
                            session: account
                        )
                    guard loaded, isPresented() else { return }
                } else {
                    // Nothing anchors a window, so page toward the unread
                    // start, stopping once a page adds no older message.
                    var previousOldestID: MessageID?
                    while isPresented(),
                          model.presentedUnreadSummary(channelID: channelID)?.isLowerBound == true,
                          let oldestID = (isThread ? model.threadMessages : model.messages).first?.id,
                          previousOldestID.map({ oldestID < $0 }) ?? true
                    {
                        previousOldestID = oldestID
                        if isThread {
                            await model.loadEarlierThread(account: account)
                        } else {
                            await model.loadEarlier(account: account)
                        }
                    }
                    guard isPresented() else { return }
                }
                glides = false
                summary = model.presentedUnreadSummary(channelID: channelID)
                model.preserveUnreadDividerIfNeeded(channelID: channelID)
            }
            // The visual divider survives acknowledgements. Jump to the
            // current unread run without moving that retained divider.
            guard let summary, !summary.isLowerBound else { return }
            model.messageNavigationRequestID &+= 1
            model.messageNavigationRequest = MessageNavigationRequest(
                requestID: model.messageNavigationRequestID,
                channelID: channelID,
                messageID: summary.firstUnreadMessageID,
                glides: glides,
                isUnreadBoundary: true
            )
        }
    }

    /// Whether `channelID` is one of the two conversations whose messages are loaded.
    func isSelectedOrOpenThread(_ channelID: ChannelID) -> Bool {
        channelID == selectedChannelID || channelID == openThread?.id
    }

    /// The loaded messages of the open thread or the selected channel.
    private func loadedMessages(for channelID: ChannelID) -> [Message] {
        channelID == openThread?.id ? threadMessages : messages
    }

    /// Jumps to the newest message as soon as a send appends its local row.
    /// Returns false on an older page (reloading would replace the local row)
    /// or before the initial position (a backlog hold can still appear); those
    /// sends advance on confirmation instead.
    func advanceTimelineForLocalSend(channelID: ChannelID) -> Bool {
        guard isSelectedOrOpenThread(channelID),
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
        guard isSelectedOrOpenThread(channelID),
              readState.canAcknowledge(channelID)
        else { return }
        markConversationRead(channelID: channelID)
        unreadDividerMessageIDs[channelID] = nil
    }

    func completeConversationReadingAndAdvance(channelID: ChannelID) {
        guard isSelectedOrOpenThread(channelID) else { return }
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
        return !loadedMessages(for: channelID).contains { $0.id == divider }
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
        guard isSelectedOrOpenThread(channelID),
              message.id.rawValue > 0,
              let currentUserID = snapshot?.currentUser.id
        else { return }
        let conversationMessages = loadedMessages(for: channelID)
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
        let millisecond = message.id.discordEpochMilliseconds
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

    func isOutsideAcknowledgementScope(_ channelID: ChannelID) -> Bool {
        isOutsideAcknowledgementScope(guildID: readState[channelID]?.guildID)
    }

    /// DEBUG Inbox verification confines account acknowledgements to one
    /// server, so live verification leaves unrelated conversations unread.
    func isOutsideAcknowledgementScope(guildID: @autoclosure () -> GuildID?) -> Bool {
        #if DEBUG
            if let scope = ProcessInfo.processInfo.environment["SAKURACORD_INBOX_VERIFICATION_GUILD_ID"] {
                return guildID()?.description != scope
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
                logReadAcknowledgement(.send, channelID: channelID, mutation: mutation)
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
                logReadAcknowledgement(.accepted, channelID: channelID, mutation: mutation)
            } catch is CancellationError {
                return
            } catch {
                // As in Discord, a failure changes no read state.
                logReadAcknowledgement(.failed, channelID: channelID, mutation: mutation)
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
        acknowledgeExplicitly(channelID: channelID, through: target)
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(channelID: channelID, mutation: readStateMutation(channelID: channelID, messageID: target))
    }

    /// Applies an explicit read locally: it replaces any debounced automatic
    /// one and lifts a hold on automatic reads.
    func acknowledgeExplicitly(channelID: ChannelID, through target: MessageID) {
        discardPendingAcknowledgement(for: channelID)
        readState.unblockAutomaticAcknowledgement(channelID: channelID)
        readState.acknowledge(channelID: channelID, messageID: target)
    }

    /// Logs a read acknowledgement's progress; a failure logs as an error.
    func logReadAcknowledgement(
        _ stage: ReadAcknowledgementLogStage,
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        let channel = channelID.rawValue
        let message = mutation.messageID.rawValue
        Self.unreadDiagnosticsLogger.log(
            level: stage == .failed ? .error : .info,
            "Read ack \(stage.rawValue, privacy: .public) c=\(channel, privacy: .public) m=\(message, privacy: .public)"
        )
    }

    func readStateMutation(channelID: ChannelID, messageID: MessageID) -> ReadStateMutation {
        let metadata = readState.acknowledgementMetadata(channelID: channelID)
        return ReadStateMutation(messageID: messageID, flags: metadata.flags, lastViewed: metadata.lastViewed)
    }

    func resetAcknowledgementWork() {
        acknowledgementGeneration &+= 1
        allServersReadTask?.cancel()
        allServersReadTask = nil
        isMarkingAllServersRead = false
        acknowledgementTasks.cancelAll()
        acknowledgementProcessorTask?.cancel()
        acknowledgementProcessorTask = nil
        guildAcknowledgementTasks.cancelAll()
        queuedAcknowledgements.removeAll()
    }

    func resetChannelNotificationMutations() {
        channelNotificationMutationGeneration &+= 1
        notificationMutationTasks.cancelAll()
        guildNotificationSettingsRevisions.removeAll()
        categoryCollapseMutationTasks.cancelAll()
        categoryCollapseMutationStates.removeAll()
        optimisticCategoryCollapsedByID.removeAll()
        channelPinMutationTasks.cancelAll()
        channelPinMutationStates.removeAll()
        optimisticChannelPinnedByID.removeAll()
    }

    /// Reads a server Mark as Read's conversations locally before Discord
    /// confirms, keeping each open timeline's unread divider in place.
    func acknowledgeServerConversationsLocally(_ targets: [BulkReadStateAcknowledgement]) {
        for target in targets {
            preserveUnreadDividerIfNeeded(channelID: target.channelID)
            acknowledgeExplicitly(channelID: target.channelID, through: target.messageID)
        }
    }

    func markGuildRead(_ guildID: GuildID) {
        guard !runsChatPerformanceBenchmark else { return }
        guard guildAcknowledgementTasks[guildID] == nil else { return }
        let targets = readState.allServerAcknowledgements(in: [guildID])
        guard !targets.isEmpty else { return }

        acknowledgeServerConversationsLocally(targets)
        for target in targets {
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

}

nonisolated enum ReadAcknowledgementLogStage: String {
    case send
    case accepted
    case failed
}
