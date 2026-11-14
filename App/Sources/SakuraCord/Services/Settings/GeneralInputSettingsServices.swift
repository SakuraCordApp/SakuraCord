import AppKit

nonisolated struct GeneralInputSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self()

    var sendsWithReturn = true
    var checksSpelling = false
    var correctsSpellingAutomatically = false
    var usesSmartQuotes = false
    var usesSmartDashes = false
    var emojiSkinTone: NativeEmojiSkinTone = .standard
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
        var value = GeneralInputSettingsSnapshot.defaults
        if let saved = preferences.bool(.sendWithReturn) {
            value.sendsWithReturn = saved
        }
        if let saved = preferences.bool(.spellCheck) {
            value.checksSpelling = saved
        }
        if let saved = preferences.bool(.automaticCorrection) {
            value.correctsSpellingAutomatically = saved
        }
        if let saved = preferences.bool(.smartQuotes) {
            value.usesSmartQuotes = saved
        }
        if let saved = preferences.bool(.smartDashes) {
            value.usesSmartDashes = saved
        }
        value.emojiSkinTone = preferences.rawValue(.emojiSkinTone) ?? value.emojiSkinTone
        return value
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
