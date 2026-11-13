import SwiftUI

struct SettingsSidebar: View {
    let account: SavedAccount?
    let state: SettingsViewState
    let onSearchResultActivated: () -> Void
    @State private var selection: SettingsPageID = .myAccount

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if state.searchText.isEmpty {
                    SettingsAccountSidebarRow(account: account)
                        .tag(SettingsPageID.myAccount)

                    ForEach(state.catalog.pages(in: .account).filter { $0.id != .myAccount }) { page in
                        SettingsSidebarPageRow(page: page, isSelected: state.selectedPage == page.id)
                    }

                    ForEach(SettingsSidebarGroupID.allCases.filter { $0 != .account }) { group in
                        Section(group.title) {
                            ForEach(state.catalog.pages(in: group)) { page in
                                SettingsSidebarPageRow(page: page, isSelected: state.selectedPage == page.id)
                            }
                        }
                        .collapsible(false)
                    }
                } else {
                    SettingsSearchResults(
                        state: state,
                        onResultActivated: onSearchResultActivated
                    )
                }
            }
            .onChange(of: selection) { _, page in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    state.selectedPage = page
                    // Restore native selection when navigation awaits confirmation.
                    selection = state.selectedPage
                }
            }
            .onChange(of: state.selectedPage, initial: true) { _, page in
                selection = page
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel(
                LocalizedStringResource(
                    "Settings categories",
                    bundle: #bundle,
                    comment: "Accessibility label for the Settings source-list sidebar."
                )
            )
            .onChange(of: state.selectedSearchResultID) { _, id in
                guard !state.searchText.isEmpty, let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

private struct SettingsSidebarPageRow: View {
    let page: SettingsPageMetadata
    let isSelected: Bool

    var body: some View {
        Label(page.title, systemImage: page.systemImage)
            .lineLimit(1)
            .labelStyle(SettingsSidebarLabelStyle(isSelected: isSelected))
            .tag(page.id)
    }
}

private struct SettingsAccountSidebarRow: View {
    let account: SavedAccount?

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            AvatarView(
                name: account?.resolvedDisplayName ?? "",
                url: account?.avatarURL,
                size: InterfaceScale.metric(28),
                // Reuse the current profile's preloaded avatar rendition.
                maximumPixelDimension: 140
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if let account {
                    Text(account.resolvedDisplayName)
                        .font(.interface(.headline))
                } else {
                    Text("Discord Account", bundle: #bundle)
                        .font(.interface(.headline))
                }
                Text("Manage Account", bundle: #bundle)
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .padding(.vertical, InterfaceScale.metric(2))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSidebarLabelStyle: LabelStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            configuration.icon
                .symbolVariant(.fill)
                .foregroundStyle(
                    isSelected ? Color.primary : SakuraCordAccentColor.color
                )
                .frame(width: InterfaceScale.metric(16))
            configuration.title
        }
    }
}

private struct SettingsSearchResults: View {
    let state: SettingsViewState
    let onResultActivated: () -> Void

    var body: some View {
        Section(
            LocalizedStringResource(
                "Search Results",
                bundle: #bundle,
                comment: "Sidebar section containing matching Settings controls."
            )
        ) {
            if state.searchResults.isEmpty {
                Text(
                    LocalizedStringResource(
                        "No Settings Found",
                        bundle: #bundle,
                        comment: "Search suggestion shown when no Settings entry matches."
                    )
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(state.searchResults) { result in
                    let isSelected = state.selectedSearchResultID == result.id
                    Button {
                        state.activate(result)
                        onResultActivated()
                    } label: {
                        SettingsSearchResultRow(result: result)
                    }
                    .buttonStyle(.plain)
                    .id(result.id)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: InterfaceScale.metric(6), style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
                    )
                    .onContinuousHover { phase in
                        guard case .active = phase else { return }
                        state.selectSearchResult(result.id)
                    }
                    .accessibilityHint(
                        LocalizedStringResource(
                            "Opens this Settings control and briefly highlights it.",
                            bundle: #bundle,
                            comment: "Accessibility hint for a Settings search result."
                        )
                    )
                }
            }
        }
    }
}

private struct SettingsSearchResultRow: View {
    let result: SettingsSearchResult

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: result.systemImage)
                .symbolVariant(.fill)
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(16))

            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                Text(result.title)
                    .lineLimit(1)

                if let pageTitle = result.pageTitle {
                    Text(pageTitle)
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.interaction, Rectangle())
    }
}
