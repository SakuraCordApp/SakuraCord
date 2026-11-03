import SwiftUI

struct AppearanceSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var value = AppearanceSettingsSnapshot.defaults
    @State private var showsResetConfirmation = false

    private let themeStore = SakuraCordThemeStore.shared

    private var isUsingDefaults: Bool {
        value.colorScheme == AppearanceSettingsSnapshot.defaults.colorScheme
            && value.windowOpacity == AppearanceSettingsSnapshot.defaults.windowOpacity
            && themeStore.activeTheme == .defaultTheme
    }

    private var windowOpacityHelp: String {
        if reduceTransparency {
            return "Turn off Reduce Transparency in macOS Accessibility settings to adjust window opacity."
        }
        if !SakuraCordWindowBlur.isAvailable {
            return "Window background blur is unavailable on this version of macOS."
        }
        return "Adjust the window opacity over a blurred backdrop while retaining your theme gradient. The default is 100%."
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

                LabeledContent("Window Opacity") {
                    HStack {
                        Slider(
                            value: $value.windowOpacity,
                            in: AppearanceSettingsSnapshot.windowOpacityRange
                        ) {
                            Text("Window Opacity", bundle: #bundle)
                        }
                        .labelsHidden()
                        .tint(SakuraCordAccentColor.color)
                        .frame(minWidth: InterfaceScale.metric(220))
                        .disabled(reduceTransparency || !SakuraCordWindowBlur.isAvailable)
                        Text(value.windowOpacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: InterfaceScale.metric(42), alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .contain)
                .help(windowOpacityHelp)
                .settingsControlAnchor(.windowOpacity, state: state)

                GradientThemeEditor(
                    themeStore: themeStore,
                    presentation: .settings(
                        appearance: value.colorScheme,
                        windowOpacity: value.windowOpacity
                    )
                )
                    .settingsControlAnchor(.themeDesigner, state: state)

                Button("Reset to Defaults…", role: .destructive) {
                    showsResetConfirmation = true
                }
                    .disabled(isUsingDefaults)
                    .settingsControlAnchor(.resetTheme, state: state)
            } header: {
                Text("Theme", bundle: #bundle)
            }

        }
        .settingsResetConfirmation(
            "Reset Theme?",
            isPresented: $showsResetConfirmation,
            resetTitle: "Reset Theme",
            message: "This resets your theme, appearance, and window opacity to their defaults. Are you sure you want to do this?",
            reset: resetTheme
        )
        .task {
            value = model.appearanceSettings
        }
        .onChange(of: value) { _, newValue in
            model.applyAppearanceSettings(newValue)
        }
        .onChange(of: model.appearanceSettings) { _, newValue in
            value = newValue
        }
    }

    private func resetTheme() {
        value.colorScheme = AppearanceSettingsSnapshot.defaults.colorScheme
        value.windowOpacity = AppearanceSettingsSnapshot.defaults.windowOpacity
        themeStore.apply(.defaultTheme)
    }
}
