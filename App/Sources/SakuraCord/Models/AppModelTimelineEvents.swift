import Foundation
import SakuraCordModels

extension AppModel {
    func updateServerRail(from snapshot: BootstrapSnapshot) {
        replaceServerRailGuilds(
            Dictionary(
                uniqueKeysWithValues: snapshot.guilds.map { ($0.id, $0) }
            )
        )
        serverRailItems = snapshot.guildRailItems
    }

    func reconcile(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        if message.nonce == nil,
           let index = selectedMessageIndex(for: message.id)
        {
            replaceSelectedMessage(
                message,
                at: index,
                preparedTextPlan: preparedTextPlan
            )
            return
        }
        let previousMessage = batchedSelectedMessages.last ?? messages.last
        if message.nonce == nil,
           previousMessage.map({
               $0.id < message.id && !Self.messagePrecedes(message, $0)
           }) ?? true
        {
            if isFlushingCreatedMessageBatch {
                batchedSelectedMessages.append(message)
                if let preparedTextPlan {
                    batchedSelectedTextPlansByID[message.id] =
                        preparedTextPlan
                }
            } else {
                appendSelectedMessage(
                    message,
                    preparedTextPlan: preparedTextPlan
                )
            }
            return
        }
        commitBatchedSelectedMessages()
        var updated = messages
        var resolved = message
        let replacementIndex =
            message.nonce.flatMap { nonce in
                updated.firstIndex(where: { $0.nonce == nonce })
            } ?? selectedMessageIndex(for: message.id)
        if let index = replacementIndex {
            resolved.replyTo = resolved.replyTo ?? updated[index].replyTo
            resolved.replyPreview = resolved.replyPreview ?? updated[index].replyPreview
            updated.remove(at: index)
            if let duplicateIndex = updated.firstIndex(where: { $0.id == resolved.id }) {
                updated.remove(at: duplicateIndex)
            }
            Self.insert(resolved, intoSorted: &updated)
        } else {
            Self.insert(resolved, intoSorted: &updated)
        }
        if updated != messages {
            replaceSelectedMessages(with: updated)
        }
    }

    func reconcileSelectedMessageUpdate(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        commitBatchedSelectedMessages()
        guard let index = selectedMessageIndex(for: message.id) else { return }
        replaceSelectedMessage(
            message,
            at: index,
            preparedTextPlan: preparedTextPlan
        )
    }

    func replaceSelectedMessage(
        _ incoming: Message,
        at index: Int,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        guard messages.indices.contains(index),
              messageRows.indices.contains(index)
        else { return }
        var resolved = incoming
        resolved.replyTo = resolved.replyTo ?? messages[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? messages[index].replyPreview
        guard resolved != messages[index] else { return }
        let previousReplyTarget = messages[index].replyTo
        if previousReplyTarget != resolved.replyTo {
            if let previousReplyTarget {
                selectedReplyMessageIDsByTarget[previousReplyTarget]?.remove(
                    resolved.id
                )
                if selectedReplyMessageIDsByTarget[previousReplyTarget]?.isEmpty
                    == true
                {
                    selectedReplyMessageIDsByTarget[previousReplyTarget] = nil
                }
            }
            if let replyTarget = resolved.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(resolved.id)
            }
        }
        messages[index] = resolved
        let changedIndexes = MessageGrouping.reconcileChangedMessage(
            id: resolved.id,
            replacement: resolved,
            messages: messages,
            availableMessageIDs: selectedMessageIDs,
            rows: &messageRows,
            messageIndex: selectedMessageIndex(for:),
            replyingMessageIDs:
                selectedReplyMessageIDsByTarget[resolved.id] ?? [],
            replacementTextPlan: preparedTextPlan
        )
        publishMessageRowsUpdate(
            change: .replace(changedIndexes),
            changedMessageIDs: Set(changedIndexes.map { messageRows[$0].id })
        )
        messageRowsNonAppendRevision &+= 1
    }

    func removeSelectedMessage(id: MessageID) {
        guard let index = selectedMessageIndex(for: id),
              messageRows.indices.contains(index)
        else { return }
        let removedReplyTarget = messages[index].replyTo
        messages.remove(at: index)
        messageRows.remove(at: index)
        selectedMessageIDs.remove(id)
        selectedMessageStoredIndexByID[id] = nil
        if index < messages.endIndex {
            for shiftedIndex in index ..< messages.endIndex {
                setSelectedMessageIndex(
                    shiftedIndex,
                    for: messages[shiftedIndex].id
                )
            }
        }
        if let removedReplyTarget {
            selectedReplyMessageIDsByTarget[removedReplyTarget]?.remove(id)
            if selectedReplyMessageIDsByTarget[removedReplyTarget]?.isEmpty
                == true
            {
                selectedReplyMessageIDsByTarget[removedReplyTarget] = nil
            }
        }
        let changedIndexes = MessageGrouping.reconcileChangedMessage(
            id: id,
            replacement: nil,
            messages: messages,
            availableMessageIDs: selectedMessageIDs,
            rows: &messageRows,
            neighborIndex: index,
            messageIndex: selectedMessageIndex(for:),
            replyingMessageIDs:
                selectedReplyMessageIDsByTarget[id] ?? []
        )
        publishMessageRowsUpdate(
            change: .remove(
                removedIndexes: IndexSet(integer: index),
                changedIndexes: changedIndexes
            ),
            changedMessageIDs: Set(changedIndexes.map { messageRows[$0].id }),
            removedMessageIDs: [id]
        )
        messageRowsNonAppendRevision &+= 1
    }

    func publishMessageRowsUpdate(
        change: MessageRowsUpdateHint.Change? = nil,
        insertedMessageIDs: [MessageID] = [],
        changedMessageIDs: Set<MessageID> = [],
        removedMessageIDs: Set<MessageID> = [],
        invalidatesAllRows: Bool = false
    ) {
        let nextRevision = latestMessageRowsRevision &+ 1
        latestMessageRowsRevision = nextRevision
        messageRowsUpdateHint = change.map {
            MessageRowsUpdateHint(revision: nextRevision, change: $0)
        }
        messageRowsUpdateJournal.append(
            MessageRowsUpdateRecord(
                revision: nextRevision,
                change: change,
                insertedMessageIDs: insertedMessageIDs,
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: removedMessageIDs,
                invalidatesAllRows: invalidatesAllRows
            )
        )
        messageRowsRevision = nextRevision
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: self
        )
    }

    func invalidateTimelinePresentation() {
        timelinePresentationRevision &+= 1
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: self
        )
    }

    func publishTimelineMemberPresentationChanges(
        from oldMembers: [UserID: Member],
        to newMembers: [UserID: Member],
        publishesCurrentRows: Bool = true
    ) {
        let changedUserIDs = AppPerformanceSignposts.measureSync(
            "TimelineMemberPresentationImpact"
        ) {
            var referencedUserIDs = TimelineMemberPresentationImpact
                .referencedUserIDs(in: messages)
            referencedUserIDs.formUnion(
                TimelineMemberPresentationImpact.referencedUserIDs(
                    in: threadMessages
                )
            )
            for cachedMessages in messageCache.values {
                referencedUserIDs.formUnion(
                    TimelineMemberPresentationImpact.referencedUserIDs(
                        in: cachedMessages
                    )
                )
            }
            guard !referencedUserIDs.isEmpty else { return Set<UserID>() }
            return TimelineMemberPresentationImpact.changedUserIDs(
                from: oldMembers,
                to: newMembers,
                guildRoles: guildRoles,
                candidates: referencedUserIDs
            )
        }
        guard !changedUserIDs.isEmpty else { return }

        let channelMessageIDs = TimelineMemberPresentationImpact
            .affectedMessageIDs(
                in: messages,
                changedUserIDs: changedUserIDs
            )
        let threadMessageIDs = TimelineMemberPresentationImpact
            .affectedMessageIDs(
                in: threadMessages,
                changedUserIDs: changedUserIDs
            )
        let affectsCachedConversation = messageCache.values.contains {
            !TimelineMemberPresentationImpact.affectedMessageIDs(
                in: $0,
                changedUserIDs: changedUserIDs
            ).isEmpty
        }

        // A recent off-screen conversation owns validated layouts and row
        // bitmaps inside the shared coordinator. Its model storage is not the
        // currently published row journal, so use the global revision only
        // when one of those cached rows genuinely depends on this member.
        if affectsCachedConversation {
            AppPerformanceSignposts.signposter.emitEvent(
                "TimelineInvalidationCachedMemberPresentation"
            )
            invalidateTimelinePresentation()
            return
        }
        guard publishesCurrentRows else { return }
        if !channelMessageIDs.isEmpty {
            publishMessageRowsUpdate(changedMessageIDs: channelMessageIDs)
        }
        if !threadMessageIDs.isEmpty {
            publishThreadMessageRowsPresentationUpdate(
                changedMessageIDs: threadMessageIDs
            )
        }
    }

    func applySelectedHistoryMemberHydration(
        _ hydratedMessages: [Message],
        presentationMessageIDs: Set<MessageID>
    ) {
        guard messages.count == hydratedMessages.count,
              messageRows.count == hydratedMessages.count,
              zip(messages, hydratedMessages).allSatisfy({
                  $0.id == $1.id
              }),
              zip(messageRows, hydratedMessages).allSatisfy({
                  $0.id == $1.id
              })
        else {
            replaceSelectedMessages(with: hydratedMessages)
            return
        }

        messages = hydratedMessages
        var replacedIndexes = IndexSet()
        for index in hydratedMessages.indices
        where presentationMessageIDs.contains(hydratedMessages[index].id) {
            let previousRow = messageRows[index]
            let hydratedMessage = hydratedMessages[index]
            guard previousRow.message != hydratedMessage else { continue }
            messageRows[index] = MessageRowPresentation(
                message: hydratedMessage,
                startsGroup: previousRow.startsGroup,
                endsGroup: previousRow.endsGroup,
                startsDay: previousRow.startsDay,
                replyPreview:
                    hydratedMessage.replyPreview
                    ?? previousRow.replyPreview,
                isReplyAvailable: previousRow.isReplyAvailable,
                textPlan: previousRow.textPlan
            )
            replacedIndexes.insert(index)
        }

        guard !presentationMessageIDs.isEmpty else { return }
        publishMessageRowsUpdate(
            change:
                replacedIndexes.isEmpty
                ? nil
                : .replace(replacedIndexes),
            changedMessageIDs: presentationMessageIDs
        )
    }

    func publishThreadMessageRowsPresentationUpdate(
        changedMessageIDs: Set<MessageID>
    ) {
        guard !changedMessageIDs.isEmpty else { return }
        let nextRevision = threadMessageRowsRevision &+ 1
        threadMessageRowsUpdateHint = nil
        threadMessageRowsUpdateJournal.append(
            MessageRowsUpdateRecord(
                revision: nextRevision,
                change: nil,
                insertedMessageIDs: [],
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: [],
                invalidatesAllRows: false
            )
        )
        threadMessageRowsRevision = nextRevision
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: self
        )
    }

    func requestUnreadPresentationRefresh() {
        guard liveScrollingConversationIDs.isEmpty,
              !isAppScrollDeferringUnread
        else {
            requestCoalescedUnreadPresentationRefresh()
            return
        }
        refreshUnreadPresentation()
    }

    func requestCoalescedUnreadPresentationRefresh() {
        hasDeferredUnreadPresentationRefresh = true
        guard unreadPresentationRefreshTask == nil
        else { return }
        AppPerformanceSignposts.signposter.emitEvent(
            "UnreadPresentationRefreshScheduled"
        )
        let account = accountSession()
        unreadPresentationRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentAccountSession(account)
            else { return }
            while !self.liveScrollingConversationIDs.isEmpty
                || self.isAppScrollDeferringUnread
            {
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
            }
            self.unreadPresentationRefreshTask = nil
            self.flushUnreadPresentationRefresh()
        }
    }

    func flushUnreadPresentationRefresh() {
        guard hasDeferredUnreadPresentationRefresh else { return }
        hasDeferredUnreadPresentationRefresh = false
        refreshUnreadPresentation()
    }

    func selectedMessageIndex(for id: MessageID) -> Int? {
        selectedMessageStoredIndexByID[id].map {
            $0 - selectedMessageIndexOrigin
        }
    }

    func setSelectedMessageIndex(
        _ index: Int,
        for id: MessageID
    ) {
        selectedMessageStoredIndexByID[id] =
            index + selectedMessageIndexOrigin
    }

    func rebuildSelectedMessageIndexes() {
        selectedMessageIDs = Set(messages.lazy.map(\.id))
        selectedMessageIndexOrigin = 0
        selectedMessageStoredIndexByID.removeAll(keepingCapacity: true)
        selectedMessageStoredIndexByID.reserveCapacity(messages.count)
        selectedReplyMessageIDsByTarget.removeAll(keepingCapacity: true)
        for (index, message) in messages.enumerated() {
            setSelectedMessageIndex(index, for: message.id)
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
    }

    func replaceSelectedMessages(
        with incomingMessages: [Message],
        preparedRows: [MessageRowPresentation]? = nil
    ) {
        let commit = AppPerformanceSignposts.signposter.beginInterval(
            "MessageStateCommit"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "MessageStateCommit",
                commit
            )
        }
        let newMessages = pollVoteMutations.isEmpty
            ? incomingMessages : incomingMessages.map(pollVotePresentationPreserving)
        seedSlowmodeHistory(newMessages)
        let oldMessages = messages
        messages = newMessages
        rebuildSelectedMessageIndexes()
        let rows = AppPerformanceSignposts.signposter.beginInterval(
            "MessageRowPreparation"
        )
        if let preparedRows,
           Self.rows(preparedRows, match: newMessages)
        {
            messageRows = preparedRows
        } else {
            messageRows = MessageGrouping.updating(
                existing: messageRows,
                oldMessages: oldMessages,
                newMessages: newMessages
            )
        }
        AppPerformanceSignposts.signposter.endInterval(
            "MessageRowPreparation",
            rows
        )
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    func mutateSelectedMessages(
        _ mutation: (inout [Message]) -> Void
    ) {
        let oldMessages = messages
        mutation(&messages)
        rebuildSelectedMessageIndexes()
        messageRows = MessageGrouping.updating(
            existing: messageRows,
            oldMessages: oldMessages,
            newMessages: messages
        )
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    func prependSelectedMessages(
        _ earlier: [Message],
        channelID: ChannelID
    ) async -> Bool {
        guard !earlier.isEmpty else { return true }
        // History preparation performs Markdown/CoreText setup for an entire
        // page. Running it at userInitiated priority lets it contend with the
        // main thread for font and attributed-string internals precisely
        // while the display link is trying to present the next scroll frame.
        // The page is prefetched thousands of points ahead, so utility
        // priority preserves that headroom without priority-inverting UI
        // presentation on every pagination boundary.
        let preparationPriority: TaskPriority = AppScrollWorkGate.isActive
            ? .background
            : .utility
        let preparedInsertedRows = await AppPerformanceSignposts.measure(
            "EarlierHistoryRowPreparation"
        ) {
            await prepareTimelineRows(
                for: earlier,
                priority: preparationPriority
            )
        }
        guard !Task.isCancelled, selectedChannelID == channelID else {
            return false
        }
        let stateCommit = AppPerformanceSignposts.signposter.beginInterval(
            "EarlierHistoryStateCommit",
            id: AppPerformanceSignposts.signposter.makeSignpostID()
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "EarlierHistoryStateCommit", stateCommit
            )
        }
        let commitStart = ProcessInfo.processInfo.systemUptime
        var potentiallyChangedMessageIDs = Set<MessageID>()
        if let firstExistingID = messageRows.first?.id {
            potentiallyChangedMessageIDs.insert(firstExistingID)
        }
        for message in earlier {
            potentiallyChangedMessageIDs.formUnion(
                selectedReplyMessageIDsByTarget[message.id] ?? []
            )
        }
        var previousRowsByID: [MessageID: MessageRowPresentation] = [:]
        previousRowsByID.reserveCapacity(potentiallyChangedMessageIDs.count)
        for id in potentiallyChangedMessageIDs {
            if let oldIndex = selectedMessageIndex(for: id),
               messageRows.indices.contains(oldIndex)
            {
                previousRowsByID[id] = messageRows[oldIndex]
            }
        }
        MessageGrouping.prependRows(
            for: earlier,
            into: &messageRows,
            preparedInsertedRows: preparedInsertedRows,
            existingMessageIndex: selectedMessageIndex(for:),
            replyingMessageIDsByTarget:
                selectedReplyMessageIDsByTarget
        )
        let changedMessageIDs = Set(
            potentiallyChangedMessageIDs.filter { id in
                guard let oldIndex = selectedMessageIndex(for: id),
                      let previousRow = previousRowsByID[id],
                      messageRows.indices.contains(earlier.count + oldIndex)
                else { return false }
                return previousRow
                    != messageRows[earlier.count + oldIndex]
            }
        )
        messages.insert(contentsOf: earlier, at: 0)
        selectedMessageIndexOrigin -= earlier.count
        selectedMessageIDs.formUnion(earlier.lazy.map(\.id))
        selectedMessageStoredIndexByID.reserveCapacity(messages.count)
        for (index, message) in earlier.enumerated() {
            setSelectedMessageIndex(index, for: message.id)
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
        publishMessageRowsUpdate(
            change: .insert(
                IndexSet(integersIn: 0 ..< earlier.count)
            ),
            insertedMessageIDs: earlier.map(\.id),
            changedMessageIDs: changedMessageIDs
        )
        messageRowsNonAppendRevision &+= 1
        if runsChatPerformanceBenchmark {
            let commitMilliseconds =
                (ProcessInfo.processInfo.systemUptime - commitStart) * 1_000
            if commitMilliseconds >= 4 {
                NSLog(
                    "SakuraCord history commit: %.2f ms (%d rows)",
                    commitMilliseconds,
                    messageRows.count
                )
            }
        }
        return true
    }

    func appendSelectedMessage(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        appendSelectedMessages(
            [message],
            preparedTextPlans:
                preparedTextPlan.map { [message.id: $0] } ?? [:]
        )
    }

    func appendSelectedMessages(
        _ appendedMessages: [Message],
        preparedTextPlans: [MessageID: NativeTimelineTextPlan] = [:],
        preparedRows: [MessageRowPresentation]? = nil
    ) {
        guard !appendedMessages.isEmpty else { return }
        let insertionStart = messageRows.count
        let previousBoundaryRow = messageRows.last
        let preparedRows = preparedRows?.map { row in
            guard let textPlan = preparedTextPlans[row.id] else { return row }
            return MessageRowPresentation(
                message: row.message,
                startsGroup: row.startsGroup,
                endsGroup: row.endsGroup,
                startsDay: row.startsDay,
                replyPreview: row.replyPreview,
                isReplyAvailable: row.isReplyAvailable,
                textPlan: textPlan
            )
        }
        MessageGrouping.appendRows(
            for: appendedMessages,
            into: &messageRows,
            after: messages.last,
            preparedInsertedRows: preparedRows,
            existingMessage: { [self] id in
                selectedMessageIndex(for: id).map { messages[$0] }
            }
        )
        if preparedRows == nil, !preparedTextPlans.isEmpty {
            for index in insertionStart ..< messageRows.count {
                let row = messageRows[index]
                guard let textPlan = preparedTextPlans[row.id] else { continue }
                messageRows[index] = MessageRowPresentation(
                    message: row.message,
                    startsGroup: row.startsGroup,
                    endsGroup: row.endsGroup,
                    startsDay: row.startsDay,
                    replyPreview: row.replyPreview,
                    isReplyAvailable: row.isReplyAvailable,
                    textPlan: textPlan
                )
            }
        }
        var changedBoundaryMessageIDs = Set<MessageID>()
        if let previousBoundaryRow,
           messageRows[insertionStart - 1] != previousBoundaryRow
        {
            changedBoundaryMessageIDs.insert(previousBoundaryRow.id)
        }
        messages.append(contentsOf: appendedMessages)
        selectedMessageIDs.formUnion(appendedMessages.lazy.map(\.id))
        for (offset, message) in appendedMessages.enumerated() {
            setSelectedMessageIndex(
                insertionStart + offset,
                for: message.id
            )
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
        publishMessageRowsUpdate(
            change: .insert(
                IndexSet(
                    integersIn:
                        insertionStart ..< insertionStart + appendedMessages.count
                )
            ),
            insertedMessageIDs: appendedMessages.map(\.id),
            changedMessageIDs: changedBoundaryMessageIDs
        )
    }

    func appendSelectedHistoryMessages(
        _ later: [Message],
        channelID: ChannelID
    ) async -> Bool {
        guard !later.isEmpty else { return true }
        let preparationPriority: TaskPriority = AppScrollWorkGate.isActive
            ? .background
            : .utility
        let preparedRows = await AppPerformanceSignposts.measure(
            "LaterHistoryRowPreparation"
        ) {
            await prepareTimelineRows(
                for: later,
                priority: preparationPriority
            )
        }
        guard !Task.isCancelled, selectedChannelID == channelID else {
            return false
        }
        AppPerformanceSignposts.measureSync("LaterHistoryStateCommit") {
            appendSelectedMessages(later, preparedRows: preparedRows)
        }
        return true
    }

    func commitBatchedSelectedMessages() {
        guard !batchedSelectedMessages.isEmpty else { return }
        let pending = batchedSelectedMessages
        batchedSelectedMessages.removeAll(keepingCapacity: true)
        let preparedTextPlans = batchedSelectedTextPlansByID
        batchedSelectedTextPlansByID.removeAll(keepingCapacity: true)
        appendSelectedMessages(
            pending,
            preparedTextPlans: preparedTextPlans
        )
    }

    @discardableResult
    func reconcileVisibleOrCached(_ incoming: Message) -> Message {
        let message = pollVotePresentationPreserving(reactionPresentationPreserving(
            outgoingMediaPresentationPreserving(incoming)
        ))
        reconcileInboxMessage(message)
        receiveGuideResourceEvent(.messageUpdated(message))
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            reconcile(message)
        } else {
            cache(message)
        }
        return message
    }

    func reactionPresentationPreserving(_ incoming: Message) -> Message {
        var result = incoming
        let lookupKey = ReactionMutationKey(
            channelID: incoming.channelID,
            messageID: incoming.id,
            reactionID: ""
        )
        if let existing = reactionMessage(for: lookupKey) {
            result = result.preservingReactionReactors(from: existing)
        }

        guard let currentUserID = snapshot?.currentUser.id else { return result }
        let currentUserReactor = knownReactionReactor(for: currentUserID)
        for (key, mutation) in reactionMutations
        where key.channelID == result.channelID && key.messageID == result.id {
            let currentlyReacted =
                result.reactions.first(where: { $0.id == key.reactionID })?
                    .didCurrentUserReact ?? false
            guard currentlyReacted != mutation.desiredReacted else { continue }
            let update: MessageReactionUpdate =
                mutation.desiredReacted
                ? .add(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
                : .remove(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
            _ = result.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: currentUserReactor
            )
        }
        return result
    }

    func reactionConfirmedSnapshot(_ message: Message) -> Message {
        guard let currentUserID = snapshot?.currentUser.id else { return message }
        var result = message
        let currentUserReactor = knownReactionReactor(for: currentUserID)
        for (key, mutation) in reactionMutations
        where key.channelID == result.channelID && key.messageID == result.id {
            let currentlyReacted =
                result.reactions.first(where: { $0.id == key.reactionID })?
                    .didCurrentUserReact ?? false
            guard currentlyReacted != mutation.confirmedReacted else { continue }
            let update: MessageReactionUpdate =
                mutation.confirmedReacted
                ? .add(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
                : .remove(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
            _ = result.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: currentUserReactor
            )
        }
        return result
    }

    func updateOutgoingState(_ state: OutboxState, nonce: String, channelID: ChannelID) {
        if openThread?.id == channelID,
           let index = threadMessages.firstIndex(where: { $0.nonce == nonce })
        {
            threadMessages[index].outboxState = state
            return
        }
        if selectedChannelID == channelID,
           let index = messages.firstIndex(where: { $0.nonce == nonce })
        {
            mutateSelectedMessages {
                $0[index].outboxState = state
            }
            return
        }
        guard var cached = messageCache[channelID],
              let index = cached.firstIndex(where: { $0.nonce == nonce })
        else { return }
        cached[index].outboxState = state
        messageCache[channelID] = cached
    }

    func removeOutgoingMessage(nonce: String, channelID: ChannelID) {
        if openThread?.id == channelID {
            threadMessages.removeAll { $0.nonce == nonce }
            return
        }
        if selectedChannelID == channelID {
            mutateSelectedMessages {
                $0.removeAll { $0.nonce == nonce }
            }
            return
        }
        guard var cached = messageCache[channelID] else { return }
        cached.removeAll { $0.nonce == nonce }
        messageCache[channelID] = cached
    }

    func outgoingState(nonce: String, channelID: ChannelID) -> OutboxState? {
        if openThread?.id == channelID {
            return threadMessages.first { $0.nonce == nonce }?.outboxState
        }
        if selectedChannelID == channelID {
            return messages.first { $0.nonce == nonce }?.outboxState
        }
        return messageCache[channelID]?.first { $0.nonce == nonce }?.outboxState
    }

    func reconcileThread(_ message: Message) {
        var updated = threadMessages
        if let index = updated.firstIndex(where: {
            $0.id == message.id || ($0.nonce != nil && $0.nonce == message.nonce)
        }) {
            updated.remove(at: index)
            if let duplicateIndex = updated.firstIndex(where: {
                $0.id == message.id
            }) {
                updated.remove(at: duplicateIndex)
            }
        }
        Self.insert(message, intoSorted: &updated)
        guard updated != threadMessages else { return }
        threadMessages = updated
    }

    func reconcileThreadUpdate(_ message: Message) {
        guard let index = threadMessages.firstIndex(where: {
            $0.id == message.id
        }) else { return }
        var updated = threadMessages
        var resolved = message
        resolved.replyTo = resolved.replyTo ?? updated[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? updated[index].replyPreview
        guard resolved != updated[index] else { return }
        updated[index] = resolved
        threadMessages = updated
    }

    static func insert(_ message: Message, intoSorted messages: inout [Message]) {
        guard let last = messages.last, !messagePrecedes(message, last) else {
            let index = insertionIndex(for: message, in: messages)
            messages.insert(message, at: index)
            return
        }
        messages.append(message)
    }

    static func insertionIndex(for message: Message, in messages: [Message]) -> Int {
        var lowerBound = messages.startIndex
        var upperBound = messages.endIndex
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if messagePrecedes(messages[midpoint], message) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    /// Unconfirmed local sends stay below settled messages in submission
    /// order. A confirmation carries a later server timestamp than the local
    /// time of the sends queued behind it, so it settles in place.
    static func messagePrecedes(_ lhs: Message, _ rhs: Message) -> Bool {
        let lhsUnconfirmed = lhs.isUnconfirmedLocalSend
        if lhsUnconfirmed != rhs.isUnconfirmedLocalSend { return !lhsUnconfirmed }
        return lhs.timestamp != rhs.timestamp ? lhs.timestamp < rhs.timestamp : lhs.id < rhs.id
    }

    func cache(_ message: Message) {
        let current = messageCache[message.channelID] ?? []
        storeCachedMessages(
            Self.merging(current: current, fresh: [message]),
            for: message.channelID
        )
    }

    func storeCachedMessages(
        _ messages: [Message],
        for channelID: ChannelID
    ) {
        let retained = ChannelMessageCachePolicy.retainedMessages(from: messages)
        messageCache[channelID] = retained
        if let cachedRows = messageRowCache[channelID],
           !Self.rows(cachedRows, match: retained)
        {
            messageRowCache[channelID] = nil
            messageRowCacheOrder.removeAll { $0 == channelID }
        }
        messageCacheOrder.removeAll { $0 == channelID }
        messageCacheOrder.append(channelID)
        if retained.count < messages.count {
            hasMoreCache[channelID] = true
        }
        while messageCacheOrder.count
            > ChannelMessageCachePolicy.maximumChannelCount
        {
            let evicted = messageCacheOrder.removeFirst()
            messageCache[evicted] = nil
            messageRowCache[evicted] = nil
            messageRowCacheOrder.removeAll { $0 == evicted }
            hasMoreCache[evicted] = nil
        }
    }

    func storeCachedMessageRows(
        _ rows: [MessageRowPresentation],
        for channelID: ChannelID
    ) {
        guard let cachedMessages = messageCache[channelID]
        else {
            messageRowCache[channelID] = nil
            messageRowCacheOrder.removeAll { $0 == channelID }
            return
        }
        let retainedRows = Array(rows.suffix(cachedMessages.count))
        guard Self.rows(retainedRows, match: cachedMessages) else {
            messageRowCache[channelID] = nil
            messageRowCacheOrder.removeAll { $0 == channelID }
            return
        }
        messageRowCache[channelID] = retainedRows
        messageRowCacheOrder.removeAll { $0 == channelID }
        messageRowCacheOrder.append(channelID)
        while messageRowCacheOrder.count
            > ChannelMessageCachePolicy.maximumPreparedChannelCount
        {
            let evicted = messageRowCacheOrder.removeFirst()
            messageRowCache[evicted] = nil
        }
    }

    func takeCachedMessages(for channelID: ChannelID) -> [Message] {
        messageCacheOrder.removeAll { $0 == channelID }
        return messageCache.removeValue(forKey: channelID) ?? []
    }

    func takeCachedMessageRows(
        for channelID: ChannelID
    ) -> [MessageRowPresentation]? {
        messageRowCacheOrder.removeAll { $0 == channelID }
        return messageRowCache.removeValue(forKey: channelID)
    }

    static func rows(
        _ rows: [MessageRowPresentation],
        match messages: [Message]
    ) -> Bool {
        rows.count == messages.count
            && zip(rows, messages).allSatisfy {
                $0.message == $1
            }
    }

    func reconcileCachedMessageUpdate(_ message: Message) {
        guard var cached = messageCache[message.channelID],
              let index = cached.firstIndex(where: { $0.id == message.id })
        else { return }
        var resolved = message
        resolved.replyTo = resolved.replyTo ?? cached[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? cached[index].replyPreview
        guard resolved != cached[index] else { return }
        cached[index] = resolved
        messageCache[message.channelID] = cached
    }
}
