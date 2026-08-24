import SwiftUI

struct ExtensionsSettingsPage: View {
    let state: SettingsViewState

    var body: some View {
        SettingsPageForm(page: .extensions, state: state) {
            Section {
                ContentUnavailableView {
                    Label(
                        "Extensions Aren’t Available Yet",
                        systemImage: "puzzlepiece.extension"
                    )
                } description: {
                    VStack(spacing: 10) {
                        Text(
                            "SakuraCordPluginSDK defines manifests, declared capabilities, network origins, and scoped permission requests for a future extension system."
                        )
                        Text(
                            "The separate host executable and signing target establish a future process boundary, but the host is intentionally inert and loads no plugins."
                        )
                        Text(
                            "The planned runtime is sandboxed and permission-scoped. Discord credentials and credential handles never enter plugin APIs."
                        )
                        Text("Extensions cannot currently be installed or run.")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }
}
