import Foundation
import MediaPipeline

nonisolated extension SettingsPreferenceRegistration {
    /// Whether a stored or imported value is one this setting can hold.
    func accepts(_ value: SettingsPreferenceValue) -> Bool {
        // Swift's NSNumber bridging can treat 1 as true. Match the declared type exactly.
        switch (defaultValue, value) {
        case (.bool, .bool), (.integer, .integer), (.double, .double), (.string, .string), (.strings, .strings): break
        default: return false
        }
        if case let .double(number) = value, !number.isFinite { return false }
        switch value {
        case let .string(raw): return acceptsString(raw)
        case let .double(number): return Self.acceptsDouble(number, id: id)
        case let .integer(number):
            switch id {
            case .localStorageLimit: return LocalStorageLimit(rawValue: Int64(number)) != nil
            case .voiceScreenShareFrameRate: return ScreenShareFrameRate(rawValue: number) != nil
            default: return true
            }
        case let .strings(domains) where id == .trustedDomains:
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

    /// Keyboard shortcuts are validated as chords; any other string setting
    /// without its own validator accepts any value.
    private func acceptsString(_ raw: String) -> Bool {
        if let validate { return validate(raw) }
        guard let action = KeyboardShortcutAction.allCases.first(where: { $0.controlID == id }) else { return true }
        if raw.isEmpty { return true }
        guard let chord = KeyboardShortcutChord(storageValue: raw), chord.modifiers.rawValue < 16 else { return false }
        return KeyboardShortcutPolicy.validate(chord, for: action, shortcuts: [:]) == .valid
    }
}
