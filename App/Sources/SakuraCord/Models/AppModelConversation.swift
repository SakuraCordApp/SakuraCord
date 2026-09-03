import CoreAudio
import CoreText
import DiscordProtocol
import Foundation
import ImageIO
import MediaPipeline
import MessageRendering
import OSLog
import Observation
import SakuraCordModels
import SakuraCordPersistence
import UniformTypeIdentifiers
import UserNotifications

// Conversation mutation, pagination, and composer operations intentionally
// share the same account-session extension so cancellation guards stay local.
// swiftlint:disable file_length

extension AppModel {
    func removeForumPost(_ postID: ChannelID) {
        guard let index = forumCatalogueIndexByID.removeValue(forKey: postID) else { return }
        forumCataloguePosts.remove(at: index)
        if index < forumCataloguePosts.endIndex {
            for updatedIndex in index ..< forumCataloguePosts.endIndex {
                forumCatalogueIndexByID[forumCataloguePosts[updatedIndex].id] = updatedIndex
            }
        }
        applyForumPresentation()
    }

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

        guard let channelID = selectedChannelID,
              selectedChannel?.kind != .voice || isVoiceChatOpen,
              selectedConversationAccess.isReadable
        else {
            replaceSelectedMessages(with: [])
            draft = ""
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
            channelLoadTask = startAccountChildTask(account: account) { model, account in
                let savedDraft = await model.storedDraft(in: channelID, account: account)
                guard model.isCurrentAccountSession(account),
                      model.isCurrentLoad(channelID, generation: generation),
                      model.draft.isEmpty
                else { return }
                model.draft = savedDraft
            }
            return
        }
        isLoadingMessages = true
        preserveUnreadDividerIfNeeded(channelID: channelID)
        draft = ""
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

    // swiftlint:disable:next function_body_length
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
        let freshPageTask: Task<MessagePage, any Error>
        if let prefetch = bootstrapHistoryPrefetch,
           prefetch.accountGeneration == account.generation,
           prefetch.accountRevision == account.installedRevision,
           prefetch.channelID == channelID
        {
            bootstrapHistoryPrefetch = nil
            freshPageTask = prefetch.task
        } else {
            bootstrapHistoryPrefetch?.task.cancel()
            bootstrapHistoryPrefetch = nil
            freshPageTask = makeHistoryRequestTask(
                channelID: channelID,
                account: account
            )
        }

        let savedDraft = await storedDraft
        guard isCurrentAccountSession(account),
              isCurrentLoad(channelID, generation: generation)
        else { return }
        if draft.isEmpty {
            draft = savedDraft
        }

        do {
            let page = try await freshPageTask.value
            guard isCurrentAccountSession(account),
                  isCurrentLoad(channelID, generation: generation)
            else { return }
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
                    await AppPerformanceSignposts.measure(
                        "ConversationRowPreprocessing"
                    ) {
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
            else { return }
            AppPerformanceSignposts.measureSync("ConversationInitialCommit") {
                let initialMutations = conversationRefreshMutations(
                    in: channelID,
                    revision: refreshRevision
                )
                let refreshedMessages = Self.applyingConversationRefreshMutations(
                    initialMutations,
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
                    replaceSelectedMessages(
                        with: merged,
                        preparedRows: preparedRows
                    )
                }
            }
            reportStartupContentReady(channelID)
            let freshMessageIDs = Set(page.messages.map(\.id))
            let needsSupplementalMemberResolution =
                !page.hasCompleteMemberResolution
                || messages.contains { !freshMessageIDs.contains($0.id) }
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

    func reply(to message: Message) {
        let destination: MessageComposerDestination
        if message.channelID == selectedChannelID {
            replyingTo = message
            replyMentionsAuthor = true
            destination = .channel
        } else if message.channelID == openThread?.id {
            threadReplyingTo = message
            threadReplyMentionsAuthor = true
            destination = .thread
        } else {
            return
        }
        NotificationCenter.default.post(
            name: .sakuracordFocusComposer,
            object: destination
        )
    }

    @discardableResult
    func navigateReplySelection(
        in destination: MessageComposerDestination,
        direction: MessageReplyNavigationDirection
    ) -> Bool {
        let availableMessages: [Message]
        let currentReply: Message?
        switch destination {
        case .channel:
            availableMessages = messages
            currentReply = replyingTo
        case .thread:
            availableMessages = threadMessages
            currentReply = threadReplyingTo
        }
        guard !availableMessages.isEmpty else { return false }

        let nextIndex: Int
        if let currentReply,
           let currentIndex = availableMessages.firstIndex(where: { $0.id == currentReply.id })
        {
            switch direction {
            case .older:
                nextIndex = currentIndex > availableMessages.startIndex
                    ? availableMessages.index(before: currentIndex)
                    : currentIndex
            case .newer:
                nextIndex = currentIndex < availableMessages.index(before: availableMessages.endIndex)
                    ? availableMessages.index(after: currentIndex)
                    : currentIndex
            }
        } else {
            nextIndex = availableMessages.index(before: availableMessages.endIndex)
        }
        if currentReply?.id == availableMessages[nextIndex].id {
            return true
        }
        reply(to: availableMessages[nextIndex])
        return true
    }

    func cancelReply(in destination: MessageComposerDestination = .channel) {
        switch destination {
        case .channel:
            replyingTo = nil
        case .thread:
            threadReplyingTo = nil
        }
        NotificationCenter.default.post(
            name: .sakuracordFocusComposer,
            object: destination
        )
    }

    @discardableResult
    func consumeEscapeForReply(
        in destination: MessageComposerDestination
    ) -> Bool {
        let hasReply = switch destination {
        case .channel: replyingTo != nil
        case .thread: threadReplyingTo != nil
        }
        guard hasReply else { return false }
        cancelReply(in: destination)
        return true
    }

    func setReplyMentionsAuthor(
        _ mentionsAuthor: Bool,
        in destination: MessageComposerDestination
    ) {
        switch destination {
        case .channel:
            replyMentionsAuthor = mentionsAuthor
        case .thread:
            threadReplyMentionsAuthor = mentionsAuthor
        }
    }

    func open(_ thread: MessageThreadSummary) {
        guard openThread?.id != thread.id else { return }
        let starter = messages.first { $0.thread?.id == thread.id }
        openThreadConversation(
            thread,
            starter: starter?.author,
            startedAt: starter?.timestamp,
            initialMessages: []
        )
    }

    func open(_ post: ForumPost) {
        guard openThread?.id != post.id else { return }
        readState.merge(forumPost: post)
        openThreadConversation(
            post.thread,
            starter: post.owner ?? post.firstMessage?.author,
            startedAt: post.firstMessage?.timestamp ?? post.createdAt,
            initialMessages: post.firstMessage.map { [$0] } ?? []
        )
    }

    func openThreadConversation(
        _ thread: MessageThreadSummary,
        starter: User?,
        startedAt: Date?,
        initialMessages: [Message]
    ) {
        threadLoadTask?.cancel()
        AppPerformanceSignposts.beginConversationNavigation(to: thread.id)
        readState.merge(thread: thread)
        openThread = thread
        recordForwardDestinationVisit(thread.id)
        _ = readState.updatePresentation(
            channelID: thread.id,
            isPresented: true,
            initialHistoryLoaded: false,
            initialPositionEstablished: false,
            windowIsActive: mainWindowIsActive,
            hasReachedReadBoundary: false,
            blocksAutomaticAcknowledgement: false
        )
        openThreadStarter = starter
        openThreadStartedAt = startedAt
        let cachedMessages = takeCachedMessages(for: thread.id)
        let cachedBoundary = hasMoreCache[thread.id]
        threadMessages = Self.merging(
            current: initialMessages,
            fresh: cachedMessages
        )
        threadDraft = ""
        threadReplyingTo = nil
        clearComposerAttachments(for: .thread)
        hasMoreThreadMessages = cachedBoundary ?? false
        beginInitialThreadLoad(thread)
    }

    func beginInitialThreadLoad(_ thread: MessageThreadSummary) {
        threadLoadTask?.cancel()
        threadErrorMessage = nil
        threadErrorScope = nil
        if hasMoreCache[thread.id] != nil {
            isLoadingThread = false
            hasCompletedInitialThreadLoad = true
            readState.observeLoadedMessages(
                channelID: thread.id,
                messages: threadMessages
            )
            reportConversationHistoryLoaded(channelID: thread.id)
            return
        }
        isLoadingThread = true
        hasCompletedInitialThreadLoad = false
        let account = accountSession()
        threadLoadTask = startAccountChildTask(account: account) { model, account in
            let refreshRevision = model.beginConversationRefresh(in: thread.id)
            defer {
                model.endConversationRefresh(
                    in: thread.id,
                    revision: refreshRevision
                )
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
            async let freshPage = account.provider.messages(
                in: thread.id,
                before: nil,
                limit: 100
            )
            do {
                let page = try await freshPage
                guard !Task.isCancelled,
                      model.isCurrentAccountSession(account),
                      model.openThread?.id == thread.id
                else { return }
                try await model.finishInitialThreadLoad(
                    page,
                    threadID: thread.id,
                    refreshRevision: refreshRevision,
                    session: account
                )
            } catch is CancellationError {
                return
            } catch {
                guard model.isCurrentAccountSession(account),
                      model.openThread?.id == thread.id
                else { return }
                model.threadErrorMessage = error.localizedDescription
                model.threadErrorScope = .initialPage
                model.isLoadingThread = false
                model.hasCompletedInitialThreadLoad = true
            }
        }
    }

    func finishInitialThreadLoad(
        _ page: MessagePage,
        threadID: ChannelID,
        refreshRevision: UInt64,
        session: AppModelAccountSession
    ) async throws {
        guard isCurrentAccountSession(session) else { return }
        let mutations = conversationRefreshMutations(
            in: threadID,
            revision: refreshRevision
        )
        let refreshedMessages = Self.applyingConversationRefreshMutations(
            mutations,
            to: page.messages
        )
        threadMessages = Self.reconcilingNewestPage(
            current: threadMessages,
            fresh: refreshedMessages,
            hasMoreBefore: page.hasMoreBefore,
            authoritativeOldestMessageID: page.messages.map(\.id).min()
        )
        hasMoreThreadMessages = page.hasMoreBefore
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingThread = false
        hasCompletedInitialThreadLoad = true
        readState.observeLoadedMessages(
            channelID: threadID,
            messages: threadMessages
        )
        reportConversationHistoryLoaded(channelID: threadID)
        hasMoreCache[threadID] = page.hasMoreBefore
    }

    func closeThread() {
        if let threadID = openThread?.id {
            cancelConversationRefresh(in: threadID)
            storeCachedMessages(threadMessages, for: threadID)
            hasMoreCache[threadID] = hasMoreThreadMessages
            unreadDividerMessageIDs[threadID] = nil
            if conversationNewestRequest?.channelID == threadID {
                conversationNewestRequest = nil
            }
            _ = readState.updatePresentation(channelID: threadID, isPresented: false)
        }
        threadLoadTask?.cancel()
        threadLoadTask = nil
        openThread = nil
        openThreadStarter = nil
        openThreadStartedAt = nil
        threadMessages = []
        threadDraft = ""
        threadReplyingTo = nil
        clearComposerAttachments(for: .thread)
        isLoadingThread = false
        hasCompletedInitialThreadLoad = false
        isLoadingEarlierThread = false
        hasMoreThreadMessages = false
        threadErrorMessage = nil
        threadErrorScope = nil
    }

    func openVoiceChat(for channel: Channel) {
        guard channel.kind == .voice else { return }
        if selectedChannelID != channel.id {
            selectedChannelID = channel.id
        }
        guard selectedChannelID == channel.id, !isVoiceChatOpen else { return }
        isVoiceChatOpen = true
        beginSelectedChannelLoad()
    }

    func closeVoiceChat() {
        guard isVoiceChatOpen else { return }
        if let selectedChannelID {
            cancelConversationRefresh(in: selectedChannelID)
        }
        channelLoadTask?.cancel()
        channelLoadTask = nil
        channelLoadGeneration &+= 1
        isVoiceChatOpen = false
        isLoadingMessages = false
        isLoadingEarlier = false
        messageLoadError = nil
    }

    func loadEarlierThread(account: AppModelAccountSession? = nil) async {
        let session = account ?? accountSession()
        guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
        guard let thread = openThread, let first = threadMessages.first, hasMoreThreadMessages,
              !isLoadingEarlierThread
        else { return }
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingEarlierThread = true
        defer {
            if isCurrentAccountSession(session), openThread?.id == thread.id {
                isLoadingEarlierThread = false
            }
        }
        do {
            let page = try await session.provider.messages(
                in: thread.id,
                before: first.id,
                limit: 50
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  openThread?.id == thread.id
            else { return }
            let ids = Set(threadMessages.map(\.id))
            threadMessages.insert(contentsOf: page.messages.filter { !ids.contains($0.id) }, at: 0)
            hasMoreThreadMessages = page.hasMoreBefore
            threadErrorMessage = nil
            threadErrorScope = nil
            hasMoreCache[thread.id] = page.hasMoreBefore
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccountSession(session),
                  openThread?.id == thread.id
            else { return }
            threadErrorMessage = error.localizedDescription
            threadErrorScope = .earlierPage
        }
    }

    func retryThreadLoad() {
        guard let thread = openThread else { return }
        switch threadErrorScope {
        case .initialPage:
            beginInitialThreadLoad(thread)
        case .earlierPage:
            threadErrorMessage = nil
            threadErrorScope = nil
            let account = accountSession()
            startAccountChildTask(account: account) { model, account in
                await model.loadEarlierThread(account: account)
            }
        case .action, nil:
            return
        }
    }

    @discardableResult
    func sendThreadMessage(attachments: [URL] = []) async -> Bool {
        await sendThreadComposerMessage(
            attachments: attachments.map { ForumPostAttachment(url: $0) }
        )
    }

    @discardableResult
    func sendThreadComposerMessage(attachments: [ForumPostAttachment]) async -> Bool {
        await submitThreadComposerMessage(attachments: attachments).serverConfirmed
    }

    func submitThreadComposerMessage(
        attachments: [ForumPostAttachment]
    ) async -> ComposerSubmissionResult {
        guard let thread = openThread, openThreadAccess.canSend else { return .rejected }
        let content = threadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return .rejected }
        guard validateAttachmentCount(attachments) else { return .rejected }
        let replyTo = threadReplyingTo?.id
        let mentionsRepliedUser = threadReplyMentionsAuthor
        let confirmed = await sendThreadMessage(
            content: content,
            replyTo: replyTo,
            mentionsRepliedUser: mentionsRepliedUser,
            replyPreview: threadReplyingTo.map(MessageReplyPreview.init),
            attachments: attachments,
            thread: thread,
            clearsComposer: true
        )
        return .enqueued(serverConfirmed: confirmed)
    }

    @discardableResult
    func sendThreadMessage(
        content: String,
        replyTo: MessageID? = nil,
        mentionsRepliedUser: Bool = true,
        replyPreview: MessageReplyPreview? = nil,
        attachments: [ForumPostAttachment],
        thread: MessageThreadSummary,
        clearsComposer: Bool
    ) async -> Bool {
        let draft = SendMessageDraft(
            channelID: thread.id,
            content: content,
            replyTo: replyTo,
            mentionsRepliedUser: mentionsRepliedUser,
            attachments: attachments
        )
        let optimistic = optimisticMessage(
            for: draft,
            replyPreview: replyPreview
        )
        appendOutgoingMessage(optimistic)
        outgoingMessages.draftsByNonce[draft.nonce] = draft
        if clearsComposer {
            threadDraft = ""
            threadReplyingTo = nil
        }
        let didSend = await performOutgoingSend(draft, isRetry: false)
        if didSend {
            completeConversationReadingAndAdvance(channelID: thread.id)
        }
        return didSend
    }

    func updateDraft(_ value: String) {
        let draftByteDelta = Int64(value.utf8.count - draft.utf8.count)
        draft = value
        if value.hasPrefix("/") || commandComposer.activeCommand != nil {
            stopLocalTyping(clearThrottle: false)
        } else {
            scheduleLocalTyping(for: value)
        }
        guard let channelID = selectedChannelID else { return }
        LocalStorageBudgetCoordinator.shared.scheduleAdjustment(
            draftByteDelta: draftByteDelta
        )
        quickSwitcherDraftChannelIDs.removeAll { $0 == channelID }
        if !value.isEmpty {
            quickSwitcherDraftChannelIDs.insert(channelID, at: 0)
        }
        let session = accountSession()
        Task { [weak self] in
            guard let self, self.isCurrentAccountSession(session) else { return }
            try? await session.database?.saveDraft(value, channelID: channelID)
        }
    }

    func updateThreadDraft(_ value: String) {
        threadDraft = value
        guard let thread = openThread else {
            stopLocalTyping(clearThrottle: value.isEmpty)
            return
        }
        scheduleLocalTyping(for: value, channelID: thread.id)
    }

    func loadApplicationCommands() {
        guard supportedCapabilities.contains(.slashCommands),
              let channel = selectedChannel,
              channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown
        else {
            commandComposer.failLoading(
                ChatProviderError.capabilityDisabled(.slashCommands).localizedDescription
            )
            return
        }
        let contextTarget: ApplicationCommandIndexTarget =
            channel.guildID.map {
                .guild($0)
            } ?? .channel(channel.id)
        let targets: Set<ApplicationCommandIndexTarget> = [contextTarget, .user]
        commandComposer.beginLoading(targets: targets)
        commandLoadTask?.cancel()
        let account = accountSession()
        commandLoadTask = Task { [weak self] in
            guard let self,
                  !Task.isCancelled,
                  isCurrentAccountSession(account)
            else { return }
            do {
                async let context: ApplicationCommandCatalog? =
                    try? account.provider.applicationCommandCatalog(
                        for: contextTarget
                    )
                async let user: ApplicationCommandCatalog? =
                    try? account.provider.applicationCommandCatalog(
                        for: .user
                    )
                let catalogs = await [context, user].compactMap(\.self)
                guard !catalogs.isEmpty else {
                    throw ChatProviderError.invalidRequest(
                        "Discord did not return an application command index for this conversation."
                    )
                }
                guard !Task.isCancelled,
                      isCurrentAccountSession(account),
                      selectedChannelID == channel.id
                else { return }
                let roleIDs = Set(
                    (snapshot?.currentUser.id).flatMap { membersByID[$0] }?.roles.map(\.id) ?? []
                )
                commandComposer.replaceCatalogs(
                    catalogs,
                    channel: channel,
                    currentUserID: snapshot?.currentUser.id,
                    memberRoleIDs: roleIDs
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(account),
                      selectedChannelID == channel.id
                else { return }
                commandComposer.failLoading(error.localizedDescription)
            }
        }
    }

    func requestApplicationCommandAutocomplete(
        for option: ApplicationCommandOption,
        query: String
    ) {
        guard option.usesAutocomplete, option.type.supportsAutocomplete,
              let channelID = selectedChannelID,
              let invocation = commandComposer.invocation(
                  channelID: channelID, guildID: selectedGuildID
              )
        else { return }
        let request = ApplicationCommandAutocompleteRequest(
            invocation: invocation, focusedOptionID: option.id, query: query
        )
        switch commandComposer.prepareAutocomplete(
            option: option, query: query, nonce: request.nonce
        ) {
        case .cached:
            commandAutocompleteTask?.cancel()
            commandAutocompleteTask = nil
            return
        case .pending:
            return
        case .request:
            commandAutocompleteTask?.cancel()
        }
        let session = accountSession()
        commandAutocompleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                try await session.provider.requestApplicationCommandAutocomplete(request)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                commandComposer.failAutocomplete(
                    nonce: request.nonce, message: error.localizedDescription
                )
            }
        }
    }

    func cancelApplicationCommandAutocompleteTask() {
        commandAutocompleteTask?.cancel()
        commandAutocompleteTask = nil
    }

    func requestApplicationCommandMemberSearch(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let option = commandComposer.focusedOption,
              option.type == .user || option.type == .mentionable,
              let guildID = selectedGuildID,
              !normalized.isEmpty
        else {
            cancelApplicationCommandMemberSearch()
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = commandMemberSearchCache[key] {
            commandMemberSearchTask?.cancel()
            commandMemberSearchTask = nil
            commandMemberSearchQuery = nil
            commandMemberResults = cached
            return
        }
        guard commandMemberSearchQuery != key else { return }
        commandMemberSearchTask?.cancel()
        commandMemberSearchQuery = key
        commandMemberResults = []
        let session = accountSession()
        commandMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let results = try await session.provider.searchMembers(
                    in: guildID, query: normalized, limit: 20
                )
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      commandMemberSearchQuery == key,
                      selectedGuildID == guildID
                else { return }
                commandMemberSearchCache[key] = results
                commandMemberResults = results
                commandMemberSearchQuery = nil
                commandMemberSearchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountSession(session),
                      commandMemberSearchQuery == key
                else { return }
                commandMemberSearchQuery = nil
                commandMemberSearchTask = nil
                commandMemberResults = []
            }
        }
    }

    func cancelApplicationCommandMemberSearch() {
        commandMemberSearchTask?.cancel()
        commandMemberSearchTask = nil
        commandMemberSearchQuery = nil
        commandMemberResults = []
    }

    func requestMentionMemberSearch(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guildID = selectedGuildID, !normalized.isEmpty else {
            mentionMemberSearchTask?.cancel()
            mentionMemberSearchTask = nil
            mentionMemberSearchQuery = nil
            mentionMemberResults = []
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = mentionMemberSearchCache[key],
           Date().timeIntervalSince(cached.storedAt) < 60
        {
            mentionMemberResults = cached.members
            return
        }
        mentionMemberSearchCache[key] = nil
        guard mentionMemberSearchQuery != key else { return }
        mentionMemberSearchTask?.cancel()
        mentionMemberSearchQuery = key
        mentionMemberResults = []
        let session = accountSession()
        mentionMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                let results = try await session.provider.searchMembers(
                    in: guildID, query: key.query, limit: 10
                )
                let roles = try? await session.provider.roles(in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      mentionMemberSearchQuery == key,
                      selectedGuildID == guildID
                else { return }
                if let roles { applyGuildRoles(roles, to: guildID) }
                mentionMemberSearchCache[key] = MentionMemberSearchCacheEntry(
                    members: results,
                    storedAt: Date()
                )
                mentionMemberResults = results
                mergeMentionAutocompleteMembers(results)
                for member in results { knownMentionMembers[member.id] = member }
                mentionMemberSearchQuery = nil
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountSession(session),
                      mentionMemberSearchQuery == key
                else { return }
                mentionMemberSearchQuery = nil
                mentionMemberResults = []
            }
        }
    }

    func rememberMentionMember(_ member: Member) {
        knownMentionMembers[member.id] = member
    }

    func mergeMentionAutocompleteMembers(_ updates: [Member]) {
        var positions = Dictionary(
            uniqueKeysWithValues: mentionAutocompleteMembers.indices.map {
                (mentionAutocompleteMembers[$0].id, $0)
            }
        )
        for member in updates {
            if let index = positions[member.id] {
                mentionAutocompleteMembers[index] = member
            } else {
                positions[member.id] = mentionAutocompleteMembers.count
                mentionAutocompleteMembers.append(member)
            }
        }
    }

    func showMembers(withRole roleID: RoleID) {
        roleMemberTask?.cancel()
        roleMemberResult = nil
        roleMemberErrorMessage = nil
        guard let guildID = selectedGuildID else {
            roleMemberErrorMessage = "Role members are only available inside a server."
            return
        }
        isLoadingRoleMembers = true
        let session = accountSession()
        roleMemberTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.provider.members(withRole: roleID, in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      selectedGuildID == guildID
                else { return }
                roleMemberResult = result
                for member in result.members { knownMentionMembers[member.id] = member }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                roleMemberErrorMessage = error.localizedDescription
            }
            if isCurrentAccountSession(session) {
                isLoadingRoleMembers = false
            }
        }
    }

    func executeApplicationCommand() {
        guard commandExecutionTask == nil,
              let channelID = selectedChannelID,
              let invocation = commandComposer.invocation(
                  channelID: channelID, guildID: selectedGuildID
              )
        else { return }
        commandAutocompleteTask?.cancel()
        stopLocalTyping(clearThrottle: true)
        updateDraft("")
        let session = accountSession()
        commandExecutionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrentAccountSession(session) {
                    commandExecutionTask = nil
                }
            }
            do {
                try await session.provider.executeApplicationCommand(invocation) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              self.isCurrentAccountSession(session)
                        else { return }
                        self.commandComposer.updateExecutionProgress(progress)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountSession(session) else { return }
                commandComposer.failExecution(error.localizedDescription)
            }
        }
    }

    func searchGIFs(_ query: String) {
        gifSearchTask?.cancel()
        isLoadingGIFs = true
        gifErrorMessage = nil
        let session = accountSession()
        gifSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard await session.provider.supports(.gifs),
                      isCurrentAccountSession(session)
                else {
                    throw ChatProviderError.capabilityDisabled(.gifs)
                }
                let values =
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? try await session.provider.trendingGIFs()
                        : try await session.provider.searchGIFs(query: query)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                gifResults = values
                isLoadingGIFs = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                gifResults = []
                gifErrorMessage = error.localizedDescription
                isLoadingGIFs = false
            }
        }
    }

    func loadGIFPicker() {
        gifPickerLoadTask?.cancel()
        gifPickerLoadGeneration &+= 1
        let generation = gifPickerLoadGeneration
        isLoadingGIFPicker = true
        gifErrorMessage = nil
        let session = accountSession()
        gifPickerLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrentAccountSession(session),
                   gifPickerLoadGeneration == generation
                {
                    gifPickerLoadTask = nil
                    isLoadingGIFPicker = false
                }
            }
            do {
                guard await session.provider.supports(.gifs),
                      isCurrentAccountSession(session)
                else {
                    throw ChatProviderError.capabilityDisabled(.gifs)
                }
                async let landing = session.provider.gifPickerLanding()
                async let favorites = session.provider.favoriteGIFs()
                let (loadedLanding, loadedFavorites) = try await (landing, favorites)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      gifPickerLoadGeneration == generation
                else { return }
                gifCategories = loadedLanding.categories
                gifTrendingPreviewURL = loadedLanding.trendingPreviewURL
                favoriteGIFs = loadedFavorites
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      gifPickerLoadGeneration == generation
                else { return }
                gifErrorMessage = error.localizedDescription
            }
        }
    }

    func setGIFFavorite(_ gif: GIFSearchResult, isFavorite: Bool) {
        guard gifFavoriteMutationURL == nil else { return }
        gifFavoriteMutationURL = gif.url
        let session = accountSession()
        Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrentAccountSession(session) {
                    gifFavoriteMutationURL = nil
                }
            }
            do {
                let favorites = try await session.provider.setGIFFavorite(
                    gif,
                    isFavorite: isFavorite
                )
                guard isCurrentAccountSession(session) else { return }
                favoriteGIFs = favorites
            } catch {
                guard isCurrentAccountSession(session) else { return }
                gifErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func sendGIF(_ gif: GIFSearchResult) async -> Bool {
        guard selectedChannelID != nil else { return false }
        let session = accountSession()
        let priorDraft = draft
        updateDraft(gif.url.absoluteString)
        let sent = await send()
        if !sent, isCurrentAccountSession(session) {
            updateDraft(priorDraft)
        }
        return sent
    }

    func loadStickersIfNeeded(in guildID: GuildID) {
        guard stickersByGuild[guildID] == nil, stickerLoadTasks[guildID] == nil else { return }
        let session = accountSession()
        let generation = stickerLoadGeneration
        stickerLoadTasks[guildID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrentAccountSession(session),
                   self.stickerLoadGeneration == generation
                {
                    self.stickerLoadTasks[guildID] = nil
                }
            }
            guard await session.provider.supports(.stickers),
                  self.isCurrentAccountSession(session),
                  self.stickerLoadGeneration == generation,
                  !Task.isCancelled
            else {
                guard self.isCurrentAccountSession(session),
                      self.stickerLoadGeneration == generation,
                      !Task.isCancelled
                else { return }
                stickersByGuild[guildID] = []
                return
            }
            let stickers = await (try? session.provider.stickers(in: guildID)) ?? []
            guard self.isCurrentAccountSession(session),
                  self.stickerLoadGeneration == generation,
                  !Task.isCancelled
            else { return }
            stickersByGuild[guildID] = stickers
        }
    }

    @discardableResult
    func sendSticker(_ sticker: MessageSticker) async -> Bool {
        let session = accountSession()
        guard let channelID = selectedChannelID,
              supportedCapabilities.contains(.stickerSending),
              isCurrentAccountSession(session)
        else {
            return false
        }
        let draft = SendMessageDraft(channelID: channelID, content: "", stickerIDs: [sticker.id])
        var presentedSticker = sticker
        presentedSticker.assetURL = sticker.pickerMediaURL ?? sticker.mediaURL
        let optimistic = optimisticMessage(
            for: draft,
            replyPreview: nil,
            stickers: [presentedSticker]
        )
        appendOutgoingMessage(optimistic)
        outgoingMessages.draftsByNonce[draft.nonce] = draft
        let didSend = await performOutgoingSend(draft, isRetry: false)
        if didSend {
            completeConversationReadingAndAdvance(channelID: channelID)
        }
        return didSend
    }

    func submitComponent(
        on message: Message, customID: String, kind: ComponentInteractionKind, values: [String] = []
    ) async {
        let key = ComponentControlKey(messageID: message.id, customID: customID)
        guard !componentInteractionPresentation.pendingControls.contains(key)
        else { return }
        guard supportedCapabilities.contains(.components) else {
            componentInteractionPresentation.errors[key] =
                ChatProviderError.capabilityDisabled(.components).localizedDescription
            return
        }
        let submission = ComponentInteractionSubmission(
            messageID: message.id, channelID: message.channelID, guildID: message.guildID,
            applicationID: message.applicationID, customID: customID, kind: kind, values: values
        )
        componentInteractionPresentation.pendingControls.insert(key)
        componentKeyByNonce[submission.nonce] = key
        componentInteractionPresentation.errors[key] = nil
        let session = accountSession()
        do {
            try await session.provider.submitComponentInteraction(submission)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            componentInteractionPresentation.pendingControls.remove(key)
            componentKeyByNonce[submission.nonce] = nil
            componentInteractionPresentation.errors[key] =
                error.localizedDescription
        }
    }

    func supportsCapability(_ capability: ChatCapability) -> Bool {
        supportedCapabilities.contains(capability)
    }

    func componentChoices(
        kind: ComponentSelectKind,
        query: String,
        guildID: GuildID?,
        channelID: ChannelID
    ) async throws -> [ComponentSelectOption] {
        guard supportedCapabilities.contains(.remoteComponentChoices) else {
            throw ChatProviderError.capabilityDisabled(
                .remoteComponentChoices
            )
        }
        let session = accountSession()
        let choices = try await session.provider.componentChoices(
                kind: kind,
                query: query,
                guildID: guildID,
                channelID: channelID
            )
        guard isCurrentAccountSession(session) else {
            throw CancellationError()
        }
        return Array(
            resolvedComponentChoices(
                choices,
                kind: kind,
                guildID: guildID
            ).prefix(25)
        )
    }

    func cachedComponentChoices(
        kind: ComponentSelectKind,
        guildID: GuildID?,
        channelTypes: [Int]
    ) -> [ComponentSelectOption] {
        let roles = componentChoiceRoles(in: guildID)
        let choices: [ComponentSelectOption]
        switch kind {
        case .string:
            choices = []
        case .user:
            choices = componentChoiceMembers(in: guildID).map {
                componentChoice(for: $0, roles: roles)
            }
        case .role:
            choices = roles
                .sorted(by: componentChoiceRolePrecedes)
                .map(componentChoice(for:))
        case .mentionable:
            choices = componentChoiceMembers(in: guildID).map {
                componentChoice(for: $0, roles: roles)
            } + roles
                .sorted(by: componentChoiceRolePrecedes)
                .map(componentChoice(for:))
        case .channel:
            choices = componentChoiceChannels(
                in: guildID,
                channelTypes: channelTypes
            ).map(componentChoice(for:))
        }
        return Array(choices.prefix(25))
    }

    private func resolvedComponentChoices(
        _ choices: [ComponentSelectOption],
        kind: ComponentSelectKind,
        guildID: GuildID?
    ) -> [ComponentSelectOption] {
        let membersByValue = Dictionary(
            componentChoiceMembers(in: guildID).map {
                (String($0.id.rawValue), $0)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        let rolesByValue = Dictionary(
            componentChoiceRoles(in: guildID).map {
                (String($0.id.rawValue), $0)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        let channelsByValue = Dictionary(
            componentChoiceChannels(in: guildID, channelTypes: []).map {
                (String($0.id.rawValue), $0)
            },
            uniquingKeysWith: { _, newer in newer }
        )
        let roles = Array(rolesByValue.values)
        return choices.map { choice in
            switch kind {
            case .string:
                choice
            case .user:
                membersByValue[choice.value].map {
                    componentChoice(for: $0, roles: roles)
                } ?? componentChoiceFallback(choice, entityKind: .user)
            case .role:
                rolesByValue[choice.value].map(componentChoice(for:))
                    ?? componentChoiceFallback(choice, entityKind: .role)
            case .mentionable:
                if let member = membersByValue[choice.value] {
                    componentChoice(for: member, roles: roles)
                } else if let role = rolesByValue[choice.value] {
                    componentChoice(for: role)
                } else {
                    choice
                }
            case .channel:
                channelsByValue[choice.value].map(componentChoice(for:))
                    ?? componentChoiceFallback(choice, entityKind: .channel)
            }
        }
    }

    private func componentChoiceMembers(
        in guildID: GuildID?
    ) -> [Member] {
        let values: [Member]
        if let guildID,
           let stored = membersByGuildID[guildID],
           !stored.isEmpty
        {
            values = Array(stored.values)
        } else {
            values = members
        }
        return values.sorted {
            let comparison = $0.user.displayName.localizedCaseInsensitiveCompare(
                $1.user.displayName
            )
            return comparison == .orderedSame
                ? $0.id < $1.id
                : comparison == .orderedAscending
        }
    }

    private func componentChoiceRoles(
        in guildID: GuildID?
    ) -> [GuildRole] {
        if let guildID,
           let stored = guildRolesByGuildID[guildID],
           !stored.isEmpty
        {
            return stored
        }
        return guildRoles
    }

    private func componentChoiceChannels(
        in guildID: GuildID?,
        channelTypes: [Int]
    ) -> [Channel] {
        let source = snapshot?.channels ?? visibleChannels
        return source.filter { channel in
            (guildID == nil || channel.guildID == guildID)
                && (channelTypes.isEmpty
                    || channelTypes.contains(channel.discordCommandType))
        }.sorted {
            if $0.categoryPosition != $1.categoryPosition {
                return $0.categoryPosition < $1.categoryPosition
            }
            if $0.position != $1.position {
                return $0.position < $1.position
            }
            return $0.id < $1.id
        }
    }

    private func componentChoice(
        for member: Member,
        roles: [GuildRole]
    ) -> ComponentSelectOption {
        let roleIDs = Set(member.roleIDs)
        let colorHex = MessageAuthorPresentation.topRoleColor(
            in: member.roles
        ) ?? MessageAuthorPresentation.topRoleColor(
            in: roles.filter { roleIDs.contains($0.id) }
        )
        return ComponentSelectOption(
            label: member.user.displayName,
            value: String(member.id.rawValue),
            description: "@\(member.user.username)",
            imageURL: member.guildAvatarURL ?? member.user.avatarURL,
            imageShape: .circle,
            entityKind: .user,
            colorHex: colorHex
        )
    }

    private func componentChoice(
        for role: GuildRole
    ) -> ComponentSelectOption {
        ComponentSelectOption(
            label: role.name,
            value: String(role.id.rawValue),
            imageURL: role.iconURL,
            imageShape: .roundedRectangle,
            entityKind: .role,
            colorHex: role.colorHex,
            unicodeEmoji: role.unicodeEmoji
        )
    }

    private func componentChoice(
        for channel: Channel
    ) -> ComponentSelectOption {
        ComponentSelectOption(
            label: channel.name,
            value: String(channel.id.rawValue),
            description: channel.category,
            entityKind: .channel,
            channelKind: channel.kind
        )
    }

    private func componentChoiceFallback(
        _ choice: ComponentSelectOption,
        entityKind: ComponentSelectOptionEntityKind
    ) -> ComponentSelectOption {
        var resolved = choice
        resolved.entityKind = entityKind
        if entityKind == .role, resolved.label.hasPrefix("@")
            || entityKind == .channel && resolved.label.hasPrefix("#")
        {
            resolved.label.removeFirst()
        }
        return resolved
    }

    private func componentChoiceRolePrecedes(
        _ lhs: GuildRole,
        _ rhs: GuildRole
    ) -> Bool {
        if lhs.position != rhs.position {
            return lhs.position > rhs.position
        }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return comparison == .orderedSame
            ? lhs.id < rhs.id
            : comparison == .orderedAscending
    }

    func isComponentPending(messageID: MessageID, customID: String) -> Bool {
        componentInteractionPresentation.pendingControls.contains(
            ComponentControlKey(messageID: messageID, customID: customID))
    }

    func componentSelection(
        messageID: MessageID,
        customID: String
    ) -> [ComponentSelectOption]? {
        componentInteractionPresentation.selections[
            ComponentControlKey(messageID: messageID, customID: customID)
        ]
    }

    func setComponentSelection(
        _ options: [ComponentSelectOption],
        messageID: MessageID,
        customID: String
    ) {
        componentInteractionPresentation.selections[
            ComponentControlKey(messageID: messageID, customID: customID)
        ] = options
    }

    func publishComponentSelectionPresentation() {
        timelinePresentationRevision &+= 1
    }

    func componentError(for messageID: MessageID) -> String? {
        componentInteractionPresentation.errors
            .filter { $0.key.messageID == messageID }
            .sorted { $0.key.customID < $1.key.customID }
            .first?.value
    }

    func dismissInteractionModal() {
        presentedInteractionModal = nil
        interactionModalNonce = nil
    }

    func submitModal(values: [String: [String]], fileURLs: [String: [URL]]) async -> Bool {
        guard let modal = presentedInteractionModal, let nonce = interactionModalNonce else {
            return false
        }
        let session = accountSession()
        do {
            try await session.provider.submitModal(
                ModalSubmission(customID: modal.customID, values: values, fileURLs: fileURLs),
                nonce: nonce
            )
            guard isCurrentAccountSession(session) else { return false }
            dismissInteractionModal()
            return true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            interactionErrorMessage = error.localizedDescription
            return false
        }
    }

    func scheduleLocalTyping(for value: String, channelID: ChannelID? = nil) {
        let destination: (id: ChannelID, supportsTyping: Bool)? =
            if let channelID {
                (channelID, true)
            } else if let selectedChannel {
                (selectedChannel.id, Self.supportsTyping(selectedChannel.kind))
            } else {
                nil
            }
        guard chatSettings.sendsTypingIndicators,
              !value.isEmpty,
              connectionState == .ready,
              let destination,
              destination.supportsTyping
        else {
            stopLocalTyping(clearThrottle: value.isEmpty)
            return
        }
        if localTypingTask != nil, localTypingChannelID == destination.id {
            return
        }
        stopLocalTyping(clearThrottle: false)
        localTypingGeneration &+= 1
        let generation = localTypingGeneration
        localTypingChannelID = destination.id
        let now = Date.now
        let debounce = Self.seconds(localTypingTiming.debounce)
        let remainingThrottle =
            lastTypingRequestAt[destination.id]
                .map { max(0, Self.seconds(localTypingTiming.throttle) - now.timeIntervalSince($0)) }
                ?? 0
        let delay = max(debounce, remainingThrottle)
        localTypingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.performLocalTyping(
                channelID: destination.id,
                generation: generation
            )
        }
    }

    func performLocalTyping(channelID: ChannelID, generation: UInt64) async {
        let isActiveChannelDraft = selectedChannelID == channelID
            && !draft.isEmpty
        let isActiveThreadDraft = openThread?.id == channelID
            && !threadDraft.isEmpty
        guard chatSettings.sendsTypingIndicators,
              generation == localTypingGeneration,
              localTypingChannelID == channelID,
              isActiveChannelDraft || isActiveThreadDraft,
              connectionState == .ready
        else { return }
        localTypingTask = nil
        localTypingChannelID = nil
        // Count the attempt, not only a successful response. A failed mutation is
        // not immediately retried by subsequent keystrokes.
        lastTypingRequestAt[channelID] = .now
        let session = accountSession()
        do {
            try await session.provider.sendTyping(in: channelID)
        } catch is CancellationError {
            return
        } catch {
            // Typing is best-effort. The shared provider still applies its safety
            // circuit and mutation retry rules; composer input remains available.
        }
    }

    func stopLocalTyping(clearThrottle: Bool) {
        localTypingGeneration &+= 1
        localTypingTask?.cancel()
        localTypingTask = nil
        if clearThrottle {
            if let localTypingChannelID {
                lastTypingRequestAt[localTypingChannelID] = nil
            }
            if let selectedChannelID {
                lastTypingRequestAt[selectedChannelID] = nil
            }
        }
        localTypingChannelID = nil
    }

    static func supportsTyping(_ kind: ChannelKindValue) -> Bool {
        switch kind {
        case .text, .announcement, .directMessage, .groupDirectMessage: true
        case .forum, .voice, .unknown: false
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    @discardableResult
    func send(attachments: [URL] = []) async -> Bool {
        await sendComposerMessage(
            attachments: attachments.map { ForumPostAttachment(url: $0) }
        )
    }

    @discardableResult
    func sendComposerMessage(attachments: [ForumPostAttachment]) async -> Bool {
        await submitComposerMessage(attachments: attachments).serverConfirmed
    }

    func submitComposerMessage(
        attachments: [ForumPostAttachment]
    ) async -> ComposerSubmissionResult {
        guard let channelID = selectedChannelID, selectedConversationAccess.canSend else {
            return .rejected
        }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return .rejected }
        guard validateAttachmentCount(attachments) else { return .rejected }
        if hasMoreLaterMessages {
            guard await loadNewestMessageWindow() else { return .rejected }
        }
        let replyTo = replyingTo?.id
        let mentionsRepliedUser = replyMentionsAuthor
        let replyPreview = replyingTo.map {
            MessageReplyPreview(message: $0)
        }
        let confirmed = await sendChannelMessage(
            channelID: channelID,
            content: content,
            replyTo: replyTo,
            mentionsRepliedUser: mentionsRepliedUser,
            replyPreview: replyPreview,
            attachments: attachments,
            clearsComposer: true
        )
        return .enqueued(serverConfirmed: confirmed)
    }

    @discardableResult
    func sendChannelMessage(
        channelID: ChannelID,
        content: String,
        replyTo: MessageID?,
        mentionsRepliedUser: Bool = true,
        replyPreview: MessageReplyPreview?,
        attachments: [ForumPostAttachment],
        clearsComposer: Bool
    ) async -> Bool {
        let outgoing = SendMessageDraft(
            channelID: channelID,
            content: content,
            replyTo: replyTo,
            mentionsRepliedUser: mentionsRepliedUser,
            attachments: attachments
        )
        if clearsComposer {
            stopLocalTyping(clearThrottle: true)
        }
        let optimistic = optimisticMessage(
            for: outgoing,
            replyPreview: replyPreview
        )
        appendOutgoingMessage(optimistic)
        outgoingMessages.draftsByNonce[outgoing.nonce] = outgoing
        if clearsComposer {
            replyingTo = nil
            updateDraft("")
        }
        let didSend = await performOutgoingSend(outgoing, isRetry: false)
        if didSend {
            completeConversationReadingAndAdvance(channelID: channelID)
        }
        return didSend
    }

    func composerAttachments(
        for destination: MessageComposerDestination
    ) -> [ForumPostAttachment] {
        switch destination {
        case .channel: channelComposerAttachments
        case .thread: threadComposerAttachments
        }
    }

    func isComposerDropEligible(_ destination: MessageComposerDestination) -> Bool {
        switch destination {
        case .channel:
            guard commandComposer.activeCommand == nil,
                  selectedConversationAccess.canSend,
                  let kind = selectedChannel?.kind
            else { return false }
            return Self.supportsTyping(kind)
        case .thread:
            return openThread != nil && openThreadAccess.canSend
        }
    }

    @discardableResult
    func addPromisedComposerAttachments(
        _ batch: ComposerPromisedFileBatch,
        to destination: MessageComposerDestination
    ) -> Bool {
        let adoptedURLs = adoptPromisedFileBatch(batch)
        let didHandle = addComposerAttachments(adoptedURLs, to: destination)
        pruneOwnedPromisedAttachmentFiles()
        return didHandle
    }

    func preparePromisedAttachmentsForImmediateSend(
        _ batch: ComposerPromisedFileBatch,
        to destination: MessageComposerDestination
    ) -> [URL] {
        let adoptedURLs = adoptPromisedFileBatch(batch)
        guard isComposerDropEligible(destination) else {
            pruneOwnedPromisedAttachmentFiles()
            return []
        }
        let acceptedURLs = attachmentURLsWithinDiscordLimit(
            adoptedURLs,
            offeringExternalUploadFor: destination
        )
        let sentURLs = Array(
            acceptedURLs.prefix(SendMessageDraft.maximumAttachmentCount)
        )
        if acceptedURLs.count > sentURLs.count {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
        }
        beginUsingOwnedPromisedFiles(sentURLs)
        pruneOwnedPromisedAttachmentFiles()
        return sentURLs
    }

    @discardableResult
    func addComposerAttachments(
        _ urls: [URL],
        to destination: MessageComposerDestination
    ) -> Bool {
        guard isComposerDropEligible(destination), !urls.isEmpty else { return false }
        let acceptedURLs = attachmentURLsWithinDiscordLimit(
            urls,
            offeringExternalUploadFor: destination
        )
        var attachments = composerAttachments(for: destination)
        let remaining = max(0, SendMessageDraft.maximumAttachmentCount - attachments.count)
        attachments.append(
            contentsOf: acceptedURLs.prefix(remaining).map { ForumPostAttachment(url: $0) }
        )
        setComposerAttachments(attachments, for: destination)
        if acceptedURLs.count > remaining {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
        }
        // Claim a valid drop even when every file was rejected, preventing its path
        // from being inserted into the text field by the system fallback.
        return remaining > 0 || !urls.isEmpty
    }

    func removeComposerAttachment(
        _ id: UUID,
        from destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        attachments.removeAll { $0.id == id }
        setComposerAttachments(attachments, for: destination)
    }

    func updateComposerAttachment(
        _ attachment: ForumPostAttachment,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else {
            return
        }
        attachments[index] = attachment
        setComposerAttachments(attachments, for: destination)
    }

    func toggleComposerAttachmentSpoiler(
        _ id: UUID,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].isSpoiler.toggle()
        setComposerAttachments(attachments, for: destination)
    }

    func clearComposerAttachments(for destination: MessageComposerDestination) {
        setComposerAttachments([], for: destination)
    }

    @discardableResult
    func consumeEscapeForComposerAttachments(
        in destination: MessageComposerDestination
    ) -> Bool {
        guard !composerAttachments(for: destination).isEmpty else { return false }
        clearComposerAttachments(for: destination)
        return true
    }

    @discardableResult
    func consumeEscapeForSupplementaryConversation() -> Bool {
        if openThread != nil {
            closeThread()
            return true
        }
        guard isVoiceChatOpen else { return false }
        closeVoiceChat()
        return true
    }

    func restoreComposerAttachments(
        _ restoredAttachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) {
        let current = composerAttachments(for: destination)
        var seen = Set(current.map(\.id))
        let restored = restoredAttachments.filter {
            seen.insert($0.id).inserted
        }
        setComposerAttachments(
            Array((restored + current).prefix(SendMessageDraft.maximumAttachmentCount)),
            for: destination
        )
    }

    @discardableResult
    func sendAttachmentsImmediately(
        _ attachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) async -> Bool {
        guard isComposerDropEligible(destination), !attachments.isEmpty,
              validateAttachmentCount(attachments)
        else { return false }
        switch destination {
        case .channel:
            guard let channelID = selectedChannelID else { return false }
            return await sendChannelMessage(
                channelID: channelID,
                content: "",
                replyTo: nil,
                replyPreview: nil,
                attachments: attachments,
                clearsComposer: false
            )
        case .thread:
            guard let thread = openThread else { return false }
            return await sendThreadMessage(
                content: "",
                attachments: attachments,
                thread: thread,
                clearsComposer: false
            )
        }
    }

    func setComposerAttachments(
        _ attachments: [ForumPostAttachment],
        for destination: MessageComposerDestination
    ) {
        switch destination {
        case .channel:
            channelComposerAttachments = attachments
        case .thread:
            threadComposerAttachments = attachments
        }
        pruneOwnedPromisedAttachmentFiles()
    }

    func validateAttachmentCount(_ attachments: [ForumPostAttachment]) -> Bool {
        guard attachments.count <= SendMessageDraft.maximumAttachmentCount else {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
            return false
        }
        return true
    }

    @discardableResult
    func retrySending(_ message: Message) async -> Bool {
        guard message.outboxState == .failed,
              let nonce = message.nonce,
              outgoingState(nonce: nonce, channelID: message.channelID) == .failed,
              let outgoing = outgoingMessages.draftsByNonce[nonce]
        else { return false }
        if let sourceURL = outgoingMessages.stickerUploadSourceURLByNonce[nonce] {
            updateOutgoingState(.uploading, nonce: nonce, channelID: message.channelID)
            return await performStickerUpload(
                outgoing,
                sourceURL: sourceURL,
                isRetry: true
            )
        }
        updateOutgoingState(.sending, nonce: nonce, channelID: message.channelID)
        return await performOutgoingSend(outgoing, isRetry: true)
    }

    func performOutgoingSend(_ outgoing: SendMessageDraft, isRetry: Bool) async -> Bool {
        let session = accountSession()
        let attachmentURLs = outgoing.attachmentURLs
        beginUsingOwnedPromisedFiles(attachmentURLs)
        let securityScopedURLs = attachmentURLs.filter {
            $0.startAccessingSecurityScopedResource()
        }
        defer {
            for url in securityScopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            endUsingOwnedPromisedFiles(attachmentURLs)
        }
        Self.messageSendLogger.info(
            """
            Message send started channel=\(outgoing.channelID.description, privacy: .public) \
            nonce=\(outgoing.nonce, privacy: .public) attachments=\(outgoing.attachmentURLs.count) \
            stickers=\(outgoing.stickerIDs.count) retry=\(isRetry)
            """
        )
        do {
            let confirmed = try await session.provider.send(outgoing)
            guard isCurrentAccountSession(session) else { return false }
            let reconciled = reconcileVisibleOrCached(confirmed)
            outgoingMessages.draftsByNonce[outgoing.nonce] = nil
            outgoingMessages.stickerUploadSourceURLByNonce[outgoing.nonce] = nil
            journalAuthoritativeMessageUpsert(reconciled)
            guard isCurrentAccountSession(session) else { return false }
            Self.messageSendLogger.info(
                """
                Message send succeeded channel=\(outgoing.channelID.description, privacy: .public) \
                nonce=\(outgoing.nonce, privacy: .public) \
                message=\(confirmed.id.description, privacy: .public) retry=\(isRetry)
                """
            )
            return true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            let state: OutboxState
            if (error as? URLError)?.code == .timedOut {
                state = .awaitingReconciliation
                updateOutgoingState(state, nonce: outgoing.nonce, channelID: outgoing.channelID)
            } else {
                state = .failed
                updateOutgoingState(state, nonce: outgoing.nonce, channelID: outgoing.channelID)
            }
            let nsError = error as NSError
            Self.messageSendLogger.error(
                """
                Message send failed channel=\(outgoing.channelID.description, privacy: .public) \
                nonce=\(outgoing.nonce, privacy: .public) state=\(state.rawValue, privacy: .public) \
                retry=\(isRetry) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) \
                details=\(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }

    func optimisticMessage(
        for outgoing: SendMessageDraft,
        replyPreview: MessageReplyPreview?,
        stickers: [MessageSticker] = []
    ) -> Message {
        let id = outgoingMessages.nextOptimisticMessageID()
        return Message(
            id: id,
            channelID: outgoing.channelID,
            author: snapshot?.currentUser
                ?? User(id: UserID(rawValue: 1), username: "me", displayName: "Me"),
            content: outgoing.content,
            replyTo: outgoing.replyTo,
            replyPreview: replyPreview,
            attachments: outgoing.attachments.enumerated().map {
                var presentation = OptimisticAttachmentPresentation.attachment(
                    for: $0.element.url,
                    index: $0.offset
                )
                presentation.filename = $0.element.filename
                presentation.description = $0.element.description
                presentation.isSpoiler = $0.element.isSpoiler
                return presentation
            },
            nonce: outgoing.nonce,
            outboxState: .sending,
            stickers: stickers
        )
    }

    func appendOutgoingMessage(_ message: Message) {
        if message.channelID == openThread?.id {
            var updated = threadMessages
            Self.insert(message, intoSorted: &updated)
            threadMessages = updated
        } else if message.channelID == selectedChannelID {
            appendSelectedMessage(message)
        } else {
            cache(message)
        }
    }
}
