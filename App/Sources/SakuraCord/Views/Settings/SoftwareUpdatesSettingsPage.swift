import SwiftUI

struct SoftwareUpdatesSettingsPage: View {
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState
    @State private var navigationPath: [SoftwareUpdatesDestination] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SettingsPageForm(page: .softwareUpdates, state: state) {
                SoftwareUpdateOverviewSection(
                    updateController: updateController,
                    state: state,
                    checkForUpdatesControlID: .checkForUpdates,
                    changelogControlID: .updateChangelog,
                    changelogDestination: SoftwareUpdatesDestination.changelog
                )

                Section {
                    Picker(
                        "Release track",
                        selection: Binding(
                            get: { updateController.releaseTrack },
                            set: { updateController.setReleaseTrack($0) }
                        )
                    ) {
                        ForEach(AppUpdateReleaseTrack.allCases) { track in
                            Label(track.title, systemImage: track.systemImage)
                                .tag(track)
                        }
                    }
                    .disabled(!updateController.isEnabled)
                    .settingsControlAnchor(.updateReleaseTrack, state: state)

                    Toggle(
                        "Automatically check for updates",
                        isOn: Binding(
                            get: { updateController.automaticallyChecksForUpdates },
                            set: { updateController.setAutomaticallyChecksForUpdates($0) }
                        )
                    )
                    .tint(SakuraCordAccentColor.color)
                    .disabled(!updateController.isEnabled)
                    .settingsControlAnchor(.updateAutomaticChecks, state: state)

                    Toggle(
                        "Automatically download updates",
                        isOn: Binding(
                            get: { updateController.automaticallyDownloadsUpdates },
                            set: { updateController.setAutomaticallyDownloadsUpdates($0) }
                        )
                    )
                    .tint(SakuraCordAccentColor.color)
                    .disabled(
                        !updateController.isEnabled
                            || !updateController.allowsAutomaticUpdates
                    )
                    .settingsControlAnchor(.updateAutomaticDownloads, state: state)
                } header: {
                    Text("Update preferences", bundle: #bundle)
                }

                if let reason = updateController.unavailabilityDescription {
                    Section {
                        UpdatesUnavailableNotice(reason: reason)
                    }
                }
            }
            .navigationDestination(for: SoftwareUpdatesDestination.self) { destination in
                switch destination {
                case .changelog:
                    AboutChangelogPage(
                        releaseNotes: AboutResources.packagedReleaseNotes
                    )
                }
            }
        }
        .onChange(of: state.revealRequest?.id) {
            guard state.revealRequest?.destination.page == .softwareUpdates else { return }
            navigationPath.removeAll()
        }
    }
}

private enum SoftwareUpdatesDestination: Hashable {
    case changelog
}

private struct UpdatesUnavailableNotice: View {
    let reason: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Updates Unavailable", bundle: #bundle)
                    .font(.headline)

                Text(reason)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
