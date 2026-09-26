import Foundation
import SakuraCordModels
import SakuraCordPersistence

nonisolated struct LocalDraftStorageSummary: Equatable, Sendable {
    let allAccounts: DraftStorageSummary
}

extension AppModel {
    func localDraftStorageSummary() async throws -> LocalDraftStorageSummary {
        let databases = draftDatabasesByAccountID()
        await composer.flushDraftOperations()
        await onboarding.draftWrite?.value
        var all = DraftStorageSummary(draftCount: 0, approximateByteCount: 0)
        for (_, database) in databases {
            let summary = try await database.draftStorageSummary()
            all = DraftStorageSummary(
                draftCount: all.draftCount + summary.draftCount,
                approximateByteCount: all.approximateByteCount
                    + summary.approximateByteCount
            )
        }
        return LocalDraftStorageSummary(allAccounts: all)
    }

    @discardableResult
    func applyLocalStorageLimit(
        _ limit: LocalStorageLimit
    ) async throws -> LocalDraftStorageSummary {
        let summary = try await localDraftStorageSummary()
        try await LocalStorageBudgetCoordinator.shared.apply(
            limit: limit,
            measuredDraftBytes: summary.allAccounts.approximateByteCount
        )
        return summary
    }

    func applyConfiguredLocalStorageLimit() async {
        let limit = StorageDownloadsSettingsStore.shared.load().localStorageLimit
        _ = try? await applyLocalStorageLimit(limit)
    }

    func clearAllLocalDrafts() async throws {
        let session = accountSession()
        let databases = draftDatabasesByAccountID().map(\.1)
        if session.database != nil {
            try await clearActiveLocalDrafts(account: session)
        }
        for database in databases where database !== session.database {
            try Task.checkCancellation()
            guard isCurrentAccountSession(session) else { throw LocalPrivacyActionError.accountChanged }
            try await database.clearDrafts()
        }
        guard isCurrentAccountSession(session) else {
            throw LocalPrivacyActionError.accountChanged
        }
        await applyConfiguredLocalStorageLimit()
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
