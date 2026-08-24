import SwiftUI

struct SettingsSidebar: View {
    let state: SettingsViewState

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedPage) {
            ForEach(SettingsSidebarGroupID.allCases) { group in
                Section {
                    ForEach(state.catalog.pages(in: group)) { page in
                        SettingsSidebarRow(
                            title: page.title,
                            systemImage: page.systemImage
                        )
                        .tag(page.id)
                    }
                } header: {
                    Text(group.title)
                }
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

private struct SettingsSidebarRow: View {
    let title: LocalizedStringResource
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
    }
}

struct SettingsSearchSuggestions: View {
    let state: SettingsViewState

    var body: some View {
        if !state.searchText.isEmpty {
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
