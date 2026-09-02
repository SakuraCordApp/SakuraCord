import SwiftUI
import UniformTypeIdentifiers

struct PrivacySafetySettingsPage: View {
    private enum Confirmation: String, Identifiable {
        case messageSearch
        case destinations
        case emoji
        case reset

        var id: String { rawValue }
    }

    let model: AppModel
    let state: SettingsViewState

    @State private var value = PrivacySafetySettingsSnapshot.defaults
    @State private var chatValue = ChatSettingsSnapshot.defaults
    @State private var confirmation: Confirmation?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var operationMessage: String?
    @State private var navigationPath: [PrivacyDestination] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SettingsPageForm(page: .privacySafety, state: state) {
                PrivacyDiscordActivitySection(
                    value: $chatValue,
                    state: state
                )
                PrivacyLinksServicesSection(value: $value, state: state)
                localDataSection
            }
            .navigationDestination(for: PrivacyDestination.self) { destination in
                switch destination {
                case .trustedDomains:
                    TrustedDomainsSettingsPage(trustedDomains: $value.trustedDomains)
                }
            }
        }
        .task {
            value = model.privacySafetySettings
            chatValue = model.chatSettings
        }
        .onChange(of: value) { _, newValue in
            model.applyPrivacySafetySettings(newValue)
        }
        .onChange(of: chatValue) { _, newValue in
            model.applyChatSettings(newValue)
        }
        .onChange(of: state.revealRequest?.id) {
            guard state.revealRequest?.destination.page == .privacySafety else { return }
            navigationPath.removeAll()
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
            defaultFilename: "SakuraCord-Privacy-v1"
        ) { result in
            switch result {
            case .success:
                operationMessage = "Exported Privacy preferences."
            case let .failure(error):
                operationMessage = "Export failed: \(error.localizedDescription)"
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
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

            Button("Manage Local Drafts in Storage & Downloads…") {
                state.navigate(
                    to: SettingsDestination(
                        page: .storageDownloads,
                        section: .localStorage
                    ),
                    controlID: .clearAllAccountDrafts
                )
            }
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
            Text(
                "Each clear action is independently confirmed. None deletes Discord messages, "
                    + "favorites, server data, credentials, or another account's drafts. "
                    + "Preference reset covers external links and trusted domains. Exports omit "
                    + "the trusted-domain list."
            )
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .messageSearch: "Clear Current Message Search?"
        case .destinations: "Clear Recent Destinations?"
        case .emoji: "Clear Local Emoji Learning?"
        case .reset: "Reset Privacy Preferences?"
        case nil: "Confirm Privacy Action"
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmation {
        case .messageSearch: "Clear Message Search"
        case .destinations: "Clear Recent Destinations"
        case .emoji: "Clear Emoji Learning"
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
        case .reset:
            "This restores external-link confirmation and trusted domains. It does not clear "
                + "histories, searches, emoji learning, drafts, credentials, or Discord data."
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
        case .reset:
            SettingsPreferenceStore.shared.reset(
                scope: .appWide,
                page: .privacySafety
            )
            value = PrivacySafetySettingsStore.shared.load()
            operationMessage = "Restored Privacy preferences."
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

private enum PrivacyDestination: Hashable {
    case trustedDomains
}

private struct PrivacyLinksServicesSection: View {
    @Binding var value: PrivacySafetySettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Picker(
                "Ask permission when opening external links",
                selection: $value.externalLinkConfirmationPolicy
            ) {
                ForEach(ExternalLinkConfirmationPolicy.allCases) { policy in
                    Label(policy.title, systemImage: policy.systemImage)
                        .tag(policy)
                }
            }
            .settingsControlAnchor(.externalLinkProtection, state: state)

            NavigationLink(value: PrivacyDestination.trustedDomains) {
                Label("Manage Trusted Domains", systemImage: "checkmark.shield")
            }
            .settingsControlAnchor(.trustedDomains, state: state)

        } header: {
            Text("Links & External Services", bundle: #bundle)
        }
    }
}

private struct TrustedDomainsSettingsPage: View {
    @Binding var trustedDomains: [String]

    @State private var newDomain = ""
    @State private var searchText = ""
    @State private var visibleDomains: [String] = []
    @State private var isPresentingAddDomain = false

    var body: some View {
        SettingsForm {
            Section {
                if trustedDomains.isEmpty {
                    TrustedDomainsEmptyState(kind: .noDomains)
                        .listRowInsets(EdgeInsets())
                } else if visibleDomains.isEmpty {
                    TrustedDomainsEmptyState(kind: .noResults(searchText))
                        .listRowInsets(EdgeInsets())
                } else {
                    ForEach(visibleDomains, id: \.self) { domain in
                        TrustedDomainRow(domain: domain) {
                            remove(domain)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Trusted Domains", bundle: #bundle)

                    Spacer()

                    Button {
                        newDomain = ""
                        isPresentingAddDomain = true
                    } label: {
                        Image(systemName: "plus")
                            .symbolRenderingMode(.monochrome)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Add Trusted Domain")
                    .accessibilityLabel("Add Trusted Domain")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Trusted Domains")
        .searchable(text: $searchText, prompt: "Search Trusted Domains")
        .alert("Add Trusted Domain", isPresented: $isPresentingAddDomain) {
            TextField("example.com", text: $newDomain)
                .textContentType(.URL)

            Button("Cancel", role: .cancel) {
                newDomain = ""
            }

            Button("Add", action: addDomain)
                .disabled(domainToAdd == nil)
        } message: {
            Text(
                "Enter the domain you want SakuraCord to trust.",
                bundle: #bundle
            )
        }
        .task(refreshVisibleDomains)
        .onChange(of: trustedDomains) {
            refreshVisibleDomains()
        }
        .onChange(of: searchText) {
            refreshVisibleDomains()
        }
    }

    private var domainToAdd: String? {
        guard let normalized = ExternalLinkTrustedDomain.normalized(newDomain),
              !trustedDomains.contains(normalized)
        else { return nil }
        return normalized
    }

    private func addDomain() {
        guard let domainToAdd else { return }
        trustedDomains.append(domainToAdd)
        trustedDomains.sort()
        newDomain = ""
        searchText = ""
    }

    private func remove(_ domain: String) {
        trustedDomains.removeAll { $0 == domain }
    }

    private func refreshVisibleDomains() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleDomains = query.isEmpty
            ? trustedDomains
            : trustedDomains.filter { $0.localizedStandardContains(query) }
    }
}

private struct TrustedDomainsEmptyState: View {
    enum Kind {
        case noDomains
        case noResults(String)
    }

    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .noDomains:
                ContentUnavailableView(
                    "No Trusted Domains",
                    systemImage: "globe",
                    description: Text(
                        "Domains you trust will appear here.",
                        bundle: #bundle
                    )
                )
            case let .noResults(searchText):
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text(
                        "No trusted domains match “\(searchText)”.",
                        bundle: #bundle,
                        comment: "Empty search result; the variable is the user's search text."
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
    }
}

private struct TrustedDomainRow: View {
    let domain: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(domain)
                .textSelection(.enabled)

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .symbolRenderingMode(.monochrome)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(domain)")
            .accessibilityLabel("Remove \(domain)")
        }
    }
}

private struct PrivacyDiscordActivitySection: View {
    @Binding var value: ChatSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle("Send typing indicators", isOn: $value.sendsTypingIndicators)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.privacyTypingIndicators, state: state)

            Toggle(
                "Automatically mark messages as read",
                isOn: $value.automaticallyAcknowledgesMessages
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.privacyReadAcknowledgements, state: state)
        } header: {
            Text("Discord Activity", bundle: #bundle)
        }
    }
}
