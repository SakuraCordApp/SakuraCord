import DiscordProtocol
import Foundation
import SakuraCordModels

/// The current user's poll selection while a vote request is pending.
struct PollVoteMutationState {
    var channelID: ChannelID
    var confirmed: Set<Int>
    var desired: Set<Int>
    var isSending: Bool
}

extension MessageUpdate {
    /// A fetched tally has no ordering token relative to Gateway vote deltas.
    /// Only a snapshot recorded in the journal establishes a replay baseline.
    func applyForRefresh(to message: inout Message) {
        var fields = self
        fields.pollUpdates = []
        fields.apply(to: &message)
        var hasPollBaseline = message.poll?.results?.isFinalized == true
        var needsPollRefresh = false
        for update in pollUpdates {
            switch update {
            case .snapshot(let poll, _):
                update.apply(to: &message)
                hasPollBaseline = hasPollBaseline || poll.results != nil
                if poll.results != nil { needsPollRefresh = false }
            case .vote(_, _, let isCurrentUser):
                if hasPollBaseline || isCurrentUser {
                    update.apply(to: &message)
                } else {
                    needsPollRefresh = true
                }
            }
        }
        if needsPollRefresh { message.poll?.results = nil }
    }
}

private extension Message {
    func selectingCurrentUserPollAnswers(_ answerIDs: Set<Int>) -> Message {
        guard let poll, var results = poll.results, poll.selectedAnswerIDs != answerIDs else { return self }
        var result = self
        if results.isFinalized {
            // Final counts are authoritative; only the personal selection may
            // still need correction when a pending request completes.
            for index in results.answerCounts.indices {
                results.answerCounts[index].meVoted = answerIDs.contains(results.answerCounts[index].id)
            }
            result.poll?.results = results
            return result
        }
        for update in MessagePollUpdate.currentUserSelection(from: poll.selectedAnswerIDs, to: answerIDs) {
            update.apply(to: &result)
        }
        return result
    }
}

extension AppModel {
    func canCreatePoll(in channelID: ChannelID) -> Bool {
        let isThread = openThread?.id == channelID
        guard let channel = isThread ? openThreadParentChannel : snapshot?.channels.first(where: { $0.id == channelID }),
              (isThread ? openThreadAccess : conversationAccess(for: channel)).canSend else { return false }
        guard channel.guildID != nil else { return true }
        guard let permissions = effectiveMessagePermissions(in: channel) else { return false }
        return permissions & ((1 << 49) | DiscordPermissionBits.administrator) != 0
    }

    func createPoll(_ poll: PollDraft, in channelID: ChannelID) async -> ComposerSubmissionResult {
        guard canCreatePoll(in: channelID), allowSlowmodeSubmission(in: channelID) else { return .rejected }
        if let validationError = poll.validationError {
            errorMessage = validationError
            return .rejected
        }
        let session = accountSession()
        if channelID == selectedChannelID {
            guard await prepareChannelMessageSubmission(channelID: channelID, account: session) else { return .rejected }
        }
        guard isCurrentAccountSession(session), canCreatePoll(in: channelID),
              allowOutgoingQueueSubmission(),
              // The poll appears as an outgoing message with retry, so the
              // creator does not wait for the server.
              let delivery = enqueueChannelMessage(channelID: channelID, content: "", replyTo: nil,
                                                   replyPreview: nil, attachments: [], clearsComposer: false, poll: poll)
        else { return .rejected }
        return .enqueued(delivery: delivery)
    }

    /// Shows the current user's selection immediately and coalesces requests.
    /// Gateway echoes of the current user's vote are idempotent.
    @discardableResult
    func vote(on message: Message, answerIDs: Set<Int>) -> Bool {
        guard let poll = (retainedMessage(channelID: message.channelID, messageID: message.id) ?? message).poll,
              !poll.isClosed(), poll.layoutType == 1, poll.allowsMultipleAnswers || answerIDs.count <= 1,
              answerIDs.allSatisfy({ id in poll.answers.contains { $0.id == id } }) else { return false }
        var state = pollVoteMutations[message.id] ?? PollVoteMutationState(
            channelID: message.channelID, confirmed: poll.selectedAnswerIDs, desired: poll.selectedAnswerIDs, isSending: false
        )
        state.desired = answerIDs
        pollVoteMutations[message.id] = state
        applyCurrentUserPollSelection(answerIDs, messageID: message.id, channelID: message.channelID)
        sendPollVoteMutation(messageID: message.id)
        return true
    }

    private func sendPollVoteMutation(messageID: MessageID) {
        guard var state = pollVoteMutations[messageID], !state.isSending else { return }
        guard state.desired != state.confirmed else {
            pollVoteMutations[messageID] = nil
            return
        }
        let answerIDs = state.desired
        let channelID = state.channelID
        state.isSending = true
        pollVoteMutations[messageID] = state
        startAccountChildTask(account: accountSession()) { model, session in
            do {
                try await session.provider.setPollAnswers(answerIDs.sorted(), messageID: messageID, channelID: channelID)
            } catch {
                guard model.isCurrentAccountSession(session),
                      let latest = model.pollVoteMutations.removeValue(forKey: messageID) else { return }
                model.applyCurrentUserPollSelection(latest.confirmed, messageID: messageID, channelID: channelID)
                model.errorMessage = error.localizedDescription
                return
            }
            guard model.isCurrentAccountSession(session), var latest = model.pollVoteMutations[messageID] else { return }
            latest.confirmed = answerIDs
            latest.isSending = false
            model.pollVoteMutations[messageID] = latest
            if let message = model.retainedMessage(channelID: channelID, messageID: messageID) {
                model.recordAuthoritativeMessageUpsert(message)
                model.reconcilePollSearchMessage(message)
                model.reconcileInboxMessage(message)
            }
            model.sendPollVoteMutation(messageID: messageID)
            guard let message = model.retainedMessage(channelID: channelID, messageID: messageID) else { return }
            if message.poll?.results == nil { await model.loadUnknownPollResults(message) }
        }
    }

    func reconcilePollVoteConfirmation(_ update: MessageUpdate) {
        guard var state = pollVoteMutations[update.messageID], state.channelID == update.channelID else { return }
        for case let .vote(answerID, isAddition, true) in update.pollUpdates {
            if isAddition { state.confirmed.insert(answerID) } else { state.confirmed.remove(answerID) }
        }
        pollVoteMutations[update.messageID] = state
    }

    private func applyCurrentUserPollSelection(_ answerIDs: Set<Int>, messageID: MessageID, channelID: ChannelID) {
        guard let message = retainedMessage(channelID: channelID, messageID: messageID) else { return }
        let updated = message.selectingCurrentUserPollAnswers(answerIDs)
        guard updated != message else { return }
        consumeMessageUpdated(updated, preparedTextPlan: nil, recordsRefreshMutation: false)
    }

    func pollVotePresentationPreserving(_ incoming: Message) -> Message {
        guard let mutation = pollVoteMutations[incoming.id], mutation.channelID == incoming.channelID else { return incoming }
        return incoming.selectingCurrentUserPollAnswers(mutation.desired)
    }

    func pollVoteConfirmedSnapshot(_ message: Message) -> Message {
        guard let mutation = pollVoteMutations[message.id], mutation.channelID == message.channelID else { return message }
        return message.selectingCurrentUserPollAnswers(mutation.confirmed)
    }

    func endPoll(_ message: Message) async {
        let session = accountSession()
        do {
            let updated = try await session.provider.endPoll(messageID: message.id, channelID: message.channelID)
            guard isCurrentAccountSession(session) else { return }
            let reconciled = reconcileVisibleOrCached(updated)
            recordAuthoritativeMessageUpsert(reconciled)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

extension AppModel {
    func messageSearchPagePreservingPollVotes(_ incoming: MessageSearchPage) -> MessageSearchPage {
        let mutations = messageSearch.pollRefreshJournal?.mutationsByMessageID ?? [:]
        guard !pollVoteMutations.isEmpty || !mutations.isEmpty else { return incoming }
        var page = incoming
        for resultIndex in page.results.indices {
            for index in page.results[resultIndex].messages.indices {
                var message = page.results[resultIndex].messages[index]
                if case .patch(let update) = mutations[message.id] {
                    update.applyForRefresh(to: &message)
                }
                page.results[resultIndex].messages[index] = pollVotePresentationPreserving(message)
            }
        }
        return page
    }

    func reconcilePollSearchMessage(_ message: Message) {
        guard message.poll != nil, var page = messageSearch.page else { return }
        var changed = false
        for resultIndex in page.results.indices {
            for index in page.results[resultIndex].messages.indices
            where page.results[resultIndex].messages[index].id == message.id {
                guard page.results[resultIndex].messages[index].poll != message.poll else { continue }
                page.results[resultIndex].messages[index].poll = message.poll
                page.results[resultIndex].messages[index].hasPoll = true
                changed = true
            }
        }
        guard changed else { return }
        let oldRows = messageSearch.rows
        messageSearch.page = page
        messageSearch.rows = MessageSearchPresentation.rows(for: page, channelsByID: messageSearchChannelsByID(additionalChannels: page.channels))
        let revision = messageSearch.rowsRevision &+ 1
        messageSearch.rowsUpdateJournal.append(MessageRowsUpdateRecordBuilder.make(oldRows: oldRows, newRows: messageSearch.rows, revision: revision))
        messageSearch.rowsRevision = revision
    }

    func recordPollRefreshMutation(_ mutation: ConversationRefreshMutation, messageID: MessageID, channelID: ChannelID) {
        guard pollResultRefreshJournals[messageID] != nil || messageSearch.pollRefreshJournal != nil else { return }
        let updates: [MessagePollUpdate]
        switch mutation {
        case .upsert(let message):
            // A retained snapshot may have changed only its reactions or pins.
            // Merge its poll fields rather than replacing fetched results with
            // that snapshot's still-unknown results.
            updates = message.poll.map { [.snapshot($0, preservingSelection: false)] } ?? []
        case .patch(let update):
            updates = update.pollUpdates
        case .delete:
            pollResultRefreshJournals[messageID]?.record(.delete, messageID: messageID)
            return
        }
        guard !updates.isEmpty else { return }
        var patch = MessageUpdate(messageID: messageID, channelID: channelID)
        patch.pollUpdates = updates
        pollResultRefreshJournals[messageID]?.record(.patch(patch), messageID: messageID)
        messageSearch.pollRefreshJournal?.record(.patch(patch), messageID: messageID)
    }

    func loadUnknownPollResults(_ message: Message) async {
        let current = retainedMessage(channelID: message.channelID, messageID: message.id) ?? message
        guard pollResultRefreshJournals[message.id] == nil else { return }
        if let poll = current.poll, poll.results != nil {
            var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
            update.pollUpdates = [.snapshot(poll, preservingSelection: false)]
            consumeImmediately(.messagePatched(update))
            return
        }
        let session = accountSession()
        conversationRefreshJournalRevision &+= 1
        let revision = conversationRefreshJournalRevision
        pollResultRefreshJournals[message.id] = ConversationRefreshJournal(revision: revision)
        defer {
            if isCurrentAccountSession(session), pollResultRefreshJournals[message.id]?.revision == revision {
                pollResultRefreshJournals[message.id] = nil
            }
        }
        do {
            for attempt in 0 ..< 2 {
                let page = try await session.provider.messages(in: message.channelID, anchoredAt: .around(message.id), limit: 1)
                guard !Task.isCancelled, isCurrentAccountSession(session),
                      let journal = pollResultRefreshJournals[message.id], journal.revision == revision,
                      let fetched = page.messages.first(where: { $0.id == message.id }) else { return }
                let mutations = ConversationRefreshMutations(messages: journal.mutationsByMessageID, updatedUsers: journal.updatedUsers)
                guard let poll = Self.applyingConversationRefreshMutations(mutations, to: [fetched]).first?.poll else { return }
                if poll.results == nil, fetched.poll?.results != nil {
                    guard attempt == 0 else {
                        errorMessage = "Poll results changed while loading. Try again."
                        return
                    }
                    pollResultRefreshJournals[message.id] = ConversationRefreshJournal(revision: revision)
                    continue
                }
                var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
                update.pollUpdates = [.snapshot(poll, preservingSelection: false)]
                consumeImmediately(.messagePatched(update))
                return
            }
        } catch {
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
