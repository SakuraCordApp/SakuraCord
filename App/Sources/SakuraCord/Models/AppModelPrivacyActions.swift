import Foundation

extension AppModel {
    func clearLocalDestinationHistory() {
        forwardDestinationHistory = []
        workspaceNavigationOverlay = nil
        guard launchMode == .normal else { return }
        UserDefaults.standard.removeObject(
            forKey: forwardDestinationHistoryDefaultsKey
        )
    }

    func clearLocallyLearnedEmojiRanking() {
        clearLocalEmojiRecents()
        resetLocalEmojiRanking()
    }

    func clearLocalActivity() async throws {
        let session = accountSession()
        try await session.provider.clearLocalSearchCache()
        guard isCurrentAccountSession(session) else { throw LocalPrivacyActionError.accountChanged }
        snapshot?.forwardChannelStoreOrder = []
        forwardSearchSourceRevision &+= 1
        clearLocalDestinationHistory()
        clearLocallyLearnedEmojiRanking()
    }

    func clearLocalDrafts() async throws {
        try await clearActiveLocalDrafts(account: accountSession())
        await applyConfiguredLocalStorageLimit()
    }

    func clearActiveLocalDrafts(account session: AppModelAccountSession) async throws {
        guard isCurrentAccountSession(session) else { throw LocalPrivacyActionError.accountChanged }
        guard let database = session.database else {
            throw LocalPrivacyActionError.noActiveAccount
        }
        let previousDraftChannelIDs = quickSwitcherDraftChannelIDs
        quickSwitcherDraftChannelIDs = []
        do {
            let previous = onboarding.draftWrite
            let revisions = onboarding.entries.mapValues(\.revision)
            let deletion = Task {
                await previous?.value
                try await composer.clearDrafts(in: database)
            }
            onboarding.draftWrite = Task { _ = try? await deletion.value }
            try await deletion.value
            if isCurrentAccountSession(session) {
                for (guildID, revision) in revisions where onboarding.entries[guildID]?.revision == revision {
                    onboarding.entries[guildID] = nil
                }
                onboarding.presentedGuildID = nil
            }
        } catch {
            if isCurrentAccountSession(session) {
                let currentIDs = Set(quickSwitcherDraftChannelIDs)
                quickSwitcherDraftChannelIDs += previousDraftChannelIDs.filter { !currentIDs.contains($0) }
            }
            throw error
        }
        guard isCurrentAccountSession(session) else {
            throw LocalPrivacyActionError.accountChanged
        }
    }
}

nonisolated enum LocalPrivacyActionError: LocalizedError {
    case noActiveAccount
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            "No signed-in account has local drafts to clear."
        case .accountChanged:
            "The active account changed while local data was being cleared."
        }
    }
}
