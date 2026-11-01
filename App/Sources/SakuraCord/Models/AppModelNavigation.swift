import DiscordProtocol
import Foundation
import SakuraCordModels

/// The Direct Messages home destinations: Friends above every conversation.
nonisolated enum DirectMessageSidebarSelection: Hashable, Sendable {
    case friends
    case messageRequests
    case channel(ChannelID)
}

/// Marks work performed by a conversation navigation's own task, including the
/// tasks it starts, so its presentation changes do not count as user changes.
nonisolated enum ConversationNavigationContext {
    @TaskLocal static var isActive = false
}

nonisolated struct PendingConversationNavigation: Sendable {
    let id: UUID
    let target: ConversationNavigationTarget
    let sideConversationRevision: UInt64
}

/// The destination of an asynchronous conversation navigation. Repeating the
/// in-flight destination is redundant; any other destination supersedes it.
nonisolated enum ConversationNavigationTarget: Hashable, Sendable {
    case channel(ChannelID)
    case thread(ChannelID, fullWidth: Bool)
    case message(ChannelID, MessageID, fullWidthThread: Bool)
}

extension AppModel {
    func selectGuild(_ guildID: GuildID?) {
        startConversationNavigation { model, account in
            await model.activateGuild(guildID, account: account)
        }
    }

    func recordConversationNavigation() {
        if let channel = navigationChannel {
            conversationNavigationHistory.record(channel)
        }
    }

    private var navigationChannel: Channel? {
        if isThreadFullWidth, let openThread { return threadNavigationChannel(openThread) }
        return snapshot?.channels.first { $0.id == selectedChannelID }
            ?? visibleChannels.first { $0.id == selectedChannelID }
    }

    // Sidebar choices supersede asynchronous navigation to another destination
    // immediately; re-selecting the in-flight destination leaves it running.
    var channelSidebarSelection: ChannelID? {
        get { guildWorkspacePage == nil ? selectedChannelID : nil }
        set {
            onboarding.presentedGuildID = nil
            if let newValue, isNavigating(to: .channel(newValue)) { return }
            cancelConversationNavigation()
            selectedChannelID = newValue
            recordConversationNavigation()
        }
    }

    func cancelConversationNavigation() {
        guildActivationTask?.cancel()
        guildActivationTask = nil
        conversationNavigationTarget = nil
        conversationNavigationHistory.cancelNavigation()
    }

    /// A repeated destination is a duplicate only while nothing else replaced
    /// the side conversation or guild page since its navigation started.
    func isNavigating(to target: ConversationNavigationTarget) -> Bool {
        guard let pending = conversationNavigationTarget else { return false }
        return pending.target == target
            && pending.sideConversationRevision == sideConversationRevision
    }

    func noteSideConversationChange() {
        guard !ConversationNavigationContext.isActive else { return }
        sideConversationRevision &+= 1
    }

    func startConversationNavigation(
        target: ConversationNavigationTarget? = nil,
        to destination: ConversationNavigationHistory.Destination? = nil,
        operation: @escaping @MainActor (AppModel, AppModelAccountSession) async -> Void
    ) {
        cancelConversationNavigation()
        let account = accountSession()
        let task = startAccountChildTask(account: account) { model, account in
            // A task cancelled before it starts never opens a history transaction.
            let navigation = model.conversationNavigationHistory.beginNavigation(to: destination)
            defer {
                let channel = !Task.isCancelled && model.isCurrentAccountSession(account)
                    ? model.navigationChannel : nil
                model.conversationNavigationHistory.finishNavigation(navigation, at: channel)
            }
            await ConversationNavigationContext.$isActive.withValue(true) {
                await operation(model, account)
            }
        }
        guildActivationTask = task
        guard let target else { return }
        let navigationID = UUID()
        conversationNavigationTarget = PendingConversationNavigation(
            id: navigationID, target: target, sideConversationRevision: sideConversationRevision
        )
        // The operation may never run after an account change, so completion
        // of the task itself retires its destination.
        Task { @MainActor [weak self] in
            await task.value
            if self?.conversationNavigationTarget?.id == navigationID {
                self?.conversationNavigationTarget = nil
            }
        }
    }

    func navigationDestination(for shortcutNumber: Int) -> ServerRailNavigationDestination? {
        guard (1 ... 9).contains(shortcutNumber) else { return nil }
        if shortcutNumber == 1 {
            return .directMessages
        }

        let visibleGuildIDs = orderedNavigationGuildIDs
        let guildIndex = shortcutNumber - 2
        guard visibleGuildIDs.indices.contains(guildIndex) else { return nil }
        return .guild(visibleGuildIDs[guildIndex])
    }

    func navigateUsingShortcut(_ shortcutNumber: Int) {
        switch navigationDestination(for: shortcutNumber) {
        case .directMessages:
            selectGuild(nil)
        case .guild(let guildID):
            selectGuild(guildID)
        case nil:
            break
        }
    }

    func rebuildMemberSections() {
        memberSections = AppPerformanceSignposts.measureSync(
            "MemberSectionBuild"
        ) {
            MemberSection.make(
                from: members,
                groups: memberListGroups,
                roles: guildRoles
            )
        }
    }

    func updateMemberListViewport(_ visibleRange: ClosedRange<Int>) {
        guard !isThreadFullWidth || openThreadParentChannel?.kind == .announcement else { return }
        guard let guildID = selectedGuildID,
              let channelID = selectedChannelID
        else { return }
        lastMemberListVisibleRange = visibleRange
        let session = accountSession()
        let request = MemberListViewportRequest(
            guildID: guildID,
            channelID: channelID,
            visibleRange: visibleRange
        )
        memberListViewportRequest = request
        submitMemberListViewport(request, account: session)
    }

    func submitMemberListViewport(
        _ request: MemberListViewportRequest,
        account session: AppModelAccountSession
    ) {
        Task { [weak self] in
            guard let self,
                  isCurrentAccountSession(session),
                  memberListViewportRequest == request,
                  selectedGuildID == request.guildID,
                  selectedChannelID == request.channelID
            else { return }
            do {
                try await session.provider.updateMemberListViewport(
                    in: request.guildID,
                    channelID: request.channelID,
                    visibleRange: request.visibleRange
                )
            } catch {
                guard isCurrentAccountSession(session) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                AppModel.memberListLogger.debug(
                    "Member-list viewport subscription failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func replayMemberListViewportIfNeeded(
        for guildID: GuildID,
        account session: AppModelAccountSession
    ) async {
        guard let channelID = selectedChannelID,
              isCurrentAccountSession(session)
        else { return }
        // An empty cold member list has no native row from which the canvas can
        // derive a viewport. Seed the first Gateway block after members(in:)
        // arms the subscription; subsequent reports replace this with the real
        // visible range.
        let visibleRange = lastMemberListVisibleRange ?? 0 ... 0
        let request = MemberListViewportRequest(
            guildID: guildID,
            channelID: channelID,
            visibleRange: visibleRange
        )
        memberListViewportRequest = request
        do {
            try await session.provider.updateMemberListViewport(
                in: request.guildID,
                channelID: request.channelID,
                visibleRange: request.visibleRange
            )
        } catch {
            guard isCurrentAccountSession(session) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            AppModel.memberListLogger.debug(
                "Member-list viewport replay failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func mergedMemberStore(with updates: [Member]) -> [UserID: Member] {
        guard let guildID = selectedGuildID else {
            return Dictionary(
                updates.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
        }
        let merged = MemberStoreMerge.merging(
            existing: membersByGuildID[guildID] ?? [:],
            updates: updates
        )
        membersByGuildID[guildID] = merged
        return merged
    }

    func applyGuildRoles(_ roles: [GuildRole], to guildID: GuildID) {
        // Every guild has at least @everyone. An empty result is incomplete
        // state, so retain the last Gateway/REST catalog like Paicord's
        // per-guild role store instead of blanking every message author.
        guard !roles.isEmpty else { return }
        guard guildRolesByGuildID[guildID] != roles else { return }
        guildRolesByGuildID[guildID] = roles
        guard selectedGuildID == guildID else { return }
        guildRoles = roles
        refreshUnreadPresentation(
            appliesAccessImmediately: true,
            accessAffectedGuildIDs: [guildID]
        )
    }

    var directMessageInspectorSections: [MemberSection] {
        guard let channel = selectedChannel, channel.guildID == nil else {
            return memberSections
        }
        return MemberSection.make(
            from: DirectMessageMemberResolver.members(
                for: channel,
                knownMembers: members,
                currentUser: currentUser,
                currentStatus: currentStatus
            )
        )
    }

    func knownRootChannel(_ channelID: ChannelID) -> Channel? {
        snapshot?.channels.first(where: { $0.id == channelID })
            ?? visibleChannels.first(where: { $0.id == channelID })
    }

    func navigate(
        to channelID: ChannelID,
        historyDestination: ConversationNavigationHistory.Destination? = nil
    ) {
        onboarding.presentedGuildID = nil
        if let thread = sidebarThread(channelID) {
            openSidebarThread(thread, historyDestination: historyDestination)
            return
        }
        guard let channel = knownRootChannel(channelID) else {
            // A mention or history entry can name a thread the sidebar does
            // not list; resolve it through the provider like a channel link.
            navigate(
                to: selectedGuildID,
                linkedChannelID: channelID,
                fullWidthThread: true,
                historyDestination: historyDestination
            )
            return
        }
        let target = ConversationNavigationTarget.channel(channel.id)
        if historyDestination == nil, isNavigating(to: target) { return }
        startConversationNavigation(target: target, to: historyDestination) { model, account in
            if model.selectedGuildID != channel.guildID {
                await model.activateGuild(channel.guildID, account: account)
            }
            guard !Task.isCancelled,
                  model.isCurrentAccountSession(account)
            else { return }
            model.recordForwardDestinationVisit(channel.id)
            model.closeThread()
            model.selectedChannelID = channel.id
        }
    }

    func navigate(
        to guildID: GuildID?,
        linkedChannelID channelID: ChannelID,
        messageID: MessageID? = nil,
        initialMessages: [Message] = [],
        fullWidthThread: Bool = false,
        historyDestination: ConversationNavigationHistory.Destination? = nil
    ) {
        if messageID == nil, knownRootChannel(channelID) != nil {
            navigate(to: channelID, historyDestination: historyDestination)
            return
        }
        let target: ConversationNavigationTarget = messageID.map {
            .message(channelID, $0, fullWidthThread: fullWidthThread)
        } ?? .thread(channelID, fullWidth: fullWidthThread)
        if historyDestination == nil, isNavigating(to: target) { return }
        startConversationNavigation(target: target, to: historyDestination) { model, session in
            if model.selectedGuildID != guildID {
                await model.activateGuild(guildID, account: session)
            }
            guard !Task.isCancelled, model.isCurrentAccountSession(session) else { return }
            if messageID == nil, let channel = model.knownRootChannel(channelID) {
                model.selectedChannelID = channel.id
                return
            }
            await model.openThreadDestination(
                channelID,
                guildID: guildID,
                messageID: messageID,
                initialMessages: initialMessages,
                fullWidth: fullWidthThread,
                session: session
            )
        }
    }

    /// Resolves a thread or forum post that may be unknown to every local
    /// projection through the provider (its cache, else one Get Channel),
    /// selects its parent and opens it. Failures are user-visible.
    private func openThreadDestination(
        _ channelID: ChannelID,
        guildID: GuildID?,
        messageID: MessageID?,
        initialMessages: [Message],
        fullWidth: Bool,
        session: AppModelAccountSession
    ) async {
        let post: ForumPost
        do {
            post = if let knownPost = forumCataloguePosts.first(where: { $0.id == channelID })
                ?? forumPosts.first(where: { $0.id == channelID })
            {
                knownPost
            } else {
                try await session.provider.forumPost(threadID: channelID)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  isCurrentAccountSession(session)
            else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = Self.threadResolutionErrorMessage(error)
            return
        }
        guard !Task.isCancelled, isCurrentAccountSession(session) else { return }

        // The parent's guild is authoritative; a link or message can omit it.
        let parentGuildID = post.thread.parentID.flatMap { knownRootChannel($0)?.guildID }
        let targetGuildID = parentGuildID ?? post.thread.guildID ?? guildID
        if selectedGuildID != targetGuildID {
            await activateGuild(targetGuildID, account: session)
        }
        guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
        guard let parentID = post.thread.parentID,
              let parent = knownRootChannel(parentID)
        else {
            errorMessage = "That thread's parent channel has not been discovered yet."
            return
        }
        if selectedChannelID != parent.id {
            selectedChannelID = parent.id
        }
        await channelLoadTask?.value
        guard !Task.isCancelled,
              isCurrentAccountSession(session),
              selectedChannelID == parent.id
        else { return }
        if parent.kind == .forum {
            mergeForumCatalogue([post])
            applyForumPresentation()
        }
        await openLinkedThread(
            post,
            initialMessages: initialMessages,
            messageID: messageID,
            fullWidth: fullWidth,
            session: session
        )
    }

    nonisolated static func threadResolutionErrorMessage(_ error: any Error) -> String {
        switch error as? ChatProviderError {
        case .channelNotFound, .transport(status: 404, _):
            "This thread doesn’t exist or was deleted."
        case .transport(status: 403, _):
            "You don’t have access to this thread."
        default:
            error.localizedDescription
        }
    }

    private func openLinkedThread(
        _ post: ForumPost,
        initialMessages: [Message],
        messageID: MessageID?,
        fullWidth: Bool,
        session: AppModelAccountSession
    ) async {
        let wasShowingMessage = openThread?.id == post.id
            && threadMessages.contains(where: { $0.id == messageID })
        // Search keeps the results beside the destination conversation, so
        // establish the thread's primary-pane presentation before loading it.
        if !initialMessages.isEmpty || openThread?.id != post.id {
            readState.merge(forumPost: post)
            openThreadConversation(
                post.thread,
                starter: post.owner ?? post.firstMessage?.author,
                startedAt: post.firstMessage?.timestamp ?? post.createdAt,
                starterMessageID: post.firstMessage?.id,
                initialMessages: initialMessages.isEmpty
                    ? post.firstMessage.map { [$0] } ?? [] : initialMessages,
                fullWidth: fullWidth,
                historyTarget: messageID
            )
        } else if fullWidth {
            presentOpenThreadFullWidth()
        }
        guard let messageID else { return }
        let generation = threadLoadGeneration
        let windowRevision = threadWindow.revision
        // Whether the thread's first window is already the target's.
        let initialLoadReadsTarget = threadWindow.initialLoadTarget == messageID
        await threadLoadTask?.value
        // A later jump or return to the newest messages owns the window now.
        guard isCurrentAccountSession(session),
              isCurrentThreadLoad(post.id, generation: generation),
              threadWindow.revision == windowRevision
        else { return }
        // A failed read around the target keeps it for an explicit Retry
        // instead of repeating the read.
        if initialLoadReadsTarget, threadWindow.failedInitialTarget == messageID { return }
        if !initialLoadReadsTarget, !threadMessages.contains(where: { $0.id == messageID }) {
            // Present the target's own window; it pages toward the newest
            // message instead of being joined to unrelated history.
            guard await loadThreadWindow(around: messageID, session: session) else { return }
        }
        guard threadMessages.contains(where: { $0.id == messageID }) else {
            errorMessage = "That message could not be found in the linked thread."
            return
        }
        messageNavigationRequestID &+= 1
        messageNavigationRequest = MessageNavigationRequest(
            requestID: messageNavigationRequestID,
            channelID: post.id,
            messageID: messageID,
            glides: wasShowingMessage
        )
    }

    func navigate(
        to guildID: GuildID?,
        channelID: ChannelID,
        messageID: MessageID
    ) {
        let target = ConversationNavigationTarget.message(
            channelID, messageID, fullWidthThread: false
        )
        if isNavigating(to: target) { return }
        startConversationNavigation(target: target) { [weak self] _, session in
            guard let self else { return }
            if selectedGuildID != guildID {
                // The server may reopen at this very channel; that selection
                // then reads only the window around the target.
                pendingChannelJumpTarget = (channelID, messageID)
                await activateGuild(guildID, account: session)
                pendingChannelJumpTarget = nil
            }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            guard let channel = knownRootChannel(channelID) else {
                // Not a known root channel: the message may be in a thread
                // that no local projection has discovered yet.
                await openThreadDestination(
                    channelID,
                    guildID: guildID,
                    messageID: messageID,
                    initialMessages: [],
                    fullWidth: false,
                    session: session
                )
                return
            }
            let wasShowingMessage = !isThreadFullWidth && selectedChannelID == channel.id
                && messages.contains(where: { $0.id == messageID })
            closeThread()
            if selectedChannelID != channel.id {
                pendingChannelJumpTarget = (channel.id, messageID)
                selectedChannelID = channel.id
            }
            pendingChannelJumpTarget = nil
            await channelLoadTask?.value
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == channel.id
            else { return }

            if !messages.contains(where: { $0.id == messageID }) {
                guard await loadSelectedMessageWindow(
                    around: messageID,
                    channelID: channel.id,
                    session: session
                ) else { return }
            }

            guard isCurrentAccountSession(session),
                  messages.contains(where: { $0.id == messageID })
            else {
                guard isCurrentAccountSession(session) else { return }
                errorMessage = "That message could not be found in the linked channel."
                return
            }
            messageNavigationRequestID &+= 1
            messageNavigationRequest = MessageNavigationRequest(
                requestID: messageNavigationRequestID,
                channelID: channel.id,
                messageID: messageID,
                glides: wasShowingMessage
            )
        }
    }

    /// Replaces the selected channel's window with one `around` a message.
    /// Returns false when the selection changed or the read failed.
    func loadSelectedMessageWindow(
        around messageID: MessageID,
        channelID: ChannelID,
        session: AppModelAccountSession
    ) async -> Bool {
        // Gateway edits and deletions that land while the read is in flight
        // are replayed onto its older response.
        let refreshRevision = beginScopedConversationRefresh(in: channelID)
        defer { endScopedConversationRefresh(refreshRevision) }
        do {
            let page = try await session.provider.messages(
                in: channelID,
                anchoredAt: .around(messageID),
                limit: DiscordHistoryFetchLimit.aroundLimit
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == channelID
            else { return false }
            // Unconfirmed sends keep their rows, including failed ones
            // awaiting Retry or Discard, whichever window is presented.
            replaceSelectedMessages(with: Self.merging(
                current: messages.filter { $0.outboxState != .confirmed },
                fresh: Self.applyingConversationRefreshMutations(
                    scopedConversationRefreshMutations(refreshRevision),
                    to: page.messages,
                    within: MessageHistorySpan(page: page)
                )
            ))
            hasMoreMessages = page.hasMoreBefore
            hasMoreLaterMessages = page.hasMoreAfter
            hasMoreCache[channelID] = page.hasMoreBefore
            contiguousHistoryBoundaries[channelID] = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentAccountSession(session),
                  selectedChannelID == channelID
            else { return false }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
            return false
        }
    }

    func navigate(from notification: NotificationDeepLink) async {
        if readState.accountID != notification.accountID {
            let handles = try? await credentialStore.handles()
            if let handles {
                rememberCredentialHandles(handles)
            }
            guard let handle = handles?.first(where: { $0.accountID == notification.accountID }) else {
                errorMessage = "The account for this notification is no longer available."
                return
            }
            guard await connectAuthenticatedAccount(handle) else { return }
        }
        if let messageID = notification.messageID {
            navigate(
                to: notification.guildID,
                channelID: notification.channelID,
                messageID: messageID
            )
        } else {
            navigate(
                to: notification.guildID,
                linkedChannelID: notification.channelID
            )
        }
    }

    func completeMessageNavigation(requestID: UInt64) {
        guard messageNavigationRequest?.requestID == requestID else { return }
        messageNavigationRequest = nil
    }

    func completeConversationNewestRequest(requestID: UInt64) {
        guard conversationNewestRequest?.requestID == requestID else { return }
        conversationNewestRequest = nil
    }

    func activateGuild(
        _ guildID: GuildID?,
        account: AppModelAccountSession? = nil
    ) async {
        let session = account ?? accountSession()
        guard !Task.isCancelled,
              isCurrentAccountSession(session)
        else { return }
        AppPerformanceSignposts.beginGuildActivationWork()
        let activationSignpost = AppPerformanceSignposts.signposter.beginInterval(
            "GuildActivation"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "GuildActivation",
                activationSignpost
            )
            AppPerformanceSignposts.endGuildActivationWork()
        }
        // Snapshot this before changing the selected guild. A synchronous
        // workspace projection may select that guild's first channel while
        // activation is in flight, which must not replace the user's memory.
        let rememberedDirectMessage = lastDirectMessageSelection
        let rememberedChannelID: ChannelID? = if let guildID {
            lastOpenedChannelIDsByGuild[guildID]
        } else if case .channel(let channelID) = rememberedDirectMessage {
            channelID
        } else { nil }
        let keepsFriends = guildID == nil && (rememberedDirectMessage == .friends || friends.isPresented)
        dismissAllProfiles()
        // Friends stays the Direct Messages home; clear the server channel
        // first so automatic reselection does not replace it.
        if keepsFriends { selectedChannelID = nil }
        if guildID == nil { friends.isPresented = keepsFriends }
        selectedGuildID = guildID
        refreshSelectedGuildOnboarding()
        beginCurrentUserProfilePrefetch(in: guildID, account: session)
        AppPerformanceSignposts.measureSync(
            "GuildActivationMemberPresentationRestore"
        ) {
            restoreMemberPresentation(for: guildID)
        }
        mentionAutocompleteMembers = []
        var channels =
            snapshot?.channels.filter { channel in
                guildID == nil ? channel.guildID == nil : channel.guildID == guildID
            } ?? []
        visibleChannels = channels
        if channels.isEmpty {
            do {
                channels = try await session.provider.channels(in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      selectedGuildID == guildID
                else { return }
                if var value = snapshot {
                    value.channels.removeAll { $0.guildID == guildID }
                    value.channels.append(contentsOf: channels)
                    snapshot = value
                }
                visibleChannels = channels
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                errorMessage = error.localizedDescription
            }
        }
        guard !Task.isCancelled,
              isCurrentAccountSession(session),
              selectedGuildID == guildID
        else { return }
        if let guildID {
            refreshUnreadPresentation(
                appliesAccessImmediately: true,
                accessAffectedGuildIDs: [guildID]
            )
        }
        if launchMode == .offlineTesting, let guildID {
            await loadEmojis(for: guildID)
            guard isCurrentAccountSession(session) else { return }
        }
        restoreGuildChannelSelection(guildID: guildID, rememberedChannelID: rememberedChannelID, keepsFriends: keepsFriends)
        beginMemberLoad(for: guildID)
    }

    private func restoreGuildChannelSelection(guildID: GuildID?, rememberedChannelID: ChannelID?, keepsFriends: Bool) {
        let permissionBasis = guildID.flatMap {
            conversationPermissionBasis(for: $0)
        }
        let selectableChannels = AppPerformanceSignposts.measureSync(
            "GuildActivationChannelSelection"
        ) {
            visibleChannels.filter {
                conversationAccess(
                    for: $0,
                    permissionBasis: permissionBasis
                ) != .hidden
            }
        }
        // A previewed message request opens only when chosen again.
        let restoredChannelID = rememberedChannelID.flatMap { rememberedID in
            selectableChannels.contains(where: { $0.id == rememberedID && $0.messageRequest == nil })
                ? rememberedID
                : nil
        }
        if keepsFriends {
            friends.isPresented = true
            selectedChannelID = nil
            lastDirectMessageSelection = .friends
        }
        if !keepsFriends, restoredChannelID != nil || !visibleChannels.contains(where: { $0.id == selectedChannelID }) {
            let preferredChannelID = restoredChannelID
                ?? Self.preferredInitialChannelID(in: selectableChannels)
            pendingAutomaticChannelAccessID = preferredChannelID.flatMap { id in
                selectableChannels.first(where: { $0.id == id }).flatMap { channel in
                    conversationAccess(
                        for: channel,
                        permissionBasis: permissionBasis
                    ) == .checking ? id : nil
                }
            }
            selectedChannelID = preferredChannelID
            if guildID == nil, preferredChannelID == nil {
                friends.isPresented = true
                lastDirectMessageSelection = .friends
            }
        }
    }

    func restoreMemberPresentation(for guildID: GuildID?) {
        let restoredGroups = guildID.flatMap { memberListGroupsByGuildID[$0] } ?? []
        let restoredRoles = guildID.flatMap { guildRolesByGuildID[$0] } ?? []
        let restoredMembersByID = (guildID.flatMap { membersByGuildID[$0] } ?? [:]).mapValues(memberWithCurrentStatus)
        let restoredMembers = membersWithCurrentStatus(guildID.flatMap { memberListsByGuildID[$0] } ?? [])
        let presentationChanged =
            memberListGroups != restoredGroups
            || guildRoles != restoredRoles
            || members != restoredMembers

        defersMemberPresentationRebuild = true
        memberListGroups = restoredGroups
        guildRoles = restoredRoles
        membersByID = restoredMembersByID
        members = restoredMembers
        defersMemberPresentationRebuild = false

        guard presentationChanged else { return }
        rebuildMemberSections()
        AppPerformanceSignposts.signposter.emitEvent(
            "TimelineInvalidationGuildPresentationRestore"
        )
        invalidateTimelinePresentation()
    }

    nonisolated static func preferredInitialChannelID(in channels: [Channel]) -> ChannelID? {
        // Message requests wait on their own page until accepted.
        let channels = channels.filter { $0.messageRequest == nil }
        let textChannels = channels.filter { channel in
            switch channel.kind {
            case .text, .announcement, .forum, .directMessage, .groupDirectMessage:
                true
            case .voice, .unknown:
                false
            }
        }
        return textChannels.first?.id ?? channels.first?.id
    }

    func beginMemberLoad(for guildID: GuildID?) {
        memberLoadTask?.cancel()
        memberLoadGeneration &+= 1
        let requestGeneration = memberLoadGeneration
        let session = accountSession()
        let requestProvider = session.provider
        memberLoadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer {
                if isCurrentAccountSession(session),
                   memberLoadGeneration == requestGeneration
                {
                    memberLoadTask = nil
                }
            }
            do {
                let timeoutRevision = guildID.map { onboarding.timeoutRevisions[$0, default: 0] }
                var value = try await AppPerformanceSignposts.measure(
                    "MemberListInitialRequest"
                ) {
                    try await requestProvider.members(in: guildID)
                }
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      memberLoadGeneration == requestGeneration,
                      selectedGuildID == guildID
                else { return }
                if let guildID,
                   onboarding.timeoutRevisions[guildID, default: 0] != timeoutRevision,
                   let index = value.firstIndex(where: { $0.id == currentUser?.id }) {
                    // A live membership update can overtake this snapshot.
                    // Preserve its timeout in both the self and list stores.
                    value[index].communicationDisabledUntil = onboarding.members[guildID]?.communicationDisabledUntil
                }
                AppPerformanceSignposts.measureSync(
                    "MemberListInitialPublication"
                ) {
                    if let guildID {
                        memberListsByGuildID[guildID] = value
                        if let loadedMember = value.first(where: { $0.id == currentUser?.id }) {
                            // Initial list hydration supplies timeout evidence;
                            // keep the existing onboarding/role state authoritative.
                            var member = onboarding.members[guildID] ?? loadedMember
                            member.communicationDisabledUntil = loadedMember.communicationDisabledUntil
                            receiveOnboardingMember(member, guildID: guildID)
                        }
                    }
                    members = value
                    // Keep the pre-subscription GuildMemberStore snapshot for
                    // composer search. Full member-list subscriptions feed the
                    // inspector, but Discord does not use their visual list order
                    // as autocomplete's candidate store.
                    mentionAutocompleteMembers = value
                }
                if let guildID {
                    await replayMemberListViewportIfNeeded(
                        for: guildID,
                        account: session
                    )
                }
                if let guildID {
                    let roles = try? await AppPerformanceSignposts.measure(
                        "MemberListRoleRequest"
                    ) {
                        try await requestProvider.roles(in: guildID)
                    }
                    if let roles,
                       !Task.isCancelled,
                       isCurrentAccountSession(session),
                       memberLoadGeneration == requestGeneration,
                       selectedGuildID == guildID
                    {
                        applyGuildRoles(roles, to: guildID)
                    }
                } else {
                    guildRoles = []
                }
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      memberLoadGeneration == requestGeneration,
                      selectedGuildID == guildID
                else { return }
                members =
                    snapshot.map {
                        [Member(user: $0.currentUser, roleName: "You", status: currentStatus)]
                    }
                    ?? []
                if guildID == nil {
                    guildRoles = []
                }
            }
        }
    }
}
