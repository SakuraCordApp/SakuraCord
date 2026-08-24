import SwiftUI

struct GeneralSettingsPage: View {
    let state: SettingsViewState
    @ObservedObject var updateController: AppUpdateController

    @AppStorage("sendWithReturn") private var sendWithReturn = true
    @AppStorage("reduceAnimatedMedia") private var reduceAnimatedMedia = false

    var body: some View {
        SettingsPageForm(page: .general, state: state) {
            GeneralMessagesAndMediaSection(
                sendWithReturn: $sendWithReturn,
                reduceAnimatedMedia: $reduceAnimatedMedia,
                state: state
            )
            GeneralSoftwareUpdatesSection(
                updateController: updateController,
                state: state
            )
        }
    }
}

private struct GeneralMessagesAndMediaSection: View {
    @Binding var sendWithReturn: Bool
    @Binding var reduceAnimatedMedia: Bool
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle("Press Return to send messages", isOn: $sendWithReturn)
                .settingsControlAnchor(.sendWithReturn, state: state)

            Toggle("Reduce animated media", isOn: $reduceAnimatedMedia)
                .settingsControlAnchor(.reduceAnimatedMedia, state: state)
        } header: {
            Text("Messages and media", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}

private struct GeneralSoftwareUpdatesSection: View {
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState

    var body: some View {
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
                "Uses SakuraCord’s signed update feed on the configured schedule."
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
                "Downloaded updates remain cryptographically verified before installation."
            )
            .settingsControlAnchor(.updateAutomaticDownloads, state: state)

            LabeledContent("Update status") {
                Text(updateController.availabilityDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .settingsControlAnchor(.updateStatus, state: state)

            Button("Check for Updates…") {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
            .accessibilityHint(updateController.availabilityDescription)
            .settingsControlAnchor(.checkForUpdates, state: state)
        } header: {
            Text("Software updates", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}
