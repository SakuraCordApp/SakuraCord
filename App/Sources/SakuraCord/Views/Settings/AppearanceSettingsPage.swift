import SwiftUI

struct AppearanceSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var value = AppearanceSettingsSnapshot.defaults

    var body: some View {
        SettingsPageForm(page: .appearance, state: state) {
            Section {
                LabeledContent("Input bar") {
                    Picker("Input bar", selection: $value.composerBarAppearance) {
                        ForEach(ComposerBarAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
                .settingsControlAnchor(.composerBarAppearance, state: state)
            } header: {
                Text("Message Composer", bundle: #bundle)
            } footer: {
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
        .task {
            value = model.appearanceSettings
        }
        .onChange(of: value) { _, newValue in
            model.applyAppearanceSettings(newValue)
        }
    }
}
