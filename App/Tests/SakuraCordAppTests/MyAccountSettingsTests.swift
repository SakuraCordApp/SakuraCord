@testable import SakuraCord
import DiscordProtocol
import Foundation
import Testing

@MainActor
@Test func `My Account catalog exposes every production control with honest scope`() {
    let expectedIDs: Set<SettingsControlID> = [
        .selectedAccount,
        .switchAccount,
        .addAccount,
        .reopenLastAccount,
        .preferredLaunchAccount,
        .removeSavedSession,
        .exportAccountPreferences,
        .resetAccountPreferences,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .myAccount
    }

    #expect(Set(controls.map(\.id)) == expectedIDs)
    #expect(
        controls.first { $0.id == .selectedAccount }?.scope
            == .accountLocal
    )
    #expect(
        controls.first { $0.id == .reopenLastAccount }?.scope
            == .appWideLocal
    )
    #expect(
        controls.first { $0.id == .removeSavedSession }?.owner
            == .appModel
    )

    let search = SettingsViewState()
    search.searchText = "default startup account"
    #expect(search.searchResults.first?.id == .preferredLaunchAccount)
    search.searchText = "keychain sign out"
    #expect(search.searchResults.contains { $0.id == .removeSavedSession })
    search.searchText = "backup account JSON"
    #expect(search.searchResults.contains { $0.id == .exportAccountPreferences })
}

@Test func `Settings account inspection selection is independent and repairs removed accounts`() {
    let first = SavedAccount(accountID: "100", displayName: "First")
    let second = SavedAccount(accountID: "200", displayName: "Second")
    let accounts = [first, second]

    #expect(
        SettingsAccountSelectionPolicy.accountID(
            storedAccountID: second.accountID,
            activeAccountID: first.accountID,
            accounts: accounts
        ) == second.accountID
    )
    #expect(
        SettingsAccountSelectionPolicy.accountID(
            storedAccountID: "removed",
            activeAccountID: first.accountID,
            accounts: accounts
        ) == first.accountID
    )
    #expect(
        SettingsAccountSelectionPolicy.accountID(
            storedAccountID: "removed",
            activeAccountID: "signed-out",
            accounts: accounts
        ) == first.accountID
    )
    #expect(
        SettingsAccountSelectionPolicy.accountID(
            storedAccountID: "removed",
            activeAccountID: nil,
            accounts: []
        ) == nil
    )
}

@Test func `account launch policy chooses last active or fixed preference safely`() {
    let first = CredentialHandle(accountID: "100")
    let second = CredentialHandle(accountID: "200")
    let handles = [first, second]

    #expect(
        SettingsAccountLaunchPolicy.handle(
            from: handles,
            reopensLastActiveAccount: true,
            lastActiveAccountID: second.accountID,
            preferredLaunchAccountID: first.accountID
        ) == second
    )
    #expect(
        SettingsAccountLaunchPolicy.handle(
            from: handles,
            reopensLastActiveAccount: false,
            lastActiveAccountID: second.accountID,
            preferredLaunchAccountID: first.accountID
        ) == first
    )
    #expect(
        SettingsAccountLaunchPolicy.handle(
            from: handles,
            reopensLastActiveAccount: false,
            lastActiveAccountID: second.accountID,
            preferredLaunchAccountID: "removed"
        ) == first
    )
}

@MainActor
@Test func `My Account launch preferences persist and reset through the production registry`() {
    let defaults = InMemoryPreferences()
    let store = SettingsPreferenceStore(defaults: defaults)

    #expect(store.value(for: .reopenLastAccount) == .bool(true))
    #expect(store.value(for: .preferredLaunchAccount) == .string(""))

    store.set(.bool(false), for: .reopenLastAccount)
    store.set(.string("200"), for: .preferredLaunchAccount)

    #expect(store.value(for: .reopenLastAccount) == .bool(false))
    #expect(store.value(for: .preferredLaunchAccount) == .string("200"))

    let export = store.export(scope: .appWide, page: .myAccount)
    #expect(
        export.values == [
            SettingsControlID.reopenLastAccount.rawValue: .bool(false),
            SettingsControlID.preferredLaunchAccount.rawValue: .string("200"),
        ]
    )

    store.reset(scope: .appWide, page: .myAccount)
    #expect(store.value(for: .reopenLastAccount) == .bool(true))
    #expect(store.value(for: .preferredLaunchAccount) == .string(""))
}
