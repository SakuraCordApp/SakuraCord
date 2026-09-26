import DiscordProtocol
import Foundation
import SakuraCordModels
import SakuraCordPersistence

extension AppModel {
    func completeOfflineSignIn() async -> String? {
        guard launchMode == .offlineTesting, awaitsOfflineSignIn else {
            return "The offline sign-in session is no longer active."
        }
        awaitsOfflineSignIn = false
        await start(publishesSessionState: false)
        if snapshot != nil {
            sessionState = .workspace
            return nil
        }
        awaitsOfflineSignIn = true
        sessionState = .signedOut
        return errorMessage ?? "The offline workspace could not be opened."
    }

    func start(publishesSessionState: Bool = true) async {
        guard !awaitsOfflineSignIn else { return }
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

        let previousEventTask = eventTask
        previousEventTask?.cancel()
        eventTask = nil
        await resetAccountScopedLoadsAndForumState()
        guard isCurrentAccountSession(session) else { return }
        await leaveVoice(account: session, notifyDiscord: false)
        guard isCurrentAccountSession(session) else { return }
        resetAppSounds()
        await session.provider.disconnect()
        await previousEventTask?.value
        guard isCurrentAccountSession(session) else { return }
        await drainAccountChildTasks()
        guard isCurrentAccountSession(session) else { return }

        installSignedOutAccountState()
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
                if case let .sessionInvalidated(reason) = event {
                    // Detach this consumer before teardown, which drains eventTask.
                    self.eventTask = nil
                    await self.failAuthenticatedSessionStart(
                        ChatProviderError.invalidRequest(reason), account: account
                    )
                    break
                }
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
        DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
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
            hasPendingLaunchWelcome = !didAttemptSessionRestore
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
            if savedAccounts.isEmpty {
                // If a remembered account disappeared, return to sign-in
                // without playing the welcome after its loading skeleton.
                hasPendingLaunchWelcome = sessionState == .restoring
                isLoading = false
                sessionState = .signedOut
                return false
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
                    ?? .lastVisitedConversation
            } else {
                .lastVisitedConversation
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
            let restoredHandle = handles.flatMap { handles in
                SettingsLaunchAccountPolicy.handle(
                    from: handles,
                    performanceAccountID: preferredPerformanceAccountID,
                    lastVisitedAccountID: SettingsConversationRestorationStore
                        .shared.preferredAccountID(for: launchDestination),
                    lastActiveAccountID: preferredStoredAccountID
                )
            }
            if let restoredHandle {
                SettingsConversationRestorationStore.shared.prepareLaunch(
                    destination: launchDestination
                )
                sessionState = .connecting
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

    func applyBootstrap(
        _ value: BootstrapSnapshot,
        publishesSessionState: Bool,
        account: AppModelAccountSession? = nil
    ) async {
        if let account, !isCurrentAccountSession(account) { return }
        AppPerformanceSignposts.measureSync("BootstrapSnapshotPublish") {
            snapshot = value
            onboarding.members = value.currentMembersByGuildID
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
        let initialReadState = await makeBootstrapReadState(from: value)
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
        beginCurrentUserProfilePrefetch(in: initialGuildID, account: account)
        let initialHistoryChannelID = bootstrapInitialHistoryChannelID(
            in: value,
            retainedChannel: retainedChannel,
            initialGuildID: initialGuildID
        )
        let initialAccess = await prepareBootstrapInitialAccess(account: account)
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
        guard await seedBootstrapMemberCacheAndRestorePresence(
            from: value,
            account: account
        ) else { return }
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

    private func prepareBootstrapInitialAccess(
        account: AppModelAccountSession?
    ) async -> UnreadAccessProjection? {
        if launchMode == .offlineTesting {
            return snapshot.map { unreadAccessProjection(for: $0.channels) }
        }
        if let account {
            return await prepareBootstrapUnreadAccessProjection(account: account)
        }
        return snapshot.map { unreadAccessProjection(for: $0.channels) }
    }

    private func makeBootstrapReadState(
        from value: BootstrapSnapshot
    ) async -> AccountReadStateModel.InitialState {
        let accountID = credentialHandle?.accountID
            ?? (launchMode == .offlineTesting ? "offline" : nil)
        return await AppPerformanceSignposts.measure("BootstrapReadStateBuild") {
            await Task.detached(priority: .userInitiated) {
                AccountReadStateModel.makeInitialState(.init(
                    accountID: accountID,
                    guilds: value.guilds,
                    channels: value.channels,
                    threads: value.threads,
                    readStates: value.readStates,
                    notificationSettings: value.notificationSettings,
                    usesNewNotifications: value.usesNewNotifications,
                    currentUserID: value.currentUser.id
                ))
            }.value
        }
    }

    private func seedBootstrapMemberCacheAndRestorePresence(
        from value: BootstrapSnapshot,
        account: AppModelAccountSession?
    ) async -> Bool {
        AppPerformanceSignposts.measureSync("BootstrapMemberCacheSeed") {
            guard let firstGuildID = value.guilds.first?.id else { return }
            let indexed = Dictionary(
                value.members.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            membersByGuildID[firstGuildID] = indexed
            memberListsByGuildID[firstGuildID] = value.members
        }
        if let bootstrapStatus = value.members.first(where: {
            $0.id == value.currentUser.id
        })?.status {
            AppPerformanceSignposts.measureSync("BootstrapPresenceRestore") {
                currentStatus = bootstrapStatus
            }
            return true
        }
        let statusProvider = account?.provider ?? provider
        let restoredStatus = await AppPerformanceSignposts.measure(
            "BootstrapPresenceRestore"
        ) {
            await statusProvider.currentStatus()
        }
        guard canPublishBootstrap(for: account) else { return false }
        currentStatus = restoredStatus
        return true
    }

    private func bootstrapInitialHistoryChannelID(
        in value: BootstrapSnapshot,
        retainedChannel: Channel?,
        initialGuildID: GuildID?
    ) -> ChannelID? {
        AppPerformanceSignposts.measureSync("BootstrapNavigationProjection") {
            AppPerformanceSignposts.measureSync("BootstrapUnreadDiagnostics") {
                logBootstrapUnreadState(value)
            }
            AppPerformanceSignposts.measureSync("BootstrapAccessSourcePublication") {
                applyBootstrapCurrentUserRoles(value)
                updateServerRail(from: value)
            }
            let permissionBasis = initialGuildID.flatMap {
                conversationPermissionBasis(for: $0)
            }
            let initialChannel = bootstrapInitialChannel(
                in: value.channels,
                retainedChannel: retainedChannel,
                guildID: initialGuildID,
                permissionBasis: permissionBasis
            )
            guard let initialChannel,
                  initialChannel.kind != .forum,
                  initialChannel.kind != .voice,
                  conversationAccess(
                      for: initialChannel,
                      permissionBasis: permissionBasis
                  ).isReadable
            else { return nil }
            return initialChannel.id
        }
    }

    private func bootstrapInitialChannel(
        in channels: [Channel],
        retainedChannel: Channel?,
        guildID: GuildID?,
        permissionBasis: ConversationPermissionBasis?
    ) -> Channel? {
        AppPerformanceSignposts.measureSync("BootstrapInitialChannelProjection") {
            let initialChannels = channels.filter { channel in
                guildID == nil ? channel.guildID == nil : channel.guildID == guildID
            }
            let selectableChannels = initialChannels.filter {
                conversationAccess(for: $0, permissionBasis: permissionBasis) != .hidden
            }
            let rememberedChannel = guildID
                .flatMap { lastOpenedChannelIDsByGuild[$0] }
                .flatMap { rememberedID in
                    selectableChannels.first { $0.id == rememberedID }
                }
            let retainedSelectableChannel = retainedChannel.flatMap { retained in
                selectableChannels.first { $0.id == retained.id }
            }
            return retainedSelectableChannel
                ?? rememberedChannel
                ?? Self.preferredInitialChannelID(in: selectableChannels).flatMap { preferredID in
                    selectableChannels.first { $0.id == preferredID }
                }
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
        return BootstrapInitialGuildPolicy.resolve(
            guilds: value.guilds,
            retainedChannel: retainedChannel,
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

}
