import Foundation

nonisolated struct TranslationSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self()

    var provider: TranslationProvider = .off
    var libreTranslateServer = ""
    /// Empty follows the system language.
    var messageLanguage = ""
    var draftLanguage = TranslationLanguage.englishUS.rawValue

    var isEnabled: Bool { provider != .off }

    var resolvedMessageLanguage: TranslationLanguage {
        TranslationLanguage.resolved(messageLanguage)
    }

    var resolvedDraftLanguage: TranslationLanguage {
        TranslationLanguage.resolved(draftLanguage)
    }
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
        if case let .string(raw) = preferences.value(for: .translationProvider),
           let saved = TranslationProvider(rawValue: raw) { value.provider = saved }
        if case let .string(saved) = preferences.value(for: .translationServer) { value.libreTranslateServer = saved }
        if case let .string(saved) = preferences.value(for: .translationMessageLanguage) { value.messageLanguage = saved }
        if case let .string(saved) = preferences.value(for: .translationDraftLanguage) { value.draftLanguage = saved }
        return value
    }

    func save(_ value: TranslationSettingsSnapshot) {
        preferences.set(.string(value.provider.rawValue), for: .translationProvider)
        preferences.set(.string(value.libreTranslateServer), for: .translationServer)
        preferences.set(.string(value.messageLanguage), for: .translationMessageLanguage)
        preferences.set(.string(value.draftLanguage), for: .translationDraftLanguage)
    }
}

extension AppModel {
    func applyTranslationSettings(_ value: TranslationSettingsSnapshot) {
        let previous = translation.settings
        guard previous != value else { return }
        translation.settings = value
        translation.settingsStore.save(value)
        // Translations made with another provider or language no longer match the settings.
        if previous.provider != value.provider
            || previous.resolvedMessageLanguage != value.resolvedMessageLanguage
            || previous.libreTranslateServer != value.libreTranslateServer {
            clearMessageTranslations()
        }
        if previous.provider != value.provider || previous.resolvedDraftLanguage != value.resolvedDraftLanguage {
            translation.discardCachedDraftTranslations()
        }
    }

    func saveTranslationAPIKey(_ key: String, for provider: TranslationProvider) async throws {
        try await translation.apiKeys.setAPIKey(key, for: provider)
        await translation.refreshSavedAPIKeys()
    }
}
