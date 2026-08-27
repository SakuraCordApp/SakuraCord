@testable import SakuraCord
import AppKit
import Testing

@Test func `App color schemes map to native appearances`() {
    #expect(AppColorScheme.system.appearanceName(increasesContrast: false) == nil)
    #expect(AppColorScheme.system.appearanceName(increasesContrast: true) == nil)
    #expect(AppColorScheme.light.appearanceName(increasesContrast: false) == .aqua)
    #expect(
        AppColorScheme.light.appearanceName(increasesContrast: true)
            == .accessibilityHighContrastAqua
    )
    #expect(AppColorScheme.dark.appearanceName(increasesContrast: false) == .darkAqua)
    #expect(
        AppColorScheme.dark.appearanceName(increasesContrast: true)
            == .accessibilityHighContrastDarkAqua
    )
}

@MainActor
@Test func `Effective accent resolves in the destination appearance`() throws {
    // Create the color outside either drawing appearance. It must remain dynamic
    // until its eventual AppKit or SwiftUI destination resolves it.
    let effectiveAccent = AccentColorChoice.purple.effectiveNSColor
    for appearanceName in [
        NSAppearance.Name.aqua,
        .darkAqua,
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
    ] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var expected: NSColor?
        var actual: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            expected = NSTintConfiguration(preferredColor: AccentColorChoice.purple.nsColor)
                .equivalentContentTintColor?
                .usingColorSpace(.sRGB)
            actual = effectiveAccent.usingColorSpace(.sRGB)
        }

        let expectedComponents = try #require(expected)
        let actualComponents = try #require(actual)
        #expect(abs(actualComponents.redComponent - expectedComponents.redComponent) < 0.0001)
        #expect(abs(actualComponents.greenComponent - expectedComponents.greenComponent) < 0.0001)
        #expect(abs(actualComponents.blueComponent - expectedComponents.blueComponent) < 0.0001)
    }
}

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
