import SwiftUI
import UniformTypeIdentifiers

struct InterfaceSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var value = InterfaceSettingsSnapshot.defaults
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var confirmsReset = false
    @State private var operationMessage: String?

    var body: some View {
        SettingsPageForm(page: .interface, state: state) {
            InterfaceDensitySection(value: $value, state: state)
            InterfaceTypographySection(
                value: $value,
                resetTextSizes: resetTextSizes,
                state: state
            )
            InterfaceTimeSection(value: $value, state: state)
            InterfaceVisibilitySection(value: $value, state: state)
            Section {
                InterfaceSettingsPreview(value: value)
                    .settingsControlAnchor(.interfacePreview, state: state)
            } header: {
                Text("Preview", bundle: #bundle)
            } footer: {
                Text("Representative local samples only. The preview never reads Discord data.")
            }
            InterfaceLocalDataSection(
                operationMessage: operationMessage,
                export: exportPreferences,
                requestReset: { confirmsReset = true },
                state: state
            )
        }
        .task {
            value = model.interfaceSettings
        }
        .onChange(of: value) { _, newValue in
            model.applyInterfaceSettings(newValue)
        }
        .confirmationDialog(
            "Reset Interface Settings?",
            isPresented: $confirmsReset
        ) {
            Button("Reset Interface Settings", role: .destructive) {
                resetPreferences()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This restores only registered local Interface preferences. Credentials and Discord data are unchanged."
            )
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Interface-Settings-v1"
        ) { result in
            switch result {
            case .success:
                operationMessage = "Exported Interface settings."
            case let .failure(error):
                operationMessage = "Export failed: \(error.localizedDescription)"
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
        }
    }

    private func resetTextSizes() {
        value.messageTextSize = InterfaceSettingsSnapshot.defaults.messageTextSize
        value.interfaceTextSize = InterfaceSettingsSnapshot.defaults.interfaceTextSize
    }

    private func exportPreferences() {
        let export = SettingsPreferenceStore.shared.export(
            scope: .appWide,
            page: .interface
        )
        exportedPreferences = SettingsPreferenceExportFile(export: export)
        isExporting = true
    }

    private func resetPreferences() {
        SettingsPreferenceStore.shared.reset(
            scope: .appWide,
            page: .interface
        )
        value = InterfaceSettingsStore.shared.load()
        operationMessage = "Restored Interface settings to their defaults."
    }
}

private struct InterfaceDensitySection: View {
    @Binding var value: InterfaceSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Picker("Message density", selection: $value.messageDensity) {
                ForEach(InterfaceMessageDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }
            .pickerStyle(.segmented)
            .settingsControlAnchor(.messageDensity, state: state)

            Picker("Sidebar density", selection: $value.sidebarDensity) {
                ForEach(InterfaceSidebarDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }
            .pickerStyle(.segmented)
            .settingsControlAnchor(.sidebarDensity, state: state)
        } header: {
            Text("Density", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}

private struct InterfaceTypographySection: View {
    @Binding var value: InterfaceSettingsSnapshot
    let resetTextSizes: () -> Void
    let state: SettingsViewState

    var body: some View {
        Section {
            InterfaceTextSizeSlider(
                label: "Message text size",
                value: $value.messageTextSize,
                range: InterfaceSettingsSnapshot.messageTextSizeRange
            )
            .settingsControlAnchor(.messageTextSize, state: state)

            InterfaceTextSizeSlider(
                label: "Interface text size",
                value: $value.interfaceTextSize,
                range: InterfaceSettingsSnapshot.interfaceTextSizeRange
            )
            .settingsControlAnchor(.interfaceTextSize, state: state)

            Button("Reset Text Sizes", action: resetTextSizes)
                .settingsControlAnchor(.resetInterfaceTextSizes, state: state)
        } header: {
            Text("Text", bundle: #bundle)
        } footer: {
            Text("Text sizes are bounded to keep messages and controls readable.")
        }
    }
}

private struct InterfaceTextSizeSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: $value, in: range, step: 1)
                    .tint(SakuraCordAccentColor.color)
                    .frame(minWidth: 220)
                Text("\(Int(value)) pt")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .accessibilityValue("\(Int(value)) points")
    }
}

private struct InterfaceTimeSection: View {
    @Binding var value: InterfaceSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Picker("Timestamp format", selection: $value.timestampFormat) {
                ForEach(InterfaceTimestampFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .settingsControlAnchor(.timestampFormat, state: state)

            Toggle(
                "Show seconds in full timestamps",
                isOn: $value.includesTimestampSeconds
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.timestampSeconds, state: state)

            LabeledContent("Consecutive-message grouping") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(value.groupingIntervalMinutes) },
                            set: { value.groupingIntervalMinutes = Int($0) }
                        ),
                        in: Double(InterfaceSettingsSnapshot.groupingIntervalRange.lowerBound)
                            ... Double(InterfaceSettingsSnapshot.groupingIntervalRange.upperBound),
                        step: 1
                    )
                    .tint(SakuraCordAccentColor.color)
                    .frame(minWidth: 220)
                    Text(value.groupingIntervalMinutes, format: .number)
                        .monospacedDigit()
                    Text("min", bundle: #bundle)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityValue("\(value.groupingIntervalMinutes) minutes")
            .settingsControlAnchor(.groupingInterval, state: state)
        } header: {
            Text("Time and grouping", bundle: #bundle)
        } footer: {
            Text("System follows the current locale. Explicit 12- and 24-hour choices keep their selected clock.")
        }
    }
}

private struct InterfaceVisibilitySection: View {
    @Binding var value: InterfaceSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle("Underline links", isOn: $value.underlinesLinks)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.underlineLinks, state: state)
            Toggle("Show member list", isOn: $value.showsMemberList)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.showMemberList, state: state)
            Toggle(
                "Show activity and presence details",
                isOn: $value.showsActivityDetails
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.showActivityDetails, state: state)
            Picker(
                "Message actions",
                selection: $value.messageActionVisibility
            ) {
                ForEach(InterfaceMessageActionVisibility.allCases) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            .settingsControlAnchor(.messageActionVisibility, state: state)
            Toggle("Show Discord role colors", isOn: $value.showsRoleColors)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.showRoleColors, state: state)
        } header: {
            Text("Visibility", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }
}

private struct InterfaceLocalDataSection: View {
    let operationMessage: String?
    let export: () -> Void
    let requestReset: () -> Void
    let state: SettingsViewState

    var body: some View {
        Section {
            HStack {
                Button("Export Interface Settings…", action: export)
                    .settingsControlAnchor(.exportInterfaceSettings, state: state)
                Button("Reset Interface Settings…", role: .destructive, action: requestReset)
                    .settingsControlAnchor(.resetInterfaceSettings, state: state)
            }
            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Local data", bundle: #bundle)
        } footer: {
            Text("Reset and export cover only registered app-wide Interface preferences on this Mac.")
        }
    }
}
