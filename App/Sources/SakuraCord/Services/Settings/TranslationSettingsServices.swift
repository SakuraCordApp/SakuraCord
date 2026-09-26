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
        if case let .bool(saved) = preferences.value(for: .translationEnabled) { value.isEnabled = saved }
        if case let .string(saved) = preferences.value(for: .translationMessageLanguage) { value.messageLanguage = saved }
        if case let .string(saved) = preferences.value(for: .translationDraftLanguage) { value.draftLanguage = saved }
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
    }
}
