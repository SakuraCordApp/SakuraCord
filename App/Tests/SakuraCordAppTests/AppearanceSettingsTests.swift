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
@Test func `Theme accent resolves adaptively in the destination appearance`() throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let themeStore = SakuraCordThemeStore(
        persistence: SakuraCordThemeSettingsStore(preferences: preferences)
    )
    themeStore.setFirstHue(0.04)
    themeStore.setSecondHue(0.96)
    themeStore.setIntensity(0.72)
    themeStore.finishInteraction()
    let effectiveAccent = themeStore.accentNSColor()
    var resolvedComponents: [NSColor] = []
    for appearanceName in [
        NSAppearance.Name.aqua,
        .darkAqua,
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
    ] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var actual: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            actual = effectiveAccent.usingColorSpace(.sRGB)
        }
        let actualComponents = try #require(actual)
        #expect(actualComponents.alphaComponent == 1)
        #expect(actualComponents.redComponent.isFinite)
        #expect(actualComponents.greenComponent.isFinite)
        #expect(actualComponents.blueComponent.isFinite)
        resolvedComponents.append(actualComponents)
    }
    #expect(resolvedComponents[0].brightnessComponent < resolvedComponents[1].brightnessComponent)
}

@MainActor
@Test func `Zero intensity uses the native system surface`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let themeStore = SakuraCordThemeStore(
        persistence: SakuraCordThemeSettingsStore(preferences: preferences)
    )

    #expect(!themeStore.usesSystemSurface)
    themeStore.setIntensity(0)
    #expect(themeStore.usesSystemSurface)
    themeStore.setIntensity(0.01)
    #expect(!themeStore.usesSystemSurface)
}

@MainActor
@Test func `Appearance preferences persist export and reset by page`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = AppearanceSettingsStore(preferences: preferences)

    #expect(store.load() == .defaults)

    let selected = AppearanceSettingsSnapshot(
        colorScheme: .light,
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
        export.values[SettingsControlID.composerBarAppearance.rawValue]
            == .string(ComposerBarAppearance.legacy.rawValue)
    )

    preferences.reset(scope: .appWide, page: .appearance)
    #expect(store.load() == .defaults)
}

@MainActor
@Test func `Theme designer persists all controls across store recreation`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let persistence = SakuraCordThemeSettingsStore(preferences: preferences)
    let themeStore = SakuraCordThemeStore(persistence: persistence)

    themeStore.setFirstHue(0.01)
    themeStore.setSecondHue(0.99)
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
@Test func `Invalid persisted theme values fall back safely`() {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    preferences.set(.string("not,a,theme"), for: .themeDesigner)

    let theme = SakuraCordThemeSettingsStore(preferences: preferences).load()
    #expect(theme == .defaultTheme)
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

    let task = Task { await themeStore.randomize(reduceMotion: false) }
    try? await Task.sleep(for: .milliseconds(60))

    #expect(themeStore.activeTheme != original)
    #expect(themeStore.committedTheme == original)
    #expect(themeStore.activeTheme.brightness == original.brightness)

    await task.value
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

    themeStore.setFirstHue(0.42)
    themeStore.setSecondHue(0.84)
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
            first: .init(hue: 0.16, saturation: 1),
            second: .init(hue: 0.83, saturation: 1),
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
            for color in [theme.first, theme.second] {
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
