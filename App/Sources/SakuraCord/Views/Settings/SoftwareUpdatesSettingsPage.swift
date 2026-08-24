import SwiftUI

struct SoftwareUpdatesSettingsPage: View {
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState

    var body: some View {
        SettingsPageForm(page: .softwareUpdates, state: state) {
            Section {
                Picker(
                    "Release track",
                    selection: Binding(
                        get: { updateController.releaseTrack },
                        set: { updateController.setReleaseTrack($0) }
                    )
                ) {
                    ForEach(AppUpdateReleaseTrack.allCases) { track in
                        Text(track.title).tag(track)
                    }
                }
                .disabled(!updateController.isEnabled)
                .accessibilityHint(
                    updateController.isEnabled
                        ? "Changes which signed SakuraCord feed is checked."
                        : updateController.availabilityDescription
                )
                .settingsControlAnchor(.updateReleaseTrack, state: state)

                Text(updateController.releaseTrack.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updateController.automaticallyChecksForUpdates },
                        set: { updateController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .disabled(!updateController.isEnabled)
                .accessibilityHint(
                    updateController.isEnabled
                        ? "Uses SakuraCord’s signed update feed on the configured schedule."
                        : updateController.availabilityDescription
                )
                .settingsControlAnchor(.updateAutomaticChecks, state: state)

                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { updateController.automaticallyDownloadsUpdates },
                        set: { updateController.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(
                    !updateController.isEnabled
                        || !updateController.allowsAutomaticUpdates
                )
                .accessibilityHint(
                    updateController.isEnabled
                        ? "Downloaded updates remain cryptographically verified before installation."
                        : updateController.availabilityDescription
                )
                .settingsControlAnchor(.updateAutomaticDownloads, state: state)
            } header: {
                Text("Update preferences", bundle: #bundle)
            } footer: {
                SettingsScopeFooter(scope: .appWideLocal)
            }

            Section {
                LabeledContent("Update status") {
                    Text(updateController.availabilityDescription)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .settingsControlAnchor(.updateStatus, state: state)

                LabeledContent("Last successful signed-feed check") {
                    if let date = updateController.lastSuccessfulCheckDate {
                        Text(date, format: .dateTime)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsControlAnchor(.updateLastSuccessfulCheck, state: state)

                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
                .accessibilityHint(updateController.availabilityDescription)
                .settingsControlAnchor(.checkForUpdates, state: state)
            } header: {
                Text("Update service", bundle: #bundle)
            } footer: {
                Text(
                    "A successful check is recorded only after Sparkle downloads the configured signed appcast. Failed and unavailable checks do not change this date."
                )
            }
        }
    }
}
