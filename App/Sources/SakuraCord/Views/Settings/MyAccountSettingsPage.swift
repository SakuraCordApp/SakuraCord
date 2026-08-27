import SwiftUI
import UniformTypeIdentifiers

struct MyAccountSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState
    @Binding var selectedAccountID: String

    @State private var showsLogin = false
    @State private var operation: AccountOperation?
    @State private var pendingRemoval: SavedAccount?
    @State private var operationMessage: AccountOperationMessage?
    @State private var confirmsReset = false
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var exportFilename = "SakuraCord Account Preferences"
    @State private var isExporting = false
    @State private var reopensLastActiveAccount = true
    @State private var preferredLaunchAccountID = ""

    private var selectedAccount: SavedAccount? {
        model.savedAccounts.first { $0.accountID == selectedAccountID }
    }

    private var isBusy: Bool {
        operation != nil || model.isSwitchingAccounts
    }

    var body: some View {
        SettingsPageForm(page: .myAccount, state: state) {
            accountIdentitySection
            accountLaunchSection
            accountLocalDataSection
        }
        .task {
            loadLaunchPreferences()
            await model.refreshSavedAccounts()
            normalizeSelectedAccount()
            normalizePreferredLaunchAccount()
        }
        .onChange(of: model.savedAccounts.map(\.accountID)) {
            normalizeSelectedAccount()
            normalizePreferredLaunchAccount()
        }
        .sheet(isPresented: $showsLogin) {
            DiscordLoginView(
                showsCancel: true,
                networkingEnabled: !model.isDiscordNetworkingDisabled
            ) { credential in
                let connected = await model.connectPendingAuthenticatedAccount(
                    credential,
                    preservesInteractivePresentation: true
                )
                if connected {
                    await model.refreshSavedAccounts()
                    selectedAccountID = model.activeAccountID ?? selectedAccountID
                    operationMessage = .success("Account added and connected.")
                }
                return connected
                    ? nil
                    : (model.errorMessage
                        ?? "Discord account bootstrap failed for an unknown reason.")
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: pendingRemovalBinding
        ) {
            Button(removalButtonTitle, role: .destructive) {
                guard let account = pendingRemoval else { return }
                pendingRemoval = nil
                removeSavedSession(for: account)
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(removalMessage)
        }
        .confirmationDialog(
            "Reset Local Preferences?",
            isPresented: $confirmsReset
        ) {
            Button("Reset Preferences", role: .destructive) {
                resetSelectedAccountPreferences()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Only registered local settings for this account will return to their defaults. Credentials, drafts, other accounts, and Discord state are not changed."
            )
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case let .success(url):
                operationMessage = .success("Exported preferences to \(url.lastPathComponent).")
            case let .failure(error):
                operationMessage = .error(error.localizedDescription)
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
        }
    }

    private var accountIdentitySection: some View {
        Section {
            if let selectedAccount {
                SettingsAccountIdentityHeader(
                    account: selectedAccount,
                    isActive: selectedAccount.accountID == model.activeAccountID
                )
            } else {
                ContentUnavailableView(
                    "No Saved Accounts",
                    systemImage: "person.crop.circle.badge.xmark",
                    description: Text(
                        "Add a Discord account to inspect its identity and local settings."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            }

            accountSelector
                .disabled(isBusy)
                .settingsControlAnchor(.selectedAccount, state: state)

            HStack {
                Button {
                    switchToSelectedAccount()
                } label: {
                    if operation == .switching(selectedAccountID) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Switch to Account", bundle: #bundle)
                    }
                }
                .disabled(
                    isBusy
                        || selectedAccount == nil
                        || selectedAccountID == model.activeAccountID
                        || model.isDiscordNetworkingDisabled
                )
                .settingsControlAnchor(.switchAccount, state: state)

                Button("Add Account…") {
                    showsLogin = true
                }
                .disabled(isBusy || model.isDiscordNetworkingDisabled)
                .settingsControlAnchor(.addAccount, state: state)

                Spacer()

                Button(removalButtonTitle, role: .destructive) {
                    pendingRemoval = selectedAccount
                }
                .disabled(isBusy || selectedAccount == nil)
                .settingsControlAnchor(.removeSavedSession, state: state)
            }

            if model.isDiscordNetworkingDisabled {
                Label(
                    "Discord account actions are unavailable while networking is disabled.",
                    systemImage: "network.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let operationMessage {
                Label(operationMessage.text, systemImage: operationMessage.systemImage)
                    .font(.caption)
                    .foregroundStyle(operationMessage.isError ? Color.red : Color.secondary)
                    .accessibilityLabel(operationMessage.text)
            }
        } header: {
            Text("Saved account", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .mixed)
        }
    }

    @ViewBuilder
    private var accountSelector: some View {
        if model.savedAccounts.count > 1 {
            Picker("Account to inspect", selection: $selectedAccountID) {
                ForEach(model.savedAccounts) { account in
                    Text(account.resolvedDisplayName)
                        .tag(account.accountID)
                }
            }
            .accessibilityHint(
                "Changes only the account whose local preferences are shown in Settings."
            )
        } else {
            LabeledContent("Account to inspect") {
                Text(selectedAccount?.resolvedDisplayName ?? "No saved account")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accountLaunchSection: some View {
        Section {
            Toggle(
                "Reopen the last active account",
                isOn: reopensLastActiveAccountBinding
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.reopenLastAccount, state: state)

            Picker(
                "Preferred launch account",
                selection: preferredLaunchAccountBinding
            ) {
                if model.savedAccounts.isEmpty {
                    Text("No saved accounts").tag("")
                } else {
                    ForEach(model.savedAccounts) { account in
                        Text(account.resolvedDisplayName)
                            .tag(account.accountID)
                    }
                }
            }
            .disabled(reopensLastActiveAccount || model.savedAccounts.isEmpty)
            .settingsControlAnchor(.preferredLaunchAccount, state: state)
        } header: {
            Text("On launch", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    reopensLastActiveAccount
                        ? "SakuraCord reconnects the account used most recently."
                        : "SakuraCord reconnects the fixed account selected above. If it is no longer saved, the first available account is used."
                )
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }

    private var accountLocalDataSection: some View {
        Section {
            LabeledContent("Export format") {
                Text("Version 1 JSON")
                    .foregroundStyle(.secondary)
            }

            Text(
                "Exports enumerate the registered account-local settings in this build. Account IDs, Keychain credentials, drafts, and Discord-synchronized data are excluded."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Export Local Preferences…") {
                    exportSelectedAccountPreferences()
                }
                .disabled(selectedAccount == nil)
                .settingsControlAnchor(.exportAccountPreferences, state: state)

                Button("Reset Local Preferences…", role: .destructive) {
                    confirmsReset = true
                }
                .disabled(selectedAccount == nil)
                .settingsControlAnchor(.resetAccountPreferences, state: state)
            }
        } header: {
            Text("Account-local data", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .accountLocal)
        }
    }

    private var reopensLastActiveAccountBinding: Binding<Bool> {
        Binding(
            get: { reopensLastActiveAccount },
            set: { value in
                reopensLastActiveAccount = value
                SettingsPreferenceStore.shared.set(
                    .bool(value),
                    for: .reopenLastAccount
                )
                if !value {
                    normalizePreferredLaunchAccount()
                }
            }
        )
    }

    private var preferredLaunchAccountBinding: Binding<String> {
        Binding(
            get: { preferredLaunchAccountID },
            set: { value in
                preferredLaunchAccountID = value
                SettingsPreferenceStore.shared.set(
                    .string(value),
                    for: .preferredLaunchAccount
                )
            }
        )
    }

    private var pendingRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemoval = nil
                }
            }
        )
    }

    private var removalButtonTitle: String {
        selectedAccount?.accountID == model.activeAccountID
            ? "Log Out…"
            : "Remove Saved Account…"
    }

    private var removalTitle: String {
        guard let pendingRemoval else { return "Remove Saved Account?" }
        return pendingRemoval.accountID == model.activeAccountID
            ? "Log Out of \(pendingRemoval.resolvedDisplayName)?"
            : "Remove \(pendingRemoval.resolvedDisplayName)?"
    }

    private var removalMessage: String {
        guard let pendingRemoval else { return "" }
        let action = pendingRemoval.accountID == model.activeAccountID
            ? "SakuraCord will disconnect this account and remove its saved session"
            : "SakuraCord will remove this account's saved session without changing the active workspace"
        return """
        \(action). Its credential is removed from macOS Keychain and its saved account metadata is removed from this Mac. \
        Drafts, account-local preferences, other accounts, and Discord data are kept.
        """
    }

    private func normalizeSelectedAccount() {
        selectedAccountID = SettingsAccountSelectionPolicy.accountID(
            storedAccountID: selectedAccountID,
            activeAccountID: model.activeAccountID,
            accounts: model.savedAccounts
        ) ?? ""
    }

    private func loadLaunchPreferences() {
        reopensLastActiveAccount = SettingsPreferenceStore.shared.value(
            for: .reopenLastAccount
        ) == .bool(true)
        if case let .string(value) = SettingsPreferenceStore.shared.value(
            for: .preferredLaunchAccount
        ) {
            preferredLaunchAccountID = value
        }
    }

    private func normalizePreferredLaunchAccount() {
        guard !reopensLastActiveAccount else { return }
        let availableIDs = Set(model.savedAccounts.map(\.accountID))
        guard !availableIDs.contains(preferredLaunchAccountID) else { return }
        let fallback = selectedAccountID.isEmpty
            ? (model.activeAccountID ?? model.savedAccounts.first?.accountID ?? "")
            : selectedAccountID
        preferredLaunchAccountID = fallback
        SettingsPreferenceStore.shared.set(
            .string(fallback),
            for: .preferredLaunchAccount
        )
    }

    private func switchToSelectedAccount() {
        guard let selectedAccount, !isBusy else { return }
        operationMessage = nil
        operation = .switching(selectedAccount.accountID)
        Task {
            let connected = await model.switchAccount(to: selectedAccount.accountID)
            operation = nil
            if connected {
                operationMessage = .success("Switched to \(selectedAccount.resolvedDisplayName).")
            } else if Task.isCancelled {
                operationMessage = .error("Account switch was cancelled.")
            } else {
                operationMessage = .error(
                    model.errorMessage ?? "SakuraCord could not switch accounts."
                )
            }
        }
    }

    private func removeSavedSession(for account: SavedAccount) {
        guard !isBusy else { return }
        let wasActive = account.accountID == model.activeAccountID
        operationMessage = nil
        operation = .removing(account.accountID)
        Task {
            await model.logout(accountID: account.accountID)
            await model.refreshSavedAccounts()
            operation = nil
            normalizeSelectedAccount()
            normalizePreferredLaunchAccount()
            if model.savedAccounts.contains(where: {
                $0.accountID == account.accountID
            }) {
                let prefix = wasActive
                    ? "The account was disconnected, but its saved session could not be removed."
                    : "The saved session could not be removed."
                operationMessage = .error(
                    model.errorMessage.map { "\(prefix) \($0)" } ?? prefix
                )
            } else {
                operationMessage = .success(
                    wasActive
                        ? "Logged out and removed the saved session."
                        : "Removed the saved account."
                )
            }
        }
    }

    private func exportSelectedAccountPreferences() {
        guard let selectedAccount else { return }
        let export = SettingsPreferenceStore.shared.export(
            scope: .accountLocal,
            accountID: selectedAccount.accountID
        )
        exportedPreferences = SettingsPreferenceExportFile(export: export)
        exportFilename = "SakuraCord-\(safeFilenameComponent(selectedAccount.resolvedDisplayName))-Preferences-v\(export.version)"
        isExporting = true
    }

    private func resetSelectedAccountPreferences() {
        operationMessage = nil
        guard let selectedAccount else { return }
        SettingsPreferenceStore.shared.reset(
            scope: .accountLocal,
            accountID: selectedAccount.accountID
        )
        operationMessage = .success(
            "Reset registered local preferences for \(selectedAccount.resolvedDisplayName)."
        )
    }

    private func safeFilenameComponent(_ value: String) -> String {
        let allowed = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        let collapsed = String(allowed).replacingOccurrences(of: "--", with: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct SettingsAccountIdentityHeader: View {
    let account: SavedAccount
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(
                name: account.resolvedDisplayName,
                url: account.avatarURL,
                size: 56,
                maximumPixelDimension: 112,
                animates: false
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.resolvedDisplayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(account.resolvedSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(
                    isActive ? "Active account" : "Saved account",
                    systemImage: isActive ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(.caption)
                .foregroundStyle(isActive ? .green : .secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private enum AccountOperation: Equatable {
    case switching(String)
    case removing(String)
}

private enum AccountOperationMessage: Equatable {
    case success(String)
    case error(String)

    var text: String {
        switch self {
        case let .success(text), let .error(text): text
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var isError: Bool {
        if case .error = self { true } else { false }
    }
}
