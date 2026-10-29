@testable import SakuraCord
import AppKit
import Observation
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
@Test func `Zero intensity uses the native system surface`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let themeStore = SakuraCordThemeStore(
        persistence: SakuraCordThemeSettingsStore(preferences: preferences)
    )

    #expect(themeStore.usesSystemSurface)
    themeStore.setIntensity(0.01)
    #expect(!themeStore.usesSystemSurface)
    themeStore.setIntensity(0)
    #expect(themeStore.usesSystemSurface)
}

@MainActor
@Test(arguments: LegacyAccentColorChoice.allCases)
func `Public beta accents migrate into native-surface single-color themes`(
    _ legacyAccent: LegacyAccentColorChoice
) {
    let defaults = InMemoryPreferences()
    defaults.set(
        legacyAccent.rawValue,
        forKey: "settings.appearance.accentColor"
    )
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let persistence = SakuraCordThemeSettingsStore(preferences: preferences)

    let migrated = persistence.load()

    #expect(migrated.colors == [legacyAccent.themeColor])
    #expect(migrated.activeColorCount == 1)
    #expect(migrated.intensity == 0)
    #expect(migrated.brightness == 1)
    #expect(preferences.containsStoredValue(for: .themeDesigner))
    #expect(persistence.load() == migrated)
}

@MainActor
@Test func `Pre-accent releases and new installs start with native-surface Sakura pink`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let persistence = SakuraCordThemeSettingsStore(preferences: preferences)

    let theme = persistence.load()

    #expect(theme == .defaultTheme)
    #expect(theme.colors == [.sakuraPink])
    #expect(theme.activeColorCount == 1)
    #expect(theme.intensity == 0)
    #expect(theme.brightness == 1)
    #expect(preferences.containsStoredValue(for: .themeDesigner))
}

@MainActor
@Test func `Saved gradient themes take precedence over legacy accents`() {
    let defaults = InMemoryPreferences()
    defaults.set(
        LegacyAccentColorChoice.red.rawValue,
        forKey: "settings.appearance.accentColor"
    )
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let expected = SakuraCordGradientTheme(
        colors: [
            .init(hue: 0.18, saturation: 0.72),
            .init(hue: 0.61, saturation: 0.81),
        ],
        intensity: 0.74,
        brightness: 0.83
    )
    preferences.set(.string(expected.storageValue), for: .themeDesigner)

    let actual = SakuraCordThemeSettingsStore(preferences: preferences).load()

    #expect(actual == expected)

    preferences.reset(scope: .appWide, page: .appearance)
    let reset = SakuraCordThemeSettingsStore(preferences: preferences).load()
    #expect(reset == .defaultTheme)
}

@MainActor
@Test func `Legacy Graphite migrates to Blurple`() {
    let defaults = InMemoryPreferences()
    defaults.set(
        LegacyAccentColorChoice.gray.rawValue,
        forKey: "settings.appearance.accentColor"
    )
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let theme = SakuraCordThemeSettingsStore(preferences: preferences).load()

    #expect(theme.colors == [.discordBlurple])
    #expect(theme.activeColorCount == 1)
    #expect(theme.intensity == 0)
    #expect(theme.brightness == 1)
}

@MainActor
@Test func `Appearance preferences persist export and reset by page`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = AppearanceSettingsStore(preferences: preferences)

    #expect(store.load() == .defaults)

    let selected = AppearanceSettingsSnapshot(
        overrideMacOSAccent: true,
        colorScheme: .light,
        composerBarAppearance: .legacy,
        directMessageAppearance: .bubbles,
        groupMessageAppearance: .defaultStyle,
        serverMessageAppearance: .bubbles,
        messageSpacing: 12
    )
    store.save(selected)

    #expect(AppearanceSettingsStore(preferences: SettingsPreferenceStore(defaults: defaults)).load() == selected)
    let appearanceExport = preferences.export(scope: .appWide, page: .appearance)
    #expect(appearanceExport.values[SettingsControlID.overrideMacOSAccent.rawValue] == .bool(true))
    #expect(
        appearanceExport.values[SettingsControlID.appColorScheme.rawValue]
            == .string(AppColorScheme.light.rawValue)
    )
    let interfaceExport = preferences.export(scope: .appWide, page: .interface)
    #expect(
        interfaceExport.values[SettingsControlID.composerBarAppearance.rawValue]
            == .string(ComposerBarAppearance.legacy.rawValue)
    )
    #expect(
        interfaceExport.values[SettingsControlID.messageAppearance.rawValue]
            == .string(MessageAppearance.bubbles.rawValue)
    )
    #expect(interfaceExport.values[SettingsControlID.directMessageAppearance.rawValue] == .string("bubbles"))
    #expect(interfaceExport.values[SettingsControlID.groupMessageAppearance.rawValue] == .string("default"))
    #expect(
        interfaceExport.values[SettingsControlID.messageDensity.rawValue]
            == .double(12)
    )

    let importedPreferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let archive = SettingsTransferService(preferences: preferences).export(pages: [.interface, .appearance])
    let report = SettingsTransferService(preferences: importedPreferences).importPreferences(archive)
    #expect(report.unsupportedKeys.isEmpty)
    #expect(AppearanceSettingsStore(preferences: importedPreferences).load() == selected)

    preferences.reset(scope: .appWide, page: .interface)
    #expect(store.load().colorScheme == .light)
    preferences.reset(scope: .appWide, page: .appearance)
    #expect(store.load() == .defaults)
}

@MainActor
@Test func `Theme designer persists all controls across store recreation`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let persistence = SakuraCordThemeSettingsStore(preferences: preferences)
    let themeStore = SakuraCordThemeStore(persistence: persistence)

    themeStore.setHue(0.01, at: 0)
    themeStore.addColor()
    themeStore.setHue(0.99, at: 1)
    themeStore.setIntensity(1)
    themeStore.setBrightness(0)
    themeStore.finishInteraction()
    let expected = themeStore.activeTheme

    let restored = SakuraCordThemeStore(persistence: persistence)
    #expect(restored.activeTheme == expected)

    let export = preferences.export(scope: .appWide, page: .appearance)
    #expect(
        export.values[SettingsControlID.themeDesigner.rawValue]
            == .string(expected.storageValue)
    )
}

@MainActor
@Test func `Upgrading existing themes preserves the background unless macOS selects an accent`() {
    for theme in [
        SakuraCordGradientTheme.defaultTheme,
        SakuraCordGradientTheme(colors: [.discordBlurple, .sakuraPink], intensity: 0.65, brightness: 0.72),
    ] {
        let defaults = InMemoryPreferences()
        defaults.set(theme.storageValue, forKey: "settings.appearance.customGradientTheme")
        let preferences = SettingsPreferenceStore(defaults: defaults)
        let persistence = SakuraCordThemeSettingsStore(preferences: preferences)
        let appearance = AppearanceSettingsStore(preferences: preferences).load()
        let store = SakuraCordThemeStore(persistence: persistence)
        #expect(!appearance.overrideMacOSAccent)
        #expect(AppAccentColorController.systemAccentColor(for: nil) == nil)
        #expect(AppAccentColorController.systemAccentColor(for: -2) == nil)
        store.setSystemAccentColor(AppAccentColorController.systemAccentColor(for: -2))
        #expect(!store.isSystemAccentActive)
        #expect(store.activeTheme == theme)
        #expect(store.backgroundTheme == theme)
        #expect(store.committedBackgroundTheme == theme)
        #expect(persistence.load() == theme)
    }
}

@MainActor
@Test func `Invalid persisted theme values fall back safely`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    preferences.set(.string("not,a,theme"), for: .themeDesigner)

    let theme = SakuraCordThemeSettingsStore(preferences: preferences).load()
    #expect(theme == .defaultTheme)
}

@Test func `Legacy two-color themes migrate into the ordered color model`() throws {
    let legacy = "0.1,0.65,0.8,0.75,0.9,0.4"
    let theme = try #require(SakuraCordGradientTheme(storageValue: legacy))

    #expect(theme.activeColorCount == 2)
    #expect(theme.colors.count == 2)
    #expect(theme.colors[0] == SakuraCordThemeColor(hue: 0.1, saturation: 0.65))
    #expect(theme.colors[1] == SakuraCordThemeColor(hue: 0.8, saturation: 0.75))
    #expect(theme.intensity == 0.9)
    #expect(theme.brightness == 0.4)
}

@Test func `Removed gradient colors retain their order across persistence`() throws {
    let originalColors = [
        SakuraCordThemeColor(hue: 0.05, saturation: 0.70),
        SakuraCordThemeColor(hue: 0.25, saturation: 0.72),
        SakuraCordThemeColor(hue: 0.45, saturation: 0.74),
        SakuraCordThemeColor(hue: 0.65, saturation: 0.76),
        SakuraCordThemeColor(hue: 0.85, saturation: 0.78),
    ]
    var theme = SakuraCordGradientTheme(
        colors: originalColors,
        intensity: 0.8,
        brightness: 0.9
    )

    let removedFifth = theme.removeColor()
    let removedFourth = theme.removeColor()
    #expect(removedFifth)
    #expect(removedFourth)
    #expect(theme.activeColorCount == 3)
    #expect(Array(theme.activeColors) == Array(originalColors.prefix(3)))

    let restored = try #require(SakuraCordGradientTheme(storageValue: theme.storageValue))
    #expect(restored == theme)

    var reactivated = restored
    let addedFourth = reactivated.addColor()
    #expect(addedFourth)
    #expect(reactivated.activeColorCount == 4)
    #expect(reactivated.colors[3] == originalColors[3])
}

@Test func `Theme share links are compact deterministic and omit inactive colors`() throws {
    let sharedTheme = SakuraCordSharedTheme(
        appearance: .dark,
        theme: SakuraCordGradientTheme(
            colors: [
                .init(hue: 0.05, saturation: 0.70),
                .init(hue: 0.25, saturation: 0.72),
                .init(hue: 0.45, saturation: 0.74),
                .init(hue: 0.65, saturation: 0.76),
                .init(hue: 0.85, saturation: 0.78),
            ],
            activeColorCount: 3,
            intensity: 0.812345,
            brightness: 0.412345
        )
    )

    let token = try SakuraCordThemeShareCodec.token(for: sharedTheme)
    #expect(token == "AQJKz_VpjwzNszNAALhRczO9cP__yjw")
    #expect(token.count == 31)
    #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })

    let url = try SakuraCordThemeShareCodec.shareURL(for: sharedTheme)
    #expect(url.absoluteString == "https://sakuracord.app/settings/themes/\(token)")

    guard case let .current(decoded) = SakuraCordThemeShareCodec.decode(token) else {
        Issue.record("Current theme token did not decode")
        return
    }
    #expect(decoded.appearance == .dark)
    #expect(decoded.theme.activeColorCount == 3)
    #expect(decoded.theme.colors.count == 3)
    #expect(decoded.windowOpacity == 1)
    let tolerance = 1.0 / 65_535
    #expect(abs(decoded.theme.intensity - sharedTheme.theme.intensity) <= tolerance)
    #expect(abs(decoded.theme.brightness - sharedTheme.theme.brightness) <= tolerance)
    for (decodedColor, sourceColor) in zip(
        decoded.theme.colors,
        sharedTheme.theme.activeColors
    ) {
        #expect(abs(decodedColor.hue - sourceColor.hue) <= tolerance)
        #expect(abs(decodedColor.saturation - sourceColor.saturation) <= tolerance)
    }
    #expect(try SakuraCordThemeShareCodec.token(for: decoded) == token)

    for opacity in [0.0, 0.42, 1.0] {
        var translucentTheme = sharedTheme
        translucentTheme.windowOpacity = opacity
        let url = try SakuraCordThemeShareCodec.shareURL(for: translucentTheme)
        guard case let .applyTheme(imported) = SakuraCordDeepLinkPresentation.action(for: url) else {
            Issue.record("Theme link did not produce an import action")
            continue
        }
        #expect(abs(imported.windowOpacity - opacity) <= tolerance)
        #expect(imported.theme == decoded.theme)
    }

    let previousCompactToken = "AQFKz_VpjwzNszNAALhRczO9cEn9"
    guard case let .current(previousCompactTheme) = SakuraCordThemeShareCodec.decode(previousCompactToken) else {
        Issue.record("Previous compact theme token did not decode")
        return
    }
    #expect(previousCompactTheme == decoded)

    let previousTokenWithInactiveColors =
        "AQGKz_VpjwzNszNAALhRczO9cKZmwo_Zmcet62c"
    guard case let .current(previouslyDecoded) = SakuraCordThemeShareCodec.decode(
        previousTokenWithInactiveColors
    ) else {
        Issue.record("Previous theme token did not decode")
        return
    }
    #expect(previouslyDecoded.theme.activeColorCount == 3)
    #expect(previouslyDecoded.theme.colors.count == 5)
    #expect(previouslyDecoded.windowOpacity == 1)
    #expect(try SakuraCordThemeShareCodec.token(for: previouslyDecoded) == token)

    var corrupted = token
    let corruptionIndex = corrupted.index(corrupted.startIndex, offsetBy: 8)
    corrupted.replaceSubrange(corruptionIndex ... corruptionIndex, with: "A")
    #expect(SakuraCordThemeShareCodec.decode(corrupted) == nil)
}

@Test func `Future theme links retain their preview and require a SakuraCord update`() throws {
    let sharedTheme = SakuraCordSharedTheme(
        appearance: .light,
        theme: .defaultTheme
    )
    let token = try SakuraCordThemeShareCodec.token(
        for: sharedTheme,
        minimumReaderVersion: SakuraCordThemeShareCodec.readerVersion + 1
    )

    guard case let .requiresNewerClient(preview) =
        SakuraCordThemeShareCodec.decode(token)
    else {
        Issue.record("Future theme token was not recognized")
        return
    }
    let decodedPreview = try #require(preview)
    #expect(decodedPreview.appearance == .light)
    #expect(decodedPreview.theme.activeColorCount == 1)

    let url = try #require(
        URL(string: "https://sakuracord.app/settings/themes/\(token)")
    )
    guard case let .updateToApplyTheme(actionPreview) =
        SakuraCordDeepLinkPresentation.action(for: url)
    else {
        Issue.record("Future theme link did not produce the update action")
        return
    }
    #expect(actionPreview == decodedPreview)
}

@Test func `Adding a gradient color corrects overlapping remembered hues`() {
    var theme = SakuraCordGradientTheme(
        colors: [
            .init(hue: 0.02, saturation: 0.7),
            .init(hue: 0.34, saturation: 0.7),
            .init(hue: 0.35, saturation: 0.8),
        ],
        activeColorCount: 2,
        intensity: 1,
        brightness: 1
    )

    let addedThird = theme.addColor()
    #expect(addedThird)
    #expect(theme.activeColorCount == 3)
    for existing in theme.activeColors.dropLast() {
        #expect(
            SakuraCordGradientTheme.circularHueDistance(
                existing.hue,
                theme.activeColors.last?.hue ?? existing.hue
            ) >= SakuraCordGradientTheme.minimumHueSpacing
        )
    }
}

@Test func `Gradient color count remains bounded from one through five`() {
    var theme = SakuraCordGradientTheme.defaultTheme

    while theme.removeColor() {}
    #expect(theme.activeColorCount == SakuraCordGradientTheme.minimumColorCount)
    let removedBelowMinimum = theme.removeColor()
    #expect(!removedBelowMinimum)

    while theme.addColor() {}
    #expect(theme.activeColorCount == SakuraCordGradientTheme.maximumColorCount)
    #expect(theme.colors.count == SakuraCordGradientTheme.maximumColorCount)
    let addedAboveMaximum = theme.addColor()
    #expect(!addedAboveMaximum)
}

@MainActor
@Test func `Randomise preserves one to five colors without handle overlap`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let themeStore = SakuraCordThemeStore(
        persistence: SakuraCordThemeSettingsStore(preferences: preferences)
    )

    for colorCount in SakuraCordGradientTheme.minimumColorCount ... SakuraCordGradientTheme.maximumColorCount {
        while themeStore.activeTheme.activeColorCount < colorCount {
            themeStore.addColor()
        }
        while themeStore.activeTheme.activeColorCount > colorCount {
            themeStore.removeColor()
        }

        for _ in 0 ..< 20 {
            let randomized = themeStore.randomizedTheme()
            #expect(randomized.activeColorCount == colorCount)
            #expect(randomized.colors.allSatisfy { $0.saturation == randomized.colors[0].saturation })
            let colors = Array(randomized.activeColors)
            for firstIndex in colors.indices {
                for secondIndex in colors.indices where secondIndex > firstIndex {
                    #expect(
                        SakuraCordGradientTheme.circularHueDistance(
                            colors[firstIndex].hue,
                            colors[secondIndex].hue
                        ) >= SakuraCordGradientTheme.minimumHueSpacing
                    )
                }
            }
        }
    }
}

@MainActor
@Test func `Randomise is immediate with Reduce Motion and commits the theme`() async {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let themeStore = SakuraCordThemeStore(
        persistence: SakuraCordThemeSettingsStore(preferences: preferences)
    )
    themeStore.setBrightness(0.27)
    themeStore.finishInteraction()
    let original = themeStore.activeTheme

    await themeStore.randomize(reduceMotion: true)

    #expect(themeStore.activeTheme == themeStore.committedTheme)
    #expect(themeStore.activeTheme != original)
    #expect(themeStore.activeTheme.brightness == original.brightness)
    #expect(themeStore.activeTheme.intensity >= 0.6)
}

@MainActor
@Test func `Animated Randomise publishes intermediate frames before one final commit`() async {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let themeStore = SakuraCordThemeStore(
        persistence: SakuraCordThemeSettingsStore(preferences: preferences)
    )
    themeStore.setBrightness(0.31)
    themeStore.finishInteraction()
    let original = themeStore.activeTheme

    let frames = ThemeIntermediateFrameProbe()
    frames.observe(themeStore, original: original)
    await themeStore.randomize(reduceMotion: false)
    #expect(frames.observedIntermediateFrame)
    #expect(themeStore.activeTheme == themeStore.committedTheme)
    #expect(themeStore.activeTheme.brightness == original.brightness)
    #expect(themeStore.activeTheme.intensity >= 0.6)
}

@MainActor
@Test func `Manual editing wins over an in flight Randomise transition`() async throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let themeStore = SakuraCordThemeStore(
        persistence: SakuraCordThemeSettingsStore(preferences: preferences)
    )
    let task = Task { await themeStore.randomize(reduceMotion: false) }
    try await Task.sleep(for: .milliseconds(60))

    themeStore.setHue(0.42, at: 0)
    themeStore.setHue(0.84, at: 1)
    themeStore.finishInteraction()
    let expected = themeStore.activeTheme
    await task.value

    #expect(themeStore.activeTheme == expected)
    #expect(themeStore.committedTheme == expected)
}

@Test func `Extreme theme values preserve readable adaptive contrast`() {
    let extremes = [
        SakuraCordGradientTheme(
            first: .init(hue: 0, saturation: 0),
            second: .init(hue: 0.5, saturation: 1),
            intensity: 0,
            brightness: 0
        ),
        SakuraCordGradientTheme(
            colors: [
                .init(hue: 0.03, saturation: 1),
                .init(hue: 0.21, saturation: 1),
                .init(hue: 0.42, saturation: 1),
                .init(hue: 0.63, saturation: 1),
                .init(hue: 0.84, saturation: 1),
            ],
            intensity: 1,
            brightness: 1
        ),
        SakuraCordGradientTheme.defaultTheme,
    ]

    for theme in extremes {
        for appearance in [SakuraCordThemeAppearance.light, .dark] {
            let blendOpacity = theme.backgroundBlendOpacity(for: appearance)
            #expect(blendOpacity >= 0)
            #expect(blendOpacity <= 0.96)
            let base = theme.surfaceBaseRGB(for: appearance)
            let label: SakuraCordThemeRGB = appearance == .dark ? .white : .black
            for background in theme.backgroundSamples(for: appearance) {
                #expect(background.contrastRatio(with: label) >= 4.5)
            }
            for color in theme.activeColors {
                let background = theme.backgroundTintRGB(color, for: appearance)
                    .composited(
                        over: base,
                        opacity: blendOpacity
                    )
                #expect(background.contrastRatio(with: label) >= 4.5)
            }
            let sourceColors = [
                SakuraCordThemeRGB(red: 1, green: 0.78, blue: 0.15),
                SakuraCordThemeRGB(red: 0.35, green: 0.85, blue: 0.62),
                SakuraCordThemeRGB(red: 0.4, green: 0.52, blue: 1),
            ]
            for source in sourceColors {
                let foreground = theme.readableForeground(source, for: appearance)
                for background in theme.backgroundSamples(for: appearance) {
                    #expect(foreground.contrastRatio(with: background) >= 4.5)
                }
                let buttonBackground = source.adjustedForContrast(
                    with: .white,
                    toward: .black
                )
                #expect(buttonBackground.contrastRatio(with: .white) >= 4.5)
            }
        }
    }
}

@Test func `Brightness controls luminance independently from intensity`() {
    let color = SakuraCordThemeColor(hue: 0.37, saturation: 0.82)
    let darkTheme = SakuraCordGradientTheme(
        first: color,
        second: color,
        intensity: 1,
        brightness: 0
    )
    let midTheme = SakuraCordGradientTheme(
        first: color,
        second: color,
        intensity: 0,
        brightness: 0.5
    )
    let brightTheme = SakuraCordGradientTheme(
        first: color,
        second: color,
        intensity: 1,
        brightness: 1
    )
    let halfIntensityTheme = SakuraCordGradientTheme(
        first: color,
        second: color,
        intensity: 0.5,
        brightness: 1
    )

    #expect(darkTheme.renderedRGB(color, for: .dark) == .black)
    #expect(darkTheme.surfaceBaseRGB(for: .dark) == .black)
    #expect(darkTheme.backgroundSamples(for: .dark).allSatisfy { $0 == .black })
    #expect(midTheme.surfaceBaseRGB(for: .dark) == .darkWindow)
    #expect(midTheme.backgroundBlendOpacity(for: .dark) == 0)
    #expect(midTheme.backgroundBlendOpacity(for: .light) == 0)
    let maximumDarkBase = SakuraCordThemeRGB.darkWindow.blended(
        toward: .black,
        fraction: 0.68
    )
    #expect(brightTheme.surfaceBaseRGB(for: .dark) == maximumDarkBase)
    #expect(brightTheme.backgroundBlendOpacity(for: .dark) == 0.96)
    #expect(halfIntensityTheme.intensityProgress < 0.5)
    #expect(
        halfIntensityTheme.backgroundBlendOpacity(for: .dark)
            == 0.96 * halfIntensityTheme.intensityProgress
    )

    let middleColor = midTheme.renderedRGB(color, for: .dark)
    let brightestColor = brightTheme.renderedRGB(color, for: .dark)
    let brightestBackgroundTint = brightTheme.backgroundTintRGB(color, for: .dark)
    #expect(middleColor.relativeLuminance > 0)
    #expect(brightestColor.relativeLuminance > middleColor.relativeLuminance)
    #expect(brightestBackgroundTint.relativeLuminance < brightestColor.relativeLuminance)
    #expect(
        brightTheme.surfaceBaseRGB(for: .dark).relativeLuminance
            < midTheme.surfaceBaseRGB(for: .dark).relativeLuminance
    )
    #expect(
        brightTheme.backgroundBlendOpacity(for: .dark)
            > brightTheme.backgroundBlendOpacity(for: .light)
    )

    let lowIntensity = SakuraCordGradientTheme(
        first: color,
        second: color,
        intensity: 0,
        brightness: 0.5
    )
    let highIntensity = SakuraCordGradientTheme(
        first: color,
        second: color,
        intensity: 1,
        brightness: 0.5
    )
    #expect(
        lowIntensity.renderedRGB(color, for: .dark)
            == highIntensity.renderedRGB(color, for: .dark)
    )
    #expect(
        lowIntensity.backgroundBlendOpacity(for: .dark)
            < highIntensity.backgroundBlendOpacity(for: .dark)
    )
    #expect(
        lowIntensity.backgroundSamples(for: .dark)
            != highIntensity.backgroundSamples(for: .dark)
    )
}

@MainActor
@Test func `Hue handles stay centered on the ring and clear the intensity hit region`() {
    let center = CGPoint(
        x: ThemePickerGeometry.diameter / 2,
        y: ThemePickerGeometry.diameter / 2
    )
    let expectedRadius = (ThemePickerGeometry.diameter - ThemePickerGeometry.ringWidth) / 2
    let intensityFrame = CGRect(
        x: center.x - ThemePickerGeometry.intensityHitWidth / 2,
        y: center.y - ThemePickerGeometry.intensityTrackHeight / 2,
        width: ThemePickerGeometry.intensityHitWidth,
        height: ThemePickerGeometry.intensityTrackHeight
    )

    for degree in 0 ..< 360 {
        let hue = Double(degree) / 360
        let handleCenter = ThemePickerGeometry.hueHandleCenter(for: hue)
        let radius = hypot(handleCenter.x - center.x, handleCenter.y - center.y)
        #expect(abs(radius - expectedRadius) < 0.0001)
        #expect(abs(ThemePickerGeometry.hue(at: handleCenter) - hue) < 0.0001)

        let handleFrame = CGRect(
            x: handleCenter.x - ThemePickerGeometry.hueHandleHitSize / 2,
            y: handleCenter.y - ThemePickerGeometry.hueHandleHitSize / 2,
            width: ThemePickerGeometry.hueHandleHitSize,
            height: ThemePickerGeometry.hueHandleHitSize
        )
        #expect(!handleFrame.intersects(intensityFrame))
    }
}

@MainActor
@Test func `Intensity and brightness handles remain centered on their tracks`() {
    #expect(ThemePickerGeometry.brightnessIndicatorWidth > ThemePickerGeometry.brightnessIndicatorHeight)
    #expect(ThemePickerGeometry.sideControlDiameter == 112)
    #expect(
        ThemePickerGeometry.intensityTrackTopWidth
            > ThemePickerGeometry.intensityTrackBottomWidth
    )
    #expect(
        ThemePickerGeometry.intensityHandleWidth
            < ThemePickerGeometry.intensityHitWidth
    )
    #expect(ThemePickerGeometry.intensityWaveCount >= 3)
    #expect(ThemePickerGeometry.ringGlowLineWidth < ThemePickerGeometry.ringGlowRadius)
    #expect(ThemePickerGeometry.ringGlowOpacity < 0.4)
    #expect(ThemePickerGeometry.intensityWaveStrength(for: 0) > 0)
    #expect(ThemePickerGeometry.intensityWaveStrength(for: 1) < 1)
    #expect(
        ThemePickerGeometry.intensityWaveStrength(for: 0)
            < ThemePickerGeometry.intensityWaveStrength(for: 0.5)
    )
    #expect(
        ThemePickerGeometry.intensityTrackWidth(at: 0)
            == ThemePickerGeometry.intensityTrackTopWidth
    )
    #expect(
        ThemePickerGeometry.intensityTrackWidth(at: 0.5)
            == (ThemePickerGeometry.intensityTrackTopWidth
                + ThemePickerGeometry.intensityTrackBottomWidth) / 2
    )
    #expect(
        ThemePickerGeometry.intensityTrackWidth(at: 1)
            == ThemePickerGeometry.intensityTrackBottomWidth
    )
    #expect(ThemePickerGeometry.hapticStep(for: -1, divisions: 20) == 0)
    #expect(ThemePickerGeometry.hapticStep(for: 0.49, divisions: 20) == 10)
    #expect(ThemePickerGeometry.hapticStep(for: 2, divisions: 20) == 20)

    let brightnessGapMidpoint = CGPoint(
        x: ThemePickerGeometry.sideControlDiameter / 2,
        y: ThemePickerGeometry.sideControlDiameter / 2
            + ThemePickerGeometry.brightnessTickRadius
    )
    #expect(
        ThemePickerGeometry.brightness(
            at: brightnessGapMidpoint,
            preservingEndpointFor: 0
        ) == 0
    )
    #expect(
        ThemePickerGeometry.brightness(
            at: brightnessGapMidpoint,
            preservingEndpointFor: 1
        ) == 1
    )

    for value in stride(from: 0.0, through: 1.0, by: 0.05) {
        let intensityY = ThemePickerGeometry.intensityHandleCenterY(for: value)
        #expect(intensityY >= ThemePickerGeometry.intensityHandleHeight / 2)
        #expect(
            intensityY
                <= ThemePickerGeometry.intensityTrackHeight
                    - ThemePickerGeometry.intensityHandleHeight / 2
        )
        #expect(abs(ThemePickerGeometry.intensity(atY: intensityY) - value) < 0.0001)

        let brightnessCenter = ThemePickerGeometry.brightnessHandleCenter(for: value)
        #expect(abs(ThemePickerGeometry.brightness(at: brightnessCenter) - value) < 0.0001)
    }
}

@MainActor
@Test func `Shared saturation and hex edits persist and survive theme sharing`() async throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let persistence = SakuraCordThemeSettingsStore(preferences: preferences)
    let store = SakuraCordThemeStore(persistence: persistence)
    store.addColor()
    store.addColor()
    store.removeColor()
    store.setBrightness(0.37)
    store.setSaturation(0.24)
    store.finishInteraction()
    #expect(persistence.load().colors.allSatisfy { $0.saturation == 0.24 })
    store.addColor()
    #expect(store.activeTheme.colors.allSatisfy { $0.saturation == 0.24 })

    let originalHues = store.activeTheme.colors.map(\.hue)
    let color = try #require(SakuraCordThemeColor(hexCode: " #80c040 "))
    await store.applyColor(color, at: 1, reduceMotion: true)
    #expect(store.activeTheme.colors[0].hue == originalHues[0])
    #expect(store.activeTheme.colors[1].hue == color.hue)
    #expect(store.activeTheme.colors[2].hue == originalHues[2])
    #expect(store.activeTheme.colors.allSatisfy { $0.saturation == color.saturation })
    #expect(store.activeTheme.brightness == 0.37)
    #expect(store.activeTheme == store.committedTheme)
    #expect(persistence.load() == store.activeTheme)

    let token = try SakuraCordThemeShareCodec.token(for: .init(appearance: .dark, theme: store.activeTheme))
    guard case let .current(shared) = SakuraCordThemeShareCodec.decode(token) else {
        Issue.record("Edited theme did not survive sharing")
        return
    }
    #expect(shared.theme.activeColors.allSatisfy { abs($0.saturation - color.saturation) < 1.0 / 65_535 })

    store.setSaturation(0)
    for appearance in [SakuraCordThemeAppearance.light, .dark] {
        for color in store.activeTheme.activeColors {
            let tint = store.activeTheme.backgroundTintRGB(color, for: appearance)
            #expect(tint.red == tint.green && tint.green == tint.blue)
        }
    }
}

@Test func `Hex colors accept RGB forms and reject invalid input`() {
    let expected = SakuraCordThemeColor(sRGBRed: 0xAA, green: 0xBB, blue: 0xCC)
    for input in ["abc", "#ABC", "aabbcc", "#AaBbCc", "  #abc  "] {
        #expect(SakuraCordThemeColor(hexCode: input) == expected)
    }
    for input in ["", "#", "##abc", "12", "12345", "12345678", "ggg", "0x1234", "ab cd ef", "１２３"] {
        #expect(SakuraCordThemeColor(hexCode: input) == nil)
    }
}

@Test func `Removing a selected gradient color preserves order and remembered colors`() throws {
    var theme = SakuraCordGradientTheme(
        colors: [0.1, 0.3, 0.5, 0.7].map { .init(hue: $0, saturation: 0.8) },
        activeColorCount: 3,
        intensity: 0.6,
        brightness: 0.4
    )
    let removedMiddle = theme.removeColor(at: 1)
    #expect(removedMiddle)
    #expect(theme.activeColors.map(\.hue) == [0.1, 0.5])
    #expect(theme.colors.map(\.hue) == [0.1, 0.5, 0.3, 0.7])
    let removedNegative = theme.removeColor(at: -1)
    #expect(!removedNegative)
    let removedInactive = theme.removeColor(at: 2)
    #expect(!removedInactive)
    let restoredColor = theme.addColor()
    #expect(restoredColor)
    #expect(theme.activeColors.map(\.hue) == [0.1, 0.5, 0.3])
    let explicitColor = try #require(SakuraCordThemeColor(hexCode: "#4080C0"))
    let addedExplicit = theme.addColor(explicitColor)
    #expect(addedExplicit)
    #expect(theme.activeColors.last == explicitColor)
    #expect(theme.colors.allSatisfy { $0.saturation == explicitColor.saturation })
    while theme.removeColor(at: 0) {}
    #expect(theme.activeColorCount == 1)
    let removedLast = theme.removeColor(at: 0)
    #expect(!removedLast)
    #expect(theme.brightness == 0.4 && theme.intensity == 0.6)
}

/// Observe before each synchronous mutation. An asynchronous Observations
/// consumer can coalesce the entire sub-second animation under parallel load.
@MainActor
private final class ThemeIntermediateFrameProbe {
    private(set) var observedIntermediateFrame = false

    func observe(_ store: SakuraCordThemeStore, original: SakuraCordGradientTheme) {
        withObservationTracking {
            _ = store.activeTheme
        } onChange: { [weak self, weak store] in
            // Theme mutations are isolated to the main actor. Capture the
            // previous frame synchronously, before the next frame/commit.
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                if store.activeTheme != original,
                   store.committedTheme == original,
                   store.activeTheme.brightness == original.brightness {
                    self.observedIntermediateFrame = true
                }
                self.observe(store, original: original)
            }
        }
    }
}

@MainActor
@Test func `Interface size persists normalized and stays independent of density`() throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let store = AppearanceSettingsStore(preferences: preferences)
    #expect(store.load().interfaceSize == InterfaceScale.defaultFactor)

    var selected = AppearanceSettingsSnapshot.defaults
    selected.interfaceSize = 1.27
    store.save(selected)
    let loaded = store.load()
    #expect(loaded.interfaceSize == 1.3)
    #expect(loaded.messageSpacing == AppearanceSettingsSnapshot.defaultMessageSpacing)

    selected.interfaceSize = 9
    store.save(selected)
    #expect(store.load().interfaceSize == InterfaceScale.range.upperBound)

    let registration = try #require(
        SettingsPreferenceRegistry.foundation.registrations.first { $0.id == .interfaceSize }
    )
    #expect(SettingsImportValidation.accepts(.double(0.8), registration: registration))
    #expect(!SettingsImportValidation.accepts(.double(2), registration: registration))
    #expect(!SettingsImportValidation.accepts(.double(.nan), registration: registration))
}

@MainActor
@Test func `Legacy message appearance migrates once and preserves context choices`() {
    let defaults = InMemoryPreferences()
    defaults.set("bubbles", forKey: "settings.appearance.messages")
    defaults.set("default", forKey: "settings.appearance.groupMessages")
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let migrated = AppearanceSettingsStore(preferences: preferences).load()
    #expect(migrated.directMessageAppearance == .bubbles)
    #expect(migrated.groupMessageAppearance == .defaultStyle)
    #expect(migrated.serverMessageAppearance == .bubbles)
    #expect(defaults.object(forKey: "settings.appearance.messages") == nil)

    preferences.reset(scope: .appWide, page: .interface)
    let restored = AppearanceSettingsStore(preferences: SettingsPreferenceStore(defaults: defaults))
    #expect(restored.load() == .defaults)
}

@MainActor
@Test func `System primary stays locked while secondary background colours remain editable`() async throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let persistence = SakuraCordThemeSettingsStore(preferences: preferences)
    let store = SakuraCordThemeStore(persistence: persistence)
    let custom = SakuraCordGradientTheme(colors: [.sakuraPink], intensity: 0.3, brightness: 0.8)
    store.apply(custom)
    let systemColor = try #require(AppAccentColorController.systemAccentColor(for: 4))
    store.setSystemAccentColor(systemColor)
    #expect(Array(store.backgroundTheme.activeColors) == [systemColor])
    store.setHue(0.4, at: 0)
    #expect(store.activeTheme.colors[0] == systemColor)
    store.addColor(.discordBlurple)
    #expect(store.activeTheme.activeColorCount == 2)
    #expect(Array(store.activeTheme.activeColors.dropFirst()) == [.discordBlurple])
    store.setHue(0.4, at: 1)
    store.finishInteraction()
    #expect(store.activeTheme.colors[0] == systemColor)
    #expect(store.activeTheme.colors[1].hue == 0.4)
    #expect(persistence.load().colors[1].hue == 0.4)
    #expect(Array(store.backgroundTheme.activeColors) == Array(store.activeTheme.activeColors))
    store.setSaturation(0)
    store.finishInteraction()
    #expect(store.editableSaturation == 0)
    #expect(store.activeTheme.colors[0] == systemColor)
    #expect(persistence.load().colors[0] == custom.colors[0])
    await store.applyColor(.init(hue: 0.7, saturation: 0.5), at: 1, reduceMotion: true)
    #expect(persistence.load().colors[0] == custom.colors[0])
    #expect(store.activeTheme.colors[0] == systemColor)
    let random = store.randomizedTheme()
    #expect(random.colors[0] == custom.colors[0])
    store.apply(random)
    store.setSystemAccentColor(nil)
    #expect(store.activeTheme.colors[0] == custom.colors[0])
}
