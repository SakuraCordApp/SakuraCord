import DiscordProtocol
import Foundation
import SakuraCordModels

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
        snapshot?.channels.first { $0.id == selectedChannelID }
            ?? visibleChannels.first { $0.id == selectedChannelID }
    }

    // Sidebar choices supersede asynchronous navigation immediately.
    var channelSidebarSelection: ChannelID? {
        get { guildWorkspacePage == nil ? selectedChannelID : nil }
        set {
            onboarding.presentedGuildID = nil
            cancelConversationNavigation()
            selectedChannelID = newValue
            recordConversationNavigation()
        }
    }

    func cancelConversationNavigation() {
        guildActivationTask?.cancel()
        guildActivationTask = nil
        conversationNavigationHistory.cancelNavigation()
    }

    func startConversationNavigation(
        to destination: ConversationNavigationHistory.Destination? = nil,
        operation: @escaping @MainActor (AppModel, AppModelAccountSession) async -> Void
    ) {
        cancelConversationNavigation()
        let account = accountSession()
        guildActivationTask = startAccountChildTask(account: account) { model, account in
            // A task cancelled before it starts never opens a history transaction.
            let navigation = model.conversationNavigationHistory.beginNavigation(to: destination)
            defer {
                let channel = !Task.isCancelled && model.isCurrentAccountSession(account)
                    ? model.navigationChannel : nil
                model.conversationNavigationHistory.finishNavigation(navigation, at: channel)
            }
            await operation(model, account)
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
                currentUser: snapshot?.currentUser,
                currentStatus: currentStatus
            )
        )
    }

    func navigate(
        to channelID: ChannelID,
        historyDestination: ConversationNavigationHistory.Destination? = nil
    ) {
        onboarding.presentedGuildID = nil
        guard
            let channel = snapshot?.channels.first(where: { $0.id == channelID })
            ?? visibleChannels.first(where: { $0.id == channelID })
        else {
            errorMessage = "That mentioned channel has not been discovered yet."
            return
        }
        startConversationNavigation(to: historyDestination) { model, account in
            if model.selectedGuildID != channel.guildID {
                await model.activateGuild(channel.guildID, account: account)
            }
            guard !Task.isCancelled,
                  model.isCurrentAccountSession(account)
            else { return }
            model.recordForwardDestinationVisit(channel.id)
            model.selectedChannelID = channel.id
        }
    }

    func navigate(
        to guildID: GuildID?,
        linkedChannelID channelID: ChannelID,
        messageID: MessageID? = nil,
        initialMessages: [Message] = []
    ) {
        let isKnownRootChannel =
            snapshot?.channels.contains(where: { $0.id == channelID }) == true
                || visibleChannels.contains(where: { $0.id == channelID })
        if messageID == nil, isKnownRootChannel {
            navigate(to: channelID)
            return
        }

        startConversationNavigation { [weak self] _, session in
            guard let self else { return }
            let knownPost =
                forumCataloguePosts.first(where: { $0.id == channelID })
                    ?? forumPosts.first(where: { $0.id == channelID })
            if selectedGuildID != guildID {
                await activateGuild(guildID, account: session)
            }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            if messageID == nil, let channel =
                snapshot?.channels.first(where: { $0.id == channelID })
                    ?? visibleChannels.first(where: { $0.id == channelID })
            {
                selectedChannelID = channel.id
                return
            }

            let post: ForumPost
            do {
                post = if let knownPost {
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
                errorMessage = error.localizedDescription
                return
            }

            let targetGuildID = post.thread.guildID ?? guildID
            if selectedGuildID != targetGuildID {
                await activateGuild(targetGuildID, account: session)
            }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            guard let parentID = post.thread.parentID,
                  let parent =
                  snapshot?.channels.first(where: { $0.id == parentID })
                      ?? visibleChannels.first(where: { $0.id == parentID })
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
                session: session
            )
        }
    }

    private func openLinkedThread(
        _ post: ForumPost,
        initialMessages: [Message],
        messageID: MessageID?,
        session: AppModelAccountSession
    ) async {
        if initialMessages.isEmpty {
            open(post)
        } else {
            readState.merge(forumPost: post)
            openThreadConversation(
                post.thread,
                starter: post.owner ?? post.firstMessage?.author,
                startedAt: post.firstMessage?.timestamp ?? post.createdAt,
                starterMessageID: post.firstMessage?.id,
                initialMessages: initialMessages
            )
        }
        guard let messageID else { return }
        await threadLoadTask?.value
        guard !Task.isCancelled,
              isCurrentAccountSession(session),
              openThread?.id == post.id
        else { return }
        if !threadMessages.contains(where: { $0.id == messageID }) {
            do {
                let page = try await session.provider.messages(
                    in: post.id,
                    anchoredAt: .around(messageID),
                    limit: 50
                )
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      openThread?.id == post.id
                else { return }
                threadMessages = Self.merging(
                    current: threadMessages,
                    fresh: page.messages
                )
                hasMoreThreadMessages = page.hasMoreBefore
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountSession(session),
                      openThread?.id == post.id
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                errorMessage = error.localizedDescription
                return
            }
        }
        guard threadMessages.contains(where: { $0.id == messageID }) else {
            errorMessage = "That message could not be found in the linked thread."
            return
        }
        messageNavigationRequestID &+= 1
        messageNavigationRequest = MessageNavigationRequest(
            requestID: messageNavigationRequestID,
            channelID: post.id,
            messageID: messageID
        )
    }

    func navigate(to guildID: GuildID?, channelID: ChannelID, messageID: MessageID) {
        startConversationNavigation { [weak self] _, session in
            guard let self else { return }
            if selectedGuildID != guildID {
                await activateGuild(guildID, account: session)
            }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            guard
                let channel = snapshot?.channels.first(where: { $0.id == channelID })
                ?? visibleChannels.first(where: { $0.id == channelID })
            else {
                errorMessage = "That message's channel has not been discovered yet."
                return
            }
            if selectedChannelID != channel.id {
                selectedChannelID = channel.id
            }
            await channelLoadTask?.value
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == channel.id
            else { return }

            if !messages.contains(where: { $0.id == messageID }) {
                do {
                    let page = try await session.provider.messages(
                        in: channel.id,
                        anchoredAt: .around(messageID),
                        limit: 50
                    )
                    guard !Task.isCancelled,
                          isCurrentAccountSession(session),
                          selectedChannelID == channel.id
                    else { return }
                    replaceSelectedMessages(with: page.messages)
                    hasMoreMessages = page.hasMoreBefore
                    hasMoreLaterMessages = page.hasMoreAfter
                    hasMoreCache[channel.id] = page.hasMoreBefore
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrentAccountSession(session),
                          selectedChannelID == channel.id
                    else { return }
                    DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                    errorMessage = error.localizedDescription
                    return
                }
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
                messageID: messageID
            )
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
        let rememberedChannelID = guildID.flatMap { lastOpenedChannelIDsByGuild[$0] }
        dismissAllProfiles()
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
        let restoredChannelID = rememberedChannelID.flatMap { rememberedID in
            selectableChannels.contains(where: { $0.id == rememberedID })
                ? rememberedID
                : nil
        }
        if restoredChannelID != nil
            || !visibleChannels.contains(where: { $0.id == selectedChannelID })
        {
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
        }
        beginMemberLoad(for: guildID)
    }

    func restoreMemberPresentation(for guildID: GuildID?) {
        let restoredGroups = guildID.flatMap { memberListGroupsByGuildID[$0] } ?? []
        let restoredRoles = guildID.flatMap { guildRolesByGuildID[$0] } ?? []
        let restoredMembersByID = guildID.flatMap { membersByGuildID[$0] } ?? [:]
        let restoredMembers = guildID.flatMap { memberListsByGuildID[$0] } ?? []
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
                let value = try await AppPerformanceSignposts.measure(
                    "MemberListInitialRequest"
                ) {
                    try await requestProvider.members(in: guildID)
                }
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      memberLoadGeneration == requestGeneration,
                      selectedGuildID == guildID
                else { return }
                AppPerformanceSignposts.measureSync(
                    "MemberListInitialPublication"
                ) {
                    if let guildID {
                        memberListsByGuildID[guildID] = value
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
