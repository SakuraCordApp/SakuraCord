import AppKit
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

// Account lifecycle and its DEBUG-only authenticated benchmark drivers share
// one cancellation domain and account-generation contract.
// swiftlint:disable file_length

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

nonisolated enum PerformanceBenchmarkInitialGuildPolicy {
    static func resolve(
        guilds: [Guild],
        retainedGuildID: GuildID?,
        avoidingGuildNamed avoidedName: String?
    ) -> GuildID? {
        if let avoidedName,
           let nonTargetGuild = guilds.first(where: {
               $0.name.localizedCaseInsensitiveCompare(avoidedName)
                   != .orderedSame
           })
        {
            return nonTargetGuild.id
        }
        return retainedGuildID ?? guilds.first?.id
    }
}

extension AppModel {
    static func loadEmojiRecents(usageCounts: [String: Int]) -> [String] {
        UserDefaults.standard.removeObject(
            forKey: "dev.sakuracord.favorite-emojis"
        )
        if let stored = UserDefaults.standard.stringArray(
            forKey: "dev.sakuracord.emoji-recents"
        ) {
            return stored
        }
        let migrated = usageCounts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(50).map(\.key)
        UserDefaults.standard.set(
            migrated,
            forKey: "dev.sakuracord.emoji-recents"
        )
        return migrated
    }

    var isOfflineTesting: Bool {
        launchMode == .offlineTesting
    }

    var isDiscordNetworkingDisabled: Bool {
        discordNetworkDisabled
    }

    func refreshSavedAccounts() async {
        guard launchMode == .normal else {
            savedAccounts = []
            return
        }
        do {
            let handles = try await credentialStore.handles()
            rememberCredentialHandles(handles)
            savedAccounts = await savedAccountStore.accounts(matching: handles)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchAccount(to accountID: String) async -> Bool {
        guard accountID != activeAccountID else { return true }
        let preservesWorkspace = sessionState == .workspace
        isSwitchingAccounts = true
        defer { isSwitchingAccounts = false }
        do {
            let handle: CredentialHandle?
            if let remembered = credentialHandlesByAccountID[accountID] {
                handle = remembered
            } else {
                let handles = try await credentialStore.handles()
                rememberCredentialHandles(handles)
                handle = credentialHandlesByAccountID[accountID]
            }
            guard let handle else {
                savedAccounts.removeAll { $0.accountID == accountID }
                await savedAccountStore.remove(accountID: accountID)
                errorMessage = "That saved Discord account is no longer available."
                return false
            }
            return await connectAuthenticatedAccount(
                handle,
                preservesInteractivePresentation: preservesWorkspace
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
            try await AppPerformanceSignposts.measure(
                "AccountAuthenticationPreparation"
            ) {
                try await nextProvider.prepareAuthentication()
            }
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
        componentInteractionPresentation = .init()
        componentKeyByNonce = [:]
        credentialHandle = handle
        activeAccountID = handle.accountID
        didAttemptSessionRestore = true
        commandComposer.configureFrecencyScope(handle.accountID)
    }

    func resetAccountPresentationState() {
        unreadPresentationRefreshTask?.cancel()
        unreadPresentationRefreshTask = nil
        unreadPresentationPreparationTask?.cancel()
        unreadPresentationPreparationTask = nil
        unreadPresentationPreparationSequence &+= 1
        activeUnreadPreparationGeneration = nil
        unreadPresentationPreparationGeneration &+= 1
        hasDeferredUnreadPresentationRefresh = false
        bootstrapHistoryPrefetch?.task.cancel()
        bootstrapHistoryPrefetch = nil
        workspaceNavigationOverlay = nil
        lastOpenedChannelIDsByGuild = [:]
        forwardingMessage = nil
        forwardingErrorMessage = nil
        isForwardingMessages = false
        forwardDestinationHistory = []
        quickSwitcherDraftChannelIDs = []
        snapshot = nil
        replaceServerRailGuilds([:])
        serverRailHomeIsUnread = false
        serverRailHomeMentionCount = 0
        serverRailItems = []
        emojisByGuild = [:]
        loadingEmojiGuildIDs = []
        emojiLoadErrorsByGuild = [:]
        discordFavoriteEmojiKeys = []
        discordFrequentlyUsedEmojiKeys = []
        discordEmojiUsageScores = [:]
        discordGuildAndChannelUsageScores = [:]
        discordSyncedGuildAndChannelUsageScores = [:]
        discordGuildAndChannelUsage = [:]
        discordGuildAndChannelUsageOrder = []
        pendingDiscordFrecencyUses = []
        appliedDiscordFrecencyDeltasKey = nil
        lastDiscordFrecencyChannelID = nil
        lastDiscordFrecencyGuildID = nil
        hasLoadedDiscordEmojiSettings = false
        didAttemptDiscordEmojiSettings = false
        voiceStates = [:]
        privateCallsByChannel = [:]
        visibleChannels = []
        unreadCategoryIDsByGuild = [:]
        selectedChannel = nil
        selectedGuildID = nil
        selectedChannelID = nil
        replaceSelectedMessages(with: [])
        hasCompletedInitialMessageLoad = false
        hasCompletedInitialThreadLoad = false
        isLoadingLater = false
        hasMoreLaterMessages = false
        messageCache = [:]
        messageCacheOrder = []
        messageRowCache = [:]
        messageRowCacheOrder = []
        hasMoreCache = [:]
        membersByGuildID = [:]
        memberListsByGuildID = [:]
        memberListGroupsByGuildID = [:]
        memberListViewportRequest = nil
        lastMemberListVisibleRange = nil
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

    func logout(accountID: String) async {
        guard accountID != activeAccountID else {
            await logout()
            return
        }
        guard await accountTransitionCoordinator.acquireIfAvailable() else { return }
        accountTransitionIsActive = true
        do {
            let handles = try await credentialStore.handles()
            if let handle = handles.first(where: { $0.accountID == accountID }) {
                try await removeSavedAccount(handle)
            } else {
                savedAccounts.removeAll { $0.accountID == accountID }
                await savedAccountStore.remove(accountID: accountID)
                await savedAccountStore.setPreferredAccountID(
                    activeAccountID ?? savedAccounts.first?.accountID
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
                try await removeSavedAccount(previousCredentialHandle)
                guard accountSessionGeneration == transitionGeneration else { return }
            } catch {
                guard accountSessionGeneration == transitionGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
        installSignedOutAccountState()
        if launchMode == .offlineTesting {
            await start()
            guard accountSessionGeneration == transitionGeneration else { return }
        }
    }

    private func installSignedOutAccountState() {
        bootstrapHistoryPrefetch?.task.cancel()
        bootstrapHistoryPrefetch = nil
        credentialHandle = nil
        activeAccountID = nil
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
        componentInteractionPresentation = .init()
        componentKeyByNonce = [:]
        let signedOutDatabase = launchMode == .offlineTesting
            ? try? SakuraCordDatabase(inMemory: true)
            : nil
        installAccountSession(provider: signedOutProvider, database: signedOutDatabase)
        accountTransitionIsActive = false
        workspaceNavigationOverlay = nil
        lastOpenedChannelIDsByGuild = [:]
        snapshot = nil
        replaceServerRailGuilds([:])
        serverRailHomeIsUnread = false
        serverRailHomeMentionCount = 0
        serverRailItems = []
        emojisByGuild = [:]
        loadingEmojiGuildIDs = []
        emojiLoadErrorsByGuild = [:]
        discordFavoriteEmojiKeys = []
        discordFrequentlyUsedEmojiKeys = []
        discordEmojiUsageScores = [:]
        discordGuildAndChannelUsageScores = [:]
        discordSyncedGuildAndChannelUsageScores = [:]
        discordGuildAndChannelUsage = [:]
        discordGuildAndChannelUsageOrder = []
        pendingDiscordFrecencyUses = []
        appliedDiscordFrecencyDeltasKey = nil
        lastDiscordFrecencyChannelID = nil
        lastDiscordFrecencyGuildID = nil
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
        isLoadingLater = false
        hasMoreLaterMessages = false
        messageCache = [:]
        messageCacheOrder = []
        messageRowCache = [:]
        messageRowCacheOrder = []
        hasMoreCache = [:]
        membersByGuildID = [:]
        memberListsByGuildID = [:]
        memberListGroupsByGuildID = [:]
        memberListViewportRequest = nil
        lastMemberListVisibleRange = nil
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
    }

    private func removeSavedAccount(_ handle: CredentialHandle) async throws {
        try await credentialStore.remove(handle)
        credentialHandlesByAccountID[handle.accountID] = nil
        await savedAccountStore.remove(accountID: handle.accountID)
        savedAccounts.removeAll { $0.accountID == handle.accountID }
        await savedAccountStore.setPreferredAccountID(
            savedAccounts.first?.accountID
        )
    }

    func start(publishesSessionState: Bool = true) async {
        let session = accountSession()
        let startSignpost = AppPerformanceSignposts.signposter.beginInterval("SessionStart")
        defer {
            AppPerformanceSignposts.signposter.endInterval("SessionStart", startSignpost)
        }
        guard snapshot == nil else { return }
        guard await prepareSessionStart() else { return }
        guard isCurrentAccountSession(session) else { return }
        if publishesSessionState {
            sessionState = .connecting
            if launchMode == .offlineTesting {
                try? await Task.sleep(for: .seconds(8))
            }
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
            async let storedDraftChannelIDs: [ChannelID] = {
                guard let database = session.database else { return [] }
                return (try? await database.recentDraftChannelIDs()) ?? []
            }()
            let value = try await AppPerformanceSignposts.measure("ProviderBootstrap") {
                try await session.provider.bootstrap()
            }
            guard isCurrentAccountSession(session) else { return }
            quickSwitcherDraftChannelIDs = await storedDraftChannelIDs
            await applyLiveBootstrap(
                value,
                publishesSessionState: publishesSessionState,
                account: session
            )
            guard isCurrentAccountSession(session) else { return }
        } catch {
            await failAuthenticatedSessionStart(error, account: session)
        }
    }

    func failAuthenticatedSessionStart(
        _ error: any Error,
        account session: AppModelAccountSession
    ) async {
        guard isCurrentAccountSession(session) else { return }
        guard launchMode == .normal else {
            handleSessionStartFailure(error, account: session)
            return
        }

        await session.provider.disconnect()
        eventTask?.cancel()
        await eventTask?.value
        guard isCurrentAccountSession(session) else { return }
        eventTask = nil
        await drainAccountChildTasks()
        guard isCurrentAccountSession(session) else { return }

        installAccountSession(provider: SignedOutChatProvider(), database: nil)
        credentialHandle = nil
        activeAccountID = nil
        supportedCapabilities = []
        connectionState = .disconnected
        readState.reset(accountID: nil)
        commandComposer.configureFrecencyScope("signed-out")
        resetAccountPresentationState()
        isLoading = false
        handleSessionStartFailure(error, account: accountSession())
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
        snapshot = nil
        isAuthenticated = false
        activeAccountID = nil
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
            if let handles {
                rememberCredentialHandles(handles)
                savedAccounts = await savedAccountStore.accounts(
                    matching: handles
                )
            }
            let preferredPerformanceAccountID =
                runsChatPerformanceBenchmark
                    ? ProcessInfo.processInfo.environment[
                        "SAKURACORD_PERFORMANCE_ACCOUNT_ID"
                    ]
                    : nil
            let launchDestination: SettingsLaunchDestination = if case let .string(value) =
                SettingsPreferenceStore.shared.value(for: .launchDestination)
            {
                SettingsLaunchDestination(rawValue: value)
                    ?? .preferredAccountLastLocation
            } else {
                .preferredAccountLastLocation
            }
            if SettingsLaunchAccountPolicy.presentsAccountPicker(
                destination: launchDestination,
                performanceAccountID: preferredPerformanceAccountID
            ) {
                isLoading = false
                sessionState = .signedOut
                return false
            }
            let preferredStoredAccountID = await savedAccountStore
                .preferredAccountID()
            let reopensLastActiveAccount = SettingsPreferenceStore.shared.value(
                for: .reopenLastAccount
            ) == .bool(true)
            let preferredLaunchAccountID: String? = if case let .string(value) =
                SettingsPreferenceStore.shared.value(for: .preferredLaunchAccount),
                !value.isEmpty
            {
                value
            } else {
                nil
            }
            let restoredHandle = handles.flatMap { handles in
                SettingsLaunchAccountPolicy.handle(
                    from: handles,
                    destination: launchDestination,
                    performanceAccountID: preferredPerformanceAccountID,
                    lastVisitedAccountID: SettingsConversationRestorationStore
                        .shared.preferredAccountID(for: launchDestination),
                    reopensLastActiveAccount: reopensLastActiveAccount,
                    lastActiveAccountID: preferredStoredAccountID,
                    preferredLaunchAccountID: preferredLaunchAccountID
                )
            }
            if let restoredHandle {
                SettingsConversationRestorationStore.shared.prepareLaunch(
                    destination: launchDestination,
                    selectedAccountID: restoredHandle.accountID
                )
                _ = await connectAuthenticatedAccount(restoredHandle)
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

    func rememberCredentialHandles(_ handles: [CredentialHandle]) {
        credentialHandlesByAccountID = Dictionary(
            handles.map { ($0.accountID, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func applyBootstrap(
        _ value: BootstrapSnapshot,
        publishesSessionState: Bool,
        account: AppModelAccountSession? = nil
    ) async {
        if let account, !isCurrentAccountSession(account) { return }
        AppPerformanceSignposts.measureSync("BootstrapSnapshotPublish") {
            snapshot = value
            configureForwardDestinationHistoryScope(
                credentialHandle?.accountID
                    ?? (launchMode == .offlineTesting ? "offline" : "signed-out")
            )
        }
        let bootstrapAccount: SavedAccount? = if let handle = credentialHandle,
            handle.accountID == value.currentUser.id.description
        {
            SavedAccount(user: value.currentUser)
        } else {
            nil
        }
        async let accountPersistence: Void = persistBootstrapAccount(
            bootstrapAccount,
            session: account
        )
        let readStateAccountID = credentialHandle?.accountID
            ?? (launchMode == .offlineTesting ? "offline" : nil)
        let initialReadState = await AppPerformanceSignposts.measure(
            "BootstrapReadStateBuild"
        ) {
            await Task.detached(priority: .userInitiated) {
                AccountReadStateModel.makeInitialState(
                    accountID: readStateAccountID,
                    guilds: value.guilds,
                    channels: value.channels,
                    threads: value.threads,
                    readStates: value.readStates,
                    notificationSettings: value.notificationSettings,
                    usesNewNotifications: value.usesNewNotifications,
                    currentUserID: value.currentUser.id
                )
            }.value
        }
        guard canPublishBootstrap(for: account) else { return }
        AppPerformanceSignposts.measureSync("BootstrapReadStatePublication") {
            reconcilePrivateCallSounds()
            readState.applyInitialState(initialReadState)
        }
        let launchRestoration = SettingsConversationRestorationStore.shared
            .consumeLaunchRestoration(accountID: credentialHandle?.accountID)
        let restoredLaunchChannel = launchRestoration
            .flatMap { ChannelID($0.channelID) }
            .flatMap { restoredID in
                value.channels.first { $0.id == restoredID }
            }
        let retainedChannel = selectedChannelID.flatMap { selectedChannelID in
            value.channels.first { $0.id == selectedChannelID }
        } ?? restoredLaunchChannel
        let initialGuildID = bootstrapInitialGuildID(
            in: value,
            retainedChannel: retainedChannel
        )
        let initialHistoryChannelID = AppPerformanceSignposts.measureSync(
            "BootstrapNavigationProjection"
        ) { () -> ChannelID? in
            AppPerformanceSignposts.measureSync("BootstrapUnreadDiagnostics") {
                logBootstrapUnreadState(value)
            }
            AppPerformanceSignposts.measureSync("BootstrapAccessSourcePublication") {
                applyBootstrapCurrentUserRoles(value)
                updateServerRail(from: value)
            }
            let initialPermissionBasis = initialGuildID.flatMap {
                conversationPermissionBasis(for: $0)
            }
            let initialChannel = AppPerformanceSignposts.measureSync(
                "BootstrapInitialChannelProjection"
            ) {
                let initialChannels = value.channels.filter { channel in
                    initialGuildID == nil
                        ? channel.guildID == nil
                        : channel.guildID == initialGuildID
                }
                let selectableInitialChannels = initialChannels.filter {
                    conversationAccess(
                        for: $0,
                        permissionBasis: initialPermissionBasis
                    ) != .hidden
                }
                let rememberedInitialChannel = initialGuildID
                    .flatMap { lastOpenedChannelIDsByGuild[$0] }
                    .flatMap { rememberedID in
                        selectableInitialChannels.first { $0.id == rememberedID }
                    }
                let retainedSelectableChannel = retainedChannel.flatMap { retained in
                    selectableInitialChannels.first { $0.id == retained.id }
                }
                return retainedSelectableChannel
                    ?? rememberedInitialChannel
                    ?? Self.preferredInitialChannelID(
                        in: selectableInitialChannels
                    ).flatMap { preferredID in
                        selectableInitialChannels.first { $0.id == preferredID }
                    }
            }
            guard let initialChannel,
                  initialChannel.kind != .forum,
                  initialChannel.kind != .voice,
                  conversationAccess(
                      for: initialChannel,
                      permissionBasis: initialPermissionBasis
                  ).isReadable
            else { return nil }
            return initialChannel.id
        }
        let initialAccess: UnreadAccessProjection?
        if launchMode == .offlineTesting {
            initialAccess = snapshot.map {
                unreadAccessProjection(for: $0.channels)
            }
        } else if let account {
            initialAccess = await prepareBootstrapUnreadAccessProjection(
                account: account
            )
        } else {
            initialAccess = snapshot.map {
                unreadAccessProjection(for: $0.channels)
            }
        }
        guard let initialAccess else { return }
        guard canPublishBootstrap(for: account) else { return }
        AppPerformanceSignposts.measureSync("BootstrapUnreadAccessPublication") {
            applyUnreadAccessProjection(initialAccess)
        }
        requestCoalescedUnreadPresentationRefresh()
        publishBootstrapAuthenticationState()
        if publishesSessionState {
            sessionState = .workspace
        }
        if let initialHistoryChannelID, let account {
            beginBootstrapHistoryPrefetch(
                channelID: initialHistoryChannelID,
                account: account
            )
        }
        AppPerformanceSignposts.measureSync("BootstrapMemberCacheSeed") {
            if let firstGuildID = value.guilds.first?.id {
                let indexed = Dictionary(
                    value.members.map { ($0.id, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                membersByGuildID[firstGuildID] = indexed
                memberListsByGuildID[firstGuildID] = value.members
            }
        }
        if let bootstrapStatus = value.members.first(where: {
            $0.id == value.currentUser.id
        })?.status {
            AppPerformanceSignposts.measureSync("BootstrapPresenceRestore") {
                currentStatus = bootstrapStatus
            }
        } else {
            let statusProvider = account?.provider ?? provider
            let restoredStatus = await AppPerformanceSignposts.measure(
                "BootstrapPresenceRestore"
            ) {
                await statusProvider.currentStatus()
            }
            guard canPublishBootstrap(for: account) else { return }
            currentStatus = restoredStatus
        }
        guard canPublishBootstrap(for: account) else { return }
        await AppPerformanceSignposts.measure("BootstrapInitialGuildActivation") {
            await activateGuild(
                initialGuildID,
                account: account
            )
        }
        guard canPublishBootstrap(for: account) else { return }
        if let retainedChannel,
           retainedChannel.guildID == initialGuildID,
           conversationAccess(for: retainedChannel).isReadable,
           selectedChannelID != retainedChannel.id
        {
            selectedChannelID = retainedChannel.id
        }
        await accountPersistence
        guard canPublishBootstrap(for: account) else { return }
        await waitForUnreadPresentationPreparation()
        guard canPublishBootstrap(for: account) else { return }
        await AppPerformanceSignposts.measure("BootstrapInitialConversation") {
            await channelLoadTask?.value
        }
    }

    private func bootstrapInitialGuildID(
        in value: BootstrapSnapshot,
        retainedChannel: Channel?
    ) -> GuildID? {
        let runsLoadingOverlapBenchmark =
            runsChatPerformanceBenchmark
            && ProcessInfo.processInfo.arguments.contains(
                "--debug-authenticated-loading-scroll-overlap-performance"
            )
        // Benchmark setup must not pre-open the measured guild. This is
        // evaluated before history prefetch and initial guild activation,
        // so each process launch retains a genuinely cold Google Labs
        // conversation even when it is first in READY ordering.
        return PerformanceBenchmarkInitialGuildPolicy.resolve(
            guilds: value.guilds,
            retainedGuildID: retainedChannel?.guildID,
            avoidingGuildNamed:
                runsLoadingOverlapBenchmark ? "Google Labs" : nil
        )
    }

    func canPublishBootstrap(for session: AppModelAccountSession?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let session else { return true }
        return isCurrentAccountSession(session)
    }

    func persistBootstrapAccount(
        _ account: SavedAccount?,
        session: AppModelAccountSession?
    ) async {
        guard let account, canPublishBootstrap(for: session) else { return }
        await AppPerformanceSignposts.measure("BootstrapAccountPersistence") {
            await savedAccountStore.record(account)
            guard canPublishBootstrap(for: session) else {
                // `record` also selects the account in persistent preferences.
                // If cancellation or an external session invalidation won the
                // actor hop, restore the currently installed account instead
                // of letting stale bootstrap work change the next launch.
                await savedAccountStore.setPreferredAccountID(activeAccountID)
                return
            }
            savedAccounts.removeAll { $0.accountID == account.accountID }
            savedAccounts.insert(account, at: 0)
            activeAccountID = account.accountID
        }
    }

    func logBootstrapUnreadState(_ value: BootstrapSnapshot) {
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
            firstGuildMutedOverrides=\(firstGuildMutedOverrideCount)
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

    func publishBootstrapAuthenticationState() {
        if credentialHandle != nil {
            isAuthenticated = true
        }
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
        let settings = try? await session.provider.emojiUserSettings()
        guard isCurrentAccountSession(session) else { return }
        if let settings {
            applyDiscordEmojiSettings(settings)
        }
        // Destination discovery is local once bootstrap state is available.
        // A failed or timed-out settings enrichment must not leave Forward on
        // an infinite loading state; persisted local deltas still provide the
        // best available frecency signal until the next authenticated session.
        hasLoadedDiscordEmojiSettings = true
        applyPersistedDiscordFrecencyUsageDeltas()
        forwardSearchSourceRevision &+= 1
    }

    func applyDiscordEmojiSettings(_ settings: EmojiUserSettings) {
        discordFavoriteEmojiKeys = settings.favoriteKeys
        discordFrequentlyUsedEmojiKeys = settings.frequentlyUsedKeys
        discordEmojiUsageScores = settings.usageScores
        discordGuildAndChannelUsageScores = settings.guildAndChannelUsageScores
        discordSyncedGuildAndChannelUsageScores = settings.guildAndChannelUsageScores
        discordGuildAndChannelUsage = settings.guildAndChannelUsage
        discordGuildAndChannelUsageOrder = settings.guildAndChannelUsageOrder
    }

    func recordEmojiUse(_ key: String) {
        emojiUsageCounts[key, default: 0] += 1
        emojiRecentKeys.removeAll { $0 == key }
        emojiRecentKeys.insert(key, at: 0)
        if emojiRecentKeys.count > 50 {
            emojiRecentKeys.removeLast(emojiRecentKeys.count - 50)
        }
        if persistsEmojiPreferences {
            UserDefaults.standard.set(emojiUsageCounts, forKey: "dev.sakuracord.emoji-usage")
            UserDefaults.standard.set(emojiRecentKeys, forKey: "dev.sakuracord.emoji-recents")
        }
    }

    func clearLocalEmojiRecents() {
        emojiRecentKeys.removeAll()
        if persistsEmojiPreferences {
            UserDefaults.standard.removeObject(forKey: "dev.sakuracord.emoji-recents")
            UserDefaults.standard.set([String](), forKey: "dev.sakuracord.emoji-recents")
        }
    }

    func resetLocalEmojiRanking() {
        emojiUsageCounts.removeAll()
        if persistsEmojiPreferences {
            UserDefaults.standard.removeObject(forKey: "dev.sakuracord.emoji-usage")
        }
    }

    @discardableResult
    func setEmojiFavorite(
        discordKey: String,
        isFavorite: Bool
    ) async -> Bool {
        let session = accountSession()
        do {
            let settings = try await session.provider.setEmojiFavorite(
                discordKey,
                isFavorite: isFavorite
            )
            guard isCurrentAccountSession(session) else { return false }
            applyDiscordEmojiSettings(settings)
            didAttemptDiscordEmojiSettings = true
            hasLoadedDiscordEmojiSettings = true
            forwardSearchSourceRevision &+= 1
            return true
        } catch {
            return false
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
        replyingTo = nil
        threadReplyingTo = nil
        conversationRefreshJournals.removeAll(keepingCapacity: false)
        memberLoadTask?.cancel()
        memberLoadTask = nil
        memberLoadGeneration &+= 1
        guildActivationTask?.cancel()
        guildActivationTask = nil
        gifSearchTask?.cancel()
        gifSearchTask = nil
        gifPickerLoadTask?.cancel()
        gifPickerLoadTask = nil
        gifPickerLoadGeneration &+= 1
        gifResults = []
        gifCategories = []
        gifTrendingPreviewURL = nil
        favoriteGIFs = []
        isLoadingGIFs = false
        isLoadingGIFPicker = false
        gifFavoriteMutationURL = nil
        gifErrorMessage = nil
        externalAttachmentUploadGeneration &+= 1
        externalAttachmentUploadTask?.cancel()
        externalAttachmentUploadTask = nil
        externalAttachmentUploadPresentation = nil
        releaseAllOwnedPromisedFiles()
        channelComposerAttachments = []
        threadComposerAttachments = []
        outgoingMessages.reset()
        oversizedAttachmentPrompt = nil
        queuedOversizedAttachmentPrompts.removeAll()
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

    func beginForumLoad() {
        channelLoadTask?.cancel()
        resetForumLoadAndPresentationState()
        replaceSelectedMessages(with: [])
        draft = ""
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
        isLoadingMessages = false
        isLoadingEarlier = false
        isLoadingLater = false
        hasMoreMessages = false
        hasMoreLaterMessages = false
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

#if DEBUG
    private enum AuthenticatedNavigationBenchmarkKind {
        case directMessage
        case server
        case channel

        var intervalName: StaticString {
            switch self {
            case .directMessage: "AuthenticatedDirectMessageOpen"
            case .server: "AuthenticatedServerOpen"
            case .channel: "AuthenticatedChannelOpen"
            }
        }
    }

    extension AppModel {
        func prepareAuthenticatedMemberListScrollPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await channelLoadTask?.value
            guard !Task.isCancelled,
                  let snapshot,
                  let targetGuild = snapshot.guilds.first(where: {
                      $0.name.localizedCaseInsensitiveCompare("Google Labs")
                          == .orderedSame
                  }),
                  let channel = benchmarkConversationChannels(
                      snapshot.channels.filter { $0.guildID == targetGuild.id }
                  ).sorted(by: Self.prefersStableLoadingBenchmarkChannel).first
            else {
                AppPerformanceSignposts.signposter.emitEvent(
                    "MemberListAutoScrollBenchmarkTargetUnavailable"
                )
                return
            }
            guard await runAuthenticatedNavigationBenchmarkOperation(
                channel: channel,
                kind: .server
            ) else { return }
            await memberLoadTask?.value
        }

        func prepareAuthenticatedTimelineScrollPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await channelLoadTask?.value
            if await prepareSelectedTimelineScrollHistory() { return }
            guard let snapshot else { return }
            let originalChannelID = selectedChannelID
            let candidates = benchmarkEligibleChannels(snapshot.channels)
                .filter { $0.id != originalChannelID }
                .sorted {
                    ($0.lastMessageID?.rawValue ?? 0)
                        > ($1.lastMessageID?.rawValue ?? 0)
                }
            for channel in candidates.prefix(12) {
                guard !Task.isCancelled else { return }
                let kind: AuthenticatedNavigationBenchmarkKind =
                    channel.guildID != selectedGuildID ? .server : .channel
                guard await runAuthenticatedNavigationBenchmarkOperation(
                    channel: channel,
                    kind: kind
                ) else { continue }
                if await prepareSelectedTimelineScrollHistory() { return }
            }
        }

        private func prepareSelectedTimelineScrollHistory() async -> Bool {
            let channelID = selectedChannelID
            var pageCount = 0
            while !Task.isCancelled,
                  selectedChannelID == channelID,
                  messages.count < 100,
                  hasMoreMessages,
                  pageCount < 5
            {
                let previousCount = messages.count
                await loadEarlier()
                await waitForSelectedEarlierHistoryRequest(channelID: channelID)
                pageCount += 1
                guard messages.count > previousCount else { break }
            }
            return messages.count >= 100
        }

        private func waitForSelectedEarlierHistoryRequest(
            channelID: ChannelID?
        ) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            while !Task.isCancelled,
                  selectedChannelID == channelID,
                  isLoadingEarlier,
                  clock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func runAuthenticatedHistoryPaginationPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark, sessionState == .workspace else { return }
            await channelLoadTask?.value
            await waitForSelectedEarlierHistoryIdle(
                channelID: selectedChannelID
            )
            if !hasMoreMessages, let snapshot {
                let candidates = benchmarkEligibleChannels(snapshot.channels)
                for channel in candidates where !hasMoreMessages {
                    guard !Task.isCancelled else { return }
                    _ = await runAuthenticatedNavigationBenchmarkOperation(
                        channel: channel,
                        kind: channel.guildID == nil ? .directMessage : .channel
                    )
                    await waitForSelectedEarlierHistoryIdle(
                        channelID: selectedChannelID
                    )
                }
            }
            guard !Task.isCancelled, hasMoreMessages, selectedChannelID != nil else {
                writeAuthenticatedHistoryPaginationBenchmarkResult(
                    outcome: "unavailable",
                    pageCount: 0
                )
                return
            }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedHistoryPaginationBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedHistoryPaginationBenchmark"
            )
            var pageCount = 0
            while pageCount < 5, hasMoreMessages, !Task.isCancelled {
                let messageCount = messages.count
                await loadEarlier()
                if messages.count > messageCount {
                    pageCount += 1
                } else {
                    break
                }
                await Task.yield()
            }
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedHistoryPaginationBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedHistoryPaginationBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedHistoryPaginationBenchmarkCompleted"
            )
            writeAuthenticatedHistoryPaginationBenchmarkResult(
                outcome: pageCount > 0 ? "completed" : "failed",
                pageCount: pageCount
            )
        }

        private func waitForSelectedEarlierHistoryIdle(
            channelID: ChannelID?
        ) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            var idleSince: ContinuousClock.Instant?
            while !Task.isCancelled,
                  selectedChannelID == channelID,
                  clock.now < deadline
            {
                if isLoadingEarlier {
                    idleSince = nil
                } else if let idleSince {
                    if idleSince.duration(to: clock.now)
                        >= .milliseconds(250)
                    {
                        return
                    }
                } else {
                    idleSince = clock.now
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        private func writeAuthenticatedHistoryPaginationBenchmarkResult(
            outcome: String,
            pageCount: Int
        ) {
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            page_count\t\(pageCount)

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
        }

        func runAuthenticatedAccountSwitchPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark, sessionState == .workspace else { return }
            let originalPreferredAccountID = await savedAccountStore.preferredAccountID()
            let sourceAccountID = activeAccountID ?? originalPreferredAccountID
            let handles: [CredentialHandle]
            do {
                handles = try await credentialStore.handles()
                rememberCredentialHandles(handles)
            } catch {
                writeAuthenticatedAccountSwitchBenchmarkResult(
                    outcome: "credential-error",
                    switchCount: 0,
                    sourceAccountID: sourceAccountID,
                    targetAccountID: nil
                )
                return
            }
            guard let target = handles
                .filter({ $0.accountID != activeAccountID })
                .sorted(by: { $0.accountID < $1.accountID })
                .first
            else {
                writeAuthenticatedAccountSwitchBenchmarkResult(
                    outcome: "unavailable",
                    switchCount: 0,
                    sourceAccountID: sourceAccountID,
                    targetAccountID: nil
                )
                return
            }

            await channelLoadTask?.value
            if let selectedChannelID {
                await AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: selectedChannelID
                )
            }
            guard !Task.isCancelled else { return }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedAccountSwitchBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedAccountSwitchBenchmark"
            )
            let switched = await switchAccount(to: target.accountID)
            var reachedFirstFrame = false
            if switched, let selectedChannelID {
                async let firstFrame: Void =
                    AppPerformanceSignposts.waitForConversationFirstFrame(
                        channelID: selectedChannelID
                    )
                await channelLoadTask?.value
                await firstFrame
                reachedFirstFrame = hasCompletedInitialMessageLoad
                    && self.selectedChannelID == selectedChannelID
            }
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedAccountSwitchBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedAccountSwitchBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedAccountSwitchBenchmarkCompleted"
            )

            await savedAccountStore.setPreferredAccountID(
                originalPreferredAccountID
            )
            writeAuthenticatedAccountSwitchBenchmarkResult(
                outcome: switched && reachedFirstFrame ? "completed" : "failed",
                switchCount: switched && reachedFirstFrame ? 1 : 0,
                sourceAccountID: sourceAccountID,
                targetAccountID: target.accountID
            )
        }

        private func writeAuthenticatedAccountSwitchBenchmarkResult(
            outcome: String,
            switchCount: Int,
            sourceAccountID: String?,
            targetAccountID: String?
        ) {
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            switch_count\t\(switchCount)
            source_account_id\t\(sourceAccountID ?? "")
            target_account_id\t\(targetAccountID ?? "")

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
        }

        func runAuthenticatedGestureScrollPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await channelLoadTask?.value
            if let selectedChannelID {
                await AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: selectedChannelID
                )
            }
            guard !Task.isCancelled else { return }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedGestureScrollBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedGestureScrollBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedGestureScrollBenchmarkReady"
            )
            try? await Task.sleep(for: .seconds(20))
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedGestureScrollBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedGestureScrollBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedGestureScrollBenchmarkCompleted"
            )
            writeAuthenticatedScrollInteractionBenchmarkResult(
                outcome: Task.isCancelled ? "cancelled" : "completed",
                target: "current",
                messageCount: messages.count
            )
        }

        // swiftlint:disable:next function_body_length
        func runAuthenticatedLoadingScrollOverlapPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await channelLoadTask?.value
            if let selectedChannelID {
                await AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: selectedChannelID
                )
            }
            func finishUnavailable(_ detail: String) {
                writeAuthenticatedScrollInteractionBenchmarkResult(
                    outcome: "unavailable",
                    target: "Google Labs",
                    messageCount: 0,
                    initialMessageCount: 0,
                    detail: detail
                )
            }
            guard !Task.isCancelled else {
                finishUnavailable("cancelled-before-setup")
                return
            }
            guard let snapshot else {
                finishUnavailable("snapshot-missing")
                return
            }
            guard let targetGuild = serverRailGuildsByID.values.first(where: {
                $0.name.localizedCaseInsensitiveCompare("Google Labs")
                    == .orderedSame
            }) else {
                finishUnavailable("target-guild-missing")
                return
            }
            guard selectedGuildID != targetGuild.id else {
                finishUnavailable("target-preselected")
                return
            }
            guard let channel = benchmarkConversationChannels(
                snapshot.channels.filter {
                    $0.guildID == targetGuild.id
                }
            ).sorted(by: Self.prefersStableLoadingBenchmarkChannel).first else {
                finishUnavailable("target-channels-missing")
                return
            }

            await settleAuthenticatedLoadingScrollIdleControl()
            guard !Task.isCancelled else {
                finishUnavailable("cancelled-during-idle-warmup")
                return
            }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedLoadingScrollOverlapBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedLoadingScrollOverlapBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedLoadingScrollOverlapBenchmarkReady"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedLoadingScrollIdleControlReady"
            )
            let idleControl = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedLoadingScrollIdleControl"
            )
            try? await Task.sleep(for: .seconds(8))
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedLoadingScrollIdleControl",
                idleControl
            )

            let loadingWork = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedLoadingScrollWork"
            )
            let opened = await runAuthenticatedNavigationBenchmarkOperation(
                channel: channel,
                kind: .server
            )
            let initialMessageCount = opened ? messages.count : 0
            if opened {
                await memberLoadTask?.value
                _ = await prepareSelectedTimelineScrollHistory()
            }
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedLoadingScrollWork",
                loadingWork
            )
            try? await Task.sleep(for: .seconds(3))
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedLoadingScrollOverlapBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedLoadingScrollOverlapBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedLoadingScrollOverlapBenchmarkCompleted"
            )
            writeAuthenticatedScrollInteractionBenchmarkResult(
                outcome:
                    opened
                        && initialMessageCount == 10
                        && messages.count >= 100
                        && !Task.isCancelled
                    ? "completed"
                    : (Task.isCancelled ? "cancelled" : "failed"),
                target: targetGuild.name,
                messageCount: messages.count,
                initialMessageCount: initialMessageCount,
                channel: channel
            )
        }

        private func settleAuthenticatedLoadingScrollIdleControl() async {
            await waitForSelectedTimelineHistoryIdle()
            _ = await prepareSelectedTimelineScrollHistory()
            await memberLoadTask?.value
            guard !Task.isCancelled else { return }
            // The model operations above await their state commits, while
            // SwiftUI/AppKit presentation follows on the next display turns.
            // Keep those final publications outside the idle control so its
            // latency distribution contains only user scrolling, never a
            // bootstrap pagination-boundary redraw.
            await waitForSelectedTimelineHistoryIdle()
        }

        private func waitForSelectedTimelineHistoryIdle() async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            var idleSince: ContinuousClock.Instant?
            while !Task.isCancelled, clock.now < deadline {
                if isLoadingEarlier || isLoadingLater {
                    idleSince = nil
                } else if let idleSince {
                    if idleSince.duration(to: clock.now)
                        >= .milliseconds(500)
                    {
                        return
                    }
                } else {
                    idleSince = clock.now
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        private nonisolated static func prefersActiveBenchmarkChannel(
            _ lhs: Channel,
            _ rhs: Channel
        ) -> Bool {
            let lhsLastMessage = lhs.lastMessageID?.rawValue ?? 0
            let rhsLastMessage = rhs.lastMessageID?.rawValue ?? 0
            if lhsLastMessage != rhsLastMessage {
                return lhsLastMessage > rhsLastMessage
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }

        private nonisolated static func prefersStableLoadingBenchmarkChannel(
            _ lhs: Channel,
            _ rhs: Channel
        ) -> Bool {
            let lhsIsGeneral = lhs.name.localizedLowercase.hasSuffix("general")
            let rhsIsGeneral = rhs.name.localizedLowercase.hasSuffix("general")
            if lhsIsGeneral != rhsIsGeneral {
                return lhsIsGeneral
            }
            let lhsHasHistory = lhs.lastMessageID != nil
            let rhsHasHistory = rhs.lastMessageID != nil
            if lhsHasHistory != rhsHasHistory {
                return lhsHasHistory
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }

        private func writeAuthenticatedScrollInteractionBenchmarkResult(
            outcome: String,
            target: String,
            messageCount: Int,
            initialMessageCount: Int? = nil,
            detail: String = "",
            channel: Channel? = nil
        ) {
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            detail\t\(detail)
            target\t\(target)
            target_channel_id\t\(channel?.id.rawValue.description ?? "")
            target_channel_name\t\(channel?.name ?? "")
            surface\t\(ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_SCROLL_SURFACE"] ?? "all")
            display_maximum_frames_per_second\t\(max(1, NSApp.keyWindow?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60))
            initial_message_count\t\(initialMessageCount ?? messageCount)
            message_count\t\(messageCount)

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
        }

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        func runAuthenticatedNavigationPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark, sessionState == .workspace else { return }
            await channelLoadTask?.value
            if let selectedChannelID {
                await AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: selectedChannelID
                )
            }
            guard !Task.isCancelled, let snapshot else {
                writeAuthenticatedNavigationBenchmarkResult(
                    outcome: "unavailable",
                    directMessageCount: 0,
                    serverCount: 0,
                    channelCount: 0
                )
                return
            }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedNavigationBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedNavigationBenchmark"
            )
            var directMessageCount = 0
            var serverCount = 0
            var channelCount = 0
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    "AuthenticatedNavigationBenchmark",
                    overall
                )
                AppPerformanceSignposts.endResourceWindow(
                    named: "AuthenticatedNavigationBenchmark"
                )
                AppPerformanceSignposts.signposter.emitEvent(
                    "AuthenticatedNavigationBenchmarkCompleted"
                )
                writeAuthenticatedNavigationBenchmarkResult(
                    outcome: Task.isCancelled ? "cancelled" : "completed",
                    directMessageCount: directMessageCount,
                    serverCount: serverCount,
                    channelCount: channelCount
                )
            }

            let initialChannelID = selectedChannelID
            var visitedChannelIDs: Set<ChannelID> = initialChannelID.map { [$0] } ?? []
            let unorderedPrivateChannels = benchmarkEligibleChannels(
                snapshot.channels.filter { $0.guildID == nil }
            )
            let preferredPrivateChannelID = Self.preferredInitialChannelID(
                in: unorderedPrivateChannels
            )
            let privateChannels = unorderedPrivateChannels.sorted { lhs, rhs in
                lhs.id == preferredPrivateChannelID && rhs.id != preferredPrivateChannelID
            }
            for channel in privateChannels where directMessageCount < 2 {
                guard !Task.isCancelled else { return }
                guard visitedChannelIDs.insert(channel.id).inserted else { continue }
                if await runAuthenticatedNavigationBenchmarkOperation(
                    channel: channel,
                    kind: .directMessage
                ) {
                    directMessageCount += 1
                }
            }

            let initialGuildID = selectedGuildID
            let orderedGuildIDs = serverRailItems.flatMap { item -> [GuildID] in
                switch item {
                case .guild(let guildID): [guildID]
                case .folder(let folder): folder.guildIDs
                }
            }
            var visitedGuildIDs: Set<GuildID> = []
            for guildID in orderedGuildIDs where serverCount < 3 {
                guard !Task.isCancelled else { return }
                guard guildID != initialGuildID,
                      visitedGuildIDs.insert(guildID).inserted
                else { continue }
                let candidates = benchmarkEligibleChannels(
                    snapshot.channels.filter { $0.guildID == guildID }
                )
                guard let serverChannel = candidates.first(where: {
                    !visitedChannelIDs.contains($0.id)
                }) else { continue }
                visitedChannelIDs.insert(serverChannel.id)
                if await runAuthenticatedNavigationBenchmarkOperation(
                    channel: serverChannel,
                    kind: .server
                ) {
                    serverCount += 1
                }
                guard !Task.isCancelled,
                      let secondChannel = candidates.first(where: {
                          !visitedChannelIDs.contains($0.id)
                      })
                else { continue }
                visitedChannelIDs.insert(secondChannel.id)
                if await runAuthenticatedNavigationBenchmarkOperation(
                    channel: secondChannel,
                    kind: .channel
                ) {
                    channelCount += 1
                }
            }
        }

        private func benchmarkEligibleChannels(_ channels: [Channel]) -> [Channel] {
            benchmarkConversationChannels(channels).filter { channel in
                guard conversationAccess(for: channel).isReadable else { return false }
                return true
            }
        }

        private func benchmarkConversationChannels(
            _ channels: [Channel]
        ) -> [Channel] {
            channels.filter { channel in
                switch channel.kind {
                case .text, .announcement, .directMessage, .groupDirectMessage:
                    true
                default:
                    false
                }
            }
        }

        private func runAuthenticatedNavigationBenchmarkOperation(
            channel: Channel,
            kind: AuthenticatedNavigationBenchmarkKind
        ) async -> Bool {
            let interval = AppPerformanceSignposts.signposter.beginInterval(
                kind.intervalName
            )
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    kind.intervalName,
                    interval
                )
            }
            if selectedGuildID != channel.guildID {
                if let guildID = channel.guildID {
                    lastOpenedChannelIDsByGuild[guildID] = channel.id
                }
                await activateGuild(channel.guildID)
            }
            guard !Task.isCancelled else { return false }
            if selectedChannelID != channel.id {
                selectedChannelID = channel.id
            }
            guard selectedChannelID == channel.id else { return false }
            async let firstFrame: Void =
                AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: channel.id
                )
            await channelLoadTask?.value
            await firstFrame
            return !Task.isCancelled
                && selectedChannelID == channel.id
                && hasCompletedInitialMessageLoad
        }

        private func writeAuthenticatedNavigationBenchmarkResult(
            outcome: String,
            directMessageCount: Int,
            serverCount: Int,
            channelCount: Int
        ) {
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            direct_message_count\t\(directMessageCount)
            server_count\t\(serverCount)
            channel_count\t\(channelCount)

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
        }
    }
#endif
