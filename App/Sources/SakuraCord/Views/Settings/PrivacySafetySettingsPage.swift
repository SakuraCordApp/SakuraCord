import SwiftUI

struct PrivacySafetySettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var value = PrivacySafetySettingsSnapshot.defaults
    @State private var chatValue = ChatSettingsSnapshot.defaults
    @State private var navigationPath: [PrivacyDestination] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SettingsPageForm(page: .privacySafety, state: state) {
                PrivacyDiscordActivitySection(
                    value: $chatValue,
                    state: state
                )
                PrivacyLinksServicesSection(value: $value, state: state)
                PrivacyLocalActivitySection(model: model, state: state)
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

private struct PrivacyLocalActivitySection: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var isConfirmingClear = false

    var body: some View {
        Section {
            Button("Clear Local Activity…", role: .destructive) {
                isConfirmingClear = true
            }
            .settingsControlAnchor(.clearLocalActivity, state: state)
        } header: {
            Text("Local Activity", bundle: #bundle)
        }
        .confirmationDialog(
            "Clear Local Activity?",
            isPresented: $isConfirmingClear
        ) {
            Button("Clear Local Activity", role: .destructive) {
                model.clearLocalActivity()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                LocalizedStringResource(
                    """
                    This clears the current account's recent Quick Switch and forwarding destinations, plus app-wide local \
                    emoji recents and learned usage. It does not delete drafts, cached media, trusted domains, preferences, \
                    credentials, or Discord data.
                    """,
                    bundle: #bundle
                )
            )
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
