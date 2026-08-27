import SwiftUI

struct SettingsSidebar: View {
    let state: SettingsViewState

    var body: some View {
        @Bindable var state = state
        let selection = Binding(
            get: { state.selectedPage },
            set: { page in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    state.selectedPage = page
                }
            }
        )
        List(selection: selection) {
            if state.searchText.isEmpty {
                ForEach(SettingsSidebarGroupID.allCases) { group in
                    Section(group.title) {
                        ForEach(state.catalog.pages(in: group)) { page in
                            Label(page.title, systemImage: page.systemImage)
                                .lineLimit(1)
                                .labelStyle(
                                    SettingsSidebarLabelStyle(
                                        isSelected: state.selectedPage == page.id
                                    )
                                )
                                .tag(page.id)
                        }
                    }
                    .collapsible(false)
                }
            } else {
                SettingsSearchResults(state: state)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        .accessibilityLabel(
            LocalizedStringResource(
                "Settings categories",
                bundle: #bundle,
                comment: "Accessibility label for the Settings source-list sidebar."
            )
        )
    }
}

private struct SettingsSidebarLabelStyle: LabelStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .symbolVariant(.fill)
                .foregroundStyle(
                    isSelected ? Color.white : SakuraCordAccentColor.color
                )
                .frame(width: 16)
            configuration.title
        }
    }
}

private struct SettingsSearchResults: View {
    let state: SettingsViewState

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
                    Button {
                        state.activate(result)
                    } label: {
                        SettingsSearchResultRow(result: result)
                    }
                    .buttonStyle(.plain)
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
        HStack(spacing: 10) {
            Image(systemName: result.systemImage)
                .symbolVariant(.fill)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .lineLimit(1)

                if let pageTitle = result.pageTitle {
                    Text(pageTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.interaction, Rectangle())
    }
}
