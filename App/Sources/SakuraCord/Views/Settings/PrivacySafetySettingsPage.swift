import DiscordProtocol
import SwiftUI

struct PrivacySafetySettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var value = PrivacySafetySettingsSnapshot.defaults
    @State private var navigationPath: [PrivacyDestination] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SettingsPageForm(page: .privacySafety, state: state) {
                PrivacyDiscordActivitySection(
                    value: $value,
                    state: state
                )
                PrivacyIgnoreBlockSection(model: model, state: state)
                PrivacyLinksServicesSection(value: $value, state: state)
                PrivacyLocalActivitySection(model: model, state: state)
            }
            .navigationDestination(for: PrivacyDestination.self) { destination in
                switch destination {
                case .trustedDomains:
                    TrustedDomainsSettingsPage(trustedDomains: $value.trustedDomains)
                case .relationships(let list):
                    RelationshipListSettingsPage(model: model, list: list)
                }
            }
        }
        .task {
            value = model.privacySafetySettings
        }
        .onChange(of: value) { _, newValue in
            model.applyPrivacySafetySettings(newValue)
        }
        .onChange(of: state.revealRequest?.id) {
            guard state.revealRequest?.destination.page == .privacySafety else { return }
            navigationPath.removeAll()
        }
    }
}

private enum PrivacyDestination: Hashable {
    case trustedDomains
    case relationships(ManagedRelationshipList)
}

private struct PrivacyIgnoreBlockSection: View {
    let model: AppModel
    let state: SettingsViewState

    var body: some View {
        Section {
            link(.blocked).settingsControlAnchor(.blockedAccounts, state: state)
            link(.ignored).settingsControlAnchor(.ignoredAccounts, state: state)
        } header: {
            Text("Ignore & Block", bundle: #bundle)
        }
    }

    private func link(_ list: ManagedRelationshipList) -> some View {
        NavigationLink(value: PrivacyDestination.relationships(list)) {
            LabeledContent {
                Text(model.relationships.count(where: list.contains), format: .number)
            } label: {
                Label { Text(list.title) } icon: { Image(systemName: list.systemImage) }
            }
        }
    }
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
    @State private var isClearing = false
    @State private var clearError: String?

    var body: some View {
        Section {
            Button("Clear Local Activity…", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled(isClearing)
            .settingsControlAnchor(.clearLocalActivity, state: state)
            if let clearError { Text(clearError).foregroundStyle(.secondary) }
        } header: {
            Text("Local Activity", bundle: #bundle)
        }
        .confirmationDialog(
            "Clear Local Activity?",
            isPresented: $isConfirmingClear
        ) {
            Button("Clear Local Activity", role: .destructive) {
                isClearing = true
                clearError = nil
                Task {
                    defer { isClearing = false }
                    do {
                        try await model.clearLocalActivity()
                    } catch {
                        clearError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                LocalizedStringResource(
                    """
                    This clears the current account's learned people, nicknames, saved search ordering, saved emoji catalogs, \
                    and recent Quick Switch and forwarding destinations, plus app-wide local \
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
                "Enter a domain such as example.com, or *.example.com to trust its subdomains. Wildcards do not include the domain itself.",
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
        .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(260), alignment: .center)
    }
}

private struct TrustedDomainRow: View {
    let domain: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            Image(systemName: "globe")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(18))
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
    @Binding var value: PrivacySafetySettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle("Share activity status", isOn: $value.sharesActivity)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.activitySharing, state: state)
            Toggle("Display Apple Music & Spotify as activity", isOn: $value.sharesAppleMusicActivity)
                .tint(SakuraCordAccentColor.color)
                .disabled(!value.sharesActivity)
                .settingsControlAnchor(.appleMusicPresence, state: state)
            Toggle("Allow local apps & games to share activity (Discord RPC, Roblox detection without IPC)", isOn: $value.allowsLocalRPC)
                .tint(SakuraCordAccentColor.color)
                .disabled(!value.sharesActivity)
                .settingsControlAnchor(.localDiscordRPC, state: state)
            if value.sharesActivity {
                ActivityStackPriorityCard(
                    activityStackOrder: $value.activityStackOrder,
                    state: state
                )
            }
            Toggle("Remove metadata from images and videos", isOn: $value.removesMediaMetadata)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.removeMediaMetadata, state: state)
            Toggle("Anonymise file names", isOn: $value.anonymisesFileNames)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.anonymiseFileNames, state: state)
            Toggle("Send typing indicators", isOn: $value.sendsTypingIndicators)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.privacyTypingIndicators, state: state)
        } header: {
            Text("Discord Activity & Presence", bundle: #bundle)
        }
    }
}

private enum ActivityStackPreset: String, CaseIterable, Identifiable {
    case gamesFirst
    case musicFirst
    case streamingFirst
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gamesFirst: return "Games First (Default)"
        case .musicFirst: return "Music First"
        case .streamingFirst: return "Streaming First"
        case .custom: return "Custom Order"
        }
    }

    var order: [ActivityCategory]? {
        switch self {
        case .gamesFirst: return [.games, .streaming, .music, .other]
        case .musicFirst: return [.music, .games, .streaming, .other]
        case .streamingFirst: return [.streaming, .games, .music, .other]
        case .custom: return nil
        }
    }

    static func matching(order: [ActivityCategory]) -> ActivityStackPreset {
        let normalized = ActivityCategory.normalizedOrder(order)
        if normalized == ActivityStackPreset.gamesFirst.order {
            return .gamesFirst
        } else if normalized == ActivityStackPreset.musicFirst.order {
            return .musicFirst
        } else if normalized == ActivityStackPreset.streamingFirst.order {
            return .streamingFirst
        }
        return .custom
    }
}

private struct ActivityStackPriorityCard: View {
    @Binding var activityStackOrder: [ActivityCategory]
    let state: SettingsViewState

    private var currentPreset: ActivityStackPreset {
        ActivityStackPreset.matching(order: activityStackOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            HStack {
                Text("Activity Stack Priority", bundle: #bundle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Preset", selection: Binding(
                    get: { currentPreset },
                    set: { newPreset in
                        if let newOrder = newPreset.order {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                activityStackOrder = newOrder
                            }
                        }
                    }
                )) {
                    ForEach(ActivityStackPreset.allCases) { preset in
                        if preset != .custom || currentPreset == .custom {
                            Text(preset.title).tag(preset)
                        }
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            Text("Drag and arrange categories horizontally to customize priority. Top priority (leftmost) is displayed as your primary activity.", bundle: #bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    ForEach(Array(activityStackOrder.enumerated()), id: \.element) { index, category in
                        ActivityStackBlockTile(
                            index: index,
                            category: category,
                            activityStackOrder: $activityStackOrder
                        )

                        if index < activityStackOrder.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: InterfaceScale.metric(10), weight: .bold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(InterfaceScale.metric(6))
            }
            .padding(InterfaceScale.metric(4))
            .background(
                RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
        }
        .padding(.vertical, InterfaceScale.metric(4))
        .settingsControlAnchor(.activityStackOrder, state: state)
    }
}

private struct ActivityStackBlockTile: View {
    let index: Int
    let category: ActivityCategory
    @Binding var activityStackOrder: [ActivityCategory]
    @State private var isTargeted = false

    private var isTopPriority: Bool {
        index == 0
    }

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(isTopPriority ? SakuraCordAccentColor.color : .secondary)
                .frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
                .background(
                    Circle()
                        .fill(isTopPriority ? SakuraCordAccentColor.color.opacity(0.18) : Color.primary.opacity(0.08))
                )

            Image(systemName: category.iconName)
                .font(.callout)
                .foregroundStyle(isTopPriority ? SakuraCordAccentColor.color : .primary)

            VStack(alignment: .leading, spacing: 0) {
                Text(category.displayName)
                    .font(.caption.weight(isTopPriority ? .semibold : .medium))
                if isTopPriority {
                    Text("Top Priority", bundle: #bundle)
                        .font(.system(size: InterfaceScale.metric(9), weight: .bold))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: InterfaceScale.metric(9), weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, InterfaceScale.metric(10))
        .padding(.vertical, InterfaceScale.metric(8))
        .background(
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                .fill(isTargeted ? SakuraCordAccentColor.color.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                .strokeBorder(
                    isTargeted ? SakuraCordAccentColor.color : Color.primary.opacity(0.08),
                    lineWidth: isTargeted ? 1.5 : 1
                )
        )
        .draggable(category.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let draggedRaw = items.first,
                  let draggedCategory = ActivityCategory(rawValue: draggedRaw),
                  let fromIndex = activityStackOrder.firstIndex(of: draggedCategory),
                  let toIndex = activityStackOrder.firstIndex(of: category),
                  fromIndex != toIndex else {
                return false
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                let item = activityStackOrder.remove(at: fromIndex)
                activityStackOrder.insert(item, at: toIndex)
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .contextMenu {
            Button("Make Top Priority") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    guard let currIdx = activityStackOrder.firstIndex(of: category), currIdx > 0 else { return }
                    let item = activityStackOrder.remove(at: currIdx)
                    activityStackOrder.insert(item, at: 0)
                }
            }
            if index > 0 {
                Button("Move Left") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        guard let currIdx = activityStackOrder.firstIndex(of: category), currIdx > 0 else { return }
                        activityStackOrder.swapAt(currIdx, currIdx - 1)
                    }
                }
            }
            if index < activityStackOrder.count - 1 {
                Button("Move Right") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        guard let currIdx = activityStackOrder.firstIndex(of: category),
                              currIdx < activityStackOrder.count - 1 else { return }
                        activityStackOrder.swapAt(currIdx, currIdx + 1)
                    }
                }
            }
        }
        .help("Drag to rearrange priority, or right-click for quick actions")
    }
}
