import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    var openThreadParentChannel: Channel? {
        guard let parentID = openThread?.parentID else { return nil }
        if let selectedChannel, selectedChannel.id == parentID { return selectedChannel }
        return snapshot?.channels.first { $0.id == parentID }
            ?? visibleChannels.first { $0.id == parentID }
    }

    var openThreadAccess: ConversationAccess {
        guard let thread = openThread, let channel = openThreadParentChannel else { return .checking }
        guard let guildID = channel.guildID else { return .readable(canSend: true) }
        if thread.isPrivate, thread.notificationSettings == nil {
            guard let permissions = effectiveMessagePermissions(in: channel) else { return .checking }
            guard permissions & DiscordPermissionBits.manageThreads != 0 else { return .hidden }
        }
        let access = ConversationPermissionResolver.threadAccess(
            effectivePermissions: effectiveMessagePermissions(in: channel),
            isLocked: thread.isLocked
        )
        if requiresOnboarding(in: guildID) || onboardingMember(in: guildID)?.isPending == true {
            return access.isReadable ? .readable(canSend: false) : access
        }
        return access
    }

    func open(_ thread: MessageThreadSummary) {
        guard openThread?.id != thread.id else { return }
        let starter = messages.first { $0.thread?.id == thread.id }
        openThreadConversation(
            thread,
            starter: starter?.author,
            startedAt: starter?.timestamp,
            starterMessageID: nil,
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
            starterMessageID: post.firstMessage?.id,
            initialMessages: post.firstMessage.map { [$0] } ?? []
        )
    }

    func openThreadConversation(
        _ thread: MessageThreadSummary,
        starter: User?,
        startedAt: Date?,
        starterMessageID: MessageID? = nil,
        initialMessages: [Message],
        fullWidth: Bool = false
    ) {
        closeThread()
        AppPerformanceSignposts.beginConversationNavigation(to: thread.id)
        readState.merge(thread: thread)
        openThread = thread
        isThreadFullWidth = fullWidth
        if let selectedChannelID, !isConversationPresented(selectedChannelID) {
            suspendSelectedConversationPresentation()
        }
        recordForwardDestinationVisit(thread.id)
        _ = readState.updatePresentation(
            channelID: thread.id,
            isPresented: isConversationPresented(thread.id),
            initialHistoryLoaded: false,
            initialPositionEstablished: false,
            windowIsActive: mainWindowIsActive,
            hasReachedReadBoundary: false,
            blocksAutomaticAcknowledgement: false
        )
        openThreadStarter = starter
        openThreadStartedAt = startedAt
        openThreadStarterMessageID = starterMessageID
        let cachedMessages = takeCachedMessages(for: thread.id)
        let cachedBoundary = hasMoreCache[thread.id]
        let previewMessages: [Message]
        if cachedBoundary == true,
           let starterMessageID,
           !cachedMessages.contains(where: { $0.id == starterMessageID })
        {
            // The cached newest page starts after the starter. Its older edge,
            // not the forum preview, must drive earlier pagination.
            previewMessages = initialMessages.filter { $0.id != starterMessageID }
        } else {
            previewMessages = initialMessages
        }
        threadMessages = Self.merging(
            current: previewMessages,
            fresh: cachedMessages
        )
        threadDraft = ""
        threadReplyingTo = nil
        clearComposerAttachments(for: .thread)
        translation.resetDraft(.thread)
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
                guard !Task.isCancelled,
                      model.isCurrentAccountSession(account),
                      model.openThread?.id == thread.id
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
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
        let currentMessages: [Message]
        if page.hasMoreBefore,
           let starterMessageID = openThreadStarterMessageID,
           !page.messages.contains(where: { $0.id == starterMessageID })
        {
            // The preview is outside the newest page. Keeping it would hide a
            // gap and make earlier pagination request messages before the starter.
            currentMessages = threadMessages.filter { $0.id != starterMessageID }
        } else {
            currentMessages = threadMessages
        }
        threadMessages = Self.reconcilingNewestPage(
            current: currentMessages,
            fresh: refreshedMessages,
            hasMoreBefore: page.hasMoreBefore,
            authoritativeOldestMessageID: page.messages.map(\.id).min()
        ).map(pollVotePresentationPreserving)
        seedSlowmodeHistory(threadMessages)
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

    func consumeThreadEvent(_ event: ClientEvent) -> Bool {
        switch event {
        case .threadDeleted(let channelID):
            consumeThreadDeleted(channelID: channelID)
        case .forumPostsChanged(let channelID, let posts):
            consumeForumPostsChanged(channelID: channelID, posts: posts)
        case .forumPostPreviewsChanged(let channelID, let posts):
            consumeForumPostPreviewsChanged(channelID: channelID, posts: posts)
        case .activeJoinedThreadsChanged(let threads):
            if var value = snapshot {
                value.activeJoinedThreads = threads
                snapshot = value
                forwardSearchSourceRevision &+= 1
            }
            reconcileInboxEligibility()
        case .forumPageLoaded(let channelID, let query, let page):
            consumeForumPageLoaded(channelID: channelID, query: query, page: page)
        default:
            return false
        }
        return true
    }

    func consumeThreadDeleted(channelID: ChannelID) {
        // Closing saves the current conversation, so evict only after it closes.
        if openThread?.id == channelID { closeThread() }
        cancelConversationRefresh(in: channelID)
        messageCache[channelID] = nil
        messageCacheOrder.removeAll { $0 == channelID }
        messageRowCache[channelID] = nil
        messageRowCacheOrder.removeAll { $0 == channelID }
        hasMoreCache[channelID] = nil
        threadPreviewMessages[channelID] = nil
        threadPreviewParentIDs[channelID] = nil
        inbox.metadataTasks.removeValue(forKey: channelID)?.cancel()
        inbox.threads[channelID] = nil

        var seen = Set<MessageID>()
        for message in retainedMessages where message.thread?.id == channelID && seen.insert(message.id).inserted {
            var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
            update.thread = .some(nil)
            consumeImmediately(.messagePatched(update))
        }
    }

    func closeThread() {
        threadCommandComposer.resetForChannelChange()
        if let threadID = openThread?.id {
            cancelConversationRefresh(in: threadID)
            let hasLoadedHistory = hasMoreCache[threadID] != nil
            // Store the boundary before trimming so omitted older messages remain loadable.
            hasMoreCache[threadID] = hasMoreThreadMessages
            storeCachedMessages(threadMessages, for: threadID)
            // A preview or interrupted initial load is not reusable history.
            if !hasLoadedHistory {
                hasMoreCache[threadID] = nil
            }
            unreadDividerMessageIDs[threadID] = nil
            if conversationNewestRequest?.channelID == threadID {
                conversationNewestRequest = nil
            }
            _ = readState.updatePresentation(channelID: threadID, isPresented: false)
        }
        threadLoadTask?.cancel()
        threadLoadTask = nil
        openThread = nil
        isThreadFullWidth = false
        threadCreation = nil
        openThreadStarter = nil
        openThreadStartedAt = nil
        openThreadStarterMessageID = nil
        threadMessages = []
        threadDraft = ""
        threadReplyingTo = nil
        clearComposerAttachments(for: .thread)
        translation.resetDraft(.thread)
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
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
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
        await submitThreadComposerMessage(attachments: attachments).serverConfirmation()
    }

    func submitThreadComposerMessage(
        attachments: [ForumPostAttachment]
    ) async -> ComposerSubmissionResult {
        if let threadCreation {
            return await submitThreadCreation(threadCreation, attachments: attachments)
        }
        guard let thread = openThread, openThreadAccess.canSend else { return .rejected }
        guard allowSlowmodeSubmission(in: thread.id) else { return .rejected }
        let content = threadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return .rejected }
        guard validateAttachmentCount(attachments), allowOutgoingQueueSubmission() else { return .rejected }
        guard let delivery = enqueueThreadMessage(
            content: content,
            replyTo: threadReplyingTo?.id,
            mentionsRepliedUser: threadReplyMentionsAuthor,
            replyPreview: threadReplyingTo.map(MessageReplyPreview.init),
            attachments: attachments,
            thread: thread,
            clearsComposer: true
        ) else { return .rejected }
        return .enqueued(delivery: delivery)
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
        await enqueueThreadMessage(
            content: content,
            replyTo: replyTo,
            mentionsRepliedUser: mentionsRepliedUser,
            replyPreview: replyPreview,
            attachments: attachments,
            thread: thread,
            clearsComposer: clearsComposer
        )?.value ?? false
    }

    /// Shows the optimistic message and admits it to the outbox without waiting
    /// for delivery. Returns nil when the message was not admitted.
    func enqueueThreadMessage(
        content: String,
        replyTo: MessageID? = nil,
        mentionsRepliedUser: Bool = true,
        replyPreview: MessageReplyPreview? = nil,
        attachments: [ForumPostAttachment],
        thread: MessageThreadSummary,
        clearsComposer: Bool
    ) -> Task<Bool, Never>? {
        guard allowOnboardingSubmission(in: thread.id), allowSlowmodeSubmission(in: thread.id) else { return nil }
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
        composer.outbox.draftsByNonce[draft.nonce] = draft
        if clearsComposer {
            threadDraft = ""
            threadReplyingTo = nil
            translation.resetDraft(.thread)
        }
        return enqueueOutgoingSend(draft, isRetry: false, completesReading: true)
    }

}

extension AppModel {
    /// Which thread types the selected channel allows. Announcement channels
    /// only support public announcement threads.
    var selectedChannelThreadCreationPermissions: ThreadCreationPermissions {
        guard let channel = selectedChannel, channel.guildID != nil,
              channel.kind == .text || channel.kind == .announcement,
              let permissions = selectedEffectivePermissions,
              permissions & DiscordPermissionBits.readMessageHistory != 0
        else { return ThreadCreationPermissions(canCreatePublic: false, canCreatePrivate: false) }
        return ThreadCreationPermissions(
            canCreatePublic: permissions & DiscordPermissionBits.createPublicThreads != 0,
            canCreatePrivate: channel.kind == .text
                && permissions & DiscordPermissionBits.createPrivateThreads != 0
        )
    }

    var canCreateThreadInSelectedChannel: Bool {
        selectedChannelThreadCreationPermissions.canCreateAny
    }

    func beginThreadCreation() {
        let permissions = selectedChannelThreadCreationPermissions
        guard let channelID = selectedChannelID, permissions.canCreateAny else { return }
        // Like Discord, the channel's unsent text becomes the thread's first message.
        let channelDraft = draft
        closeThread()
        dismissPinnedMessages()
        threadCreation = ThreadCreationDraft(parentID: channelID, permissions: permissions)
        if !isConversationPresented(channelID) { suspendSelectedConversationPresentation() }
        if !channelDraft.isEmpty {
            translation.resetDraft(.channel)
            updateDraft("")
            threadDraft = channelDraft
        }
    }

    /// Shows required-field errors only for invalid submissions. A valid send
    /// consumes the draft while the creation pane is still visible.
    @discardableResult
    func validateThreadCreation() -> Bool {
        guard let creation = threadCreation else { return false }
        let isValid = !creation.trimmedName.isEmpty
            && (!threadDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !threadComposerAttachments.isEmpty)
        creation.showsValidationErrors = !isValid
        return isValid
    }

    /// Creates the thread, then sends the composed message as its first message.
    func submitThreadCreation(
        _ creation: ThreadCreationDraft,
        attachments: [ForumPostAttachment]
    ) async -> ComposerSubmissionResult {
        guard threadCreation === creation, !creation.isSubmitting else { return .rejected }
        let permissions = selectedChannelThreadCreationPermissions
        let content = threadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard creation.isPrivate ? permissions.canCreatePrivate : permissions.canCreatePublic,
              !creation.trimmedName.isEmpty, !content.isEmpty || !attachments.isEmpty,
              validateAttachmentCount(attachments),
              allowOnboardingSubmission(in: creation.parentID)
        else { return .rejected }
        guard let reservation = composer.outbox.reserveSubmission() else {
            composer.isSendQueueFullAlertPresented = true
            return .rejected
        }
        defer { composer.outbox.releaseSubmission(reservation) }
        let session = accountSession()
        let draft = CreateThreadDraft(
            channelID: creation.parentID,
            name: creation.trimmedName,
            isPrivate: creation.isPrivate,
            autoArchiveDuration: selectedChannel?.defaultAutoArchiveDuration ?? 4_320
        )
        translation.resetDraft(.thread)
        creation.isSubmitting = true
        defer { creation.isSubmitting = false }
        let thread: MessageThreadSummary
        do {
            thread = try await session.provider.createThread(draft)
        } catch {
            guard isCurrentAccountSession(session) else { return .rejected }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
            return .rejected
        }
        guard isCurrentAccountSession(session) else { return .rejected }
        if threadCreation === creation {
            openThreadConversation(
                thread,
                starter: currentUser,
                startedAt: thread.createdAt ?? .now,
                initialMessages: []
            )
        }
        guard let delivery = enqueueThreadMessage(
            content: content,
            attachments: attachments,
            thread: thread,
            clearsComposer: false
        ) else { return .rejected }
        return .enqueued(delivery: delivery)
    }

    func invalidateTimelineThreadPreview(channelID: ChannelID, messageID: MessageID) {
        guard threadPreviewMessages[channelID]?.id == messageID else { return }
        threadPreviewMessages[channelID] = nil
        let changed = Set(messages.filter { $0.referencedThreadID == channelID }.map(\.id))
        if !changed.isEmpty { publishMessageRowsUpdate(changedMessageIDs: changed) }
    }

    /// Keeps timeline thread cards current. A card's summary lives on its
    /// message; its latest-message preview mirrors the provider's catalogue.
    func refreshTimelineThreadCards(parentID: ChannelID, posts: [ForumPost], replacesAll: Bool = true) {
        if let updated = posts.first(where: { $0.id == openThread?.id }) {
            openThread = updated.thread
        }
        var changedPreviewThreadIDs = Set<ChannelID>()
        if replacesAll {
            let retained = Set(posts.map(\.id))
            for (threadID, parent) in threadPreviewParentIDs where parent == parentID && !retained.contains(threadID) {
                threadPreviewMessages[threadID] = nil
                threadPreviewParentIDs[threadID] = nil
                changedPreviewThreadIDs.insert(threadID)
            }
        }
        for post in posts {
            threadPreviewParentIDs[post.id] = parentID
            guard threadPreviewMessages[post.id] != post.mostRecentMessage else { continue }
            threadPreviewMessages[post.id] = post.mostRecentMessage
            changedPreviewThreadIDs.insert(post.id)
        }
        guard parentID == selectedChannelID else { return }
        let threadsByID = Dictionary(posts.map { ($0.id, $0.thread) }, uniquingKeysWith: { $1 })
        var redrawnMessageIDs = Set<MessageID>()
        for message in messages {
            guard let threadID = message.referencedThreadID else { continue }
            if let thread = threadsByID[threadID], message.thread != thread {
                var updated = message
                updated.thread = thread
                reconcileSelectedMessageUpdate(updated)
            } else if changedPreviewThreadIDs.contains(threadID) {
                redrawnMessageIDs.insert(message.id)
            }
        }
        if !redrawnMessageIDs.isEmpty {
            publishMessageRowsUpdate(changedMessageIDs: redrawnMessageIDs)
        }
    }
}
