import Foundation

extension AppModel {
    func clearLocalMessageSearchData() {
        messageSearch.clear()
        messageSearch.isPresented = false
    }

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

    func clearLocalDrafts() async throws {
        let session = accountSession()
        guard let database = session.database else {
            throw LocalPrivacyActionError.noActiveAccount
        }
        try await database.clearDrafts()
        guard isCurrentAccountSession(session) else {
            throw LocalPrivacyActionError.accountChanged
        }
        draft = ""
        threadDraft = ""
        quickSwitcherDraftChannelIDs = []
        await applyConfiguredLocalStorageLimit()
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
            "The active account changed while drafts were being cleared."
        }
    }
}
