import SwiftUI

struct StorageDownloadsSettingsPage: View {
    let state: SettingsViewState
    @AppStorage("mediaCacheLimit") private var mediaCacheLimit = 2_147_483_648

    var body: some View {
        SettingsPageForm(page: .storageDownloads, state: state) {
            MediaCacheSettingsSection(
                mediaCacheLimit: $mediaCacheLimit,
                state: state
            )
        }
    }
}

private struct MediaCacheSettingsSection: View {
    @Binding var mediaCacheLimit: Int
    let state: SettingsViewState

    var body: some View {
        Section {
            Picker("Media cache", selection: $mediaCacheLimit) {
                Text("512 MB").tag(536_870_912)
                Text("2 GB").tag(2_147_483_648)
                Text("5 GB").tag(5_368_709_120)
                Text("10 GB").tag(10_737_418_240)
            }
            .settingsControlAnchor(.mediaCacheLimit, state: state)

            Text("Credentials are stored only in the macOS Keychain. Cached message data never contains the account credential.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Media cache", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}
