import SwiftUI

struct SoftwareUpdatesSettingsPage: View {
    let state: SettingsViewState

    var body: some View {
        SettingsPendingPage(page: .softwareUpdates, phase: 12, state: state)
    }
}

struct ExtensionsSettingsPage: View {
    let state: SettingsViewState

    var body: some View {
        SettingsPendingPage(page: .extensions, phase: 13, state: state)
    }
}

struct AboutSettingsPage: View {
    let state: SettingsViewState

    var body: some View {
        SettingsPendingPage(page: .about, phase: 14, state: state)
    }
}
