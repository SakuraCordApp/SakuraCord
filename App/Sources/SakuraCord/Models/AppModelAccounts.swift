import DiscordProtocol
import Foundation
import SakuraCordModels
import SakuraCordPersistence

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

nonisolated enum BootstrapInitialGuildPolicy {
    static func resolve(
        guilds: [Guild],
        retainedChannel: Channel?,
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
        // A retained DM deliberately selects Home (nil), not the first server.
        if let retainedChannel { return retainedChannel.guildID }
        return guilds.first?.id
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
                try await removeSavedAccount(accountID: accountID)
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
        await nextProvider.updateClientAppState(isFocused: applicationIsActive)
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
        await resetAccountScopedLoadsAndForumState()
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
        hasPendingLaunchWelcome = false
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
        serverRailItems = []
        emojisByGuild = [:]
        loadingEmojiGuildIDs = []
        emojiLoadErrorsByGuild = [:]
        soundboardLoadGeneration &+= 1
        soundboardLoadTask?.cancel()
        soundboardLoadTask = nil
        defaultSoundboardSounds = []
        soundboardSoundsByGuild = [:]
        soundboardUserSettings = .init()
        isLoadingSoundboard = false
        soundboardErrorMessage = nil
        soundboardState.pendingNativeEchoes = []
        soundboardState.confirmedNativeEchoes = [:]
        soundboardState.activePlaybackTokens = [:]
        soundboardState.cardAnimations = []
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
        conversationNavigationHistory = ConversationNavigationHistory()
        replaceSelectedMessages(with: [])
        hasCompletedInitialMessageLoad = false
        hasCompletedInitialThreadLoad = false
        isLoadingLater = false
        hasMoreLaterMessages = false
        messageCache = [:]
        pinnedMessages.clear(notifying: self)
        inbox.clear(notifying: self)
        messageCacheOrder = []
        messageRowCache = [:]
        messageRowCacheOrder = []
        hasMoreCache = [:]
        membersByGuildID = [:]
        profileCustomStatus = nil
        profileCustomStatusUserID = nil
        presentedProfileGame = nil
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
            try await removeSavedAccount(
                accountID: accountID,
                credentialHandle: handles.first(where: { $0.accountID == accountID })
            )
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
        let previousAccountID = previousCredentialHandle?.accountID ?? activeAccountID
        await resetAccountScopedLoadsAndForumState()
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
        var removalError: String?
        if let previousAccountID {
            do {
                try await removeSavedAccount(accountID: previousAccountID, credentialHandle: previousCredentialHandle)
                guard accountSessionGeneration == transitionGeneration else { return }
            } catch {
                guard accountSessionGeneration == transitionGeneration else { return }
                removalError = error.localizedDescription
            }
        }
        installSignedOutAccountState()
        errorMessage = removalError
        if launchMode == .offlineTesting {
            await start()
            guard accountSessionGeneration == transitionGeneration else { return }
        }
    }

    func installSignedOutAccountState() {
        hasPendingLaunchWelcome = false
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
        resetAccountPresentationState()
        connectionState = .disconnected
        isAuthenticated = false
        didAttemptSessionRestore = true
        sessionState = launchMode == .offlineTesting ? .connecting : .signedOut
    }

    func removeSavedAccount(
        accountID: String,
        credentialHandle: CredentialHandle? = nil,
        clearCaches: (String) async throws -> Void = { try await DiscordDerivedCacheStorage.remove(accountID: $0) }
    ) async throws {
        if let credentialHandle { try await credentialStore.remove(credentialHandle) }
        credentialHandlesByAccountID[accountID] = nil
        await savedAccountStore.remove(accountID: accountID)
        savedAccounts.removeAll { $0.accountID == accountID }
        await savedAccountStore.setPreferredAccountID(
            activeAccountID != accountID ? activeAccountID ?? savedAccounts.first?.accountID : savedAccounts.first?.accountID
        )
        if launchMode == .normal {
            do {
                try await clearCaches(accountID)
            } catch {
                throw SavedAccountCacheCleanupError(reason: error.localizedDescription)
            }
        }
    }

    func resetAccountScopedLoadsAndForumState() async {
        cancelAccountChildTasks()
        resetPendingCreatedMessages()
        resetTimelineLiveScrolling()
        clearReactionMutationState()
        stopLocalTyping(clearThrottle: true)
        typingState.clearAll()
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
        cancelConversationNavigation()
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
        attachmentCompactionGeneration &+= 1
        attachmentCompactionTask?.cancel()
        attachmentCompactionTask = nil
        attachmentCompactionPresentation = nil
        externalAttachmentUploadGeneration &+= 1
        externalAttachmentUploadTask?.cancel()
        externalAttachmentUploadTask = nil
        externalAttachmentUploadPresentation = nil
        uploadPrivacyPreparation.reset()
        releaseAllOwnedPromisedFiles()
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
        standardStickerPacks = []
        stickerUserSettings = StickerUserSettings()
        isLoadingStickerPicker = false
        stickerPickerErrorMessage = nil
        loadingReactionReactors = []
        failedReactionReactorLoads = [:]
        resetForumLoadAndPresentationState()
        await composer.reset()
        await onboarding.draftWrite?.value
    }
}

private struct SavedAccountCacheCleanupError: LocalizedError {
    let reason: String
    var errorDescription: String? {
        "The saved account was removed, but its local search cache could not be cleared: \(reason)"
    }
}
