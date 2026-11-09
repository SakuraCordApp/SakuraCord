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
        // These obsolete local-only rankings are no longer read. Pending uses
        // belong to Discord-synchronized settings, not disposable learning.
        guard persistsEmojiPreferences else { return }
        for key in ["dev.sakuracord.emoji-recents", "dev.sakuracord.emoji-usage", "dev.sakuracord.favorite-emojis"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        translation.resetDraft(.channel)
        translation.resetDraft(.thread)
        let previousDraftChannelIDs = quickSwitcherDraftChannelIDs
        quickSwitcherDraftChannelIDs = []
        do {
            try await composer.clearDrafts(in: database)
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
