import SwiftUI

struct AccessibilitySettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    @State private var value = AccessibilitySettingsSnapshot.defaults
    @State private var showsResetConfirmation = false

    var body: some View {
        SettingsPageForm(page: .accessibility, state: state) {
            motionSection
            cosmeticsSection
            readabilitySection
            voiceOverSection
            Section {
                Button("Reset All…", role: .destructive) {
                    showsResetConfirmation = true
                }
                .disabled(value == .defaults)
                .settingsControlAnchor(.accessibilityReset, state: state)
            }
        }
        .task {
            value = model.accessibilitySettings
        }
        .onChange(of: value) { _, newValue in
            model.applyAccessibilitySettings(newValue)
        }
        .settingsResetConfirmation(
            "Reset All Accessibility Settings?",
            isPresented: $showsResetConfirmation,
            resetTitle: "Reset All Settings",
            message: "This resets all of SakuraCord’s accessibility settings. Are you sure you want to do this?",
            reset: resetPreferences
        )
    }

    private var motionSection: some View {
        Section {
            Toggle("Disable all animations", isOn: $value.disablesAllAnimations)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.accessibilityDisableAllAnimations, state: state)
            Group {
                Toggle("Disable sidebar and member list animations", isOn: animationBinding(\.disablesSidebarAnimations))
                    .settingsControlAnchor(.accessibilityDisableSidebarAnimations, state: state)
                Toggle("Disable side chat and full width animations", isOn: animationBinding(\.disablesSideChatAnimations))
                    .settingsControlAnchor(.accessibilityDisableSideChatAnimations, state: state)
                Toggle("Disable search, popover and overlay animations", isOn: animationBinding(\.disablesOverlayAnimations))
                    .settingsControlAnchor(.accessibilityDisableOverlayAnimations, state: state)
                Toggle("Disable message sending animations", isOn: animationBinding(\.disablesMessageSendingAnimations))
                    .settingsControlAnchor(.accessibilityDisableSendAnimations, state: state)
            }
            .tint(SakuraCordAccentColor.color)
            .disabled(value.disablesAllAnimations)
        } header: {
            Text("Motion", bundle: #bundle)
        }
    }

    /// A category switch, which shows on while "Disable all animations" is.
    private func animationBinding(_ keyPath: WritableKeyPath<AccessibilitySettingsSnapshot, Bool>) -> Binding<Bool> {
        Binding(
            get: { value.disablesAllAnimations || value[keyPath: keyPath] },
            set: { value[keyPath: keyPath] = $0 }
        )
    }

    private var cosmeticsSection: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: InterfaceScale.metric(24), verticalSpacing: InterfaceScale.metric(10)) {
                GridRow {
                    Toggle("Profile effects", isOn: $value.disablesProfileEffects)
                        .accessibilityLabel("Disable profile effects")
                        .settingsControlAnchor(.accessibilityDisableProfileEffects, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Nameplates", isOn: $value.disablesNameplates)
                        .accessibilityLabel("Disable nameplates")
                        .settingsControlAnchor(.accessibilityDisableNameplates, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Toggle("Avatar decorations", isOn: $value.disablesAvatarDecorations)
                        .accessibilityLabel("Disable avatar decorations")
                        .settingsControlAnchor(.accessibilityDisableAvatarDecorations, state: state)
                    Toggle("Profile frames", isOn: $value.disablesProfileFrames)
                        .accessibilityLabel("Disable profile frames")
                        .settingsControlAnchor(.accessibilityDisableProfileFrames, state: state)
                }
                GridRow {
                    Toggle("Name styles", isOn: $value.disablesNameStyles)
                        .accessibilityLabel("Disable name styles")
                        .settingsControlAnchor(.accessibilityDisableNameStyles, state: state)
                    Toggle("Nitro profile gradients", isOn: $value.disablesProfileGradients)
                        .accessibilityLabel("Disable nitro profile gradients")
                        .settingsControlAnchor(.accessibilityDisableProfileGradients, state: state)
                }
                GridRow {
                    Toggle("Server tags", isOn: $value.disablesServerTags)
                        .accessibilityLabel("Disable server tags")
                        .settingsControlAnchor(.accessibilityDisableServerTags, state: state)
                        .gridCellColumns(2)
                }
            }
            .toggleStyle(.checkbox)
            .tint(SakuraCordAccentColor.color)
            Toggle("Disable own", isOn: $value.disablesOwnCosmetics)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.accessibilityDisableOwnCosmetics, state: state)
        } header: {
            Text("Disable Cosmetics", bundle: #bundle)
        }
    }

    private var readabilitySection: some View {
        Section {
            Toggle("Underline links", isOn: $value.underlinesLinks)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.underlineLinks, state: state)
            Picker("Role colours", selection: $value.roleColorDisplay) {
                ForEach(RoleColorDisplay.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .settingsControlAnchor(.roleColorDisplay, state: state)
        } header: {
            Text("Readability", bundle: #bundle)
        }
    }

    private var voiceOverSection: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: InterfaceScale.metric(24), verticalSpacing: InterfaceScale.metric(10)) {
                GridRow {
                    Toggle("Timestamps", isOn: $value.announcesTimestamps)
                        .settingsControlAnchor(.accessibilityAnnounceTimestamp, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Edited status", isOn: $value.announcesEditedStatus)
                        .settingsControlAnchor(.accessibilityAnnounceEdited, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Toggle("Reaction counts", isOn: $value.announcesReactionCounts)
                        .settingsControlAnchor(.accessibilityAnnounceReactions, state: state)
                    Toggle("Attachment types", isOn: $value.announcesAttachmentTypes)
                        .settingsControlAnchor(.accessibilityAnnounceAttachmentTypes, state: state)
                }
                GridRow {
                    Toggle("Announce new messages", isOn: $value.announcesNewMessages)
                        .settingsControlAnchor(.accessibilityAnnounceNewMessages, state: state)
                        .gridCellColumns(2)
                }
            }
            .toggleStyle(.checkbox)
            .tint(SakuraCordAccentColor.color)
        } header: {
            Text("VoiceOver", bundle: #bundle)
        }
    }

    private func resetPreferences() {
        SettingsPreferenceStore.shared.reset(scope: .appWide, page: .accessibility)
        value = AccessibilitySettingsStore.shared.load()
        model.applyAccessibilitySettings(value, persists: false)
    }
}
