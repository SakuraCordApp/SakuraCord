import SwiftUI

struct SettingsSidebar: View {
    let state: SettingsViewState

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedPage) {
            if state.searchText.isEmpty {
                ForEach(SettingsSidebarGroupID.allCases) { group in
                    Section(group.title) {
                        ForEach(state.catalog.pages(in: group)) { page in
                            HStack(spacing: 8) {
                                Image(systemName: page.systemImage)
                                    .environment(\.symbolVariants, .none)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(page.title)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
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
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .lineLimit(1)
                Text(result.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let scope = result.scope {
                Text(scope.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
