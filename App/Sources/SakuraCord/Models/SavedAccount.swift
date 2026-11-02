import DiscordProtocol
import Foundation
import SakuraCordModels

nonisolated struct SavedAccount: Codable, Hashable, Identifiable, Sendable {
    let accountID: String
    var username: String?
    var displayName: String?
    var avatarURL: URL?
    var lastUsedAt: Date?
    // Set when Discord rejects the saved session, such as after a password
    // change. A successful sign-in records a fresh value without it.
    var signInRequiredAt: Date?

    var id: String { accountID }

    var requiresSignIn: Bool { signInRequiredAt != nil }

    var resolvedDisplayName: String {
        displayName ?? username ?? "Discord Account"
    }

    var resolvedSubtitle: String {
        if let username {
            return "@\(username)"
        }
        let suffix = accountID.suffix(4)
        return suffix.isEmpty ? "Saved account" : "Saved account ••••\(suffix)"
    }

    init(
        accountID: String,
        username: String? = nil,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        lastUsedAt: Date? = nil,
        signInRequiredAt: Date? = nil
    ) {
        self.accountID = accountID
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.lastUsedAt = lastUsedAt
        self.signInRequiredAt = signInRequiredAt
    }

    init(handle: CredentialHandle) {
        self.init(accountID: handle.accountID)
    }

    init(user: User, lastUsedAt: Date = .now) {
        self.init(
            accountID: user.id.description,
            username: user.username,
            displayName: user.displayName,
            avatarURL: user.avatarURL,
            lastUsedAt: lastUsedAt
        )
    }
}

nonisolated protocol SavedAccountStoring: Sendable {
    func accounts(matching handles: [CredentialHandle]) async -> [SavedAccount]
    func preferredAccountID() async -> String?
    func record(_ account: SavedAccount) async
    func markSignInRequired(accountID: String) async
    func remove(accountID: String) async
    func setPreferredAccountID(_ accountID: String?) async
}

actor UserDefaultsSavedAccountStore: SavedAccountStoring {
    nonisolated static let shared = UserDefaultsSavedAccountStore()

    private nonisolated static let accountsKey =
        "dev.sakuracord.saved-account-presentations"
    private nonisolated static let preferredAccountKey =
        "dev.sakuracord.preferred-account-id"

    private let defaults: any PreferenceStoring

    init(
        defaults: any PreferenceStoring = PRBuildProfile.defaults,
        seedFrom source: (any PreferenceStoring)? = PRBuildProfile.savedAccountMetadataSource
    ) {
        self.defaults = defaults
        if let source {
            let marker = "dev.sakuracord.preview-account-metadata-seeded"
            if !defaults.bool(forKey: marker) {
                // Only picker metadata crosses profiles; credentials remain in
                // Keychain, and preview changes never write back to the source.
                if defaults.object(forKey: Self.accountsKey) == nil,
                   defaults.object(forKey: Self.preferredAccountKey) == nil
                {
                    if let accounts = source.data(forKey: Self.accountsKey) {
                        defaults.set(accounts, forKey: Self.accountsKey)
                    }
                    if let preferred = source.string(forKey: Self.preferredAccountKey) {
                        defaults.set(preferred, forKey: Self.preferredAccountKey)
                    }
                }
                defaults.set(true, forKey: marker)
            }
        }
    }

    // A presentation hint available before asynchronous credential restoration.
    // The credential store remains authoritative for account availability.
    nonisolated var hasSavedAccounts: Bool {
        !storedAccounts().isEmpty
    }

    func accounts(matching handles: [CredentialHandle]) -> [SavedAccount] {
        var storedByID: [String: SavedAccount] = [:]
        for account in storedAccounts() {
            storedByID[account.accountID] = account
        }
        return handles
            .map { storedByID[$0.accountID] ?? SavedAccount(handle: $0) }
            .sorted(by: Self.sortsBefore)
    }

    func preferredAccountID() -> String? {
        defaults.string(forKey: Self.preferredAccountKey)
    }

    func record(_ account: SavedAccount) {
        var accounts = storedAccounts()
        accounts.removeAll { $0.accountID == account.accountID }
        accounts.append(account)
        persist(accounts.sorted(by: Self.sortsBefore))
        defaults.set(account.accountID, forKey: Self.preferredAccountKey)
    }

    func markSignInRequired(accountID: String) {
        var accounts = storedAccounts()
        if let index = accounts.firstIndex(where: { $0.accountID == accountID }) {
            guard !accounts[index].requiresSignIn else { return }
            accounts[index].signInRequiredAt = .now
        } else {
            accounts.append(SavedAccount(accountID: accountID, signInRequiredAt: .now))
        }
        persist(accounts.sorted(by: Self.sortsBefore))
    }

    func remove(accountID: String) {
        var accounts = storedAccounts()
        accounts.removeAll { $0.accountID == accountID }
        persist(accounts)
        if preferredAccountID() == accountID {
            defaults.removeObject(forKey: Self.preferredAccountKey)
        }
    }

    func setPreferredAccountID(_ accountID: String?) {
        if let accountID {
            defaults.set(accountID, forKey: Self.preferredAccountKey)
        } else {
            defaults.removeObject(forKey: Self.preferredAccountKey)
        }
    }

    private nonisolated func storedAccounts() -> [SavedAccount] {
        guard let data = defaults.data(forKey: Self.accountsKey),
              let accounts = try? JSONDecoder().decode([SavedAccount].self, from: data)
        else { return [] }
        return accounts
    }

    private func persist(_ accounts: [SavedAccount]) {
        guard !accounts.isEmpty else {
            defaults.removeObject(forKey: Self.accountsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.accountsKey)
    }

    private nonisolated static func sortsBefore(
        _ lhs: SavedAccount,
        _ rhs: SavedAccount
    ) -> Bool {
        switch (lhs.lastUsedAt, rhs.lastUsedAt) {
        case let (left?, right?) where left != right:
            left > right
        case (_?, nil):
            true
        case (nil, _?):
            false
        default:
            lhs.accountID < rhs.accountID
        }
    }
}
