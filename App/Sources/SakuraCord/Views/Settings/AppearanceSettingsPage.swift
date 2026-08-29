import SwiftUI

struct AppearanceSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var value = AppearanceSettingsSnapshot.defaults

    var body: some View {
        SettingsPageForm(page: .appearance, state: state) {
            Section {
                LabeledContent {
                    Picker("Appearance", selection: $value.colorScheme) {
                        ForEach(AppColorScheme.allCases) { colorScheme in
                            Label {
                                Text(colorScheme.title)
                            } icon: {
                                Image(systemName: colorScheme.systemImage)
                            }
                            .tag(colorScheme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                } label: {
                    Text("Appearance", bundle: #bundle)
                }
                .settingsControlAnchor(.appColorScheme, state: state)

                GradientThemeEditor(themeStore: .shared)
                    .settingsControlAnchor(.gradientTheme, state: state)
            } header: {
                Text("Theme", bundle: #bundle)
            }

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
                    .tint(SakuraCordAccentColor.color)
                }
                .settingsControlAnchor(.composerBarAppearance, state: state)
            } header: {
                Text("Message Composer", bundle: #bundle)
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
