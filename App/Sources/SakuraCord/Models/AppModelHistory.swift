import DiscordProtocol
import Foundation
import SakuraCordModels
import SakuraCordPersistence

enum ConversationRefreshMutation {
    case upsert(Message)
    case patch(MessageUpdate)
    case delete
}

struct ConversationRefreshMutations {
    var messages: [MessageID: ConversationRefreshMutation] = [:]
    var updatedUsers: [UserID: User] = [:]
}

struct ConversationRefreshJournal {
    let revision: UInt64
    var mutationsByMessageID: [MessageID: ConversationRefreshMutation] = [:]
    var updatedUsers: [UserID: User] = [:]

    mutating func record(_ mutation: ConversationRefreshMutation, messageID: MessageID) {
        if case .patch(let update) = mutation {
            switch mutationsByMessageID[messageID] {
            case .upsert(var message):
                update.apply(to: &message)
                mutationsByMessageID[messageID] = .upsert(message)
            case .patch(var previous):
                previous.merge(update)
                mutationsByMessageID[messageID] = .patch(previous)
            case .delete:
                break
            case nil:
                mutationsByMessageID[messageID] = mutation
            }
        } else {
            mutationsByMessageID[messageID] = mutation
        }
    }

    mutating func recordIdentityUpdate(_ user: User) {
        updatedUsers[user.id] = user
        // Fold the event into earlier mutations, including messages whose
        // history page has not been published in any retained projection yet.
        for (messageID, mutation) in mutationsByMessageID {
            switch mutation {
            case .upsert(var message):
                message.applyIdentityUpdate(user)
                mutationsByMessageID[messageID] = .upsert(message)
            case .patch(var patch):
                var identity = MessageUpdate(messageID: messageID, channelID: patch.channelID)
                identity.updatedUsers[user.id] = user
                patch.merge(identity)
                mutationsByMessageID[messageID] = .patch(patch)
            case .delete:
                break
            }
        }
    }
}

extension AppModel {
    func beginSelectedChannelLoad() {
        let cacheSignpost = AppPerformanceSignposts.signposter.beginInterval(
            "ConversationCachePresentation"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "ConversationCachePresentation",
                cacheSignpost
            )
        }
        channelLoadTask?.cancel()
        channelLoadGeneration &+= 1
        let generation = channelLoadGeneration
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
        isLoadingEarlier = false
        isLoadingLater = false
        hasMoreLaterMessages = false
        hasCompletedInitialMessageLoad = false
        stopLocalTyping(clearThrottle: true)
        replyingTo = nil
        // A cached conversation still needs its own draft restored.
        draft = ""

        guard let channelID = selectedChannelID,
              selectedChannel?.kind != .voice || isVoiceChatOpen,
              selectedConversationAccess.isReadable
        else {
            replaceSelectedMessages(with: [])
            hasMoreMessages = false
            hasMoreLaterMessages = false
            isLoadingMessages = false
            hasCompletedInitialMessageLoad = true
            return
        }

        let cachedMessages = takeCachedMessages(for: channelID)
        let cachedRows = takeCachedMessageRows(for: channelID)
        restoreSelectedMessages(
            cachedMessages,
            preparedRows: cachedRows
        )
        let cachedBoundary = hasMoreCache[channelID]
        hasMoreMessages = cachedBoundary ?? false
        hasMoreLaterMessages = false
        if cachedBoundary != nil {
            isLoadingMessages = false
            hasCompletedInitialMessageLoad = true
            readState.observeLoadedMessages(channelID: channelID, messages: messages)
            preserveUnreadDividerIfNeeded(channelID: channelID)
            reportConversationHistoryLoaded(channelID: channelID)
            let account = accountSession()
            let draftRevision = composer.draftRevision
            channelLoadTask = startAccountChildTask(account: account) { model, account in
                let savedDraft = await model.storedDraft(in: channelID, account: account)
                guard model.isCurrentAccountSession(account),
                      model.isCurrentLoad(channelID, generation: generation)
                else { return }
                model.composer.restoreDraft(savedDraft, ifUnchangedSince: draftRevision)
            }
            reconcileCachedConversationTailIfNeeded(
                channelID: channelID,
                generation: generation,
                account: account
            )
            return
        }
        isLoadingMessages = true
        preserveUnreadDividerIfNeeded(channelID: channelID)
        let account = accountSession()
        channelLoadTask = startAccountChildTask(account: account) { model, account in
            await model.loadSelectedChannel(
                channelID,
                generation: generation,
                account: account
            )
        }
    }

    /// Re-reads only the newest page of a conversation whose cached tail may
    /// be missing messages that arrived while it was not selected. The cached
    /// rows are already on screen; this reconciles the tail into them instead
    /// of replacing the conversation.
    private func reconcileCachedConversationTailIfNeeded(
        channelID: ChannelID,
        generation: Int,
        account: AppModelAccountSession
    ) {
        // The refresh itself owns the marker: it clears it on success and
        // restores it on failure or cancellation, so a user who leaves before
        // the read finishes still gets the tail reconciled on the next return.
        guard staleCachedTailChannelIDs.contains(channelID) else { return }
        // A read still in flight from a previous visit was already cancelled
        // by `beginSelectedChannelLoad`, and the generation guard below
        // discards any late result, so fast A→B→A navigation does not fetch
        // the same newest page twice.
        channelLoadTask = startAccountChildTask(account: account) { model, account in
            guard model.isCurrentAccountSession(account),
                  model.isCurrentLoad(channelID, generation: generation)
            else { return }
            await model.reconcileCachedConversationTail(
                channelID: channelID,
                account: account
            )
        }
    }

    /// Re-reads the newest page of a cached conversation and reconciles it
    /// into the rows already on screen. Unlike `loadNewestMessageWindow` this
    /// never moves the viewport: it corrects the data behind an already
    /// established position instead of jumping to the newest message.
    @discardableResult
    func reconcileCachedConversationTail(
        channelID: ChannelID,
        account: AppModelAccountSession
    ) async -> Bool {
        guard !Task.isCancelled,
              isCurrentAccountSession(account),
              selectedChannelID == channelID
        else {
            markStaleCachedTail(channelID)
            return false
        }
        // Record Gateway changes that arrive during the read so the page can
        // be reconciled against them instead of overwriting them, exactly as
        // the cold load does.
        let refreshRevision = beginConversationRefresh(in: channelID)
        defer {
            endConversationRefresh(in: channelID, revision: refreshRevision)
        }
        isLoadingMessages = true
        defer {
            if isCurrentAccountSession(account), selectedChannelID == channelID {
                isLoadingMessages = false
            }
        }
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
        do {
            let page = try await account.provider.messages(
                in: channelID,
                anchoredAt: .newest,
                limit: 50
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(account),
                  selectedChannelID == channelID
            else {
                markStaleCachedTail(channelID)
                return false
            }
            // An empty newest page must not blank a window the user is reading.
            // Treat it as a failed refresh and keep the cached rows so a later
            // return, or the next Gateway event, can correct them.
            guard !page.messages.isEmpty else {
                markStaleCachedTail(channelID)
                return false
            }
            // Gateway events that arrive during the read are applied to the
            // selected window directly AND recorded in the refresh journal.
            // Apply the journal to the fresh page before merging, exactly as
            // the cold load does: the page is authoritative for its range, so
            // a live arrival the page already contains must not be dropped,
            // and one it predates must survive the merge below.
            let refreshMutations = conversationRefreshMutations(
                in: channelID,
                revision: refreshRevision
            )
            let tailPage = Self.refreshedTailPage(page: page, mutations: refreshMutations)
            // The cached window's oldest row and its earlier-history boundary
            // belong together. The merge below can keep those oldest rows
            // while the page still reports more history before it; adopting
            // the page's flag then would send one wasted fetch before messages
            // already held.
            let cachedOldestID = messages.first?.id
            hasMoreLaterMessages = false
            // Returning to a quiet conversation is the common case. The fresh
            // page covers the tail of the cached window, including any edits or
            // deletions inside that range, so skip the merge and the full row
            // invalidation its commit would publish when the window already
            // matches. Its earlier-history boundary then stays as restored.
            guard !Self.tailWindowMatches(fresh: tailPage.fresh, window: messages) else {
                clearStaleCachedTail(channelID)
                return true
            }
            let tailMerge = Self.mergingCachedTail(
                window: messages,
                cachedOldestID: cachedOldestID,
                fresh: tailPage.fresh,
                pageOldestID: tailPage.pageOldestID,
                liveUpsertIDs: tailPage.liveUpsertIDs,
                pageHasMoreBefore: page.hasMoreBefore
            )
            if tailMerge.keepsCachedOldest {
                // The merge kept the cached window's oldest rows, so its
                // earlier-history boundary is still the restored one.
            } else {
                hasMoreMessages = page.hasMoreBefore
                hasMoreCache[channelID] = page.hasMoreBefore
            }
            if tailMerge.merged != messages {
                replaceSelectedMessages(with: tailMerge.merged)
            }
            // The window changed, so the read state and the unread divider that
            // positions inside it must be recomputed, exactly as the cold load
            // does after committing its page. Deliberately not
            // `reportConversationHistoryLoaded`: it schedules an
            // acknowledgement and would reuse a read boundary established
            // against the previous window, marking unread messages the user
            // has not seen as read.
            readState.observeLoadedMessages(channelID: channelID, messages: messages)
            preserveUnreadDividerIfNeeded(channelID: channelID)
            clearStaleCachedTail(channelID)
            return true
        } catch is CancellationError {
            markStaleCachedTail(channelID)
            return false
        } catch {
            guard isCurrentAccountSession(account),
                  selectedChannelID == channelID
            else {
                markStaleCachedTail(channelID)
                return false
            }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            messageLoadError = error.localizedDescription
            markStaleCachedTail(channelID)
            return false
        }
    }

    private func markStaleCachedTail(_ channelID: ChannelID) {
        staleCachedTailChannelIDs.insert(channelID)
    }

    private func clearStaleCachedTail(_ channelID: ChannelID) {
        staleCachedTailChannelIDs.remove(channelID)
    }

    func refreshSelectedChannelPreservingHistory() {
        guard let channelID = selectedChannelID,
              selectedChannel?.kind != .voice || isVoiceChatOpen,
              selectedConversationAccess.isReadable
        else { return }

        channelLoadTask?.cancel()
        channelLoadGeneration &+= 1
        let generation = channelLoadGeneration
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
        isLoadingEarlier = false
        isLoadingLater = false
        let preservesLoadedHistory = !messages.isEmpty
            && messages.allSatisfy { $0.channelID == channelID }
        isLoadingMessages = !preservesLoadedHistory
        hasCompletedInitialMessageLoad = preservesLoadedHistory

        let account = accountSession()
        channelLoadTask = startAccountChildTask(account: account) { model, account in
            await model.loadSelectedChannel(
                channelID,
                generation: generation,
                account: account
            )
        }
    }

    func loadSelectedChannel(
        _ channelID: ChannelID,
        generation: Int,
        account: AppModelAccountSession
    ) async {
        guard isCurrentAccountSession(account),
              isCurrentLoad(channelID, generation: generation)
        else { return }
        let loadSignpost = AppPerformanceSignposts.signposter.beginInterval(
            "ConversationLoad"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "ConversationLoad",
                loadSignpost
            )
        }
        let refreshRevision = beginConversationRefresh(in: channelID)
        defer {
            endConversationRefresh(
                in: channelID,
                revision: refreshRevision
            )
        }
        let draftRevision = composer.draftRevision
        async let storedDraft = AppPerformanceSignposts.measure(
            "ConversationDraftLoad"
        ) {
            await storedDraft(in: channelID, account: account)
        }
        // Discord lets already-dispatched history reads finish when the user
        // switches channels. Besides retaining the response in MessageStore,
        // this also lets UserStore learn authors for account-wide picker
        // search. Shield the provider read from presentation-task cancellation
        // and discard only its stale UI result below. This avoids repeatedly
        // cancelling URLSession HTTP/3 streams during fast navigation, which
        // can leave the reused connection stalled on macOS.
        let freshPageTask = initialHistoryPageTask(
            channelID: channelID,
            account: account
        )

        let savedDraft = await storedDraft
        guard isCurrentAccountSession(account),
              isCurrentLoad(channelID, generation: generation)
        else { return }
        composer.restoreDraft(savedDraft, ifUnchangedSince: draftRevision)

        do {
            let page = try await freshPageTask.value
            guard let needsSupplementalMemberResolution =
                await commitInitialHistoryPage(
                    page,
                    channelID: channelID,
                    generation: generation,
                    refreshRevision: refreshRevision,
                    account: account
                )
            else { return }
            guard isCurrentAccountSession(account),
                  isCurrentLoad(channelID, generation: generation)
            else { return }
            try await AppPerformanceSignposts.measure(
                "ConversationFinalize"
            ) {
                try await finishSelectedChannelLoad(
                    channelID: channelID,
                    freshMessages: page.messages,
                    refreshRevision: refreshRevision,
                    hasMoreBefore: page.hasMoreBefore,
                    session: account
                )
            }
            if needsSupplementalMemberResolution {
                startAccountChildTask(account: account) { model, account in
                    await AppPerformanceSignposts.measure(
                        "ConversationMemberResolution"
                    ) {
                        await model.resolveSelectedHistoryMembers(
                            channelID: channelID,
                            generation: generation,
                            session: account
                        )
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            handleSelectedChannelLoadFailure(
                error,
                channelID: channelID,
                generation: generation,
                account: account
            )
        }
    }

    private func commitInitialHistoryPage(
        _ page: MessagePage,
        channelID: ChannelID,
        generation: Int,
        refreshRevision: UInt64,
        account: AppModelAccountSession
    ) async -> Bool? {
        guard isCurrentAccountSession(account),
              isCurrentLoad(channelID, generation: generation)
        else { return nil }
        if !page.resolvedMembers.isEmpty {
            let indexed = mergedMemberStore(with: page.resolvedMembers)
            if membersByID != indexed {
                membersByID = indexed
            }
        }
        let initialMutations = conversationRefreshMutations(
            in: channelID,
            revision: refreshRevision
        )
        let initialRefreshedMessages = Self.applyingConversationRefreshMutations(
            initialMutations,
            to: page.messages
        )
        let initialReconciliationCurrent = hasMoreLaterMessages
            ? messages.filter { $0.outboxState != .confirmed }
            : messages
        let initiallyMerged = Self.reconcilingNewestPage(
            current: initialReconciliationCurrent,
            fresh: initialRefreshedMessages,
            hasMoreBefore: page.hasMoreBefore,
            authoritativeOldestMessageID: page.messages.map(\.id).min()
        )
        let preparedRows: [MessageRowPresentation]? =
            if initiallyMerged != messages {
                await AppPerformanceSignposts.measure("ConversationRowPreprocessing") {
                    await prepareTimelineRows(
                        for: initiallyMerged,
                        priority: .userInitiated
                    )
                }
            } else {
                nil
            }
        guard isCurrentAccountSession(account),
              isCurrentLoad(channelID, generation: generation)
        else { return nil }
        AppPerformanceSignposts.measureSync("ConversationInitialCommit") {
            let mutations = conversationRefreshMutations(
                in: channelID,
                revision: refreshRevision
            )
            let refreshedMessages = Self.applyingConversationRefreshMutations(
                mutations,
                to: page.messages
            )
            let reconciliationCurrent = hasMoreLaterMessages
                ? messages.filter { $0.outboxState != .confirmed }
                : messages
            let merged = Self.reconcilingNewestPage(
                current: reconciliationCurrent,
                fresh: refreshedMessages,
                hasMoreBefore: page.hasMoreBefore,
                authoritativeOldestMessageID: page.messages.map(\.id).min()
            )
            if merged != messages {
                replaceSelectedMessages(with: merged, preparedRows: preparedRows)
            }
        }
        reportStartupContentReady(channelID)
        let freshMessageIDs = Set(page.messages.map(\.id))
        return !page.hasCompleteMemberResolution
            || messages.contains { !freshMessageIDs.contains($0.id) }
    }

    func beginBootstrapHistoryPrefetch(
        channelID: ChannelID,
        account: AppModelAccountSession
    ) {
        bootstrapHistoryPrefetch?.task.cancel()
        bootstrapHistoryPrefetch = BootstrapHistoryPrefetch(
            accountGeneration: account.generation,
            accountRevision: account.installedRevision,
            channelID: channelID,
            task: makeHistoryRequestTask(channelID: channelID, account: account)
        )
    }

    private func initialHistoryPageTask(
        channelID: ChannelID,
        account: AppModelAccountSession
    ) -> Task<MessagePage, any Error> {
        if let prefetch = bootstrapHistoryPrefetch,
           prefetch.accountGeneration == account.generation,
           prefetch.accountRevision == account.installedRevision,
           prefetch.channelID == channelID
        {
            bootstrapHistoryPrefetch = nil
            return prefetch.task
        }
        bootstrapHistoryPrefetch?.task.cancel()
        bootstrapHistoryPrefetch = nil
        return makeHistoryRequestTask(channelID: channelID, account: account)
    }

    func makeHistoryRequestTask(
        channelID: ChannelID,
        account: AppModelAccountSession
    ) -> Task<MessagePage, any Error> {
        let provider = account.provider
        return Task.detached(priority: .userInitiated) {
            try await Self.requestInitialHistory(
                provider: provider,
                channelID: channelID
            )
        }
    }

    nonisolated static func requestInitialHistory(
        provider: any ChatProvider,
        channelID: ChannelID
    ) async throws -> MessagePage {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "ConversationHistoryRequest",
            id: AppPerformanceSignposts.signposter.makeSignpostID()
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "ConversationHistoryRequest", interval
            )
        }
        return try await provider.messagesForImmediatePresentation(
            in: channelID,
            anchoredAt: .newest,
            limit: 10
        )
    }

    private func handleSelectedChannelLoadFailure(
        _ error: Error,
        channelID: ChannelID,
        generation: Int,
        account: AppModelAccountSession
    ) {
        guard isCurrentAccountSession(account),
              isCurrentLoad(channelID, generation: generation)
        else { return }
        DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
        messageLoadError = error.localizedDescription
        messageLoadErrorIsEarlierPage = false
        isLoadingMessages = false
        hasCompletedInitialMessageLoad = true
    }

    private func reportStartupContentReady(
        _ channelID: ChannelID,
        acceptsEmpty: Bool = false
    ) {
        guard acceptsEmpty || !messages.isEmpty else { return }
        AppPerformanceSignposts.reportConversationHistoryReady(
            channelID: channelID
        )
        AppPerformanceSignposts.reportStartupConversationHistoryReady(
            channelID: channelID
        )
    }

    func finishSelectedChannelLoad(
        channelID: ChannelID,
        freshMessages: [Message],
        refreshRevision: UInt64,
        hasMoreBefore: Bool,
        session: AppModelAccountSession
    ) async throws {
        guard isCurrentAccountSession(session) else { return }
        let mutations = conversationRefreshMutations(
            in: channelID,
            revision: refreshRevision
        )
        let refreshedMessages = Self.applyingConversationRefreshMutations(
            mutations,
            to: freshMessages
        )
        let reconciliationCurrent = hasMoreLaterMessages
            ? messages.filter { $0.outboxState != .confirmed }
            : messages
        let reconciledMessages = Self.reconcilingNewestPage(
            current: reconciliationCurrent,
            fresh: refreshedMessages,
            hasMoreBefore: hasMoreBefore,
            authoritativeOldestMessageID: freshMessages.map(\.id).min()
        )
        if reconciledMessages != messages {
            replaceSelectedMessages(with: reconciledMessages)
        }
        hasMoreMessages = hasMoreBefore
        hasMoreLaterMessages = false
        hasMoreCache[channelID] = hasMoreBefore
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
        isLoadingMessages = false
        hasCompletedInitialMessageLoad = true
        readState.observeLoadedMessages(channelID: channelID, messages: messages)
        preserveUnreadDividerIfNeeded(channelID: channelID)
        reportConversationHistoryLoaded(channelID: channelID)
    }

    func resolveSelectedHistoryMembers(
        channelID: ChannelID,
        generation: Int,
        session: AppModelAccountSession
    ) async {
        guard let guildID = selectedChannel?.guildID,
              selectedChannel?.id == channelID
        else { return }

        let requested = LocalHistoryMemberResolution.userIDs(
            in: messages,
            known: Set(membersByID.keys)
        )
        guard !requested.isEmpty else { return }

        do {
            let resolved = try await session.provider.resolveMembers(
                in: guildID,
                userIDs: requested
            )
            guard isCurrentAccountSession(session),
                  isCurrentLoad(channelID, generation: generation),
                  !resolved.isEmpty
            else {
                return
            }
            let previousMembersByID = membersByID
            let indexed = mergedMemberStore(with: resolved)
            if membersByID != indexed {
                membersByID = indexed
            }
            let changedUserIDs = TimelineMemberPresentationImpact.changedUserIDs(
                from: previousMembersByID,
                to: indexed,
                guildRoles: guildRoles,
                candidates: TimelineMemberPresentationImpact
                    .referencedUserIDs(in: messages)
            )
            let affectedMessageIDs = TimelineMemberPresentationImpact
                .affectedMessageIDs(
                    in: messages,
                    changedUserIDs: changedUserIDs
                )
            let hydrated = LocalHistoryMemberResolution.hydrating(
                messages,
                with: indexed
            )
            if hydrated != messages {
                applySelectedHistoryMemberHydration(
                    hydrated,
                    presentationMessageIDs: affectedMessageIDs
                )
            } else if !affectedMessageIDs.isEmpty {
                publishMessageRowsUpdate(
                    changedMessageIDs: affectedMessageIDs
                )
            }
            publishTimelineMemberPresentationChanges(
                from: previousMembersByID,
                to: indexed,
                publishesCurrentRows: false
            )
        } catch is CancellationError {
            return
        } catch {
            // Message history remains usable when Discord cannot resolve a
            // member. A later channel load retries unresolved authors.
        }
    }

    @discardableResult
    func loadNewestMessageWindow(account: AppModelAccountSession? = nil) async -> Bool {
        let session = account ?? accountSession()
        guard !Task.isCancelled,
              isCurrentAccountSession(session),
              let channelID = selectedChannelID
        else { return false }
        if !hasMoreLaterMessages {
            requestNewestMessagePresentation(channelID: channelID)
            return true
        }
        isLoadingMessages = true
        defer {
            if isCurrentAccountSession(session), selectedChannelID == channelID {
                isLoadingMessages = false
            }
        }
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
        do {
            let page = try await session.provider.messages(
                in: channelID,
                anchoredAt: .newest,
                limit: 50
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == channelID
            else { return false }
            replaceSelectedMessages(with: page.messages)
            hasMoreMessages = page.hasMoreBefore
            hasMoreLaterMessages = false
            hasMoreCache[channelID] = page.hasMoreBefore
            requestNewestMessagePresentation(channelID: channelID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentAccountSession(session),
                  selectedChannelID == channelID
            else { return false }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            messageLoadError = error.localizedDescription
            return false
        }
    }

    private func requestNewestMessagePresentation(channelID: ChannelID) {
        conversationNewestRequestID &+= 1
        conversationNewestRequest = ConversationNewestRequest(
            requestID: conversationNewestRequestID,
            channelID: channelID
        )
    }

    func retryMessageLoad() {
        guard selectedChannelID != nil else { return }
        if messageLoadErrorIsLaterPage {
            messageLoadError = nil
            messageLoadErrorIsLaterPage = false
            let account = accountSession()
            startAccountChildTask(account: account) { model, account in
                await model.loadLater(account: account)
            }
            return
        }
        if messageLoadErrorIsEarlierPage {
            messageLoadError = nil
            messageLoadErrorIsEarlierPage = false
            let account = accountSession()
            startAccountChildTask(account: account) { model, account in
                await model.loadEarlier(account: account)
            }
            return
        }
        beginSelectedChannelLoad()
    }

    func beginConversationRefresh(in channelID: ChannelID) -> UInt64 {
        conversationRefreshJournalRevision &+= 1
        let revision = conversationRefreshJournalRevision
        conversationRefreshJournals[channelID] = ConversationRefreshJournal(
            revision: revision
        )
        return revision
    }

    func recordConversationRefreshMutation(
        _ mutation: ConversationRefreshMutation,
        messageID: MessageID,
        channelID: ChannelID
    ) {
        var mutation = mutation
        if case .patch(var update) = mutation, !update.pollUpdates.isEmpty,
           var message = retainedMessage(channelID: channelID, messageID: messageID), message.poll?.results != nil {
            // Preserve an established local tally instead of adding the same
            // vote again if a fetched page already includes it.
            update.apply(to: &message)
            if let poll = pollVoteConfirmedSnapshot(message).poll {
                update.pollUpdates = [.snapshot(poll, preservingSelection: false)]
                mutation = .patch(update)
            }
        }
        conversationRefreshJournals[channelID]?.record(mutation, messageID: messageID)
        inbox.refreshJournal?.record(mutation, messageID: messageID)
        recordPollRefreshMutation(mutation, messageID: messageID, channelID: channelID)
        for guildID in onboarding.guides.keys where onboarding.guides[guildID]?.resource?.channelID == channelID
            && onboarding.guides[guildID]?.resource?.refreshJournal != nil {
            onboarding.guides[guildID]?.resource?.refreshJournal?.record(mutation, messageID: messageID)
        }
    }

    func conversationRefreshMutations(
        in channelID: ChannelID,
        revision: UInt64
    ) -> ConversationRefreshMutations {
        guard let journal = conversationRefreshJournals[channelID],
              journal.revision == revision
        else { return .init() }
        return ConversationRefreshMutations(messages: journal.mutationsByMessageID, updatedUsers: journal.updatedUsers)
    }

    func endConversationRefresh(
        in channelID: ChannelID,
        revision: UInt64
    ) {
        guard conversationRefreshJournals[channelID]?.revision == revision else {
            return
        }
        conversationRefreshJournals[channelID] = nil
    }

    func cancelConversationRefresh(in channelID: ChannelID) {
        conversationRefreshJournals[channelID] = nil
    }

    @discardableResult
    func journalAuthoritativeMessageUpsert(_ message: Message) -> Message {
        let persistedMessage = pollVoteConfirmedSnapshot(reactionConfirmedSnapshot(message))
        recordConversationRefreshMutation(
            .upsert(persistedMessage),
            messageID: persistedMessage.id,
            channelID: persistedMessage.channelID
        )
        return persistedMessage
    }

    func recordAuthoritativeMessageUpsert(_ message: Message) {
        journalAuthoritativeMessageUpsert(message)
    }

    func dismissError() {
        errorMessage = nil
    }

    func storedDraft(
        in channelID: ChannelID,
        account: AppModelAccountSession
    ) async -> String {
        guard isCurrentAccountSession(account), let database = account.database else { return "" }
        return (try? await composer.storedDraft(in: channelID, database: database)) ?? ""
    }

    func isCurrentLoad(_ channelID: ChannelID, generation: Int) -> Bool {
        !Task.isCancelled && selectedChannelID == channelID && channelLoadGeneration == generation
    }

    static func merging(current: [Message], fresh: [Message]) -> [Message] {
        var byID: [MessageID: Message] = [:]
        var idByNonce: [String: MessageID] = [:]
        for message in current {
            byID[message.id] = message
            if let nonce = message.nonce {
                idByNonce[nonce] = message.id
            }
        }
        for message in fresh {
            var resolved = message
            let matchingID = message.nonce.flatMap { idByNonce[$0] }
            if let existing = byID[message.id] ?? matchingID.flatMap({ byID[$0] }) {
                resolved.guildMember = MessageGuildMember.merging(
                    incoming: resolved.guildMember,
                    existing: existing.guildMember
                )
                resolved.replyTo = resolved.replyTo ?? existing.replyTo
                resolved.replyPreview = resolved.replyPreview ?? existing.replyPreview
            }
            if let matchingID, matchingID != resolved.id {
                byID[matchingID] = nil
            }
            byID[resolved.id] = resolved
            if let nonce = resolved.nonce {
                idByNonce[nonce] = resolved.id
            }
        }
        return byID.values.sorted(by: messagePrecedes)
    }

    static func reconcilingNewestPage(
        current: [Message],
        fresh: [Message],
        hasMoreBefore: Bool,
        authoritativeOldestMessageID: MessageID? = nil
    ) -> [Message] {
        let oldestFreshID = authoritativeOldestMessageID ?? fresh.map(\.id).min()
        let retainedCurrent = current.filter { message in
            guard message.outboxState == .confirmed else { return true }
            guard hasMoreBefore, let oldestFreshID else { return false }
            return message.id < oldestFreshID
        }
        return merging(current: retainedCurrent, fresh: fresh)
    }

    static func applyingConversationRefreshMutations(
        _ mutations: ConversationRefreshMutations,
        to messages: [Message]
    ) -> [Message] {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        // Message mutations already contain identity events that followed them.
        // Apply the conversation-wide fallback first so it cannot overwrite
        // explicit message identity fields received later.
        for messageID in byID.keys {
            for user in mutations.updatedUsers.values { byID[messageID]?.applyIdentityUpdate(user) }
        }
        for (messageID, mutation) in mutations.messages {
            switch mutation {
            case .upsert(let message):
                byID[messageID] = message
            case .patch(let update):
                if var message = byID[messageID] {
                    update.applyForRefresh(to: &message)
                    byID[messageID] = message
                }
            case .delete:
                byID[messageID] = nil
            }
        }
        return byID.values.sorted(by: messagePrecedes)
    }

    private struct TailRefreshPage {
        let fresh: [Message]
        let pageOldestID: MessageID?
        let liveUpsertIDs: Set<MessageID>
    }

    /// Applies a refresh journal to a fetched newest page and derives the
    /// merge inputs from the page's own span: journal rows can widen the
    /// result beyond what the fetch covered, but only journal upserts newer
    /// than the fetched page count as live arrivals. An older cached row the
    /// page omits was deleted while its event was missed, and the page is
    /// authoritative evidence of that.
    private static func refreshedTailPage(
        page: MessagePage,
        mutations: ConversationRefreshMutations
    ) -> TailRefreshPage {
        let fresh = applyingConversationRefreshMutations(mutations, to: page.messages)
        let pageMaxID = page.messages.map(\.id).max()
        var liveUpsertIDs = Set<MessageID>()
        if let pageMaxID {
            for (messageID, mutation) in mutations.messages {
                if case .upsert = mutation, messageID > pageMaxID {
                    liveUpsertIDs.insert(messageID)
                }
            }
        }
        return TailRefreshPage(
            fresh: fresh,
            pageOldestID: page.messages.first?.id,
            liveUpsertIDs: liveUpsertIDs
        )
    }

    /// Matches a cached window against a refreshed newest page for the common
    /// quiet return, where the window needs no replacement at all.
    private static func tailWindowMatches(fresh: [Message], window: [Message]) -> Bool {
        let coveredCount = min(fresh.count, window.count)
        return window.suffix(coveredCount).elementsEqual(fresh)
    }

    /// Merges a fresh newest page into a cached window for the tail-refresh
    /// path. `pageOldestID` bounds the range the fetch actually covered:
    /// journal rows applied to `fresh` outside that range still merge by ID,
    /// but must not widen what the merge treats as replaced. Returns the
    /// merged window and whether it still starts at the cached window's
    /// oldest row, which decides if the restored earlier-history boundary
    /// survives or the page's replaces it.
    static func mergingCachedTail(
        window: [Message],
        cachedOldestID: MessageID?,
        fresh: [Message],
        pageOldestID: MessageID?,
        liveUpsertIDs: Set<MessageID>,
        pageHasMoreBefore: Bool
    ) -> (merged: [Message], keepsCachedOldest: Bool) {
        var current = window
        if let windowNewest = window.last?.id,
           let pageOldest = pageOldestID,
           pageOldest > windowNewest
        {
            // The page starts strictly newer than the window ends, so joining
            // them would splice two non-adjacent runs and leave a hole that
            // normal scrolling cannot cross. The window is incomplete, so take
            // the page and let the user scroll back up.
            current = window.filter { $0.outboxState != .confirmed }
        }
        var merged = reconcilingNewestPage(
            current: current,
            fresh: fresh,
            hasMoreBefore: pageHasMoreBefore,
            authoritativeOldestMessageID: pageOldestID
        )
        // Only rows that actually arrived during the refresh survive beyond
        // the fetched page: a cached row above the page's newest ID that the
        // journal did not upsert was deleted while its event was missed, and
        // the page is authoritative evidence of that.
        if !liveUpsertIDs.isEmpty {
            let keptNewer = window.filter { liveUpsertIDs.contains($0.id) }
            if !keptNewer.isEmpty {
                merged = merging(current: merged, fresh: keptNewer)
            }
        }
        let keepsCachedOldest = cachedOldestID.map { merged.first?.id == $0 } ?? false
        return (merged, keepsCachedOldest)
    }

}
