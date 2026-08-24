import DiscordProtocol

nonisolated enum SettingsAccountSelectionPolicy {
    static func accountID(
        storedAccountID: String,
        activeAccountID: String?,
        accounts: [SavedAccount]
    ) -> String? {
        if accounts.contains(where: { $0.accountID == storedAccountID }) {
            return storedAccountID
        }
        if let activeAccountID,
           accounts.contains(where: { $0.accountID == activeAccountID })
        {
            return activeAccountID
        }
        return accounts.first?.accountID
    }
}

nonisolated enum SettingsAccountLaunchPolicy {
    static func handle(
        from handles: [CredentialHandle],
        reopensLastActiveAccount: Bool,
        lastActiveAccountID: String?,
        preferredLaunchAccountID: String?
    ) -> CredentialHandle? {
        let requestedAccountID = reopensLastActiveAccount
            ? lastActiveAccountID
            : preferredLaunchAccountID
        if let requestedAccountID,
           let requested = handles.first(where: {
               $0.accountID == requestedAccountID
           })
        {
            return requested
        }
        return handles.first
    }
}
