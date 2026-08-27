import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AccessibilitySettingsPage: View {
    private enum Confirmation: String, Identifiable {
        case reset
        var id: String { rawValue }
    }

    let model: AppModel
    let state: SettingsViewState

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiatesWithoutColor
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var value = AccessibilitySettingsSnapshot.defaults
    @State private var systemRevision = 0
    @State private var confirmation: Confirmation?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var operationMessage: String?

    var body: some View {
        SettingsPageForm(page: .accessibility, state: state) {
            motionSection
            readabilitySection
            voiceOverSection
            localDataSection
        }
        .task {
            value = model.accessibilitySettings
        }
        .onChange(of: value) { _, newValue in
            model.applyAccessibilitySettings(newValue)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            systemRevision &+= 1
        }
        .confirmationDialog(
            "Reset Accessibility Settings?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            )
        ) {
            Button("Reset Accessibility Settings", role: .destructive) {
                resetPreferences()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores SakuraCord’s local accessibility preferences. macOS accessibility settings are not changed.")
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Accessibility-Settings-v1"
        ) { result in
            switch result {
            case .success:
                operationMessage = "Exported Accessibility settings."
            case let .failure(error):
                operationMessage = "Export failed: \(error.localizedDescription)"
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
        }
    }

    private var motionSection: some View {
        Section {
            LabeledContent("macOS Reduce Motion") {
                SettingsBooleanStatus(isEnabled: systemReduceMotion)
            }

            Picker("Motion preference", selection: $value.motionOverride) {
                ForEach(AccessibilityMotionOverride.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .settingsControlAnchor(.accessibilityMotionOverride, state: state)

            Toggle("Reduce animated content", isOn: $value.reducesAnimatedContent)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.accessibilityReduceAnimatedContent, state: state)

            Group {
                Toggle("Animated emoji", isOn: $value.reducesAnimatedEmoji)
                    .settingsControlAnchor(.accessibilityReduceAnimatedEmoji, state: state)
                Toggle("Animated stickers", isOn: $value.reducesAnimatedStickers)
                    .settingsControlAnchor(.accessibilityReduceAnimatedStickers, state: state)
                Toggle("GIFs and animated images", isOn: $value.reducesGIFs)
                    .settingsControlAnchor(.accessibilityReduceGIFs, state: state)
                Toggle("Animated avatars", isOn: $value.reducesAnimatedAvatars)
                    .settingsControlAnchor(.accessibilityReduceAnimatedAvatars, state: state)
                Toggle("Profile decorations", isOn: $value.reducesDecorations)
                    .settingsControlAnchor(.accessibilityReduceDecorations, state: state)
                Toggle("Nonessential transitions", isOn: $value.reducesTransitions)
                    .settingsControlAnchor(.accessibilityReduceTransitions, state: state)
            }
            .tint(SakuraCordAccentColor.color)
            .disabled(value.reducesAnimatedContent)
        } header: {
            Text("Motion & Animated Content", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if value.reducesAnimatedContent {
                    Text("The master reduction currently pauses every category above; category choices are retained for later.")
                }
                Text("macOS Reduce Motion always takes precedence. SakuraCord never overrides it to permit more motion.")
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }

    private var readabilitySection: some View {
        Section {
            LabeledContent("macOS Increase Contrast") {
                SettingsBooleanStatus(
                    isEnabled: colorSchemeContrast == .increased
                        || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                )
                .id(systemRevision)
            }
            LabeledContent("Differentiate Without Color") {
                SettingsBooleanStatus(
                    isEnabled: differentiatesWithoutColor
                        || NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
                )
                .id(systemRevision)
            }

            Toggle("Increase contrast in SakuraCord", isOn: $value.increasesContrast)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.accessibilityIncreaseContrast, state: state)
            Toggle(
                "Use larger message action targets",
                isOn: $value.enlargesMessageActionTargets
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.accessibilityLargerTargets, state: state)

            Button("Open Underline Links in Interface…") {
                state.navigate(
                    to: SettingsDestination(page: .interface, section: .interfaceVisibility),
                    controlID: .underlineLinks
                )
            }
            .settingsControlAnchor(.accessibilityUnderlineLinks, state: state)

            Button("Open Message Actions in Interface…") {
                state.navigate(
                    to: SettingsDestination(page: .interface, section: .interfaceVisibility),
                    controlID: .messageActionVisibility
                )
            }
            .settingsControlAnchor(.accessibilityMessageActions, state: state)
        } header: {
            Text("Readability & Interaction", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unread state uses weight, labels, counts, and separators; presence states use distinct shapes as well as color.")
                Text("Link and message-action controls live in Interface so there is only one setting for each behavior.")
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }

    private var voiceOverSection: some View {
        Section {
            LabeledContent("VoiceOver") {
                SettingsBooleanStatus(
                    isEnabled: voiceOverEnabled || NSWorkspace.shared.isVoiceOverEnabled
                )
                .id(systemRevision)
            }

            Group {
                Toggle("Include timestamps", isOn: $value.announcesTimestamps)
                    .settingsControlAnchor(.accessibilityAnnounceTimestamp, state: state)
                Toggle("Include edited status", isOn: $value.announcesEditedStatus)
                    .settingsControlAnchor(.accessibilityAnnounceEdited, state: state)
                Toggle("Include reaction counts", isOn: $value.announcesReactionCounts)
                    .settingsControlAnchor(.accessibilityAnnounceReactions, state: state)
                Toggle("Include attachment types", isOn: $value.announcesAttachmentTypes)
                    .settingsControlAnchor(.accessibilityAnnounceAttachmentTypes, state: state)
                Toggle("Announce new messages", isOn: $value.announcesNewMessages)
                    .settingsControlAnchor(.accessibilityAnnounceNewMessages, state: state)
            }
            .tint(SakuraCordAccentColor.color)
        } header: {
            Text("VoiceOver", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("New-message announcements run only while VoiceOver is active, group bursts, and say only a generic count—never sender, channel, or message content.")
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }

    private var localDataSection: some View {
        Section {
            HStack {
                Button("Export Settings…") {
                    exportedPreferences = SettingsPreferenceExportFile(
                        export: SettingsPreferenceStore.shared.export(
                            scope: .appWide,
                            page: .accessibility
                        )
                    )
                    isExporting = true
                }
                .settingsControlAnchor(.accessibilityExport, state: state)

                Button("Reset to Defaults…", role: .destructive) {
                    confirmation = .reset
                }
                .settingsControlAnchor(.accessibilityReset, state: state)
            }
            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(operationMessage)
            }
        } header: {
            Text("Local Data", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }

    private func resetPreferences() {
        confirmation = nil
        SettingsPreferenceStore.shared.reset(scope: .appWide, page: .accessibility)
        value = AccessibilitySettingsStore.shared.load()
        model.applyAccessibilitySettings(value, persists: false)
        operationMessage = "Restored Accessibility settings to their defaults. macOS settings were left unchanged."
    }
}

private struct SettingsBooleanStatus: View {
    let isEnabled: Bool

    var body: some View {
        Label(
            isEnabled ? "On" : "Off",
            systemImage: isEnabled ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .accessibilityValue(isEnabled ? "On" : "Off")
    }
}
