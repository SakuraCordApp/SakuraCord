import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func connectPendingAuthenticatedAccount(
        _ credential: PendingDiscordCredential,
        preservesInteractivePresentation: Bool = false
    ) async -> Bool {
        guard !discordNetworkDisabled else {
            await credential.discard()
            errorMessage = "Discord networking is disabled in offline UI mode."
            return false
        }
        guard await accountTransitionCoordinator.acquireIfAvailable() else {
            await credential.discard()
            return false
        }
        accountTransitionIsActive = true
        let installationID = await AppPerformanceSignposts.measure("InstallationRestore") {
            await UserDefaultsDiscordFingerprintStore.shared.loadInstallationID()
        }
        guard !Task.isCancelled else {
            await credential.discard()
            await finishPendingAccountTransition()
            return false
        }
        let nextProvider = AppPerformanceSignposts.measureSync("ProviderCreation") {
            pendingAuthenticatedProviderFactory(credential, installationID)
        }
        await nextProvider.updateClientAppState(isFocused: mainWindowIsActive)
        do {
            try await nextProvider.prepareAuthentication()
        } catch {
            await nextProvider.discardPendingCredential()
            errorMessage = error.localizedDescription
            if !isAuthenticated {
                sessionState = .signedOut
            }
            await finishPendingAccountTransition()
            return false
        }
        guard !Task.isCancelled else {
            await stopPendingProvider(nextProvider)
            await finishPendingAccountTransition()
            return false
        }
        invalidateAccountSession()
        let connected = await performPendingAuthenticatedAccountConnection(
            provider: nextProvider,
            preservesInteractivePresentation: preservesInteractivePresentation,
            transitionGeneration: accountSessionGeneration
        )
        await finishPendingAccountTransition()
        return connected
    }

    private func finishPendingAccountTransition() async {
        accountTransitionIsActive = false
        await accountTransitionCoordinator.release()
    }

    func performPendingAuthenticatedAccountConnection(
        provider nextProvider: any PendingCredentialChatProvider,
        preservesInteractivePresentation: Bool,
        transitionGeneration: UInt64
    ) async -> Bool {
        guard let session = await preparePendingAuthenticatedAccountConnection(
            provider: nextProvider,
            preservesInteractivePresentation: preservesInteractivePresentation,
            transitionGeneration: transitionGeneration
        ) else { return false }
        isLoading = true
        defer {
            if isCurrentAccountSession(session) {
                isLoading = false
            }
        }

        do {
            let value = try await AppPerformanceSignposts.measure("ProviderBootstrap") {
                try await nextProvider.bootstrap()
            }
            guard isCurrentAccountSession(session), !Task.isCancelled else {
                await stopPendingProvider(nextProvider)
                return false
            }
            let handle = try await nextProvider.persistPendingCredential(
                to: credentialStore,
                accountID: value.currentUser.id.description
            )
            guard isCurrentAccountSession(session), !Task.isCancelled else {
                try? await credentialStore.remove(handle)
                await nextProvider.disconnect()
                return false
            }
            database = AppPerformanceSignposts.measureSync("AccountDatabaseOpen") {
                AccountID(handle.accountID).flatMap(accountDatabaseFactory)
            }
            resetForAccountConnection(handle)
            await applyLiveBootstrap(
                value,
                publishesSessionState: !preservesInteractivePresentation,
                account: session
            )
            guard isCurrentAccountSession(session) else { return false }
            isAuthenticated = snapshot != nil
            sessionState = isAuthenticated ? .workspace : .signedOut
            if isAuthenticated {
                await requestNotificationPermissionIfNeeded()
                guard isCurrentAccountSession(session) else { return false }
            }
            return isAuthenticated
        } catch {
            await failPendingAuthenticatedAccountConnection(
                error,
                provider: nextProvider,
                session: session
            )
            return false
        }
    }

    private func preparePendingAuthenticatedAccountConnection(
        provider nextProvider: any PendingCredentialChatProvider,
        preservesInteractivePresentation: Bool,
        transitionGeneration: UInt64
    ) async -> AppModelAccountSession? {
        let previousAccount = accountSession(allowsTransition: true)
        let previousProvider = previousAccount.provider
        let previousEventTask = eventTask
        resetAccountScopedLoadsAndForumState()
        await leaveVoice(account: previousAccount)
        guard await pendingTransitionIsCurrent(transitionGeneration, provider: nextProvider)
        else { return nil }
        resetAppSounds()
        await previousProvider.disconnect()
        guard await pendingTransitionIsCurrent(transitionGeneration, provider: nextProvider)
        else { return nil }
        previousEventTask?.cancel()
        await previousEventTask?.value
        guard await pendingTransitionIsCurrent(transitionGeneration, provider: nextProvider)
        else { return nil }
        eventTask = nil
        await drainAccountChildTasks()
        guard await pendingTransitionIsCurrent(transitionGeneration, provider: nextProvider)
        else { return nil }
        resetPendingCreatedMessages()
        resetTimelineLiveScrolling()
        clearReactionMutationState()
        stopLocalTyping(clearThrottle: true)
        typingState.clearAll()
        if !preservesInteractivePresentation {
            sessionState = .connecting
        }
        installAccountSession(provider: nextProvider, database: nil)
        accountTransitionIsActive = false
        credentialHandle = nil
        didAttemptSessionRestore = true
        resetAccountPresentationState()
        let session = accountSession()
        await refreshSupportedCapabilities(for: session)
        guard isCurrentAccountSession(session) else {
            await stopPendingProvider(nextProvider)
            return nil
        }
        let stream = await nextProvider.eventStream()
        guard isCurrentAccountSession(session) else {
            await stopPendingProvider(nextProvider)
            return nil
        }
        installEventTask(stream, account: session)
        return session
    }

    private func pendingTransitionIsCurrent(
        _ transitionGeneration: UInt64,
        provider: any PendingCredentialChatProvider
    ) async -> Bool {
        guard accountSessionGeneration == transitionGeneration else {
            await stopPendingProvider(provider)
            return false
        }
        return true
    }

    private func failPendingAuthenticatedAccountConnection(
        _ error: any Error,
        provider: any PendingCredentialChatProvider,
        session: AppModelAccountSession
    ) async {
        await stopPendingProvider(provider)
        eventTask?.cancel()
        await eventTask?.value
        guard isCurrentAccountSession(session) else { return }
        eventTask = nil
        installAccountSession(provider: SignedOutChatProvider(), database: nil)
        credentialHandle = nil
        handleSessionStartFailure(error, account: accountSession())
    }

    private func stopPendingProvider(
        _ provider: any PendingCredentialChatProvider
    ) async {
        await provider.discardPendingCredential()
        await provider.disconnect()
    }
}
