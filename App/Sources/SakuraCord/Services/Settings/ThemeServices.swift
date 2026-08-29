import AppKit
import Foundation
import Observation
import SwiftUI

nonisolated enum SakuraCordThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case velvetDusk
    case polarBloom
    case sunsetSoda
    case blueHour
    case wildMint
    case rosewater
    case solarFlare
    case deepLagoon
    case custom

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .system: LocalizedStringResource("System", bundle: #bundle)
        case .velvetDusk: LocalizedStringResource("Velvet Dusk", bundle: #bundle)
        case .polarBloom: LocalizedStringResource("Polar Bloom", bundle: #bundle)
        case .sunsetSoda: LocalizedStringResource("Sunset Soda", bundle: #bundle)
        case .blueHour: LocalizedStringResource("Blue Hour", bundle: #bundle)
        case .wildMint: LocalizedStringResource("Wild Mint", bundle: #bundle)
        case .rosewater: LocalizedStringResource("Rosewater", bundle: #bundle)
        case .solarFlare: LocalizedStringResource("Solar Flare", bundle: #bundle)
        case .deepLagoon: LocalizedStringResource("Deep Lagoon", bundle: #bundle)
        case .custom: LocalizedStringResource("Custom", bundle: #bundle)
        }
    }

    var systemImage: String? {
        self == .system ? "circle.lefthalf.filled" : nil
    }

    var usesSystemAppearance: Bool {
        self == .system
    }

    var presetTheme: SakuraCordGradientTheme? {
        switch self {
        case .system:
            SakuraCordGradientTheme(
                first: .init(hue: 0.91, saturation: 0.72),
                second: .init(hue: 0.63, saturation: 0.70),
                intensity: 0.62,
                brightness: 1
            )
        case .velvetDusk:
            SakuraCordGradientTheme(
                first: .init(hue: 0.72, saturation: 0.77),
                second: .init(hue: 0.89, saturation: 0.66),
                intensity: 0.69,
                brightness: 1
            )
        case .polarBloom:
            SakuraCordGradientTheme(
                first: .init(hue: 0.48, saturation: 0.74),
                second: .init(hue: 0.39, saturation: 0.62),
                intensity: 0.58,
                brightness: 1
            )
        case .sunsetSoda:
            SakuraCordGradientTheme(
                first: .init(hue: 0.04, saturation: 0.82),
                second: .init(hue: 0.96, saturation: 0.67),
                intensity: 0.72,
                brightness: 1
            )
        case .blueHour:
            SakuraCordGradientTheme(
                first: .init(hue: 0.56, saturation: 0.78),
                second: .init(hue: 0.67, saturation: 0.62),
                intensity: 0.61,
                brightness: 1
            )
        case .wildMint:
            SakuraCordGradientTheme(
                first: .init(hue: 0.34, saturation: 0.72),
                second: .init(hue: 0.43, saturation: 0.65),
                intensity: 0.64,
                brightness: 1
            )
        case .rosewater:
            SakuraCordGradientTheme(
                first: .init(hue: 0.94, saturation: 0.68),
                second: .init(hue: 0.86, saturation: 0.48),
                intensity: 0.56,
                brightness: 1
            )
        case .solarFlare:
            SakuraCordGradientTheme(
                first: .init(hue: 0.075, saturation: 0.86),
                second: .init(hue: 0.995, saturation: 0.73),
                intensity: 0.74,
                brightness: 1
            )
        case .deepLagoon:
            SakuraCordGradientTheme(
                first: .init(hue: 0.48, saturation: 0.84),
                second: .init(hue: 0.57, saturation: 0.72),
                intensity: 0.68,
                brightness: 1
            )
        case .custom:
            nil
        }
    }
}

nonisolated struct SakuraCordThemeColor: Codable, Equatable, Sendable {
    var hue: Double
    var saturation: Double

    init(hue: Double, saturation: Double) {
        self.hue = Self.normalizedHue(hue)
        self.saturation = saturation.clamped(to: 0 ... 1)
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

nonisolated enum SakuraCordThemeAppearance: Sendable {
    case light
    case dark
}

nonisolated struct SakuraCordThemeRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        let hue = (hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        let saturation = saturation.clamped(to: 0 ... 1)
        let brightness = brightness.clamped(to: 0 ... 1)
        let sector = hue * 6
        let index = Int(floor(sector)) % 6
        let fraction = sector - floor(sector)
        let minimumComponent = brightness * (1 - saturation)
        let descendingComponent = brightness * (1 - fraction * saturation)
        let ascendingComponent = brightness * (1 - (1 - fraction) * saturation)
        switch index {
        case 0: (red, green, blue) = (brightness, ascendingComponent, minimumComponent)
        case 1: (red, green, blue) = (descendingComponent, brightness, minimumComponent)
        case 2: (red, green, blue) = (minimumComponent, brightness, ascendingComponent)
        case 3: (red, green, blue) = (minimumComponent, descendingComponent, brightness)
        case 4: (red, green, blue) = (ascendingComponent, minimumComponent, brightness)
        default: (red, green, blue) = (brightness, minimumComponent, descendingComponent)
        }
    }

    func composited(over background: Self, opacity: Double) -> Self {
        let opacity = opacity.clamped(to: 0 ... 1)
        return Self(
            red: red * opacity + background.red * (1 - opacity),
            green: green * opacity + background.green * (1 - opacity),
            blue: blue * opacity + background.blue * (1 - opacity)
        )
    }

    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: Self) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func blended(toward target: Self, fraction: Double) -> Self {
        target.composited(over: self, opacity: fraction)
    }

    func adjustedForContrast(
        with foreground: Self,
        toward target: Self,
        requiredRatio: Double = 4.7
    ) -> Self {
        if contrastRatio(with: foreground) >= requiredRatio {
            return self
        }
        var lowerBound = 0.0
        var upperBound = 1.0
        for _ in 0 ..< 12 {
            let candidateFraction = (lowerBound + upperBound) / 2
            let candidate = blended(toward: target, fraction: candidateFraction)
            if candidate.contrastRatio(with: foreground) >= requiredRatio {
                upperBound = candidateFraction
            } else {
                lowerBound = candidateFraction
            }
        }
        return blended(toward: target, fraction: upperBound)
    }

    static let black = Self(red: 0, green: 0, blue: 0)
    static let white = Self(red: 1, green: 1, blue: 1)
    static let lightWindow = Self(red: 0.94, green: 0.93, blue: 0.95)
    static let darkWindow = Self(red: 0.085, green: 0.078, blue: 0.098)
}

nonisolated struct SakuraCordGradientTheme: Codable, Equatable, Sendable {
    static let defaultCustom = SakuraCordGradientTheme(
        first: .init(hue: 0.97, saturation: 0.72),
        second: .init(hue: 0.34, saturation: 0.70),
        intensity: 0.62,
        brightness: 1
    )

    var first: SakuraCordThemeColor
    var second: SakuraCordThemeColor
    var intensity: Double
    var brightness: Double

    init(
        first: SakuraCordThemeColor,
        second: SakuraCordThemeColor,
        intensity: Double,
        brightness: Double
    ) {
        self.first = first
        self.second = second
        self.intensity = intensity.clamped(to: 0 ... 1)
        self.brightness = brightness.clamped(to: 0 ... 1)
    }

    var storageValue: String {
        [
            first.hue,
            first.saturation,
            second.hue,
            second.saturation,
            intensity,
            brightness,
        ]
        .map { String($0) }
        .joined(separator: ",")
    }

    init?(storageValue: String) {
        let values = storageValue.split(separator: ",").compactMap { Double($0) }
        guard values.count == 6, values.allSatisfy(\.isFinite) else { return nil }
        self.init(
            first: .init(hue: values[0], saturation: values[1]),
            second: .init(hue: values[2], saturation: values[3]),
            intensity: values[4],
            brightness: values[5]
        )
    }

    func interpolated(to target: Self, progress: Double) -> Self {
        let progress = progress.clamped(to: 0 ... 1)
        return Self(
            first: .init(
                hue: Self.interpolatedHue(from: first.hue, to: target.first.hue, progress: progress),
                saturation: first.saturation.interpolated(to: target.first.saturation, progress: progress)
            ),
            second: .init(
                hue: Self.interpolatedHue(from: second.hue, to: target.second.hue, progress: progress),
                saturation: second.saturation.interpolated(to: target.second.saturation, progress: progress)
            ),
            intensity: intensity.interpolated(to: target.intensity, progress: progress),
            brightness: brightness.interpolated(to: target.brightness, progress: progress)
        )
    }

    private static func interpolatedHue(from start: Double, to end: Double, progress: Double) -> Double {
        var delta = end - start
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        return start + delta * progress
    }

    var intensityProgress: Double {
        pow(intensity, 1.75)
    }

    func renderedRGB(
        _ color: SakuraCordThemeColor,
        for appearance: SakuraCordThemeAppearance
    ) -> SakuraCordThemeRGB {
        let renderedSaturation = appearance == .dark
            ? color.saturation * 0.82
            : color.saturation * 0.58
        let renderedBrightness: Double
        if appearance == .dark {
            // Preserve the established mid-point while making zero a real
            // black endpoint and one a real full-brightness endpoint.
            let midpoint = 0.67
            renderedBrightness = brightness <= 0.5
                ? midpoint * brightness / 0.5
                : midpoint + (1 - midpoint) * (brightness - 0.5) / 0.5
        } else {
            // Light appearance keeps a contrast-safe lower bound for dark
            // labels while still changing the actual gradient luminance.
            let minimum = 0.72
            let midpoint = 0.84
            renderedBrightness = brightness <= 0.5
                ? minimum + (midpoint - minimum) * brightness / 0.5
                : midpoint + (1 - midpoint) * (brightness - 0.5) / 0.5
        }
        return SakuraCordThemeRGB(
            hue: color.hue,
            saturation: renderedSaturation,
            brightness: renderedBrightness
        )
    }

    private func surfaceTargetRGB(
        for appearance: SakuraCordThemeAppearance
    ) -> SakuraCordThemeRGB {
        if appearance == .dark {
            let target = SakuraCordThemeRGB.darkWindow.blended(
                toward: .black,
                fraction: 0.68
            )
            if brightness <= 0.5 {
                return target.blended(
                    toward: .black,
                    fraction: 1 - brightness / 0.5
                )
            }
            return target
        }

        if brightness <= 0.5 {
            return SakuraCordThemeRGB.lightWindow.blended(
                toward: .black,
                fraction: (0.5 - brightness) * 0.14
            )
        }
        return SakuraCordThemeRGB.lightWindow.blended(
            toward: .white,
            fraction: (brightness - 0.5) * 0.12
        )
    }

    func surfaceBaseRGB(for appearance: SakuraCordThemeAppearance) -> SakuraCordThemeRGB {
        let systemBase: SakuraCordThemeRGB = appearance == .dark ? .darkWindow : .lightWindow
        return systemBase.blended(
            toward: surfaceTargetRGB(for: appearance),
            fraction: intensityProgress
        )
    }

    func backgroundTintRGB(
        _ color: SakuraCordThemeColor,
        for appearance: SakuraCordThemeAppearance
    ) -> SakuraCordThemeRGB {
        guard appearance == .dark else {
            return renderedRGB(color, for: appearance)
        }

        // Dark surfaces use a deep version of the selected color rather
        // than a faint full-brightness color over gray. This preserves hue
        // and saturation without lifting the whole window's luminance.
        let saturation = color.saturation
            + (1 - color.saturation) * intensity * 0.65
        let surfaceBrightness = 0.28 * pow(brightness, 0.72)
        return SakuraCordThemeRGB(
            hue: color.hue,
            saturation: saturation,
            brightness: surfaceBrightness
        )
    }

    func backgroundSamples(for appearance: SakuraCordThemeAppearance) -> [SakuraCordThemeRGB] {
        let base = surfaceBaseRGB(for: appearance)
        let opacity = backgroundBlendOpacity(for: appearance)
        let firstBackground = backgroundTintRGB(first, for: appearance)
            .composited(over: base, opacity: opacity)
        let secondBackground = backgroundTintRGB(second, for: appearance)
            .composited(over: base, opacity: opacity * 0.86)
        let radialTint = backgroundTintRGB(second, for: appearance)
        let radialOpacity = opacity * 0.48
        return [
            firstBackground,
            secondBackground,
            radialTint.composited(over: firstBackground, opacity: radialOpacity),
            radialTint.composited(over: secondBackground, opacity: radialOpacity),
        ]
    }

    func readableForeground(
        _ source: SakuraCordThemeRGB,
        for appearance: SakuraCordThemeAppearance
    ) -> SakuraCordThemeRGB {
        let backgrounds = backgroundSamples(for: appearance)
        let target: SakuraCordThemeRGB = appearance == .dark ? .white : .black
        let requiredContrast = 4.7
        if backgrounds.allSatisfy({ source.contrastRatio(with: $0) >= requiredContrast }) {
            return source
        }

        var lowerBound = 0.0
        var upperBound = 1.0
        for _ in 0 ..< 12 {
            let candidateFraction = (lowerBound + upperBound) / 2
            let candidate = source.blended(toward: target, fraction: candidateFraction)
            if backgrounds.allSatisfy({ candidate.contrastRatio(with: $0) >= requiredContrast }) {
                upperBound = candidateFraction
            } else {
                lowerBound = candidateFraction
            }
        }
        return source.blended(toward: target, fraction: upperBound)
    }

}

nonisolated struct SakuraCordThemeSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(
        selectedPreset: .system,
        customTheme: .defaultCustom
    )

    var selectedPreset: SakuraCordThemePreset
    var customTheme: SakuraCordGradientTheme
}

@MainActor
final class SakuraCordThemeSettingsStore {
    static let shared = SakuraCordThemeSettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> SakuraCordThemeSettingsSnapshot {
        let selectedPreset: SakuraCordThemePreset
        if case let .string(rawValue) = preferences.value(for: .gradientTheme),
           let stored = SakuraCordThemePreset(rawValue: rawValue)
        {
            selectedPreset = stored
        } else {
            selectedPreset = .system
        }

        let customTheme: SakuraCordGradientTheme
        if case let .string(rawValue) = preferences.value(for: .customGradientTheme),
           let stored = SakuraCordGradientTheme(storageValue: rawValue)
        {
            customTheme = stored
        } else {
            customTheme = .defaultCustom
        }
        return Self.snapshot(selectedPreset: selectedPreset, customTheme: customTheme)
    }

    func save(_ value: SakuraCordThemeSettingsSnapshot) {
        preferences.set(.string(value.selectedPreset.rawValue), for: .gradientTheme)
        preferences.set(.string(value.customTheme.storageValue), for: .customGradientTheme)
    }

    private static func snapshot(
        selectedPreset: SakuraCordThemePreset,
        customTheme: SakuraCordGradientTheme
    ) -> SakuraCordThemeSettingsSnapshot {
        SakuraCordThemeSettingsSnapshot(
            selectedPreset: selectedPreset,
            customTheme: customTheme
        )
    }
}

@MainActor
@Observable
final class SakuraCordThemeStore {
    static let shared = SakuraCordThemeStore()
    static let randomizationDuration: Duration = .milliseconds(220)

    private(set) var selectedPreset: SakuraCordThemePreset
    private(set) var activeTheme: SakuraCordGradientTheme
    private(set) var committedTheme: SakuraCordGradientTheme

    private(set) var customTheme: SakuraCordGradientTheme
    @ObservationIgnored private let persistence: SakuraCordThemeSettingsStore
    @ObservationIgnored private var deferredPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var interactionGeneration: UInt64 = 0

    init(persistence: SakuraCordThemeSettingsStore = .shared) {
        self.persistence = persistence
        let stored = persistence.load()
        selectedPreset = stored.selectedPreset
        customTheme = stored.customTheme
        let initial = stored.selectedPreset.presetTheme ?? stored.customTheme
        activeTheme = initial
        committedTheme = initial
    }

    isolated deinit {
        deferredPersistenceTask?.cancel()
    }

    var usesSystemAppearance: Bool {
        selectedPreset.usesSystemAppearance
    }

    var usesSystemSurface: Bool {
        usesSystemAppearance || activeTheme.intensity == 0
    }

    func select(_ preset: SakuraCordThemePreset) {
        interactionGeneration &+= 1
        selectedPreset = preset
        activeTheme = preset.presetTheme ?? customTheme
        commit()
    }

    func setFirstHue(_ hue: Double) {
        editCustom { $0.first.hue = Self.normalizedHue(hue) }
    }

    func setSecondHue(_ hue: Double) {
        editCustom { $0.second.hue = Self.normalizedHue(hue) }
    }

    func setIntensity(_ intensity: Double) {
        editCustom { $0.intensity = intensity.clamped(to: 0 ... 1) }
    }

    func setBrightness(_ brightness: Double) {
        editCustom { $0.brightness = brightness.clamped(to: 0 ... 1) }
    }

    func finishInteraction() {
        commit()
    }

    func randomizedTheme() -> SakuraCordGradientTheme {
        let brightness = activeTheme.brightness
        let firstHue = Double.random(in: 0 ..< 1)
        var secondHue = Double.random(in: 0 ..< 1)
        if Self.circularDistance(firstHue, secondHue) < 0.06 {
            secondHue = Self.normalizedHue(firstHue + Double.random(in: 0.06 ... 0.18))
        }
        return SakuraCordGradientTheme(
            first: .init(hue: firstHue, saturation: .random(in: 0.62 ... 0.90)),
            second: .init(hue: secondHue, saturation: .random(in: 0.58 ... 0.86)),
            intensity: .random(in: 0.60 ... 1),
            brightness: brightness
        )
    }

    func randomize(reduceMotion: Bool) async {
        interactionGeneration &+= 1
        let generation = interactionGeneration
        let target = randomizedTheme()
        selectedPreset = .custom
        if reduceMotion {
            activeTheme = target
            customTheme = target
            commit()
            return
        }

        let source = activeTheme
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled, interactionGeneration == generation {
            let elapsed = start.duration(to: clock.now)
            // The duration is sub-second, so compare attoseconds directly and use
            // a smooth ease-out curve without creating a perpetual TimelineView.
            let durationSeconds = Self.randomizationDuration.secondsValue
            let elapsedSeconds = elapsed.secondsValue
            let linearProgress = (elapsedSeconds / durationSeconds).clamped(to: 0 ... 1)
            let easedProgress = 1 - pow(1 - linearProgress, 3)
            activeTheme = source.interpolated(to: target, progress: easedProgress)
            customTheme = activeTheme
            if linearProgress >= 1 { break }
            try? await clock.sleep(for: .milliseconds(8))
        }
        guard !Task.isCancelled, interactionGeneration == generation else { return }
        activeTheme = target
        customTheme = target
        commit()
    }

    func accentNSColor() -> NSColor {
        if usesSystemAppearance {
            return Self.systemAccentNSColor
        }
        let theme = committedTheme
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let themeAppearance: SakuraCordThemeAppearance = isDark ? .dark : .light
            let source = SakuraCordThemeRGB(
                hue: theme.first.hue,
                saturation: max(0.54, theme.first.saturation),
                brightness: 0.82
            )
            return NSColor(theme.readableForeground(source, for: themeAppearance))
        }
    }

    func roleNSColor(for colorHex: UInt32) -> NSColor {
        let source = SakuraCordThemeRGB(
            red: Double((colorHex >> 16) & 0xFF) / 255,
            green: Double((colorHex >> 8) & 0xFF) / 255,
            blue: Double(colorHex & 0xFF) / 255
        )
        if usesSystemAppearance {
            return NSColor(source)
        }
        let theme = committedTheme
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let themeAppearance: SakuraCordThemeAppearance = isDark ? .dark : .light
            return NSColor(theme.readableForeground(source, for: themeAppearance))
        }
    }

    func textSelectionNSColor() -> NSColor {
        if usesSystemAppearance {
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(
                        srgbRed: 89.0 / 255,
                        green: 93.0 / 255,
                        blue: 135.0 / 255,
                        alpha: 1
                    )
                    : NSColor(
                        srgbRed: 205.0 / 255,
                        green: 209.0 / 255,
                        blue: 251.0 / 255,
                        alpha: 1
                    )
            }
        }
        return NSColor(name: nil) { appearance in
            var result = NSColor.selectedTextBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                let accent = self.accentNSColor().usingColorSpace(.sRGB)
                    ?? self.accentNSColor()
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                result = accent.blended(
                    withFraction: isDark ? 0.38 : 0.70,
                    of: .windowBackgroundColor
                ) ?? accent
            }
            return result
        }
    }

    private func editCustom(_ edit: (inout SakuraCordGradientTheme) -> Void) {
        interactionGeneration &+= 1
        if selectedPreset != .custom {
            selectedPreset = .custom
            customTheme = activeTheme
        }
        var edited = activeTheme
        edit(&edited)
        activeTheme = edited
        customTheme = edited
        schedulePersistence()
    }

    private func schedulePersistence() {
        deferredPersistenceTask?.cancel()
        deferredPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func commit() {
        deferredPersistenceTask?.cancel()
        committedTheme = activeTheme
        save()
        NotificationCenter.default.post(name: .sakuraCordThemeDidCommit, object: nil)
    }

    private func save() {
        persistence.save(
            SakuraCordThemeSettingsSnapshot(
                selectedPreset: selectedPreset,
                customTheme: customTheme
            )
        )
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    private static func circularDistance(_ first: Double, _ second: Double) -> Double {
        let distance = abs(first - second)
        return min(distance, 1 - distance)
    }

    private static var systemAccentNSColor: NSColor {
        let blurple = NSColor(
            srgbRed: 0x58 / 255,
            green: 0x65 / 255,
            blue: 0xF2 / 255,
            alpha: 1
        )
        return NSColor(name: nil) { appearance in
            var result = blurple
            appearance.performAsCurrentDrawingAppearance {
                result = NSTintConfiguration(preferredColor: blurple)
                    .equivalentContentTintColor
                    ?? blurple
            }
            return result
        }
    }
}

extension Notification.Name {
    static let sakuraCordThemeDidCommit = Notification.Name(
        "dev.sakuracord.theme-did-commit"
    )
}

extension SakuraCordGradientTheme {
    @MainActor
    func colors(for colorScheme: ColorScheme) -> (first: Color, second: Color) {
        let firstColor = renderedColor(first, for: colorScheme)
        let secondColor = renderedColor(second, for: colorScheme)
        return (firstColor, secondColor)
    }

    @MainActor
    func backgroundColors(for colorScheme: ColorScheme) -> (first: Color, second: Color) {
        let appearance: SakuraCordThemeAppearance = colorScheme == .dark ? .dark : .light
        let firstRGB = backgroundTintRGB(first, for: appearance)
        let secondRGB = backgroundTintRGB(second, for: appearance)
        return (
            Color(red: firstRGB.red, green: firstRGB.green, blue: firstRGB.blue),
            Color(red: secondRGB.red, green: secondRGB.green, blue: secondRGB.blue)
        )
    }

    @MainActor
    func renderedColor(_ color: SakuraCordThemeColor, for colorScheme: ColorScheme) -> Color {
        let rgb = renderedRGB(color, for: colorScheme == .dark ? .dark : .light)
        return Color(
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue
        )
    }

    @MainActor
    func surfaceTargetColor(for colorScheme: ColorScheme) -> Color {
        let rgb = surfaceTargetRGB(for: colorScheme == .dark ? .dark : .light)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    nonisolated func backgroundBlendOpacity(
        for appearance: SakuraCordThemeAppearance
    ) -> Double {
        let maximumOpacity = appearance == .dark ? 0.96 : 0.40
        return maximumOpacity * intensityProgress
    }
}

struct SakuraCordThemeBackground: View {
    let themeStore: SakuraCordThemeStore
    var emphasizesGradient = false

    init(
        themeStore: SakuraCordThemeStore = .shared,
        emphasizesGradient: Bool = false
    ) {
        self.themeStore = themeStore
        self.emphasizesGradient = emphasizesGradient
    }

    var body: some View {
        if themeStore.usesSystemSurface {
            Color(nsColor: .windowBackgroundColor)
                .accessibilityHidden(true)
        } else {
            SakuraCordGradientBackground(
                theme: themeStore.activeTheme,
                emphasizesGradient: emphasizesGradient
            )
        }
    }
}

private struct SakuraCordGradientBackground: View {
    let theme: SakuraCordGradientTheme
    let emphasizesGradient: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let appearance: SakuraCordThemeAppearance = colorScheme == .dark ? .dark : .light
        let colors = theme.backgroundColors(for: colorScheme)
        let contrastScale = colorSchemeContrast == .increased ? 0.76 : 1
        let emphasis = emphasizesGradient ? 1.22 : 1
        let maximumOpacity = appearance == .dark ? 0.98 : 0.46
        let opacity = min(
            maximumOpacity,
            theme.backgroundBlendOpacity(for: appearance) * contrastScale * emphasis
        )

        ZStack {
            Color(nsColor: .windowBackgroundColor)
            theme.surfaceTargetColor(for: colorScheme)
                .opacity(theme.intensityProgress)

            LinearGradient(
                colors: [
                    colors.first.opacity(opacity),
                    colors.second.opacity(opacity * 0.86),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [colors.second.opacity(opacity * 0.48), .clear],
                center: .bottomTrailing,
                startRadius: 24,
                endRadius: 720
            )

        }
        .accessibilityHidden(true)
    }
}

private extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }

    nonisolated func interpolated(to target: Double, progress: Double) -> Double {
        self + (target - self) * progress
    }
}

private extension Duration {
    nonisolated var secondsValue: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
