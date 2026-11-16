import AppKit

nonisolated struct GeneralInputSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(reading: SettingsPreferenceRegistry.foundation.defaultValue(for:))

    var sendsWithReturn: Bool
    var checksSpelling: Bool
    var correctsSpellingAutomatically: Bool
    var usesSmartQuotes: Bool
    var usesSmartDashes: Bool
    var emojiSkinTone: NativeEmojiSkinTone
}

nonisolated extension GeneralInputSettingsSnapshot {
    init(reading value: (SettingsControlID) -> SettingsPreferenceValue) {
        sendsWithReturn = value(.sendWithReturn).boolValue
        checksSpelling = value(.spellCheck).boolValue
        correctsSpellingAutomatically = value(.automaticCorrection).boolValue
        usesSmartQuotes = value(.smartQuotes).boolValue
        usesSmartDashes = value(.smartDashes).boolValue
        emojiSkinTone = value(.emojiSkinTone).rawValue()
    }
}

@MainActor
enum ComposerTextCheckingConfiguration {
    static func apply(_ settings: GeneralInputSettingsSnapshot, to textView: NSTextView) {
        textView.isContinuousSpellCheckingEnabled = settings.checksSpelling
        textView.isAutomaticSpellingCorrectionEnabled = settings.correctsSpellingAutomatically
        textView.isAutomaticQuoteSubstitutionEnabled = settings.usesSmartQuotes
        textView.isAutomaticDashSubstitutionEnabled = settings.usesSmartDashes
    }
}

@MainActor
final class GeneralInputSettingsStore {
    static let shared = GeneralInputSettingsStore()
    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> GeneralInputSettingsSnapshot {
        GeneralInputSettingsSnapshot { preferences.value(for: $0) }
    }

    func save(_ value: GeneralInputSettingsSnapshot) {
        preferences.set(.bool(value.sendsWithReturn), for: .sendWithReturn)
        preferences.set(.bool(value.checksSpelling), for: .spellCheck)
        preferences.set(.bool(value.correctsSpellingAutomatically), for: .automaticCorrection)
        preferences.set(.bool(value.usesSmartQuotes), for: .smartQuotes)
        preferences.set(.bool(value.usesSmartDashes), for: .smartDashes)
        preferences.set(.string(value.emojiSkinTone.rawValue), for: .emojiSkinTone)
    }
}

extension AppModel {
    func applyGeneralInputSettings(_ value: GeneralInputSettingsSnapshot) {
        generalInputSettings = value
        GeneralInputSettingsStore.shared.save(value)
    }
}
