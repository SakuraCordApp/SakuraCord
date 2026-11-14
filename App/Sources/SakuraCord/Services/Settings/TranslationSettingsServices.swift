import Foundation

nonisolated struct TranslationSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self()
    var isEnabled = false
    var messageLanguage = ""
    var draftLanguage = "en"
}

@MainActor
final class TranslationSettingsStore {
    static let shared = TranslationSettingsStore()
    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> TranslationSettingsSnapshot {
        var value = TranslationSettingsSnapshot.defaults
        value.isEnabled = preferences.bool(.translationEnabled)
        value.messageLanguage = preferences.string(.translationMessageLanguage)
        value.draftLanguage = preferences.string(.translationDraftLanguage)
        return value
    }

    func save(_ value: TranslationSettingsSnapshot) {
        preferences.set(.bool(value.isEnabled), for: .translationEnabled)
        preferences.set(.string(value.messageLanguage), for: .translationMessageLanguage)
        preferences.set(.string(value.draftLanguage), for: .translationDraftLanguage)
    }
}

extension AppModel {
    func applyTranslationSettings(_ value: TranslationSettingsSnapshot) {
        guard translation.settings != value else { return }
        // Drop toggle state, never the current composer text (including edits).
        resetAllTranslations()
        translation.settings = value
        translation.settingsStore.save(value)
        invalidateTimelinePresentation()
    }
}
