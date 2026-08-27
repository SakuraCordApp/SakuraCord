@testable import SakuraCord
import Testing

@MainActor
@Test func `Appearance preferences persist export and reset by page`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = AppearanceSettingsStore(preferences: preferences)

    #expect(Array(AccentColorChoice.allCases.prefix(2)) == [.blurple, .blue])
    #expect(store.load() == .defaults)

    let selected = AppearanceSettingsSnapshot(
        colorScheme: .light,
        accentColor: .blurple,
        composerBarAppearance: .legacy
    )
    store.save(selected)

    #expect(store.load() == selected)
    let export = preferences.export(scope: .appWide, page: .appearance)
    #expect(
        export.values[SettingsControlID.appColorScheme.rawValue]
            == .string(AppColorScheme.light.rawValue)
    )
    #expect(
        export.values[SettingsControlID.accentColor.rawValue]
            == .string(AccentColorChoice.blurple.rawValue)
    )
    #expect(
        export.values[SettingsControlID.composerBarAppearance.rawValue]
            == .string(ComposerBarAppearance.legacy.rawValue)
    )

    preferences.reset(scope: .appWide, page: .appearance)
    #expect(store.load() == .defaults)
}

@MainActor
@Test func `Removed system accent preference migrates to Blurple`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    preferences.set(.string("system"), for: .accentColor)

    #expect(AppearanceSettingsStore(preferences: preferences).load().accentColor == .blurple)
    #expect(preferences.value(for: .accentColor) == .string(AccentColorChoice.blurple.rawValue))
}
