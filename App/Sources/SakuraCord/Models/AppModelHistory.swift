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

/// A journal for one in-flight history request, so overlapping requests in
/// the same conversation each reconcile the mutations made during their own
/// flight.
struct ScopedConversationRefreshJournal {
    let channelID: ChannelID
    var journal: ConversationRefreshJournal
}

/// The message IDs a fetched page vouches for. A message journaled outside
/// them belongs to history the page does not cover, such as a live reply
/// beyond an older window; inserting it would join the page to it across
/// unloaded history.
struct MessageHistorySpan {
    /// Inclusive bounds; nil leaves that side open.
    var lowerBound: MessageID?
    var upperBound: MessageID?

    static let unbounded = MessageHistorySpan()

    init(lowerBound: MessageID? = nil, upperBound: MessageID? = nil) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// A page's span. An edge without more history is open; an edge the
    /// request continued from is bounded by its anchor.
    ///
    /// - Parameter closesNewerEdge: The page cannot vouch for the live tail,
    ///   as when it was read before a Gateway gap, so its newer edge ends at
    ///   what it fetched.
    init(
        page: MessagePage,
        continuingAfter lowerAnchor: MessageID? = nil,
        continuingBefore upperAnchor: MessageID? = nil,
        closesNewerEdge: Bool = false
    ) {
        let ids = page.messages.map(\.id)
        lowerBound = page.hasMoreBefore ? ids.min() ?? lowerAnchor : lowerAnchor
        upperBound = page.hasMoreAfter || closesNewerEdge
            ? ids.max() ?? upperAnchor ?? lowerAnchor ?? MessageID(rawValue: 0)
            : upperAnchor
    }

    func contains(_ messageID: MessageID) -> Bool {
        (lowerBound.map { messageID >= $0 } ?? true) && (upperBound.map { messageID <= $0 } ?? true)
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
            to: page.messages,
            within: MessageHistorySpan(page: page)
        )
        let initialReconciliationCurrent = hasMoreLaterMessages
            ? messages.filter { $0.outboxState != .confirmed }
            : messages
        let initiallyMerged = Self.reconcilingNewestPage(
            current: initialReconciliationCurrent,
            fresh: initialRefreshedMessages,
            hasMoreBefore: page.hasMoreBefore,
            authoritativeOldestMessageID: page.messages.map(\.id).min(),
            contiguousThrough: contiguousHistoryBoundaries[channelID]
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
                to: page.messages,
                within: MessageHistorySpan(page: page)
            )
            let reconciliationCurrent = hasMoreLaterMessages
                ? messages.filter { $0.outboxState != .confirmed }
                : messages
            let merged = Self.reconcilingNewestPage(
                current: reconciliationCurrent,
                fresh: refreshedMessages,
                hasMoreBefore: page.hasMoreBefore,
                authoritativeOldestMessageID: page.messages.map(\.id).min(),
                contiguousThrough: contiguousHistoryBoundaries[channelID]
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
            to: freshMessages,
            within: MessageHistorySpan(lowerBound: hasMoreBefore ? freshMessages.map(\.id).min() : nil)
        )
        let reconciliationCurrent = hasMoreLaterMessages
            ? messages.filter { $0.outboxState != .confirmed }
            : messages
        let reconciledMessages = Self.reconcilingNewestPage(
            current: reconciliationCurrent,
            fresh: refreshedMessages,
            hasMoreBefore: hasMoreBefore,
            authoritativeOldestMessageID: freshMessages.map(\.id).min(),
            contiguousThrough: contiguousHistoryBoundaries[channelID]
        )
        if reconciledMessages != messages {
            replaceSelectedMessages(with: reconciledMessages)
        }
        hasMoreMessages = hasMoreBefore
        hasMoreLaterMessages = false
        hasMoreCache[channelID] = hasMoreBefore
        contiguousHistoryBoundaries[channelID] = nil
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
            contiguousHistoryBoundaries[channelID] = nil
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

    func requestNewestMessagePresentation(channelID: ChannelID) {
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
        for revision in scopedRefreshJournals.keys where scopedRefreshJournals[revision]?.channelID == channelID {
            scopedRefreshJournals[revision]?.journal.record(mutation, messageID: messageID)
        }
        inbox.refreshJournal?.record(mutation, messageID: messageID)
        recordPollRefreshMutation(mutation, messageID: messageID, channelID: channelID)
        if guideResource?.channelID == channelID {
            guideResource?.refreshJournal?.record(mutation, messageID: messageID)
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
        scopedRefreshJournals = scopedRefreshJournals.filter { $0.value.channelID != channelID }
    }

    func beginScopedConversationRefresh(in channelID: ChannelID) -> UInt64 {
        conversationRefreshJournalRevision &+= 1
        let revision = conversationRefreshJournalRevision
        scopedRefreshJournals[revision] = ScopedConversationRefreshJournal(
            channelID: channelID,
            journal: ConversationRefreshJournal(revision: revision)
        )
        return revision
    }

    func scopedConversationRefreshMutations(_ revision: UInt64) -> ConversationRefreshMutations {
        guard let journal = scopedRefreshJournals[revision]?.journal else { return .init() }
        return ConversationRefreshMutations(messages: journal.mutationsByMessageID, updatedUsers: journal.updatedUsers)
    }

    func endScopedConversationRefresh(_ revision: UInt64) {
        scopedRefreshJournals[revision] = nil
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

    /// Records that messages retained for `channelID` after this point may
    /// follow a gap. An earlier, more conservative boundary is kept.
    func markHistoryContiguous(through messages: [Message]?, in channelID: ChannelID) {
        let newest = messages?.lazy.filter { $0.outboxState == .confirmed }.map(\.id).max()
            ?? MessageID(rawValue: 0)
        contiguousHistoryBoundaries[channelID] = min(contiguousHistoryBoundaries[channelID] ?? newest, newest)
    }

    /// A Gateway gap can drop live messages. Retained windows stay usable,
    /// but only up to their current newest message.
    func markHistoryGapForRetainedConversations() {
        historyEpoch &+= 1
        if let selectedChannelID { markHistoryContiguous(through: messages, in: selectedChannelID) }
        if let threadID = openThread?.id {
            markHistoryContiguous(through: threadMessages, in: threadID)
            // Live replies may have been missed; the window's newest edge
            // is unverified until a read in the new connection.
            threadWindow.isNewestUnverified = true
        }
        for (channelID, cached) in messageCache {
            markHistoryContiguous(through: cached, in: channelID)
        }
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

    /// Merges a newest page into a contiguous loaded window. Older confirmed
    /// messages are retained only when the page reaches the window, so two
    /// disjoint blocks are never joined across unloaded history.
    ///
    /// - Parameter contiguousThrough: The newest current message known to
    ///   connect to the older ones. Defaults to the newest confirmed message;
    ///   pass a recorded boundary when later messages arrived after a gap.
    static func reconcilingNewestPage(
        current: [Message],
        fresh: [Message],
        hasMoreBefore: Bool,
        authoritativeOldestMessageID: MessageID? = nil,
        contiguousThrough: MessageID? = nil
    ) -> [Message] {
        let oldestFreshID = authoritativeOldestMessageID ?? fresh.map(\.id).min()
        let newestContiguousID = contiguousThrough
            ?? current.lazy.filter { $0.outboxState == .confirmed }.map(\.id).max()
        let reachesCurrent = if let oldestFreshID, let newestContiguousID {
            oldestFreshID <= newestContiguousID
        } else {
            false
        }
        let retainedCurrent = current.filter { message in
            guard message.outboxState == .confirmed else { return true }
            guard hasMoreBefore, reachesCurrent, let oldestFreshID else { return false }
            return message.id < oldestFreshID
        }
        return merging(current: retainedCurrent, fresh: fresh)
    }

    /// - Parameter span: Journaled messages missing from `messages` are
    ///   added only inside it.
    static func applyingConversationRefreshMutations(
        _ mutations: ConversationRefreshMutations,
        to messages: [Message],
        within span: MessageHistorySpan = .unbounded
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
                guard byID[messageID] != nil || span.contains(messageID) else { continue }
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

}
