import Foundation
import SakuraCordModels
import SakuraCordPersistence

nonisolated struct LocalDraftStorageSummary: Equatable, Sendable {
    let selectedAccount: DraftStorageSummary?
    let allAccounts: DraftStorageSummary
    let accountCount: Int
}

extension AppModel {
    func localDraftStorageSummary() async throws -> LocalDraftStorageSummary {
        let activeID = activeAccountID
        let databases = draftDatabasesByAccountID()
        var selected: DraftStorageSummary?
        var all = DraftStorageSummary(draftCount: 0, approximateByteCount: 0)
        var countedAccounts = 0
        for (accountID, database) in databases {
            let summary = try await database.draftStorageSummary()
            countedAccounts += 1
            if accountID == activeID { selected = summary }
            all = DraftStorageSummary(
                draftCount: all.draftCount + summary.draftCount,
                approximateByteCount: all.approximateByteCount
                    + summary.approximateByteCount
            )
        }
        return LocalDraftStorageSummary(
            selectedAccount: selected,
            allAccounts: all,
            accountCount: countedAccounts
        )
    }

    func clearAllLocalDrafts() async throws {
        let session = accountSession()
        let databases = draftDatabasesByAccountID().map(\.1)
        for database in databases {
            try Task.checkCancellation()
            try await database.clearDrafts()
        }
        guard isCurrentAccountSession(session) else {
            throw LocalPrivacyActionError.accountChanged
        }
        draft = ""
        threadDraft = ""
        quickSwitcherDraftChannelIDs = []
    }

    private func draftDatabasesByAccountID() -> [(String, SakuraCordDatabase)] {
        var databases: [String: SakuraCordDatabase] = [:]
        if let activeAccountID, let database {
            databases[activeAccountID] = database
        }
        for account in savedAccounts where databases[account.accountID] == nil {
            guard let accountID = AccountID(account.accountID),
                  let database = accountDatabaseFactory(accountID)
            else { continue }
            databases[account.accountID] = database
        }
        return databases.sorted { $0.key < $1.key }
    }
}
