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
        case let .double(number): return acceptsDouble(number, id: registration.id)
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

    private static func acceptsDouble(_ number: Double, id: SettingsControlID) -> Bool {
        switch id {
        case .windowOpacity: return AppearanceSettingsSnapshot.windowOpacityRange.contains(number)
        case .messageDensity: return AppearanceSettingsSnapshot.messageSpacingRange.contains(number)
        case .messageFontSize: return InterfaceTypographyMetrics.messageTextSizeRange.contains(CGFloat(number))
        case .interfaceSize: return InterfaceScale.range.contains(number)
        case .voiceInputVolume, .voiceOutputVolume: return (0 ... 2).contains(number)
        default: return true
        }
    }

    /// What each string setting accepts. Keyboard shortcuts are validated
    /// as chords; any other string setting accepts any value.
    private static let stringValidators: [SettingsControlID: @Sendable (String) -> Bool] = [
        .translationMessageLanguage: { TranslationLanguages.validPreference($0) },
        .translationDraftLanguage: { TranslationLanguages.validPreference($0) },
        .launchDestination: { SettingsLaunchDestination(rawValue: $0) != nil },
        .appColorScheme: { AppColorScheme(rawValue: $0) != nil },
        .composerBarAppearance: { ComposerBarAppearance(rawValue: $0) != nil },
        .messageAppearance: { MessageAppearance(rawValue: $0) != nil },
        .directMessageAppearance: { MessageAppearance(rawValue: $0) != nil },
        .groupMessageAppearance: { MessageAppearance(rawValue: $0) != nil },
        .timestampFormat: { InterfaceTimestampFormat(rawValue: $0) != nil },
        .roleColorDisplay: { RoleColorDisplay(rawValue: $0) != nil },
        .emojiSkinTone: { NativeEmojiSkinTone(rawValue: $0) != nil },
        .notificationPreview: { NotificationPreviewStyle(rawValue: $0) != nil },
        .notificationDockBadge: { NotificationDockBadgeStyle(rawValue: $0) != nil },
        .voiceScreenShareQuality: { ScreenShareQuality(rawValue: $0) != nil },
        .externalLinkProtection: { ExternalLinkConfirmationPolicy(rawValue: $0) != nil },
        .updateReleaseTrack: { AppUpdateReleaseTrack(rawValue: $0) != nil },
        .attachmentCompactionPrompt: { AttachmentHandlingPolicy(rawValue: $0) != nil },
        .attachmentExternalUploadPrompt: { AttachmentHandlingPolicy(rawValue: $0) != nil },
        .attachmentExternalProvider: { ExternalAttachmentHostingService(rawValue: $0) != nil },
        .attachmentCompactionQuality: { AttachmentCompactionOptions.Quality(rawValue: $0) != nil },
        .themeDesigner: { SakuraCordGradientTheme(storageValue: $0) != nil },
        .composerIcons: { (try? JSONDecoder().decode(ComposerIconLayout.self, from: Data($0.utf8))) != nil },
    ]

    private static func acceptsString(_ raw: String, id: SettingsControlID) -> Bool {
        if let validate = stringValidators[id] { return validate(raw) }
        guard let action = KeyboardShortcutAction.allCases.first(where: { $0.controlID == id }) else { return true }
        if raw.isEmpty { return true }
        guard let chord = KeyboardShortcutChord(storageValue: raw), chord.modifiers.rawValue < 16 else { return false }
        return KeyboardShortcutPolicy.validate(chord, for: action, shortcuts: [:]) == .valid
    }
}
