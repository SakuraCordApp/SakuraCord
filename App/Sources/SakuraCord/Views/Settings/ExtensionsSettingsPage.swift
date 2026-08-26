import SwiftUI

struct ExtensionsSettingsPage: View {
    let state: SettingsViewState

    var body: some View {
        SettingsPageForm(page: .extensions, state: state) {
            Section {
                ContentUnavailableView {
                    Label(
                        "Extensions Are Planned",
                        systemImage: "puzzlepiece.extension"
                    )
                } description: {
                    Text(
                        "Support for installing and managing extensions is coming in a future SakuraCord release."
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }
}
