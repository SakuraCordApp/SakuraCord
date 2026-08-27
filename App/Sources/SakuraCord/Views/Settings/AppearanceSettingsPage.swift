import AppKit
import SwiftUI

struct AppearanceSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var value = AppearanceSettingsSnapshot.defaults
    @State private var accentPaletteRefresh: UInt64 = 0

    private var accentColorSelectionIsEnabled: Bool {
        SystemAccentPalette.allowsPreferredAccentColor(
            refresh: accentPaletteRefresh
        )
    }

    private var radioControlTint: Color {
        if accentColorSelectionIsEnabled {
            value.accentColor.effectiveColor
        } else {
            Color(nsColor: .controlAccentColor)
        }
    }

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

                AccentColorPicker(
                    selection: $value.accentColor,
                    isEnabled: accentColorSelectionIsEnabled,
                    paletteRefresh: accentPaletteRefresh
                )
                    .settingsControlAnchor(.accentColor, state: state)
            } header: {
                Text("Theme", bundle: #bundle)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !accentColorSelectionIsEnabled {
                        Text(
                            "Disabled unless the system accent color is set to “Multicolour”.",
                            bundle: #bundle,
                            comment: "Explains why the app accent color picker is disabled."
                        )
                    }

                    SettingsScopeFooter(scope: .appWideLocal)
                }
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
                    .tint(radioControlTint)
                }
                .settingsControlAnchor(.composerBarAppearance, state: state)
            } header: {
                Text("Message Composer", bundle: #bundle)
            } footer: {
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
        .background {
            SystemAccentPaletteRefreshBridge(refresh: $accentPaletteRefresh)
                .frame(width: 0, height: 0)
        }
        .task {
            value = model.appearanceSettings
        }
        .onChange(of: value) { _, newValue in
            model.applyAppearanceSettings(newValue)
        }
    }
}
