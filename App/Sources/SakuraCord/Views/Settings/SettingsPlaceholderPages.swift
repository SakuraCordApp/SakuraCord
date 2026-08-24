import SwiftUI

struct AboutSettingsPage: View {
    let state: SettingsViewState

    var body: some View {
        SettingsPendingPage(page: .about, phase: 14, state: state)
    }
}
