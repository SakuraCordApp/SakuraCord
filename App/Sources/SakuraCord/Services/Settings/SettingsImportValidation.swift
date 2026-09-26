import Foundation
import MediaPipeline

nonisolated enum SettingsImportValidation {
    static func accepts(_ value: SettingsPreferenceValue, registration: SettingsPreferenceRegistration) -> Bool {
        // Swift's NSNumber bridging can treat 1 as true. Match the archive's declared type exactly.
        switch (registration.defaultValue, value) {
        case (.bool, .bool), (.integer, .integer), (.double, .double), (.string, .string), (.strings, .strings): break
        default: return false
        }
        if case let .double(number) = value, !number.isFinite { return false }
        switch value {
        case let .string(raw): return acceptsString(raw, id: registration.id)
        case let .double(number):
            switch registration.id {
            case .windowOpacity: return AppearanceSettingsSnapshot.windowOpacityRange.contains(number)
            case .messageDensity: return AppearanceSettingsSnapshot.messageSpacingRange.contains(number)
            case .voiceInputVolume, .voiceOutputVolume: return (0 ... 2).contains(number)
            default: return true
            }
        case let .integer(number):
            switch registration.id {
            case .localStorageLimit: return LocalStorageLimit(rawValue: Int64(number)) != nil
            case .voiceScreenShareFrameRate: return ScreenShareFrameRate(rawValue: number) != nil
            default: return true
            }
        case let .strings(domains) where registration.id == .trustedDomains:
            return domains.allSatisfy { ExternalLinkTrustedDomain.normalized($0) != nil }
        default: return true
        }
    }

    private static func acceptsString(_ raw: String, id: SettingsControlID) -> Bool {
        switch id {
        case .translationMessageLanguage, .translationDraftLanguage: return TranslationLanguages.validPreference(raw)
        case .launchDestination: return SettingsLaunchDestination(rawValue: raw) != nil
        case .appColorScheme: return AppColorScheme(rawValue: raw) != nil
        case .composerBarAppearance: return ComposerBarAppearance(rawValue: raw) != nil
        case .messageAppearance: return MessageAppearance(rawValue: raw) != nil
        case .timestampFormat: return InterfaceTimestampFormat(rawValue: raw) != nil
        case .roleColorDisplay: return RoleColorDisplay(rawValue: raw) != nil
        case .emojiSkinTone: return NativeEmojiSkinTone(rawValue: raw) != nil
        case .notificationPreview: return NotificationPreviewStyle(rawValue: raw) != nil
        case .notificationDockBadge: return NotificationDockBadgeStyle(rawValue: raw) != nil
        case .voiceScreenShareQuality: return ScreenShareQuality(rawValue: raw) != nil
        case .externalLinkProtection: return ExternalLinkConfirmationPolicy(rawValue: raw) != nil
        case .updateReleaseTrack: return AppUpdateReleaseTrack(rawValue: raw) != nil
        default: return acceptsAttachmentString(raw, id: id)
        }
    }

    private static func acceptsAttachmentString(_ raw: String, id: SettingsControlID) -> Bool {
        switch id {
        case .attachmentCompactionPrompt, .attachmentExternalUploadPrompt: return AttachmentHandlingPolicy(rawValue: raw) != nil
        case .attachmentExternalProvider: return ExternalAttachmentHostingService(rawValue: raw) != nil
        case .attachmentCompactionQuality: return AttachmentCompactionOptions.Quality(rawValue: raw) != nil
        default: return acceptsStructuredString(raw, id: id)
        }
    }

    private static func acceptsStructuredString(_ raw: String, id: SettingsControlID) -> Bool {
        switch id {
        case .themeDesigner: return SakuraCordGradientTheme(storageValue: raw) != nil
        case .composerIcons: return (try? JSONDecoder().decode(ComposerIconLayout.self, from: Data(raw.utf8))) != nil
        default:
            guard let action = KeyboardShortcutAction.allCases.first(where: { $0.controlID == id }) else { return true }
            if raw.isEmpty { return true }
            guard let chord = KeyboardShortcutChord(storageValue: raw), chord.modifiers.rawValue < 16 else { return false }
            return KeyboardShortcutPolicy.validate(chord, for: action, shortcuts: [:]) == .valid
        }
    }
}
