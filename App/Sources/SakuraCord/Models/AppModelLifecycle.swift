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

nonisolated enum RestoredCredentialSelectionPolicy {
    static func handle(
        from handles: [CredentialHandle],
        preferredAccountID: String?
    ) -> CredentialHandle? {
        if let preferredAccountID,
           let preferred = handles.first(where: {
               $0.accountID == preferredAccountID
           })
        {
            return preferred
        }
        return handles.first
    }
}

extension AppModel {
    var isOfflineTesting: Bool {
        launchMode == .offlineTesting
    }

    var isDiscordNetworkingDisabled: Bool {
        discordNetworkDisabled
    }

    func connectAuthenticatedAccount(
        _ handle: CredentialHandle,
        preservesInteractivePresentation: Bool = false
    ) async -> Bool {
        guard !discordNetworkDisabled else {
            errorMessage = "Discord networking is disabled in offline UI mode."
            return false
        }
        guard await accountTransitionCoordinator.acquireIfAvailable() else { return false }
        accountTransitionIsActive = true
        let installationID = await AppPerformanceSignposts.measure("InstallationRestore") {
            await UserDefaultsDiscordFingerprintStore.shared.loadInstallationID()
        }
        guard !Task.isCancelled else {
            accountTransitionIsActive = false
            await accountTransitionCoordinator.release()
            return false
        }
        let nextProvider = AppPerformanceSignposts.measureSync("ProviderCreation") {
            authenticatedProviderFactory(handle, installationID)
        }
        await nextProvider.updateClientAppState(isFocused: mainWindowIsActive)
        do {
            // Enumerating Keychain item attributes reveals the account handle
            // without necessarily authorizing access to its secret. Preparing
            // the provider retains that value for bootstrap, avoiding a second
            // Keychain prompt after a one-time authorization.
            try await nextProvider.prepareAuthentication()
        } catch {
            errorMessage = error.localizedDescription
            accountTransitionIsActive = false
            if !isAuthenticated {
                sessionState = .signedOut
            }
            await accountTransitionCoordinator.release()
            return false
        }
        guard !Task.isCancelled else {
            accountTransitionIsActive = false
            await accountTransitionCoordinator.release()
            return false
        }
        invalidateAccountSession()
        let transitionGeneration = accountSessionGeneration
        let connected = await performAuthenticatedAccountConnection(
            handle,
            provider: nextProvider,
            preservesInteractivePresentation: preservesInteractivePresentation,
            transitionGeneration: transitionGeneration
        )
        accountTransitionIsActive = false
        await accountTransitionCoordinator.release()
        return connected
    }

    func performAuthenticatedAccountConnection(
        _ handle: CredentialHandle,
        provider nextProvider: any ChatProvider,
        preservesInteractivePresentation: Bool,
        transitionGeneration: UInt64
    ) async -> Bool {
        let previousAccount = accountSession(allowsTransition: true)
        let previousProvider = previousAccount.provider
        let previousEventTask = eventTask
        resetAccountScopedLoadsAndForumState()
        let preparationSignpost = AppPerformanceSignposts.signposter.beginInterval(
            "AccountConnectionPreparation"
        )
        var didEndPreparationSignpost = false
        defer {
            if !didEndPreparationSignpost {
                AppPerformanceSignposts.signposter.endInterval(
                    "AccountConnectionPreparation",
                    preparationSignpost
                )
            }
        }
        await AppPerformanceSignposts.measure("PreviousSessionShutdown") {
            await leaveVoice(account: previousAccount)
            guard accountSessionGeneration == transitionGeneration else { return }
            resetAppSounds()
            await previousProvider.disconnect()
        }
        guard accountSessionGeneration == transitionGeneration else { return false }
        previousEventTask?.cancel()
        await previousEventTask?.value
        guard accountSessionGeneration == transitionGeneration else { return false }
        eventTask = nil
        await drainAccountChildTasks()
        guard accountSessionGeneration == transitionGeneration else { return false }
        resetPendingCreatedMessages()
        resetTimelineLiveScrolling()
        clearReactionMutationState()
        stopLocalTyping(clearThrottle: true)
        typingState.clearAll()
        if !preservesInteractivePresentation {
            sessionState = .connecting
        }
        let nextDatabase = AppPerformanceSignposts.measureSync("AccountDatabaseOpen") {
            AccountID(handle.accountID).flatMap {
                accountDatabaseFactory($0)
            }
        }
        installAccountSession(provider: nextProvider, database: nextDatabase)
        accountTransitionIsActive = false
        resetForAccountConnection(handle)
        resetAccountPresentationState()
        AppPerformanceSignposts.signposter.endInterval(
            "AccountConnectionPreparation",
            preparationSignpost
        )
        didEndPreparationSignpost = true
        await start(
            publishesSessionState: !preservesInteractivePresentation
        )
        guard accountSessionGeneration == transitionGeneration else { return false }
        isAuthenticated = snapshot != nil
        sessionState = isAuthenticated ? .workspace : .signedOut
        if isAuthenticated {
            await requestNotificationPermissionIfNeeded()
            guard accountSessionGeneration == transitionGeneration else { return false }
        }
        return isAuthenticated
    }

    func resetForAccountConnection(_ handle: CredentialHandle) {
        resetAcknowledgementWork()
        resetChannelNotificationMutations()
        readState.reset(accountID: handle.accountID)
        currentUserRoleIDsByGuild = [:]
        supportedCapabilities = []
        pendingComponentControls = []
        componentErrors = [:]
        componentKeyByNonce = [:]
        credentialHandle = handle
        didAttemptSessionRestore = true
        commandComposer.configureFrecencyScope(handle.accountID)
    }

    func resetAccountPresentationState() {
        snapshot = nil
        serverRailGuildsByID = [:]
        serverRailItems = []
        emojisByGuild = [:]
        loadingEmojiGuildIDs = []
        emojiLoadErrorsByGuild = [:]
        discordFavoriteEmojiKeys = []
        discordFrequentlyUsedEmojiKeys = []
        discordEmojiUsageScores = [:]
        discordGuildAndChannelUsageScores = [:]
        hasLoadedDiscordEmojiSettings = false
        didAttemptDiscordEmojiSettings = false
        voiceStates = [:]
        privateCallsByChannel = [:]
        visibleChannels = []
        selectedChannel = nil
        selectedGuildID = nil
        selectedChannelID = nil
        replaceSelectedMessages(with: [])
        hasCompletedInitialMessageLoad = false
        hasCompletedInitialThreadLoad = false
        messageCache = [:]
        messageCacheOrder = []
        messageRowCache = [:]
        messageRowCacheOrder = []
        hasMoreCache = [:]
        membersByGuildID = [:]
        memberListsByGuildID = [:]
        memberListGroupsByGuildID = [:]
        guildRolesByGuildID = [:]
        membersByID = [:]
        memberListGroups = []
        guildRoles = []
        members = []
        dismissAllProfiles(clearsCache: true)
        errorMessage = nil
    }

    func logout() async {
        guard await accountTransitionCoordinator.acquireIfAvailable() else { return }
        accountTransitionIsActive = true
        invalidateAccountSession()
        let transitionGeneration = accountSessionGeneration
        await performLogout(transitionGeneration: transitionGeneration)
        accountTransitionIsActive = false
        await accountTransitionCoordinator.release()
    }

    func performLogout(transitionGeneration: UInt64) async {
        let previousAccount = accountSession(allowsTransition: true)
        let previousProvider = previousAccount.provider
        let previousEventTask = eventTask
        let previousCredentialHandle = credentialHandle
        resetAccountScopedLoadsAndForumState()
        await leaveVoice(account: previousAccount)
        guard accountSessionGeneration == transitionGeneration else { return }
        resetAppSounds()
        await previousProvider.disconnect()
        guard accountSessionGeneration == transitionGeneration else { return }
        previousEventTask?.cancel()
        await previousEventTask?.value
        guard accountSessionGeneration == transitionGeneration else { return }
        eventTask = nil
        await drainAccountChildTasks()
        guard accountSessionGeneration == transitionGeneration else { return }
        resetPendingCreatedMessages()
        resetTimelineLiveScrolling()
        clearReactionMutationState()
        stopLocalTyping(clearThrottle: true)
        typingState.clearAll()
        if let previousCredentialHandle {
            do {
                try await credentialStore.remove(previousCredentialHandle)
                guard accountSessionGeneration == transitionGeneration else { return }
            } catch {
                guard accountSessionGeneration == transitionGeneration else { return }
                errorMessage = error.localizedDescription
                return
            }
        }
        credentialHandle = nil
        resetAcknowledgementWork()
        resetChannelNotificationMutations()
        readState.reset(accountID: launchMode == .offlineTesting ? "offline" : nil)
        currentUserRoleIDsByGuild = [:]
        commandComposer.configureFrecencyScope(
            launchMode == .offlineTesting ? "offline" : "signed-out"
        )
        let signedOutProvider: any ChatProvider =
            launchMode == .offlineTesting ? MockChatProvider() : SignedOutChatProvider()
        supportedCapabilities = []
        pendingComponentControls = []
        componentErrors = [:]
        componentKeyByNonce = [:]
        let signedOutDatabase = launchMode == .offlineTesting
            ? try? SakuraCordDatabase(inMemory: true)
            : nil
        installAccountSession(
            provider: signedOutProvider,
            database: signedOutDatabase
        )
        accountTransitionIsActive = false
        snapshot = nil
        serverRailGuildsByID = [:]
        serverRailItems = []
        emojisByGuild = [:]
        loadingEmojiGuildIDs = []
        emojiLoadErrorsByGuild = [:]
        discordFavoriteEmojiKeys = []
        discordFrequentlyUsedEmojiKeys = []
        discordEmojiUsageScores = [:]
        discordGuildAndChannelUsageScores = [:]
        hasLoadedDiscordEmojiSettings = false
        didAttemptDiscordEmojiSettings = false
        voiceStates = [:]
        visibleChannels = []
        selectedChannel = nil
        selectedGuildID = nil
        selectedChannelID = nil
        replaceSelectedMessages(with: [])
        hasCompletedInitialMessageLoad = false
        hasCompletedInitialThreadLoad = false
        messageCache = [:]
        messageCacheOrder = []
        messageRowCache = [:]
        messageRowCacheOrder = []
        hasMoreCache = [:]
        membersByGuildID = [:]
        memberListsByGuildID = [:]
        memberListGroupsByGuildID = [:]
        guildRolesByGuildID = [:]
        membersByID = [:]
        memberListGroups = []
        guildRoles = []
        members = []
        dismissAllProfiles(clearsCache: true)
        connectionState = .disconnected
        isAuthenticated = false
        didAttemptSessionRestore = true
        sessionState = launchMode == .offlineTesting ? .connecting : .signedOut
        if launchMode == .offlineTesting {
            await start()
            guard accountSessionGeneration == transitionGeneration else { return }
        }
    }

    func start(
        publishesSessionState: Bool = true,
        refreshesExistingSnapshot: Bool = false
    ) async {
        let session = accountSession()
        let startSignpost = AppPerformanceSignposts.signposter.beginInterval("SessionStart")
        defer {
            AppPerformanceSignposts.signposter.endInterval("SessionStart", startSignpost)
        }
        guard snapshot == nil || refreshesExistingSnapshot else { return }
        guard await prepareSessionStart() else { return }
        guard isCurrentAccountSession(session) else { return }
        if publishesSessionState {
            sessionState = .connecting
        }
        await refreshSupportedCapabilities(for: session)
        guard isCurrentAccountSession(session) else { return }
        let stream = await session.provider.eventStream()
        guard isCurrentAccountSession(session) else { return }
        installEventTask(stream, account: session)
        isLoading = true
        defer {
            if isCurrentAccountSession(session) {
                isLoading = false
            }
        }
        do {
            let value = try await AppPerformanceSignposts.measure("ProviderBootstrap") {
                try await session.provider.bootstrap()
            }
            guard isCurrentAccountSession(session) else { return }
            await applyLiveBootstrap(
                value,
                publishesSessionState: publishesSessionState,
                account: session
            )
            guard isCurrentAccountSession(session) else { return }
        } catch {
            handleSessionStartFailure(error, account: session)
        }
    }

    func installEventTask(
        _ stream: AsyncStream<ClientEvent>,
        account: AppModelAccountSession
    ) {
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentAccountSession(account)
                else { break }
                await self.consume(event)
            }
        }
    }

    func applyLiveBootstrap(
        _ value: BootstrapSnapshot,
        publishesSessionState: Bool,
        account: AppModelAccountSession
    ) async {
        guard isCurrentAccountSession(account) else { return }
        presentsCachedStartup = false
        await AppPerformanceSignposts.measure("BootstrapApplication") {
            await applyBootstrap(
                value,
                publishesSessionState: publishesSessionState,
                account: account
            )
        }
    }

    func handleSessionStartFailure(
        _ error: any Error,
        account: AppModelAccountSession
    ) {
        guard isCurrentAccountSession(account) else { return }
        errorMessage = error.localizedDescription
        guard launchMode == .normal else { return }
        // No workspace is published until bootstrap succeeds. A failed
        // bootstrap must return to sign-in without exposing partial state.
        presentsCachedStartup = false
        snapshot = nil
        isAuthenticated = false
        sessionState = .signedOut
    }

    func prepareSessionStart() async -> Bool {
        if launchMode == .normal, discordNetworkDisabled {
            if usesInsecureDebugCredentials {
                do {
                    _ = try await credentialStore.handles()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            didAttemptSessionRestore = true
            isLoading = false
            sessionState = .signedOut
            return false
        }
        if launchMode == .normal, !didAttemptSessionRestore {
            didAttemptSessionRestore = true
            let handles: [CredentialHandle]? = if restoresStoredSession {
                try? await AppPerformanceSignposts.measure(
                    "CredentialRestore"
                ) {
                    try await credentialStore.handles()
                }
            } else {
                nil
            }
            let preferredPerformanceAccountID =
                runsChatPerformanceBenchmark
                    ? ProcessInfo.processInfo.environment[
                        "SAKURACORD_PERFORMANCE_ACCOUNT_ID"
                    ]
                    : nil
            if let handles,
               let handle = RestoredCredentialSelectionPolicy.handle(
                   from: handles,
                   preferredAccountID: preferredPerformanceAccountID
               )
            {
                _ = await connectAuthenticatedAccount(handle)
                return false
            }
        }
        if launchMode == .normal, credentialHandle == nil {
            isLoading = false
            sessionState = .signedOut
            return false
        }
        return true
    }

    func applyBootstrap(
        _ value: BootstrapSnapshot,
        publishesSessionState: Bool,
        reconcilesCurrentSelection: Bool = false,
        account: AppModelAccountSession? = nil
    ) async {
        if let account, !isCurrentAccountSession(account) { return }
        snapshot = value
        reconcilePrivateCallSounds()
        readState.configure(
            accountID: credentialHandle?.accountID ?? (launchMode == .offlineTesting ? "offline" : nil),
            guilds: value.guilds,
            channels: value.channels,
            readStates: value.readStates,
            notificationSettings: value.notificationSettings,
            usesNewNotifications: value.usesNewNotifications
        )
        for thread in value.threads {
            readState.merge(thread: thread)
        }
        readState.setCurrentUserID(value.currentUser.id)
        logBootstrapUnreadState(value)
        applyBootstrapCurrentUserRoles(value)
        updateServerRail(from: value)
        refreshUnreadPresentation(appliesAccessImmediately: true)
        if credentialHandle != nil {
            isAuthenticated = true
        }
        members = value.members
        let status = await (account?.provider ?? provider).currentStatus()
        if let account, !isCurrentAccountSession(account) { return }
        currentStatus = status
        let retainedChannel = selectedChannelID.flatMap { selectedChannelID in
            value.channels.first { $0.id == selectedChannelID }
        }
        await activateGuild(
            retainedChannel?.guildID ?? value.guilds.first?.id,
            account: account
        )
        if let account, !isCurrentAccountSession(account) { return }
        if let retainedChannel,
           selectedChannelID != retainedChannel.id
        {
            selectedChannelID = retainedChannel.id
        } else if retainedChannel != nil, reconcilesCurrentSelection {
            if retainedChannel?.kind == .forum {
                beginForumLoad()
            } else {
                beginSelectedChannelLoad()
            }
        }
        if publishesSessionState {
            sessionState = .workspace
        }
        await channelLoadTask?.value
    }

    func logBootstrapUnreadState(_ value: BootstrapSnapshot) {
        let derivedUnreadGuildCount = value.guilds.count {
            readState.guildUnread($0.id)
        }
        let firstGuildHasNotificationSettings = value.guilds.first.map { guild in
            value.notificationSettings.contains { $0.guildID == guild.id }
        } ?? false
        let firstGuildSettings = value.guilds.first.flatMap { guild in
            value.notificationSettings.last { $0.guildID == guild.id }
        }
        let firstGuildMuteIsActive =
            firstGuildSettings?.isMuted == true
            && (firstGuildSettings?.muteConfiguration?.isActive() ?? true)
        let firstGuildMutedOverrideCount =
            firstGuildSettings?.channelOverrides.count { override in
                override.isMuted
                    && (override.muteConfiguration?.isActive() ?? true)
            } ?? 0
        Self.unreadDiagnosticsLogger.info(
            """
            Bootstrap unread model configured; readStates=\(value.readStates.count), \
            guildSettings=\(value.notificationSettings.count), \
            newNotifications=\(value.usesNewNotifications), \
            guilds=\(value.guilds.count), \
            firstGuildHasSettings=\(firstGuildHasNotificationSettings), \
            firstGuildMuted=\(firstGuildMuteIsActive), \
            firstGuildMutedOverrides=\(firstGuildMutedOverrideCount), \
            derivedUnreadGuilds=\(derivedUnreadGuildCount)
            """
        )
    }

    func applyBootstrapCurrentUserRoles(_ value: BootstrapSnapshot) {
        guard let firstGuildID = value.guilds.first?.id,
              let currentMember = value.members.first(where: { $0.id == value.currentUser.id })
        else { return }
        let roleIDs = Set(currentMember.roles.map(\.id))
        currentUserRoleIDsByGuild[firstGuildID] = roleIDs
        readState.updateCurrentUserRoles(roleIDs, guildID: firstGuildID)
    }

    func refreshSupportedCapabilities(
        for session: AppModelAccountSession
    ) async {
        var values: Set<ChatCapability> = []
        for capability in ChatCapability.allCases {
            let supported = await session.provider.supports(capability)
            guard isCurrentAccountSession(session) else { return }
            if supported {
                values.insert(capability)
            }
        }
        supportedCapabilities = values
    }

    func selectGuild(_ guildID: GuildID?) {
        guildActivationTask?.cancel()
        let account = accountSession()
        guildActivationTask = startAccountChildTask(account: account) { model, account in
            await model.activateGuild(guildID, account: account)
        }
    }

    func navigationDestination(for shortcutNumber: Int) -> ServerRailNavigationDestination? {
        guard (1 ... 9).contains(shortcutNumber) else { return nil }
        if shortcutNumber == 1 {
            return .directMessages
        }

        let guildIDs = serverRailItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let guildID): [guildID]
            case .folder(let folder): folder.guildIDs
            }
        }
        let visibleGuildIDs = guildIDs.filter { serverRailGuildsByID[$0] != nil }
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
        memberSections = MemberSection.make(
            from: members,
            groups: memberListGroups,
            roles: guildRoles
        )
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
        if selectedGuildID == guildID {
            guildRoles = roles
        }
        refreshUnreadPresentation(appliesAccessImmediately: true)
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

    func navigate(to channelID: ChannelID) {
        guard
            let channel = snapshot?.channels.first(where: { $0.id == channelID })
            ?? visibleChannels.first(where: { $0.id == channelID })
        else {
            errorMessage = "That mentioned channel has not been discovered yet."
            return
        }
        guildActivationTask?.cancel()
        let account = accountSession()
        guildActivationTask = startAccountChildTask(account: account) { model, account in
            if model.selectedGuildID != channel.guildID {
                await model.activateGuild(channel.guildID, account: account)
            }
            guard !Task.isCancelled,
                  model.isCurrentAccountSession(account)
            else { return }
            model.selectedChannelID = channel.id
        }
    }

    func navigate(to guildID: GuildID?, linkedChannelID channelID: ChannelID) {
        if snapshot?.channels.contains(where: { $0.id == channelID }) == true
            || visibleChannels.contains(where: { $0.id == channelID })
        {
            navigate(to: channelID)
            return
        }

        guildActivationTask?.cancel()
        let session = accountSession()
        guildActivationTask = startAccountChildTask(account: session) { [weak self] _, session in
            guard let self else { return }
            let knownPost =
                forumCataloguePosts.first(where: { $0.id == channelID })
                    ?? forumPosts.first(where: { $0.id == channelID })
            if selectedGuildID != guildID {
                await activateGuild(guildID, account: session)
            }
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            if let channel =
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
            open(post)
        }
    }

    func navigate(to guildID: GuildID?, channelID: ChannelID, messageID: MessageID) {
        guildActivationTask?.cancel()
        let session = accountSession()
        guildActivationTask = startAccountChildTask(account: session) { [weak self] _, session in
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
                    let beforeID =
                        messageID.rawValue == UInt64.max
                            ? nil
                            : MessageID(rawValue: messageID.rawValue + 1)
                    let page = try await session.provider.messages(
                        in: channel.id,
                        before: beforeID,
                        limit: 50
                    )
                    guard !Task.isCancelled,
                          isCurrentAccountSession(session),
                          selectedChannelID == channel.id
                    else { return }
                    replaceSelectedMessages(
                        with: Self.merging(current: messages, fresh: page.messages)
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrentAccountSession(session),
                          selectedChannelID == channel.id
                    else { return }
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
            guard let handle = handles?.first(where: { $0.accountID == notification.accountID }) else {
                errorMessage = "The account for this notification is no longer available."
                return
            }
            guard await connectAuthenticatedAccount(handle) else { return }
        }
        navigate(
            to: notification.guildID,
            channelID: notification.channelID,
            messageID: notification.messageID
        )
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
        let activationSignpost = AppPerformanceSignposts.signposter.beginInterval(
            "GuildActivation"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "GuildActivation",
                activationSignpost
            )
        }
        dismissAllProfiles()
        selectedGuildID = guildID
        restoreMemberPresentation(for: guildID)
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
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                errorMessage = error.localizedDescription
            }
        }
        guard !Task.isCancelled,
              isCurrentAccountSession(session),
              selectedGuildID == guildID
        else { return }
        visibleChannels = channels
        if launchMode == .offlineTesting, let guildID {
            await loadEmojis(for: guildID)
            guard isCurrentAccountSession(session) else { return }
        }
        if !visibleChannels.contains(where: { $0.id == selectedChannelID }) {
            let selectableChannels = visibleChannels.filter {
                conversationAccess(for: $0).isReadable
            }
            selectedChannelID = Self.preferredInitialChannelID(in: selectableChannels)
        }
        if !presentsCachedStartup {
            beginMemberLoad(for: guildID)
        }
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
        return textChannels.first(where: { $0.name == "general" })?.id
            ?? textChannels.first?.id
            ?? channels.first(where: { $0.name == "general" })?.id
            ?? channels.first?.id
    }

    func loadEmojis(for guildID: GuildID) async {
        guard emojisByGuild[guildID] == nil, !loadingEmojiGuildIDs.contains(guildID) else { return }
        let session = accountSession()
        loadingEmojiGuildIDs.insert(guildID)
        defer {
            if isCurrentAccountSession(session) {
                loadingEmojiGuildIDs.remove(guildID)
            }
        }
        do {
            let emojis = try await session.provider.emojis(in: guildID)
            guard isCurrentAccountSession(session) else { return }
            applyEmojis(emojis, to: guildID)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            emojiLoadErrorsByGuild[guildID] = error.localizedDescription
        }
    }

    func applyEmojis(_ emojis: [DiscordEmoji], to guildID: GuildID) {
        emojisByGuild[guildID] = emojis
        for emoji in emojis {
            ComposerEmojiImageStore.shared.register(emoji)
        }
        emojiLoadErrorsByGuild[guildID] = nil
    }

    func applyEmojiUpdate(
        upserted: [DiscordEmoji],
        deletedIDs: [String],
        to guildID: GuildID
    ) {
        guard let existing = emojisByGuild[guildID] else {
            // Discord can send a delta when its official client has a cached base.
            // SakuraCord deliberately leaves this guild unresolved so the existing
            // coalesced REST fallback can obtain a complete catalog.
            return
        }
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for id in deletedIDs {
            byID[id] = nil
        }
        for emoji in upserted {
            byID[emoji.id] = emoji
        }
        applyEmojis(
            byID.values.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            },
            to: guildID
        )
    }

    func retryEmojis(for guildID: GuildID) async {
        emojisByGuild[guildID] = nil
        emojiLoadErrorsByGuild[guildID] = nil
        await loadEmojis(for: guildID)
    }

    func loadDiscordEmojiSettings() async {
        guard !didAttemptDiscordEmojiSettings else { return }
        let session = accountSession()
        didAttemptDiscordEmojiSettings = true
        guard let settings = try? await session.provider.emojiUserSettings(),
              isCurrentAccountSession(session)
        else { return }
        discordFavoriteEmojiKeys = settings.favoriteKeys
        discordFrequentlyUsedEmojiKeys = settings.frequentlyUsedKeys
        discordEmojiUsageScores = settings.usageScores
        discordGuildAndChannelUsageScores = settings.guildAndChannelUsageScores
        hasLoadedDiscordEmojiSettings = true
    }

    func recordEmojiUse(_ key: String) {
        emojiUsageCounts[key, default: 0] += 1
        if persistsEmojiPreferences {
            UserDefaults.standard.set(emojiUsageCounts, forKey: "dev.sakuracord.emoji-usage")
        }
    }

    func toggleFavoriteEmoji(_ key: String) {
        if favoriteEmojiKeys.contains(key) {
            favoriteEmojiKeys.remove(key)
        } else {
            favoriteEmojiKeys.insert(key)
        }
        if persistsEmojiPreferences {
            UserDefaults.standard.set(
                Array(favoriteEmojiKeys), forKey: "dev.sakuracord.favorite-emojis")
        }
    }

    func composerText(for emoji: DiscordEmoji) -> String {
        DiscordEmojiPermissionPolicy.composerText(
            for: emoji,
            currentGuildID: selectedGuildID,
            premiumType: snapshot?.currentUser.premiumType ?? 0
        )
    }

    /// Invalidates asynchronous work and presentation state owned by the
    /// current account. IDs are not sufficient guards here because Discord
    /// guild, channel, and thread IDs remain identical when the same account
    /// reconnects through a replacement provider.
    func resetAccountScopedLoadsAndForumState() {
        cancelAccountChildTasks()
        clientAppStateUpdateTask?.cancel()
        clientAppStateUpdateTask = nil
        channelLoadTask?.cancel()
        channelLoadTask = nil
        channelLoadGeneration &+= 1
        threadLoadTask?.cancel()
        threadLoadTask = nil
        conversationRefreshJournals.removeAll(keepingCapacity: false)
        memberLoadTask?.cancel()
        memberLoadTask = nil
        memberLoadGeneration &+= 1
        guildActivationTask?.cancel()
        guildActivationTask = nil
        gifSearchTask?.cancel()
        gifSearchTask = nil
        gifResults = []
        isLoadingGIFs = false
        gifErrorMessage = nil
        commandLoadTask?.cancel()
        commandLoadTask = nil
        commandAutocompleteTask?.cancel()
        commandAutocompleteTask = nil
        commandMemberSearchTask?.cancel()
        commandMemberSearchTask = nil
        commandMemberSearchQuery = nil
        commandMemberSearchCache = [:]
        commandMemberResults = []
        mentionMemberSearchTask?.cancel()
        mentionMemberSearchTask = nil
        mentionMemberSearchQuery = nil
        mentionMemberSearchCache = [:]
        mentionMemberResults = []
        mentionAutocompleteMembers = []
        knownMentionMembers = [:]
        roleMemberTask?.cancel()
        roleMemberTask = nil
        roleMemberResult = nil
        roleMemberErrorMessage = nil
        isLoadingRoleMembers = false
        commandExecutionTask?.cancel()
        commandExecutionTask = nil
        inspectorProfileTask?.cancel()
        inspectorProfileTask = nil
        contextualProfileTask?.cancel()
        contextualProfileTask = nil
        for task in stickerLoadTasks.values {
            task.cancel()
        }
        stickerLoadTasks = [:]
        stickerLoadGeneration &+= 1
        stickersByGuild = [:]
        loadingReactionReactors = []
        failedReactionReactorLoads = [:]
        resetForumLoadAndPresentationState()
        presentsCachedStartup = false
    }

    func resetForumLoadAndPresentationState() {
        forumLoadTask?.cancel()
        forumLoadTask = nil
        forumLoadGeneration &+= 1
        forumCreateGeneration &+= 1
        forumNextOffset = nil
        forumPosts = []
        forumCataloguePosts = []
        forumCatalogueIndexByID = [:]
        forumRecentPostCount = 0
        isLoadingForumPosts = false
        isSearchingForumPosts = false
        hasLoadedForumPosts = false
        isLoadingMoreForumPosts = false
        hasMoreForumPosts = false
        forumPostError = nil
        forumActionError = nil
        forumPaginationError = nil
        forumCreateProgress = nil
        forumSearchText = ""
        forumSelectedTagIDs = []
        forumSortOrder = .latestActivity
        forumLayout = .list
        forumTagMatch = .matchSome
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
                let value = try await requestProvider.members(in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      memberLoadGeneration == requestGeneration,
                      selectedGuildID == guildID
                else { return }
                if let guildID {
                    memberListsByGuildID[guildID] = value
                }
                members = value
                // Keep the pre-subscription GuildMemberStore snapshot for
                // composer search. Full member-list subscriptions feed the
                // inspector, but Discord does not use their visual list order
                // as autocomplete's candidate store.
                mentionAutocompleteMembers = value
                if let guildID {
                    if let roles = try? await requestProvider.roles(in: guildID),
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

    func beginForumLoad() {
        channelLoadTask?.cancel()
        resetForumLoadAndPresentationState()
        replaceSelectedMessages(with: [])
        draft = ""
        messageLoadError = nil
        isLoadingMessages = false
        if let channel = selectedChannel {
            forumSortOrder = channel.defaultSortOrder ?? .latestActivity
            forumLayout =
                channel.defaultForumLayout == .defaultLayout ? .list : channel.defaultForumLayout
            forumTagMatch = channel.defaultTagMatch
        }
        guard selectedConversationAccess.isReadable else { return }
        forumLoadTask = Task { [weak self] in
            await self?.loadForumPosts(reset: true)
        }
    }

    func reloadForumPosts() {
        guard selectedChannel?.kind == .forum else { return }
        forumLoadTask?.cancel()
        forumLoadTask = Task { [weak self] in
            await self?.loadForumPosts(reset: true)
        }
    }

    func loadMoreForumPosts() async {
        guard hasMoreForumPosts, !isLoadingMoreForumPosts else { return }
        await loadForumPosts(reset: false)
    }

    func updateForumSearch(_ text: String) {
        let previousSearch = forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextSearch = text.trimmingCharacters(in: .whitespacesAndNewlines)
        forumSearchText = text
        forumPostError = nil
        forumPaginationError = nil
        forumLoadGeneration &+= 1
        if nextSearch.lowercased().hasPrefix(previousSearch.lowercased()) {
            let presentation = ForumPostPresentation(
                posts: forumPosts,
                recentCount: forumRecentPostCount
            ).filtering(
                searchText: nextSearch,
                selectedTagIDs: forumSelectedTagIDs,
                tagMatch: forumTagMatch
            )
            forumPosts = presentation.posts
            forumRecentPostCount = presentation.recentCount
        } else {
            applyForumPresentation()
        }
        forumLoadTask?.cancel()
        guard !nextSearch.isEmpty else {
            isSearchingForumPosts = false
            hasMoreForumPosts = forumNextOffset != nil
            return
        }
        hasMoreForumPosts = false
        isSearchingForumPosts = true
        forumLoadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == nextSearch
            else { return }
            await loadForumPosts(reset: true)
        }
    }

    func loadForumPosts(reset: Bool) async {
        guard !Task.isCancelled,
              let channelID = selectedChannelID,
              selectedChannel?.kind == .forum,
              selectedConversationAccess.isReadable
        else { return }
        let session = accountSession()
        let loadSignpost = Self.forumPerformanceSignposter.beginInterval("ForumPostsLoad")
        defer {
            Self.forumPerformanceSignposter.endInterval("ForumPostsLoad", loadSignpost)
        }
        let trimmedSearch = forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = !trimmedSearch.isEmpty
        if isSearch { isSearchingForumPosts = true }
        if reset {
            forumLoadGeneration &+= 1
            forumPaginationError = nil
            if !isSearch { forumNextOffset = nil }
        } else {
            isLoadingMoreForumPosts = true
            forumPaginationError = nil
        }
        let requestGeneration = forumLoadGeneration
        let loadingIndicatorTask: Task<Void, Never>? =
            reset && !hasLoadedForumPosts
                ? Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, !Task.isCancelled,
                          selectedChannelID == channelID,
                          forumLoadGeneration == requestGeneration,
                          !hasLoadedForumPosts
                    else { return }
                    isLoadingForumPosts = true
                }
                : nil
        defer {
            loadingIndicatorTask?.cancel()
            if isCurrentAccountSession(session),
               selectedChannelID == channelID,
               forumLoadGeneration == requestGeneration
            {
                isLoadingForumPosts = false
                isLoadingMoreForumPosts = false
                if isSearch { isSearchingForumPosts = false }
            }
        }
        let scope: ForumPostScope =
            !trimmedSearch.isEmpty
                ? .search(trimmedSearch)
                : .active
        do {
            let page = try await requestForumPosts(
                provider: session.provider,
                channelID: channelID,
                scope: scope,
                reset: reset
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == channelID,
                  forumLoadGeneration == requestGeneration
            else { return }
            applyForumPage(page, isSearch: isSearch, reset: reset, channelID: channelID)
        } catch {
            guard !Self.isForumLoadCancellation(error) else { return }
            guard isCurrentAccountSession(session),
                  selectedChannelID == channelID,
                  forumLoadGeneration == requestGeneration
            else {
                return
            }
            applyForumLoadError(error, isSearch: isSearch, reset: reset)
        }
    }

    func requestForumPosts(
        provider: any ChatProvider,
        channelID: ChannelID,
        scope: ForumPostScope,
        reset: Bool
    ) async throws -> ForumPostPage {
        let providerSignpost = Self.forumPerformanceSignposter.beginInterval("ForumProviderLoad")
        defer {
            Self.forumPerformanceSignposter.endInterval(
                "ForumProviderLoad",
                providerSignpost
            )
        }
        return try await provider.forumPosts(
            in: channelID,
            query: ForumPostQuery(
                scope: scope,
                sortOrder: forumSortOrder,
                selectedTagIDs: forumSelectedTagIDs,
                tagMatch: forumTagMatch,
                offset: reset ? 0 : (forumNextOffset ?? 0),
                limit: 25
            )
        )
    }

    func applyForumPage(
        _ page: ForumPostPage,
        isSearch: Bool,
        reset: Bool,
        channelID: ChannelID
    ) {
        let catalogueSignpost = Self.forumPerformanceSignposter.beginInterval(
            "ForumCatalogueUpdate"
        )
        if isSearch {
            mergeForumCatalogue(page.posts)
        } else if reset {
            replaceForumCatalogue(with: page.posts)
        } else {
            mergeForumCatalogue(page.posts)
        }
        Self.forumPerformanceSignposter.endInterval(
            "ForumCatalogueUpdate",
            catalogueSignpost
        )
        let presentationSignpost = Self.forumPerformanceSignposter.beginInterval(
            "ForumPresentation"
        )
        applyForumPresentation()
        Self.forumPerformanceSignposter.endInterval(
            "ForumPresentation",
            presentationSignpost
        )
        if !isSearch {
            forumNextOffset = page.nextOffset
            hasMoreForumPosts = page.hasMore
        } else {
            hasMoreForumPosts = false
        }
        forumPostError = nil
        forumPaginationError = nil
        hasLoadedForumPosts = true
        if !isSearch, reset {
            acknowledgeForumVisitIfNeeded(channelID: channelID)
        }
    }

    func applyForumLoadError(_ error: Error, isSearch: Bool, reset: Bool) {
        if reset {
            forumPostError =
                isSearch && !forumCataloguePosts.isEmpty
                    ? nil
                    : error.localizedDescription
        } else {
            forumPaginationError = error.localizedDescription
        }
        hasLoadedForumPosts = true
    }

    func mergeForumCatalogue(_ posts: [ForumPost]) {
        for incoming in posts {
            readState.merge(forumPost: incoming)
            let post: ForumPost
            if let index = forumCatalogueIndexByID[incoming.id] {
                post = forumPostPreservingReactionPresentation(
                    incoming,
                    previous: forumCataloguePosts[index]
                )
            } else {
                post = incoming
            }
            if let index = forumCatalogueIndexByID[post.id] {
                forumCataloguePosts[index] = post
            } else {
                forumCatalogueIndexByID[post.id] = forumCataloguePosts.endIndex
                forumCataloguePosts.append(post)
            }
        }
    }

    func replaceForumCatalogue(with posts: [ForumPost]) {
        let previousByID = Dictionary(
            uniqueKeysWithValues: forumCataloguePosts.map { ($0.id, $0) }
        )
        forumCataloguePosts = posts.map { incoming in
            readState.merge(forumPost: incoming)
            guard let previous = previousByID[incoming.id] else { return incoming }
            return forumPostPreservingReactionPresentation(incoming, previous: previous)
        }
        forumCatalogueIndexByID = Dictionary(
            uniqueKeysWithValues: forumCataloguePosts.indices.map {
                (forumCataloguePosts[$0].id, $0)
            }
        )
    }

    func forumPostPreservingReactionPresentation(
        _ incoming: ForumPost,
        previous: ForumPost
    ) -> ForumPost {
        var result = incoming
        if let firstMessage = incoming.firstMessage {
            result.firstMessage = firstMessage.preservingReactionReactors(
                from: previous.firstMessage ?? firstMessage
            )
        } else {
            result.firstMessage = previous.firstMessage
        }
        if let mostRecentMessage = incoming.mostRecentMessage {
            result.mostRecentMessage = mostRecentMessage.preservingReactionReactors(
                from: previous.mostRecentMessage ?? mostRecentMessage
            )
        } else {
            result.mostRecentMessage = previous.mostRecentMessage
        }
        result.owner = incoming.owner ?? previous.owner
        if result.thread.notificationSettings == nil {
            result.thread.notificationSettings = previous.thread.notificationSettings
        }
        return result
    }

    func reconcileForumMessage(_ message: Message) {
        guard let index = forumCatalogueIndexByID[message.channelID] else { return }
        var updated = forumCataloguePosts[index]
        let isNewerReply =
            updated.thread.lastMessageID.map { message.id > $0 }
            ?? (message.id.rawValue != updated.id.rawValue)
        if message.id.rawValue == updated.id.rawValue || updated.firstMessage?.id == message.id {
            updated.firstMessage = message
        }
        if updated.mostRecentMessage == nil || message.timestamp >= updated.lastActivityAt {
            updated.mostRecentMessage = message
            updated.thread.lastMessageID = message.id
        }
        if isNewerReply {
            updated.thread.messageCount += 1
            updated.thread.totalMessageSent += 1
        }
        guard updated != forumCataloguePosts[index] else { return }
        forumCataloguePosts[index] = updated
        updateForumPresentation(with: updated)
    }

    func applyForumPresentation() {
        let presentation = ForumPostPresentation.make(
            catalogue: forumCataloguePosts,
            searchText: forumSearchText,
            selectedTagIDs: forumSelectedTagIDs,
            tagMatch: forumTagMatch,
            sortOrder: forumSortOrder
        )
        forumPosts = presentation.posts
        forumRecentPostCount = presentation.recentCount
    }

    func updateForumPresentation(with post: ForumPost) {
        let presentation = ForumPostPresentation(
            posts: forumPosts,
            recentCount: forumRecentPostCount
        ).updating(
            post,
            searchText: forumSearchText,
            selectedTagIDs: forumSelectedTagIDs,
            tagMatch: forumTagMatch,
            sortOrder: forumSortOrder
        )
        forumPosts = presentation.posts
        forumRecentPostCount = presentation.recentCount
    }

    nonisolated static func isForumLoadCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
    }

    @discardableResult
    func createForumPost(_ draft: CreateForumPostDraft) async -> Bool {
        guard !presentsCachedStartup else { return false }
        guard canCreateForumPosts else {
            forumActionError = "You do not have permission to create posts in this forum."
            return false
        }
        forumActionError = nil
        forumCreateGeneration &+= 1
        let generation = forumCreateGeneration
        let session = accountSession()
        defer {
            if forumCreateGeneration == generation {
                forumCreateProgress = nil
                forumCreateGeneration &+= 1
            }
        }
        do {
            let post = try await session.provider.createForumPost(draft) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.isCurrentAccountSession(session),
                          self.forumCreateGeneration == generation
                    else { return }
                    self.forumCreateProgress = progress
                }
            }
            guard isCurrentAccountSession(session) else { return false }
            mergeForumCatalogue([post])
            applyForumPresentation()
            open(post)
            return true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            if Self.isForumLoadCancellation(error) {
                return false
            }
            forumActionError = error.localizedDescription
            return false
        }
    }

    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async {
        guard !presentsCachedStartup else { return }
        switch mutation {
        case .tags(let tagIDs):
            guard validateForumTagMutation(tagIDs, for: post) else { return }
        case .archived:
            guard canArchiveForumPost(post) else {
                forumActionError = "You do not have permission to close or reopen this post."
                return
            }
        case .locked, .pinned:
            guard canManageForumPosts else {
                forumActionError = "Only moderators can change this post."
                return
            }
        }

        forumActionError = nil
        let session = accountSession()
        do {
            let updated = try await session.provider.updateForumPost(
                post,
                mutation: mutation
            )
            guard isCurrentAccountSession(session) else { return }
            mergeForumCatalogue([updated])
            applyForumPresentation()
            if openThread?.id == updated.id { openThread = updated.thread }
        } catch {
            guard isCurrentAccountSession(session) else { return }
            forumActionError = error.localizedDescription
        }
    }

    func validateForumTagMutation(
        _ tagIDs: [ForumTagID],
        for post: ForumPost
    ) -> Bool {
        guard canEditForumPostTags(post) else {
            forumActionError = "You do not have permission to edit this post’s tags."
            return false
        }
        let uniqueTagIDs = Set(tagIDs)
        guard uniqueTagIDs.count <= 5,
              let channel = selectedChannel,
              channel.id == post.thread.parentID
        else {
            forumActionError = "The selected tags are invalid for this forum."
            return false
        }
        let availableTagsByID = Dictionary(
            uniqueKeysWithValues: channel.availableTags.map { ($0.id, $0) }
        )
        guard uniqueTagIDs.allSatisfy({ availableTagsByID[$0] != nil }) else {
            forumActionError = "One or more selected tags are no longer available."
            return false
        }
        guard !channel.requiresForumTag || !uniqueTagIDs.isEmpty else {
            forumActionError = "This forum requires every post to have at least one tag."
            return false
        }
        if !canManageForumPosts {
            let changedTagIDs = uniqueTagIDs.symmetricDifference(post.thread.appliedTagIDs)
            guard changedTagIDs.allSatisfy({
                availableTagsByID[$0]?.isModerated == false
            }) else {
                forumActionError = "Only moderators can change moderated tags."
                return false
            }
        }
        return true
    }

    func deleteForumPost(_ post: ForumPost) async {
        guard !presentsCachedStartup else { return }
        guard canDeleteForumPost(post) else {
            forumActionError = "You do not have permission to delete this post."
            return
        }
        forumActionError = nil
        let session = accountSession()
        do {
            try await session.provider.deleteForumPost(post)
            guard isCurrentAccountSession(session) else { return }
            removeForumPost(post.id)
            if openThread?.id == post.id {
                closeThread()
            }
            forumActionError = nil
        } catch {
            guard isCurrentAccountSession(session) else { return }
            forumActionError = error.localizedDescription
        }
    }

    func dismissForumActionError() {
        forumActionError = nil
    }
}
