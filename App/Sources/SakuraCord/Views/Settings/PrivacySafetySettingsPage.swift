import SwiftUI
import UniformTypeIdentifiers

struct PrivacySafetySettingsPage: View {
    private enum Confirmation: String, Identifiable {
        case messageSearch
        case destinations
        case emoji
        case drafts
        case reset

        var id: String { rawValue }
    }

    let model: AppModel
    let state: SettingsViewState

    @State private var value = PrivacySafetySettingsSnapshot.defaults
    @State private var confirmation: Confirmation?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var isClearingDrafts = false
    @State private var operationMessage: String?

    var body: some View {
        SettingsPageForm(page: .privacySafety, state: state) {
            discordActivitySection
            linksAndServicesSection
            credentialsSection
            localDataSection
        }
        .task {
            value = model.privacySafetySettings
        }
        .onChange(of: value) { _, newValue in
            model.applyPrivacySafetySettings(newValue)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            )
        ) {
            if let confirmation {
                Button(confirmationButtonTitle, role: .destructive) {
                    perform(confirmation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Privacy-Safety-v1"
        ) { result in
            switch result {
            case .success:
                operationMessage = "Exported Privacy & Safety preferences."
            case let .failure(error):
                operationMessage = "Export failed: \(error.localizedDescription)"
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
        }
    }

    private var discordActivitySection: some View {
        Section {
            LabeledContent("Typing indicators") {
                Text(model.chatSettings.sendsTypingIndicators ? "Enabled" : "Disabled")
                    .foregroundStyle(.secondary)
            }
            Button("Open Typing Indicator Setting in Chat…") {
                openChat(controlID: .chatTypingIndicators, section: .chatComposer)
            }
            .settingsControlAnchor(.privacyTypingIndicators, state: state)

            LabeledContent("Read acknowledgements") {
                Text(model.chatSettings.readAcknowledgementMode.title)
                    .foregroundStyle(.secondary)
            }
            Button("Open Read Acknowledgement Setting in Chat…") {
                openChat(controlID: .chatReadAcknowledgement, section: .chatMessages)
            }
            .settingsControlAnchor(.privacyReadAcknowledgements, state: state)
        } header: {
            Text("Discord Activity", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Typing-indicator preference is local to SakuraCord, but enabled indicators "
                        + "are sent to Discord while you compose. Read acknowledgements alter "
                        + "Discord unread state and are visible in other clients."
                )
                SettingsScopeFooter(scope: .mixed)
            }
        }
    }

    private var linksAndServicesSection: some View {
        Section {
            LabeledContent("External web links") {
                Label("Always confirm", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.externalLinkProtection, state: state)

            Button("Open Internal Discord Link Setting in Chat…") {
                openChat(controlID: .chatInternalDiscordLinks, section: .chatMessages)
            }
            .settingsControlAnchor(.privacyInternalDiscordLinks, state: state)

            Picker(
                "When an attachment exceeds Discord's limit",
                selection: $value.externalUploaderOfferPolicy
            ) {
                ForEach(ExternalUploaderOfferPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .settingsControlAnchor(.externalUploaderPolicy, state: state)
        } header: {
            Text("Links & External Services", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "External links show their destination domain before opening. Warnings cover "
                        + "specific signals such as HTTP, encoded or malformed hosts, disguised "
                        + "service names, credentials in a URL, and display/destination mismatch; "
                        + "they cannot identify every malicious link."
                )
                Text(
                    "The uploader setting can offer Catbox or Litterbox, or never offer either. "
                        + "SakuraCord has no automatic-upload mode: choosing a service in the "
                        + "separate prompt is always required before any third-party transfer."
                )
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }

    private var credentialsSection: some View {
        Section {
            Label {
                Text("Account credentials are excluded from settings exports, caches, drafts, diagnostics, and extension APIs.")
            } icon: {
                Image(systemName: "key.fill")
            }
            .settingsControlAnchor(.credentialStorage, state: state)

            if model.usesInsecureDebugCredentials {
                Label(
                    "This repository-configured debug build enables insecure development credential storage. Release builds use macOS Keychain.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else {
                Text("Credentials are stored in macOS Keychain and are never part of SakuraCord preference data.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Credentials", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .accountLocal)
        }
    }

    private var localDataSection: some View {
        Section {
            Button("Clear Current Message Search…", role: .destructive) {
                confirmation = .messageSearch
            }
            .settingsControlAnchor(.clearMessageSearches, state: state)

            Button("Clear Recent Quick Switch & Forward Destinations…", role: .destructive) {
                confirmation = .destinations
            }
            .settingsControlAnchor(.clearDestinationHistory, state: state)

            Button("Clear Local Emoji Learning…", role: .destructive) {
                confirmation = .emoji
            }
            .settingsControlAnchor(.clearEmojiRanking, state: state)

            Button("Clear Drafts for Active Account…", role: .destructive) {
                confirmation = .drafts
            }
            .disabled(model.activeAccountID == nil || isClearingDrafts)
            .settingsControlAnchor(.clearDrafts, state: state)

            Button("Open Notification Preview Setting…") {
                state.navigate(
                    to: SettingsDestination(
                        page: .notifications,
                        section: .notificationDelivery
                    ),
                    controlID: .notificationPreview
                )
            }
            .settingsControlAnchor(.privacyNotificationPreviews, state: state)

            Divider()

            HStack {
                Button("Export Privacy Preferences…", action: exportPreferences)
                    .settingsControlAnchor(.privacyExport, state: state)
                Button("Reset Privacy Preferences…", role: .destructive) {
                    confirmation = .reset
                }
                .settingsControlAnchor(.privacyReset, state: state)
            }

            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(operationMessage)
            }
        } header: {
            Text("Local Privacy Actions", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Each clear action is independently confirmed. None deletes Discord messages, "
                        + "favorites, server data, credentials, or another account's drafts. "
                        + "Preference reset/export covers only the registered uploader policy."
                )
                SettingsScopeFooter(scope: .mixed)
            }
        }
    }

    private func openChat(
        controlID: SettingsControlID,
        section: SettingsSectionID
    ) {
        state.navigate(
            to: SettingsDestination(page: .chat, section: section),
            controlID: controlID
        )
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .messageSearch: "Clear Current Message Search?"
        case .destinations: "Clear Recent Destinations?"
        case .emoji: "Clear Local Emoji Learning?"
        case .drafts: "Clear Drafts for the Active Account?"
        case .reset: "Reset Privacy Preferences?"
        case nil: "Confirm Privacy Action"
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmation {
        case .messageSearch: "Clear Message Search"
        case .destinations: "Clear Recent Destinations"
        case .emoji: "Clear Emoji Learning"
        case .drafts: "Clear Active Account Drafts"
        case .reset: "Reset Privacy Preferences"
        case nil: "Confirm"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .messageSearch:
            "This clears the current in-memory query, filters, and results. SakuraCord does not persist a message-search history, and no Discord messages are deleted."
        case .destinations:
            "This clears the active account's bounded local recent list shared by Quick Switch and forwarding. Discord-synchronized ranking data is unchanged."
        case .emoji:
            "This clears app-wide local emoji recents and learned usage counts. Discord favorites and Discord-provided frequency remain unchanged."
        case .drafts:
            "This deletes all locally saved message drafts for the active account, including the visible channel and thread drafts. Sent Discord messages and other accounts are unchanged."
        case .reset:
            "This restores the registered oversized-uploader offer policy. It does not clear histories, searches, emoji learning, drafts, credentials, or Discord data."
        case nil:
            "No action has been selected."
        }
    }

    private func perform(_ confirmation: Confirmation) {
        self.confirmation = nil
        switch confirmation {
        case .messageSearch:
            model.clearLocalMessageSearchData()
            operationMessage = "Cleared the current local message search."
        case .destinations:
            model.clearLocalDestinationHistory()
            operationMessage = "Cleared recent Quick Switch and forwarding destinations."
        case .emoji:
            model.clearLocallyLearnedEmojiRanking()
            operationMessage = "Cleared local emoji recents and learned ranking."
        case .drafts:
            isClearingDrafts = true
            Task {
                defer { isClearingDrafts = false }
                do {
                    try await model.clearLocalDrafts()
                    operationMessage = "Cleared drafts for the active account."
                } catch {
                    operationMessage = "Draft clearing failed: \(error.localizedDescription)"
                }
            }
        case .reset:
            SettingsPreferenceStore.shared.reset(
                scope: .appWide,
                page: .privacySafety
            )
            value = PrivacySafetySettingsStore.shared.load()
            operationMessage = "Restored Privacy & Safety preferences."
        }
    }

    private func exportPreferences() {
        exportedPreferences = SettingsPreferenceExportFile(
            export: SettingsPreferenceStore.shared.export(
                scope: .appWide,
                page: .privacySafety
            )
        )
        isExporting = true
    }
}
