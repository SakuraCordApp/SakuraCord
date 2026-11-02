import DiscordProtocol
import Foundation
import SakuraCordModels

/// A request that replaces the open thread's whole history window: an
/// initial load, a jump to a message, a return to the newest messages or a
/// reconnect revalidation.
struct ThreadWindowRequest {
    let threadID: ChannelID
    /// The open thread instance.
    let generation: Int
    /// The latest replacement intent wins; an earlier one cannot publish.
    let windowRevision: Int
    /// A response that began before a Gateway gap cannot vouch for history
    /// up to the newest message.
    let historyEpoch: Int
}

/// Who may replace the open thread's whole history window.
struct ThreadWindowOwnership {
    /// Advanced by every request that replaces the whole window.
    var revision = 0
    /// The whole-window request in flight, if any.
    var activeRevision: Int?
    /// A reconnect found a thread request in flight; revalidate once it ends.
    var revalidationPending = false
    /// The window's newest edge awaits a current read, after a Gateway gap
    /// or when a cached window reopens. Until then it is treated as detached
    /// from the newest message for admission, sending and acknowledgement.
    var isNewestUnverified = false
    /// The target of a jump whose first window failed to load, for Retry.
    var failedInitialTarget: MessageID?
    /// A jump target that lands on the message before it when absent, which
    /// Retry keeps doing.
    var nearestJumpTarget: MessageID?
    /// The target of the initial load in flight when it reads around a
    /// message rather than the newest messages.
    var initialLoadTarget: MessageID?
    /// The window revision of the newest read that set `isLoadingThread`;
    /// only that read may clear it.
    var newestReadRevision: Int?
    /// The oldest and newest messages REST returned for the window. Earlier
    /// and later pages continue from these, never from whatever messages
    /// the window shows, and nothing is inserted beyond a cursor while more
    /// history lies past it.
    var lowerCursor: MessageID?
    var upperCursor: MessageID?
    /// The cursors of cached thread windows, restored when they reopen.
    var cachedCursors: [ChannelID: (lower: MessageID?, upper: MessageID?)] = [:]
}

/// Thread history is one contiguous window. A newest-backed window follows
/// live messages and may be cached; a window opened around an older message
/// pages in both directions until it reaches the newest message again.
extension AppModel {
    /// The window may not reach the newest message: it was opened around an
    /// older one, or its newest edge awaits revalidation.
    var isThreadWindowAwayFromNewest: Bool {
        hasMoreLaterThreadMessages || threadWindow.isNewestUnverified
    }

    /// An initial load around an older message is in flight; a later intent
    /// for the newest messages takes it over.
    var isLoadingInitialThreadJump: Bool {
        isLoadingThread && threadWindow.initialLoadTarget != nil
    }

    /// The open thread's messages that are loaded history. Until the first
    /// read completes, a forum post's preview of its first message is not;
    /// anything else, such as a reply sent meanwhile, is.
    var loadedThreadHistoryCount: Int {
        hasCompletedInitialThreadLoad || isLoadingInitialThreadJump
            ? threadMessages.count
            : threadMessages.count { $0.id != openThreadStarterMessageID }
    }

    func beginThreadWindowRequest(_ threadID: ChannelID) -> ThreadWindowRequest {
        threadWindow.revision &+= 1
        threadWindow.activeRevision = threadWindow.revision
        // A newer window intent supersedes a failed jump.
        threadWindow.failedInitialTarget = nil
        return ThreadWindowRequest(
            threadID: threadID,
            generation: threadLoadGeneration,
            windowRevision: threadWindow.revision,
            historyEpoch: historyEpoch
        )
    }

    /// The request may still publish the whole window.
    func isCurrentThreadWindow(_ request: ThreadWindowRequest) -> Bool {
        isCurrentThreadLoad(request.threadID, generation: request.generation)
            && threadWindow.revision == request.windowRevision
    }

    /// Ends a whole-window request and runs a revalidation a reconnect
    /// deferred while it was in flight.
    func endThreadWindowRequest(_ request: ThreadWindowRequest) {
        guard threadWindow.activeRevision == request.windowRevision else { return }
        threadWindow.activeRevision = nil
        resumePendingThreadRevalidation()
    }

    /// The load still belongs to the open thread instance. Its loading
    /// state is cleared even when its task was cancelled.
    func ownsThreadLoad(_ threadID: ChannelID, generation: Int) -> Bool {
        openThread?.id == threadID && threadLoadGeneration == generation
    }

    /// The load may still publish its result.
    func isCurrentThreadLoad(_ threadID: ChannelID, generation: Int) -> Bool {
        !Task.isCancelled && ownsThreadLoad(threadID, generation: generation)
    }

    /// Reads thread history. Discord omits the guild from history messages,
    /// and the provider cannot add it for a thread it has not cached, so the
    /// open thread supplies it for presentation that differs in servers.
    func threadHistoryPage(
        _ provider: any ChatProvider,
        in threadID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage {
        var page = try await provider.messages(in: threadID, anchoredAt: anchor, limit: limit)
        page.messages = page.messages.map(withOpenThreadGuild)
        return page
    }

    /// Replays journaled live changes onto a thread page. A journaled copy
    /// may lack the guild the page received, so the result receives it too.
    func applyingThreadRefreshMutations(
        _ mutations: ConversationRefreshMutations,
        to messages: [Message],
        within span: MessageHistorySpan
    ) -> [Message] {
        Self.applyingConversationRefreshMutations(mutations, to: messages, within: span).map(withOpenThreadGuild)
    }

    /// Supplies the open thread's guild to a message of it that omits one,
    /// so history and live copies of a message present and compare alike.
    func withOpenThreadGuild(_ message: Message) -> Message {
        guard message.guildID == nil, message.channelID == openThread?.id,
              let guildID = openThread?.guildID ?? openThreadParentChannel?.guildID
        else { return message }
        var message = message
        message.guildID = guildID
        return message
    }

    /// Loads the open thread's first window: the newest page, or the page
    /// around `target`. With `preservingWindow`, the loaded window stays
    /// visible while its newest page is revalidated in the background.
    func beginInitialThreadLoad(
        _ thread: MessageThreadSummary,
        around target: MessageID? = nil,
        preservingWindow: Bool = false
    ) {
        threadLoadTask?.cancel()
        threadErrorMessage = nil
        threadErrorScope = nil
        let request = beginThreadWindowRequest(thread.id)
        threadWindow.initialLoadTarget = preservingWindow ? nil : target
        if preservingWindow, target == nil {
            threadWindow.isNewestUnverified = true
            isLoadingThread = false
            hasCompletedInitialThreadLoad = true
            readState.observeLoadedMessages(channelID: thread.id, messages: threadMessages)
            reportConversationHistoryLoaded(channelID: thread.id)
        } else {
            isLoadingThread = true
            threadWindow.newestReadRevision = nil
            hasCompletedInitialThreadLoad = false
        }
        let account = accountSession()
        threadLoadTask = startAccountChildTask(account: account) { model, account in
            let refreshRevision = model.beginConversationRefresh(in: thread.id)
            defer {
                model.endConversationRefresh(in: thread.id, revision: refreshRevision)
                model.endThreadWindowRequest(request)
            }
            let loadSignpost = AppPerformanceSignposts.signposter.beginInterval(
                "ThreadConversationLoad"
            )
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    "ThreadConversationLoad",
                    loadSignpost
                )
            }
            do {
                let page = try await model.threadHistoryPage(
                    account.provider,
                    in: thread.id,
                    anchoredAt: target.map(MessageHistoryAnchor.around) ?? .newest,
                    limit: target == nil ? model.initialHistoryFetchLimit : DiscordHistoryFetchLimit.aroundLimit
                )
                try Task.checkCancellation()
                guard model.isCurrentAccountSession(account),
                      model.isCurrentThreadWindow(request)
                else { return }
                if target == nil {
                    model.finishInitialThreadLoad(
                        page,
                        request: request,
                        refreshRevision: refreshRevision
                    )
                } else {
                    model.replaceThreadWindow(
                        with: page,
                        request: request,
                        mutations: model.conversationRefreshMutations(in: thread.id, revision: refreshRevision)
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard model.isCurrentAccountSession(account),
                      model.isCurrentThreadWindow(request)
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.threadErrorMessage = error.localizedDescription
                model.threadErrorScope = .initialPage
                model.threadWindow.failedInitialTarget = target
                model.threadWindow.initialLoadTarget = nil
                model.isLoadingThread = false
                model.hasCompletedInitialThreadLoad = true
            }
        }
    }

    /// Merges a fresh newest page into the window. Older retained messages
    /// stay only when the page reaches them; otherwise the page replaces
    /// the window instead of hiding the gap between them.
    func finishInitialThreadLoad(
        _ page: MessagePage,
        request: ThreadWindowRequest,
        refreshRevision: UInt64
    ) {
        let threadID = request.threadID
        let mutations = conversationRefreshMutations(in: threadID, revision: refreshRevision)
        let refreshedMessages = applyingThreadRefreshMutations(
            mutations,
            to: page.messages,
            within: MessageHistorySpan(page: page, closesNewerEdge: request.historyEpoch != historyEpoch)
        )
        let oldestFreshID = page.messages.map(\.id).min()
        let current = hasMoreLaterThreadMessages
            ? threadMessages.filter { $0.outboxState != .confirmed }
            : threadMessages
        let reconciled = Self.reconcilingNewestPage(
            current: current,
            fresh: refreshedMessages,
            hasMoreBefore: page.hasMoreBefore,
            authoritativeOldestMessageID: oldestFreshID,
            contiguousThrough: contiguousHistoryBoundaries[threadID]
        )
        let keepsOlderHistory = oldestFreshID.map { oldest in
            reconciled.contains { $0.outboxState == .confirmed && $0.id < oldest }
        } ?? false
        threadMessages = reconciled.map(pollVotePresentationPreserving)
        seedSlowmodeHistory(threadMessages)
        if !keepsOlderHistory {
            hasMoreThreadMessages = page.hasMoreBefore
            threadWindow.lowerCursor = oldestFreshID
        }
        threadWindow.upperCursor = page.messages.map(\.id).max() ?? threadWindow.upperCursor
        establishThreadNewestEdge(hasMoreAfter: false, historyEpoch: request.historyEpoch)
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingThread = false
        threadWindow.initialLoadTarget = nil
        hasCompletedInitialThreadLoad = true
        readState.observeLoadedMessages(channelID: threadID, messages: threadMessages)
        reportConversationHistoryLoaded(channelID: threadID)
    }

    /// Presents `page` as the whole window, as distant navigation does.
    func replaceThreadWindow(
        with page: MessagePage,
        request: ThreadWindowRequest,
        mutations: ConversationRefreshMutations
    ) {
        let threadID = request.threadID
        let refreshedMessages = applyingThreadRefreshMutations(
            mutations,
            to: page.messages,
            within: MessageHistorySpan(page: page, closesNewerEdge: request.historyEpoch != historyEpoch)
        )
        threadWindow.lowerCursor = page.messages.map(\.id).min()
        threadWindow.upperCursor = page.messages.map(\.id).max()
        // Unconfirmed sends keep their rows, including failed ones awaiting
        // Retry or Discard, whichever window is presented.
        let pendingSends = threadMessages.filter { $0.outboxState != .confirmed }
        threadMessages = Self.merging(current: pendingSends, fresh: refreshedMessages)
            .map(pollVotePresentationPreserving)
        seedSlowmodeHistory(threadMessages)
        hasMoreThreadMessages = page.hasMoreBefore
        hasMoreCache[threadID] = nil
        establishThreadNewestEdge(hasMoreAfter: page.hasMoreAfter, historyEpoch: request.historyEpoch)
        if hasMoreLaterThreadMessages {
            // The reader no longer sees the newest message; until geometry
            // reports otherwise, nothing may be acknowledged.
            _ = readState.updatePresentation(channelID: threadID, hasReachedReadBoundary: false)
        }
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingThread = false
        threadWindow.initialLoadTarget = nil
        hasCompletedInitialThreadLoad = true
        readState.observeLoadedMessages(channelID: threadID, messages: threadMessages)
        reportConversationHistoryLoaded(channelID: threadID)
    }

    /// Sets the window's later edge. A page that reaches the newest message
    /// makes the window newest-backed and cacheable, unless its request began
    /// before a Gateway gap: messages missed during the outage would then be
    /// hidden, so the window stays open toward newer messages instead.
    func establishThreadNewestEdge(hasMoreAfter: Bool, historyEpoch requestEpoch: Int) {
        guard let threadID = openThread?.id else { return }
        guard !hasMoreAfter, requestEpoch == historyEpoch else {
            hasMoreLaterThreadMessages = true
            hasMoreCache[threadID] = nil
            return
        }
        hasMoreLaterThreadMessages = false
        threadWindow.isNewestUnverified = false
        hasMoreCache[threadID] = hasMoreThreadMessages
        contiguousHistoryBoundaries[threadID] = nil
    }

    /// Replaces the open thread's window with the page around `messageID`.
    /// Returns false when the thread changed or the page failed to load.
    func loadThreadWindow(
        around messageID: MessageID,
        session: AppModelAccountSession
    ) async -> Bool {
        guard let threadID = openThread?.id else { return false }
        let request = beginThreadWindowRequest(threadID)
        let refreshRevision = beginScopedConversationRefresh(in: threadID)
        defer {
            endScopedConversationRefresh(refreshRevision)
            endThreadWindowRequest(request)
        }
        do {
            let page = try await threadHistoryPage(
                session.provider,
                in: threadID,
                anchoredAt: .around(messageID),
                limit: DiscordHistoryFetchLimit.aroundLimit
            )
            guard isCurrentAccountSession(session), isCurrentThreadWindow(request) else { return false }
            replaceThreadWindow(
                with: page,
                request: request,
                mutations: scopedConversationRefreshMutations(refreshRevision)
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentAccountSession(session), isCurrentThreadWindow(request) else { return false }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Returns a detached thread window to the newest message, then scrolls
    /// there.
    @discardableResult
    func loadNewestThreadWindow(account: AppModelAccountSession? = nil) async -> Bool {
        let session = account ?? accountSession()
        guard !Task.isCancelled, isCurrentAccountSession(session),
              let threadID = openThread?.id
        else { return false }
        guard isThreadWindowAwayFromNewest else {
            supersedeThreadWindowRequests()
            requestNewestMessagePresentation(channelID: threadID)
            return true
        }
        guard !isLoadingThread || isLoadingInitialThreadJump else { return false }
        if isLoadingInitialThreadJump {
            // The newest messages are the later intent; the jump's read no
            // longer owns the window or its loading state.
            threadLoadTask?.cancel()
            threadLoadTask = nil
            threadWindow.initialLoadTarget = nil
        }
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingThread = true
        let request = beginThreadWindowRequest(threadID)
        threadWindow.newestReadRevision = request.windowRevision
        let refreshRevision = beginScopedConversationRefresh(in: threadID)
        defer {
            endScopedConversationRefresh(refreshRevision)
            // A later newest read may own the loading state by now.
            if ownsThreadLoad(threadID, generation: request.generation),
               threadWindow.newestReadRevision == request.windowRevision
            {
                isLoadingThread = false
                threadWindow.newestReadRevision = nil
            }
            endThreadWindowRequest(request)
        }
        do {
            let page = try await threadHistoryPage(session.provider, in: threadID, anchoredAt: .newest, limit: initialHistoryFetchLimit)
            guard isCurrentAccountSession(session), isCurrentThreadWindow(request) else { return false }
            replaceThreadWindow(
                with: page,
                request: request,
                mutations: scopedConversationRefreshMutations(refreshRevision)
            )
            requestNewestMessagePresentation(channelID: threadID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentAccountSession(session), isCurrentThreadWindow(request) else { return false }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            threadErrorMessage = error.localizedDescription
            threadErrorScope = .newestWindow
            return false
        }
    }

    func loadEarlierThread(account: AppModelAccountSession? = nil) async {
        await loadThreadHistory(.earlier, account: account)
    }

    func loadLaterThread(account: AppModelAccountSession? = nil) async {
        await loadThreadHistory(.later, account: account)
    }

    private func loadThreadHistory(
        _ direction: TimelineHistoryDirection,
        account: AppModelAccountSession?
    ) async {
        let session = account ?? accountSession()
        guard !Task.isCancelled, isCurrentAccountSession(session),
              let thread = openThread, !isLoadingThread,
              let anchorID = threadHistoryAnchor(direction)
        else { return }
        let generation = threadLoadGeneration
        let requestEpoch = historyEpoch
        setThreadHistoryLoading(true, direction: direction)
        threadErrorMessage = nil
        threadErrorScope = nil
        let refreshRevision = beginScopedConversationRefresh(in: thread.id)
        defer {
            endScopedConversationRefresh(refreshRevision)
            if isCurrentAccountSession(session), ownsThreadLoad(thread.id, generation: generation) {
                setThreadHistoryLoading(false, direction: direction)
                resumePendingThreadRevalidation()
            }
        }
        do {
            let page = try await threadHistoryPage(
                session.provider,
                in: thread.id,
                anchoredAt: direction == .earlier ? .before(anchorID) : .after(anchorID),
                limit: historyPageFetchLimit
            )
            guard isCurrentAccountSession(session),
                  isCurrentThreadLoad(thread.id, generation: generation)
            else { return }
            applyThreadHistoryPage(
                page,
                direction: direction,
                anchorID: anchorID,
                historyEpoch: requestEpoch,
                mutations: scopedConversationRefreshMutations(refreshRevision)
            )
        } catch is CancellationError {
            return
        } catch {
            // A failure for a window that has since been replaced is not
            // this window's error; its Retry would request nothing.
            guard isCurrentAccountSession(session),
                  isCurrentThreadLoad(thread.id, generation: generation),
                  threadHistoryAnchor(direction, ignoringLoading: true) == anchorID
            else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            threadErrorMessage = error.localizedDescription
            threadErrorScope = direction == .earlier ? .earlierPage : .laterPage
        }
    }

    /// The window edge a page in `direction` continues from, if it can load.
    private func threadHistoryAnchor(
        _ direction: TimelineHistoryDirection,
        ignoringLoading: Bool = false
    ) -> MessageID? {
        // One page is in flight at a time, whichever edge it continues.
        guard ignoringLoading || !(isLoadingEarlierThread || isLoadingLaterThread) else { return nil }
        switch direction {
        case .earlier:
            guard hasMoreThreadMessages else { return nil }
            return threadWindow.lowerCursor
        case .later:
            guard hasMoreLaterThreadMessages else { return nil }
            return threadWindow.upperCursor
        }
    }

    private func setThreadHistoryLoading(_ isLoading: Bool, direction: TimelineHistoryDirection) {
        switch direction {
        case .earlier: isLoadingEarlierThread = isLoading
        case .later: isLoadingLaterThread = isLoading
        }
    }

    private func applyThreadHistoryPage(
        _ page: MessagePage,
        direction: TimelineHistoryDirection,
        anchorID: MessageID,
        historyEpoch requestEpoch: Int,
        mutations: ConversationRefreshMutations
    ) {
        guard let threadID = openThread?.id else { return }
        // A window replaced while this page loaded no longer ends at its
        // anchor; attaching the page there would leave a gap.
        guard threadHistoryAnchor(direction, ignoringLoading: true) == anchorID else { return }
        // Live replies and deletions during the request reconcile here. A
        // final forward page reaches the live tail, so replies after it are
        // admitted; otherwise only messages inside the page are.
        let refreshed = applyingThreadRefreshMutations(
            mutations,
            to: page.messages,
            within: direction == .earlier
                ? MessageHistorySpan(page: page, continuingBefore: anchorID)
                : MessageHistorySpan(
                    page: page,
                    continuingAfter: anchorID,
                    closesNewerEdge: requestEpoch != historyEpoch
                )
        )
        let fetchedIDs = page.messages.map(\.id)
        switch direction {
        case .earlier:
            let ids = Set(threadMessages.map(\.id))
            let older = refreshed.filter { !ids.contains($0.id) && $0.id < anchorID }
            threadMessages = Self.merging(current: threadMessages, fresh: older)
            threadWindow.lowerCursor = fetchedIDs.min() ?? threadWindow.lowerCursor
            hasMoreThreadMessages = page.hasMoreBefore
            if !hasMoreLaterThreadMessages, requestEpoch == historyEpoch {
                hasMoreCache[threadID] = page.hasMoreBefore
            }
        case .later:
            threadMessages = Self.merging(current: threadMessages, fresh: refreshed)
            threadWindow.upperCursor = fetchedIDs.max() ?? threadWindow.upperCursor
            establishThreadNewestEdge(hasMoreAfter: page.hasMoreAfter, historyEpoch: requestEpoch)
            if !hasMoreLaterThreadMessages {
                // The window reached the newest message and follows live
                // messages again.
                readState.observeLoadedMessages(channelID: threadID, messages: threadMessages)
            }
        }
    }

    /// After a Gateway gap, the open thread's newest-backed window may have
    /// missed messages. Keep it visible and revalidate its newest page once
    /// no window or forward request is in flight; those began before the gap
    /// and cannot establish that the window is current.
    func revalidateOpenThreadAfterReconnect() {
        guard openThread != nil else { return }
        threadWindow.revalidationPending = true
        resumePendingThreadRevalidation()
    }

    func resumePendingThreadRevalidation() {
        guard threadWindow.revalidationPending, threadWindow.activeRevision == nil,
              !isLoadingThread, !isLoadingLaterThread
        else { return }
        threadWindow.revalidationPending = false
        guard let thread = openThread, hasCompletedInitialThreadLoad else { return }
        if hasMoreLaterThreadMessages, threadWindow.upperCursor != nil {
            // A detached window continues from its fetched edge in the new
            // connection, so nothing missed during the outage is skipped.
            startAccountChildTask(account: accountSession()) { model, account in
                await model.loadLaterThread(account: account)
            }
        } else {
            beginInitialThreadLoad(thread, preservingWindow: true)
        }
    }

    /// A send or a request for the newest messages is a later intent than
    /// any window request in flight, which therefore may no longer publish.
    func supersedeThreadWindowRequests() {
        if isLoadingInitialThreadJump {
            // A send while a jump's first window loads returns to the newest
            // messages instead, so the send stays visible.
            startAccountChildTask(account: accountSession()) { model, account in
                _ = await model.loadNewestThreadWindow(account: account)
            }
            return
        }
        // An initial load of the newest messages is itself the newest window.
        guard !isLoadingThread else { return }
        threadWindow.revision &+= 1
        threadWindow.activeRevision = nil
        // A superseded revalidation is still owed until a current read
        // establishes the newest edge.
        if threadWindow.isNewestUnverified { threadWindow.revalidationPending = true }
        resumePendingThreadRevalidation()
    }

    /// Whether a message may join the open thread's window: only within its
    /// cursors, unless no more history lies past that side.
    func threadWindowAdmits(_ messageID: MessageID) -> Bool {
        if hasMoreThreadMessages, let lower = threadWindow.lowerCursor, messageID < lower { return false }
        guard isThreadWindowAwayFromNewest else { return true }
        guard let upper = threadWindow.upperCursor else { return false }
        return messageID <= upper
    }
}
