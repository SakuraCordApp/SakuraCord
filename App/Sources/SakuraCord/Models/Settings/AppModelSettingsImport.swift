import Foundation

extension AppModel {
    func reloadImportedSettings(_ ids: Set<String>) async {
        let pages = Set(SettingsPreferenceRegistry.foundation.registrations.compactMap {
            ids.contains($0.id.rawValue) ? $0.page : nil
        })
        if pages.contains(.general) {
            applyGeneralInputSettings(GeneralInputSettingsStore.shared.load())
        }
        if pages.contains(.features) {
            applyFeaturesSettings(FeaturesSettingsStore.shared.load())
            applyAttachmentSettings(attachmentSettingsStore.load())
            applyTranslationSettings(translation.settingsStore.load())
        }
        if pages.contains(.appearance) || pages.contains(.interface) {
            applyAppearanceSettings(AppearanceSettingsStore.shared.load(), persists: false)
            applyInterfaceSettings(InterfaceSettingsStore.shared.load(), persists: false)
        }
        if ids.contains(SettingsControlID.themeDesigner.rawValue) {
            SakuraCordThemeStore.shared.apply(SakuraCordThemeSettingsStore.shared.load())
        }
        if pages.contains(.accessibility) {
            applyAccessibilitySettings(AccessibilitySettingsStore.shared.load(), persists: false)
        }
        if ids.contains(SettingsControlID.memberListVisibility.rawValue) {
            showInspector = GeneralWindowRestorationStore.shared.memberListIsVisible
        }
        if pages.contains(.notifications) {
            notificationPreferences.reload()
            refreshDockBadge()
        }
        if pages.contains(.keyboardShortcuts) { KeyboardShortcutSettingsStore.shared.reload() }
        if pages.contains(.privacySafety), !privacySafetySettings.sendsTypingIndicators {
            stopLocalTyping(clearThrottle: false)
        }
        if pages.contains(.diagnostics) { DiagnosticsPreferences.restore() }
        if pages.contains(.storageDownloads) { await applyConfiguredLocalStorageLimit() }
        if pages.contains(.voiceVideo) { await reloadImportedVoiceSettings(ids) }
    }

    private func reloadImportedVoiceSettings(_ ids: Set<String>) async {
        voiceVideoPreferences.reload()
        await refreshMediaDevices()
        if ids.contains(SettingsControlID.voiceInputDevice.rawValue) {
            _ = await selectInputDevice(mediaDevices.audioInputs.first { $0.uid == voiceVideoPreferences.inputDeviceUID })
        }
        if ids.contains(SettingsControlID.voiceOutputDevice.rawValue) {
            _ = await selectOutputDevice(mediaDevices.audioOutputs.first { $0.uid == voiceVideoPreferences.outputDeviceUID })
        }
        if ids.contains(SettingsControlID.voiceCamera.rawValue) {
            _ = await selectCamera(mediaDevices.cameras.first { $0.uniqueID == voiceVideoPreferences.cameraUID })
        }
        if ids.contains(SettingsControlID.voiceInputVolume.rawValue) { await updateInputVolume(inputVolume) }
        if ids.contains(SettingsControlID.voiceOutputVolume.rawValue) { await updateOutputVolume(outputVolume) }
    }
}
