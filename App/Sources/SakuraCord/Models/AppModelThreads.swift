import DiscordProtocol
import Foundation
import SakuraCordModels

nonisolated enum OpenThreadResolution: Equatable, Sendable {
    case pending(UUID)
    /// Terminal until the user retries or authoritative membership arrives.
    case failed
}

extension AppModel {
    /// The selected channel is the parent's live projection: a guild channel
    /// update that removes it also clears the selection and closes the thread.
    var openThreadParentChannel: Channel? {
        guard let parentID = openThread?.parentID else { return nil }
        if let selectedChannel, selectedChannelID == parentID, selectedChannel.id == parentID {
            return selectedChannel
        }
        return messagePresentationChannelsByID[parentID]
            ?? visibleChannels.first { $0.id == parentID }
    }

    var openThreadAccess: ConversationAccess {
        guard let thread = openThread else { return .checking }
        switch openThreadResolution {
        case .pending: return .checking
        case .failed: return .hidden
        case nil: break
        }
        guard let channel = openThreadParentChannel else {
            // Once the thread's guild has a channel list, a parent missing from
            // it is gone or not visible; only an unloaded list is pending.
            let hasChannelList = snapshot?.channels.contains { $0.guildID == thread.guildID } == true
            return hasChannelList ? .hidden : .checking
        }
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

    /// Messages, including cached ones, stay hidden while access is unknown
    /// or denied. Hidden content is not presented for read acknowledgements.
    var withholdsOpenThreadContent: Bool {
        openThread != nil && (openThreadResolution != nil || openThreadAccess == .hidden)
    }

    /// Directly opening another conversation supersedes any navigation in
    /// flight; navigation opens threads through `openThreadConversation`.
    func open(_ thread: MessageThreadSummary) {
        guard openThread?.id != thread.id else { return }
        cancelConversationNavigation()
        let starter = messages.first { $0.thread?.id == thread.id }
        // The thread's creator started it, who may not have written the
        // message it was started from. An unknown creator shows no credit.
        let creator: User? = if let ownerID = thread.ownerID {
            starter?.author.id == ownerID ? starter?.author
                : ownerID == currentUser?.id ? currentUser
                : membersByID[ownerID]?.user
        } else {
            starter?.author
        }
        openThreadConversation(
            thread,
            starter: creator,
            startedAt: thread.createdAt ?? starter?.timestamp,
            starterMessageID: nil,
            initialMessages: []
        )
    }

    func open(_ post: ForumPost) {
        guard openThread?.id != post.id else { return }
        cancelConversationNavigation()
        readState.merge(forumPost: post)
        openThreadConversation(
            post.thread,
            starter: post.owner ?? post.firstMessage?.author,
            startedAt: post.firstMessage?.timestamp ?? post.createdAt,
            starterMessageID: post.firstMessage?.id,
            initialMessages: post.firstMessage.map { [$0] } ?? []
        )
    }

    /// Opens a thread or forum post. With `historyTarget`, its first window
    /// is the history around that message unless the cached window already
    /// contains it; `initialMessages` that contain the target are shown
    /// while it loads. Otherwise they preview the thread start.
    func openThreadConversation(
        _ thread: MessageThreadSummary,
        starter: User?,
        startedAt: Date?,
        starterMessageID: MessageID? = nil,
        initialMessages: [Message],
        fullWidth: Bool = false,
        historyTarget: MessageID? = nil
    ) {
        openSideConversation(.thread(thread, isFullWidth: fullWidth))
        threadLoadGeneration &+= 1
        AppPerformanceSignposts.beginConversationNavigation(to: thread.id)
        readState.merge(thread: thread)
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
        threadDraft = ""
        threadReplyingTo = nil
        clearComposerAttachments(for: .thread)
        translation.resetDraft(.thread)

        if openThreadNeedsAccessResolution(thread) {
            beginOpenThreadResolution()
        }

        let cachedBoundary = hasMoreCache[thread.id]
        let cacheContainsTarget = historyTarget.map { target in
            messageCache[thread.id]?.contains { $0.id == target } == true
        } ?? true
        if let historyTarget, cachedBoundary == nil || !cacheContainsTarget {
            // The cached window is not where the reader is going. Opening
            // around the target replaces it rather than bridging the two.
            let pendingSends = discardCachedHistory(for: thread.id)
            let seeds = initialMessages.contains { $0.id == historyTarget } ? initialMessages : []
            threadMessages = Self.merging(current: pendingSends, fresh: seeds).map(withOpenThreadGuild)
            hasMoreThreadMessages = true
            hasMoreLaterThreadMessages = true
            beginInitialThreadLoad(thread, around: historyTarget)
            return
        }

        let cachedMessages = takeCachedMessages(for: thread.id)
        let previewMessages: [Message]
        if historyTarget != nil {
            previewMessages = []
        } else if cachedBoundary == true,
                  let starterMessageID,
                  !cachedMessages.contains(where: { $0.id == starterMessageID })
        {
            // The cached newest page starts after the starter. Its older edge,
            // not the forum preview, must drive earlier pagination.
            previewMessages = initialMessages.filter { $0.id != starterMessageID }
        } else {
            previewMessages = initialMessages
        }
        // A cached copy replaced by a live update may have lost the guild.
        threadMessages = Self.merging(
            current: previewMessages,
            fresh: cachedMessages
        ).map(withOpenThreadGuild)
        hasMoreThreadMessages = cachedBoundary ?? false
        hasMoreLaterThreadMessages = false
        let storedCursors = threadWindow.cachedCursors.removeValue(forKey: thread.id)
        if cachedBoundary != nil {
            // A cached window is a contiguous newest-backed REST window. The
            // cache keeps its newest messages, so a trimmed window starts
            // at its oldest retained message instead of its stored cursor.
            let confirmedIDs = cachedMessages.lazy.filter { $0.outboxState == .confirmed }.map(\.id)
            threadWindow.lowerCursor = [storedCursors?.lower, confirmedIDs.min()].compactMap(\.self).max()
            threadWindow.upperCursor = storedCursors?.upper ?? confirmedIDs.max()
        }
        if cachedBoundary == nil {
            // Nothing shown yet is loaded history that a newest page can extend.
            markHistoryContiguous(through: nil, in: thread.id)
        }
        // Gateway may not deliver every message of a closed thread, so a
        // cached window is shown immediately and always revalidated.
        beginInitialThreadLoad(thread, preservingWindow: cachedBoundary != nil)
    }

    /// Without Manage Threads a private thread is readable only to members, so
    /// a record without membership evidence, such as one built from a
    /// member-less Gateway update, must be resolved before it is shown. Public
    /// threads follow their parent's permissions and stay cache-first.
    private func openThreadNeedsAccessResolution(_ thread: MessageThreadSummary) -> Bool {
        guard thread.isPrivate, thread.notificationSettings == nil else { return false }
        guard let parent = openThreadParentChannel,
              let permissions = effectiveMessagePermissions(in: parent)
        else { return true }
        return permissions & DiscordPermissionBits.manageThreads == 0
    }

    /// The user closing the thread retires a navigation still heading to it.
    func dismissOpenThread() {
        if let threadID = openThread?.id {
            switch conversationNavigationTarget?.target {
            case .thread(threadID, _), .message(threadID, _, _):
                cancelConversationNavigation()
            default:
                break
            }
        }
        closeThread()
    }

    /// A fresh READY lists only joined active threads and the provider drops
    /// retained private ones, whose access follows membership. The open
    /// private thread READY did not list is withheld, and stops counting as
    /// viewed, while one provider lookup resolves it again. Success reopens it
    /// from the fresh record; failure is terminal until the user retries.
    func beginOpenThreadResolution() {
        guard let thread = openThread else { return }
        let token = UUID()
        openThreadResolution = .pending(token)
        _ = readState.updatePresentation(
            channelID: thread.id,
            isPresented: false,
            initialPositionEstablished: false,
            hasReachedReadBoundary: false
        )
        openThreadResolutionTask?.cancel()
        openThreadResolutionTask = startAccountChildTask(account: accountSession()) { model, account in
            do {
                let post = try await account.provider.resolveThreadAccess(threadID: thread.id)
                guard !Task.isCancelled, model.openThreadResolution == .pending(token) else { return }
                model.presentResolvedOpenThread(post.thread)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      model.isCurrentAccountSession(account),
                      model.openThreadResolution == .pending(token)
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.openThreadResolution = .failed
            }
        }
    }

    func retryOpenThreadResolution() {
        guard openThreadResolution == .failed else { return }
        beginOpenThreadResolution()
    }

    /// Resolves the same open instance in place: the composer's draft, reply,
    /// attachments and pending composition stay. The timeline is recreated
    /// when withholding ends, so it must establish its position again before
    /// anything is acknowledged, and its newest page is refreshed.
    func presentResolvedOpenThread(_ thread: MessageThreadSummary) {
        guard openThread?.id == thread.id else { return }
        openThreadResolutionTask?.cancel()
        openThreadResolutionTask = nil
        openThreadResolution = nil
        openThread = thread
        _ = readState.updatePresentation(
            channelID: thread.id,
            isPresented: isConversationPresented(thread.id),
            initialPositionEstablished: false,
            windowIsActive: mainWindowIsActive,
            hasReachedReadBoundary: false
        )
        // Messages sent while access was unknown, for example while
        // disconnected, may be missing from the loaded window. Like a Gateway
        // gap, its newest edge is unverified until a current read; an initial
        // load still in flight is that read.
        if hasCompletedInitialThreadLoad {
            markHistoryContiguous(through: threadMessages, in: thread.id)
            threadWindow.isNewestUnverified = true
            revalidateOpenThreadAfterReconnect()
        }
    }

    /// Forgets a conversation's cached window and its completeness, and
    /// returns its unconfirmed sends, which are not history.
    @discardableResult
    func discardCachedHistory(for channelID: ChannelID) -> [Message] {
        let pendingSends = messageCache[channelID]?.filter { $0.outboxState != .confirmed } ?? []
        messageCache[channelID] = nil
        messageCacheOrder.removeAll { $0 == channelID }
        messageRowCache[channelID] = nil
        messageRowCacheOrder.removeAll { $0 == channelID }
        hasMoreCache[channelID] = nil
        contiguousHistoryBoundaries[channelID] = nil
        threadWindow.cachedCursors[channelID] = nil
        return pendingSends
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
            readState.replaceActiveJoinedThreads(threads)
            if var value = snapshot {
                value.activeJoinedThreads = threads
                snapshot = value
                forwardSearchSourceRevision &+= 1
            }
            refreshUnreadPresentation()
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
        discardCachedHistory(for: channelID)
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
        noteSideConversationChange()
        threadTimelinePosition = ThreadTimelinePosition()
        threadVoiceMessageComposer.discard(playback: voiceMessagePlayback)
        threadCommandComposer.resetForChannelChange()
        if let threadID = openThread?.id {
            cancelConversationRefresh(in: threadID)
            // Only a loaded newest-backed window is reusable history; a
            // preview, an interrupted initial load or a window detached from
            // the newest message is not.
            if hasMoreCache[threadID] != nil, hasCompletedInitialThreadLoad, !hasMoreLaterThreadMessages {
                // Store the boundary before trimming so omitted older messages remain loadable.
                hasMoreCache[threadID] = hasMoreThreadMessages
                storeCachedMessages(threadMessages, for: threadID)
                threadWindow.cachedCursors[threadID] = (threadWindow.lowerCursor, threadWindow.upperCursor)
                // Gateway may not deliver a closed thread's messages, so
                // later cached arrivals do not prove the window is current.
                markHistoryContiguous(through: threadMessages, in: threadID)
            } else {
                discardCachedHistory(for: threadID)
                // Unconfirmed sends, including failed ones awaiting Retry or
                // Discard, return with the thread; its history is reloaded.
                let pendingSends = threadMessages.filter { $0.outboxState != .confirmed }
                if !pendingSends.isEmpty {
                    storeCachedMessages(pendingSends, for: threadID)
                    markHistoryContiguous(through: nil, in: threadID)
                }
            }
            unreadDividerMessageIDs[threadID] = nil
            if conversationNewestRequest?.channelID == threadID {
                conversationNewestRequest = nil
            }
            _ = readState.updatePresentation(channelID: threadID, isPresented: false)
        }
        threadLoadTask?.cancel()
        threadLoadTask = nil
        threadLoadGeneration &+= 1
        threadWindow.activeRevision = nil
        threadWindow.revalidationPending = false
        threadWindow.lowerCursor = nil
        threadWindow.upperCursor = nil
        threadWindow.isNewestUnverified = false
        threadWindow.failedInitialTarget = nil
        threadWindow.initialLoadTarget = nil
        threadWindow.newestReadRevision = nil
        openThreadResolutionTask?.cancel()
        openThreadResolutionTask = nil
        openThreadResolution = nil
        sideConversations.thread = nil
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
        isLoadingLaterThread = false
        hasMoreThreadMessages = false
        hasMoreLaterThreadMessages = false
        threadErrorMessage = nil
        threadErrorScope = nil
    }

    /// Selecting a voice channel opens its chat; this reopens a closed one.
    func openVoiceChat(for channel: Channel) {
        guard channel.kind == .voice else { return }
        if selectedChannelID != channel.id {
            selectedChannelID = channel.id
        }
        // Guild pages cannot show the chat.
        guard selectedChannelID == channel.id, guildWorkspacePage == nil, !isVoiceChatOpen else { return }
        openSideConversation(.voiceChat(channel.id))
        beginSelectedChannelLoad()
    }

    func closeVoiceChat() {
        guard isVoiceChatOpen else { return }
        WorkspaceLayoutMotion.perform(closeSideConversations)
    }

    func retryThreadLoad() {
        guard let thread = openThread else { return }
        switch threadErrorScope {
        case .initialPage:
            if let target = threadWindow.failedInitialTarget {
                retryThreadJump(thread, to: target)
            } else {
                beginInitialThreadLoad(thread, preservingWindow: hasMoreCache[thread.id] != nil)
            }
        case .earlierPage:
            // Without an edge to continue from, the error stays.
            guard hasMoreThreadMessages, threadWindow.lowerCursor != nil, !isLoadingEarlierThread else { return }
            retryThreadHistory { model, account in await model.loadEarlierThread(account: account) }
        case .laterPage:
            guard hasMoreLaterThreadMessages, threadWindow.upperCursor != nil, !isLoadingLaterThread else { return }
            retryThreadHistory { model, account in await model.loadLaterThread(account: account) }
        case .newestWindow:
            guard !isLoadingThread else { return }
            retryThreadHistory { model, account in _ = await model.loadNewestThreadWindow(account: account) }
        case .action, nil:
            return
        }
    }

    /// Reloads the window around a jump target and scrolls to it, unless a
    /// later intent takes over the window first.
    private func retryThreadJump(_ thread: MessageThreadSummary, to target: MessageID) {
        beginInitialThreadLoad(thread, around: target)
        let windowRevision = threadWindow.revision
        let load = threadLoadTask
        startAccountChildTask(account: accountSession()) { model, _ in
            await load?.value
            guard model.openThread?.id == thread.id, model.threadWindow.revision == windowRevision,
                  model.threadMessages.contains(where: { $0.id == target })
            else { return }
            model.messageNavigationRequestID &+= 1
            model.messageNavigationRequest = MessageNavigationRequest(
                requestID: model.messageNavigationRequestID,
                channelID: thread.id,
                messageID: target,
                glides: false
            )
        }
    }

    private func retryThreadHistory(
        _ operation: @escaping @MainActor (AppModel, AppModelAccountSession) async -> Void
    ) {
        threadErrorMessage = nil
        threadErrorScope = nil
        startAccountChildTask(account: accountSession(), operation: operation)
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
        // Capture the submission before any await; the composer stays
        // editable while a detached window returns to the newest messages.
        let content = threadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = threadReplyingTo
        let mentionsRepliedUser = threadReplyMentionsAuthor
        let draftRevision = composer.threadDraftRevision
        guard !content.isEmpty || !attachments.isEmpty else { return .rejected }
        var clearsComposer = true
        var destination = thread
        if isThreadWindowAwayFromNewest {
            // Like the channel composer, a send returns to the newest messages.
            let session = accountSession()
            let generation = threadLoadGeneration
            guard await loadNewestThreadWindow(account: session),
                  isCurrentAccountSession(session),
                  ownsThreadLoad(thread.id, generation: generation),
                  !isThreadWindowAwayFromNewest,
                  let current = openThread, openThreadAccess.canSend
            else { return .rejected }
            destination = current
            // Keep edits made while the newest messages loaded.
            clearsComposer = composer.threadDraftRevision == draftRevision && threadReplyingTo?.id == reply?.id
        }
        guard allowSlowmodeSubmission(in: destination.id) else { return .rejected }
        guard validateAttachmentCount(attachments), allowOutgoingQueueSubmission() else { return .rejected }
        guard let delivery = enqueueThreadMessage(
            content: content,
            replyTo: reply?.id,
            mentionsRepliedUser: mentionsRepliedUser,
            replyPreview: reply.map(MessageReplyPreview.init),
            attachments: attachments,
            thread: destination,
            clearsComposer: clearsComposer
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
        guard guildTimeoutUntil(in: thread.id, guildID: thread.guildID) == nil,
              allowOnboardingSubmission(in: thread.id), allowSlowmodeSubmission(in: thread.id) else { return nil }
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
              let permissions = selectedEffectivePermissions
        else { return ThreadCreationPermissions(canCreatePublic: false, canCreatePrivate: false) }
        return ThreadActionPolicy.creationPermissions(parentKind: channel.kind, permissions: permissions)
    }

    var canCreateThreadInSelectedChannel: Bool {
        selectedChannelThreadCreationPermissions.canCreateAny
    }

    func beginThreadCreation() {
        let permissions = selectedChannelThreadCreationPermissions
        guard let channelID = selectedChannelID, permissions.canCreateAny else { return }
        // Like Discord, the channel's unsent text becomes the thread's first message.
        let channelDraft = draft
        openSideConversation(.threadCreation(ThreadCreationDraft(parentID: channelID, permissions: permissions)))
        dismissPinnedMessages()
        if !isConversationPresented(channelID) { suspendSelectedConversationPresentation() }
        if !channelDraft.isEmpty {
            translation.resetDraft(.channel)
            updateDraft("")
            threadDraft = channelDraft
        }
    }

    /// Starting a public thread from a confirmed message posted directly in
    /// the selected text or announcement channel, as ThreadActionPolicy allows.
    func canCreateThread(from message: Message) -> Bool {
        guard message.channelID == selectedChannelID, let channel = selectedChannel,
              conversationAccess(for: channel).isReadable,
              let permissions = effectiveMessagePermissions(in: channel)
        else { return false }
        return ThreadActionPolicy.canCreateThread(from: message, in: channel, permissions: permissions)
    }

    /// A starter message's text as readers see it, with mentions named.
    func readableThreadStarterContent(_ message: Message) -> String {
        let names = mentionNames
        return ThreadNamePolicy.readableContent(of: message, channelNames: names.channels, roleNames: names.roles)
    }

    private var mentionNames: (channels: [ChannelID: String], roles: [RoleID: String]) {
        (
            messagePresentationChannelsByID.mapValues(\.name),
            Dictionary(guildRoles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// The message context menu's Create Thread: the creation side chat with
    /// the starter message, an optional name and a required first message.
    func beginThreadCreation(from message: Message) {
        guard canCreateThread(from: message) else { return }
        let names = mentionNames
        let defaultName = ThreadNamePolicy.defaultName(
            for: message, channelNames: names.channels, roleNames: names.roles
        )
        openSideConversation(.threadCreation(ThreadCreationDraft(startingFrom: message, defaultName: defaultName)))
        dismissPinnedMessages()
        if !isConversationPresented(message.channelID) { suspendSelectedConversationPresentation() }
    }

    /// Shows required-field errors only for invalid submissions. A valid send
    /// consumes the draft while the creation pane is still visible.
    @discardableResult
    func validateThreadCreation() -> Bool {
        guard let creation = threadCreation else { return false }
        let isValid = creation.nameToCreate != nil
            && (!threadDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !threadComposerAttachments.isEmpty)
        creation.showsValidationErrors = !isValid
        return isValid
    }

    /// Creates the thread, then sends the composed message as its first
    /// message, as the first-party client does. A failed creation keeps the
    /// draft with Discord's reason; once the thread exists it opens, and a
    /// failed first message stays in its outbox for retry instead of creating
    /// another thread.
    func submitThreadCreation(
        _ creation: ThreadCreationDraft,
        attachments: [ForumPostAttachment]
    ) async -> ComposerSubmissionResult {
        guard threadCreation === creation, !creation.isSubmitting else { return .rejected }
        let originalDraft = threadDraft
        let content = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAllowed: Bool = if let starter = creation.starterMessage {
            canCreateThread(from: starter)
        } else {
            creation.isPrivate
                ? selectedChannelThreadCreationPermissions.canCreatePrivate
                : selectedChannelThreadCreationPermissions.canCreatePublic
        }
        guard isAllowed, let name = creation.nameToCreate, !content.isEmpty || !attachments.isEmpty,
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
            name: name,
            isPrivate: creation.isPrivate,
            autoArchiveDuration: selectedChannel?.defaultAutoArchiveDuration ?? 4_320,
            starterMessageID: creation.starterMessage?.id
        )
        translation.resetDraft(.thread)
        creation.isSubmitting = true
        creation.submissionError = nil
        defer { creation.isSubmitting = false }
        let thread: MessageThreadSummary
        do {
            thread = try await session.provider.createThread(draft)
        } catch {
            guard isCurrentAccountSession(session) else { return .rejected }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            creation.submissionError = error is CancellationError
                ? "The thread was not created. Try again."
                : error.localizedDescription
            return .rejected
        }
        guard isCurrentAccountSession(session) else { return .rejected }
        let presentsCreatedThread = threadCreation === creation
        if presentsCreatedThread {
            openThreadConversation(
                thread,
                // The creator started the thread; the source message's author
                // appears only in its quoted starter.
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
        ) else {
            if presentsCreatedThread, openThread?.id == thread.id,
               guildTimeoutUntil(in: thread.id, guildID: thread.guildID) != nil {
                // Creation can succeed before a live timeout blocks its first
                // message. Keep that unsent message in the created thread.
                threadDraft = originalDraft
                restoreComposerAttachments(attachments, to: .thread)
            }
            return .rejected
        }
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
            if openThreadResolution != nil, updated.thread.notificationSettings != nil {
                // A Gateway record carrying the current user's member settles
                // access before, or instead of, the pending lookup.
                presentResolvedOpenThread(updated.thread)
            } else {
                openThread = updated.thread
            }
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
            // Catalogue previews omit the guild, which server-only system
            // message copy such as a rename depends on.
            var preview = post.mostRecentMessage
            if preview?.guildID == nil {
                preview?.guildID = post.thread.guildID
                    ?? post.thread.parentID.flatMap(messagePresentationChannel)?.guildID
            }
            guard threadPreviewMessages[post.id] != preview else { continue }
            threadPreviewMessages[post.id] = preview
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

extension AppModel {
    /// A thread's type-21 starter row quotes the parent message it started
    /// from. Keep the open thread's and cached threads' quotes in step with
    /// edits to that message; a deleted message leaves the quote unavailable.
    func refreshThreadStarterQuotes(messageID: MessageID, with message: Message?) {
        let preview = message.map(MessageReplyPreview.init(message:))
        updateThreadStarterQuotes(quoting: messageID) { _ in preview }
    }

    /// Refreshes starter quotes after a partial edit. When the original
    /// message is no longer retained, only the patch's content is known.
    func refreshThreadStarterQuotes(after update: MessageUpdate, patched: Message?) {
        if let patched {
            refreshThreadStarterQuotes(messageID: patched.id, with: patched)
            return
        }
        guard let content = update.content else { return }
        updateThreadStarterQuotes(quoting: update.messageID) { preview in
            guard var preview else { return nil }
            preview.content = content
            return preview
        }
    }

    private func updateThreadStarterQuotes(
        quoting messageID: MessageID,
        _ transform: (MessageReplyPreview?) -> MessageReplyPreview?
    ) {
        func isQuote(_ candidate: Message) -> Bool {
            candidate.type == .threadStarter && candidate.messageReference?.messageID == messageID
        }
        if let index = threadMessages.firstIndex(where: isQuote) {
            let preview = transform(threadMessages[index].replyPreview)
            if preview != threadMessages[index].replyPreview {
                threadMessages[index].replyPreview = preview
            }
        }
        for (channelID, cached) in messageCache {
            guard let index = cached.firstIndex(where: isQuote) else { continue }
            let preview = transform(cached[index].replyPreview)
            guard preview != cached[index].replyPreview else { continue }
            messageCache[channelID]?[index].replyPreview = preview
            messageRowCache[channelID] = nil
            messageRowCacheOrder.removeAll { $0 == channelID }
        }
    }
}
