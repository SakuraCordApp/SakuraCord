import AppKit
import Foundation
import Observation
import SwiftUI

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
    static let defaultTheme = SakuraCordGradientTheme(
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
        return SakuraCordThemeRGB(
            hue: color.hue,
            saturation: renderedSaturation,
            brightness: renderedBrightness(for: appearance)
        )
    }

    private func renderedBrightness(
        for appearance: SakuraCordThemeAppearance
    ) -> Double {
        if appearance == .dark {
            // Preserve the established mid-point while making zero a real
            // black endpoint and one a real full-brightness endpoint.
            let midpoint = 0.67
            return brightness <= 0.5
                ? midpoint * brightness / 0.5
                : midpoint + (1 - midpoint) * (brightness - 0.5) / 0.5
        }

        // Light appearance keeps a contrast-safe lower bound for dark
        // labels while still changing the actual gradient luminance.
        let minimum = 0.72
        let midpoint = 0.84
        return brightness <= 0.5
            ? minimum + (midpoint - minimum) * brightness / 0.5
            : midpoint + (1 - midpoint) * (brightness - 0.5) / 0.5
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
            // The light surface already softens this source by compositing it
            // over the near-white window base. Preserve the selected
            // saturation here so it is not attenuated a second time.
            return SakuraCordThemeRGB(
                hue: color.hue,
                saturation: color.saturation,
                brightness: renderedBrightness(for: appearance)
            )
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

@MainActor
final class SakuraCordThemeSettingsStore {
    static let shared = SakuraCordThemeSettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> SakuraCordGradientTheme {
        if case let .string(rawValue) = preferences.value(for: .themeDesigner),
           let stored = SakuraCordGradientTheme(storageValue: rawValue)
        {
            return stored
        }
        return .defaultTheme
    }

    func save(_ theme: SakuraCordGradientTheme) {
        preferences.set(.string(theme.storageValue), for: .themeDesigner)
    }
}

@MainActor
@Observable
final class SakuraCordThemeStore {
    static let shared = SakuraCordThemeStore()
    static let randomizationDurationSeconds = 0.22
    static let randomizationDuration: Duration = .seconds(randomizationDurationSeconds)

    private(set) var activeTheme: SakuraCordGradientTheme
    private(set) var committedTheme: SakuraCordGradientTheme

    @ObservationIgnored private let persistence: SakuraCordThemeSettingsStore
    @ObservationIgnored private var deferredPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var interactionGeneration: UInt64 = 0

    init(persistence: SakuraCordThemeSettingsStore = .shared) {
        self.persistence = persistence
        let initial = persistence.load()
        activeTheme = initial
        committedTheme = initial
    }

    isolated deinit {
        deferredPersistenceTask?.cancel()
    }

    var usesSystemSurface: Bool {
        activeTheme.intensity == 0
    }

    func setFirstHue(_ hue: Double) {
        editTheme { $0.first.hue = Self.normalizedHue(hue) }
    }

    func setSecondHue(_ hue: Double) {
        editTheme { $0.second.hue = Self.normalizedHue(hue) }
    }

    func setIntensity(_ intensity: Double) {
        editTheme { $0.intensity = intensity.clamped(to: 0 ... 1) }
    }

    func setBrightness(_ brightness: Double) {
        editTheme { $0.brightness = brightness.clamped(to: 0 ... 1) }
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
        if reduceMotion {
            activeTheme = target
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
            if linearProgress >= 1 { break }
            try? await clock.sleep(for: .milliseconds(8))
        }
        guard !Task.isCancelled, interactionGeneration == generation else { return }
        activeTheme = target
        commit()
    }

    func accentNSColor() -> NSColor {
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
        let theme = committedTheme
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let themeAppearance: SakuraCordThemeAppearance = isDark ? .dark : .light
            return NSColor(theme.readableForeground(source, for: themeAppearance))
        }
    }

    func textSelectionNSColor() -> NSColor {
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

    private func editTheme(_ edit: (inout SakuraCordGradientTheme) -> Void) {
        interactionGeneration &+= 1
        var edited = activeTheme
        edit(&edited)
        activeTheme = edited
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
        persistence.save(activeTheme)
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    private static func circularDistance(_ first: Double, _ second: Double) -> Double {
        let distance = abs(first - second)
        return min(distance, 1 - distance)
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
        // Interface color cues stay vivid while brightness remains exclusive
        // to the resulting theme surface.
        let interfaceTheme = SakuraCordGradientTheme(
            first: first,
            second: second,
            intensity: intensity,
            brightness: 1
        )
        let firstColor = interfaceTheme.renderedColor(first, for: colorScheme)
        let secondColor = interfaceTheme.renderedColor(second, for: colorScheme)
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
