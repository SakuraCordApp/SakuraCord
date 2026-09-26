@testable import SakuraCord
import Foundation
import Testing

@MainActor
@Test func `translation preferences round trip through import export and reset without activating translation`() throws {
    let source = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let store = TranslationSettingsStore(preferences: source)
    #expect(store.load() == .defaults)
    let selected = TranslationSettingsSnapshot(isEnabled: true, messageLanguage: "nl-Latn-NL", draftLanguage: "ja-Jpan-JP")
    store.save(selected)
    let archive = SettingsTransferService(preferences: source).export(pages: [.features])
    let decoded = try SettingsArchive.decode(archive.encodedData())
    let target = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let report = SettingsTransferService(preferences: target).importPreferences(decoded)
    #expect(!report.needsUpdate)
    #expect(TranslationSettingsStore(preferences: target).load() == selected)
    target.reset(scope: .appWide, page: .features)
    #expect(TranslationSettingsStore(preferences: target).load() == .defaults)
    let coordinator = AppleTranslationCoordinator()
    let state = TranslationState(settingsStore: store, coordinator: coordinator)
    #expect(state.settings.isEnabled)
    #expect(coordinator.active == nil)
    #expect(coordinator.languages.supported.isEmpty)
}

@MainActor
@Test func `malformed translation preferences are rejected while unavailable identifiers stay reviewable`() throws {
    let target = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let report = SettingsTransferService(preferences: target).importPreferences(SettingsArchive(values: [
        SettingsControlID.translationEnabled.rawValue: .string("true"),
        SettingsControlID.translationMessageLanguage.rawValue: .string("https://example.com"),
        SettingsControlID.translationDraftLanguage.rawValue: .string("xx-Latn-XX"),
    ]))
    #expect(report.importedCount == 1)
    #expect(report.needsUpdate)
    let saved = TranslationSettingsStore(preferences: target).load()
    #expect(!saved.isEnabled)
    #expect(saved.messageLanguage.isEmpty)
    #expect(saved.draftLanguage == "xx-Latn-XX")
    let shortcut = try #require(KeyboardShortcutAction.translateDraft.defaultShortcut)
    #expect(KeyboardShortcutPolicy.validate(shortcut, for: .translateDraft, shortcuts: [:]) == .valid)
    #expect(KeyboardShortcutAction.allCases.filter { $0.defaultShortcut == shortcut } == [.translateDraft])
}
