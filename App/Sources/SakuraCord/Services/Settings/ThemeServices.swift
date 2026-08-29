import AppKit
import Foundation
import Observation
import SwiftUI

nonisolated struct SakuraCordThemeColor: Codable, Equatable, Hashable, Sendable {
    var hue: Double
    var saturation: Double

    init(hue: Double, saturation: Double) {
        self.hue = Self.normalizedHue(hue)
        self.saturation = saturation.clamped(to: 0 ... 1)
    }

    init(sRGBRed red: Int, green: Int, blue: Int) {
        let red = Double(red) / 255
        let green = Double(green) / 255
        let blue = Double(blue) / 255
        let maximumComponent = max(red, green, blue)
        let minimumComponent = min(red, green, blue)
        let delta = maximumComponent - minimumComponent

        let hue: Double
        if delta == 0 {
            hue = 0
        } else if maximumComponent == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maximumComponent == green {
            hue = ((blue - red) / delta + 2) / 6
        } else {
            hue = ((red - green) / delta + 4) / 6
        }
        self.init(
            hue: hue,
            saturation: maximumComponent == 0 ? 0 : delta / maximumComponent
        )
    }

    static let discordBlurple = Self(sRGBRed: 0x58, green: 0x65, blue: 0xF2)

    private static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

nonisolated enum LegacyAccentColorChoice: String, CaseIterable, Sendable {
    case blurple
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case gray

    var themeColor: SakuraCordThemeColor {
        switch self {
        case .blurple:
            .discordBlurple
        case .blue:
            .init(sRGBRed: 0x00, green: 0x7A, blue: 0xFF)
        case .purple:
            .init(sRGBRed: 0x95, green: 0x3D, blue: 0x96)
        case .pink:
            .init(sRGBRed: 0xF7, green: 0x4F, blue: 0x9E)
        case .red:
            .init(sRGBRed: 0xE0, green: 0x38, blue: 0x3E)
        case .orange:
            .init(sRGBRed: 0xF7, green: 0x82, blue: 0x1B)
        case .yellow:
            .init(sRGBRed: 0xFF, green: 0xC7, blue: 0x26)
        case .green:
            .init(sRGBRed: 0x62, green: 0xBA, blue: 0x46)
        case .gray:
            .discordBlurple
        }
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

nonisolated struct SakuraCordGradientTheme: Codable, Equatable, Hashable, Sendable {
    static let minimumColorCount = 1
    static let maximumColorCount = 5
    static let minimumHueSpacing = 0.075

    static let defaultTheme = SakuraCordGradientTheme(
        colors: [.discordBlurple],
        intensity: 0,
        brightness: 1
    )

    private(set) var colors: [SakuraCordThemeColor]
    private(set) var activeColorCount: Int
    var intensity: Double
    var brightness: Double

    init(
        colors: [SakuraCordThemeColor],
        activeColorCount: Int? = nil,
        intensity: Double,
        brightness: Double
    ) {
        precondition(!colors.isEmpty)
        let storedColors = Array(colors.prefix(Self.maximumColorCount))
        self.colors = storedColors
        self.activeColorCount = min(
            max(activeColorCount ?? storedColors.count, Self.minimumColorCount),
            storedColors.count
        )
        self.intensity = intensity.clamped(to: 0 ... 1)
        self.brightness = brightness.clamped(to: 0 ... 1)
    }

    init(
        first: SakuraCordThemeColor,
        second: SakuraCordThemeColor,
        intensity: Double,
        brightness: Double
    ) {
        self.init(
            colors: [first, second],
            intensity: intensity,
            brightness: brightness
        )
    }

    var activeColors: ArraySlice<SakuraCordThemeColor> {
        colors.prefix(activeColorCount)
    }

    var storageValue: String {
        var components = [
            "v2",
            String(activeColorCount),
            String(intensity),
            String(brightness),
        ]
        for color in colors {
            components.append(String(color.hue))
            components.append(String(color.saturation))
        }
        return components.joined(separator: ",")
    }

    init?(storageValue: String) {
        let components = storageValue.split(separator: ",")
        if components.first == "v2" {
            guard components.count >= 6,
                  components.count.isMultiple(of: 2),
                  let activeColorCount = Int(components[1]),
                  let intensity = Double(components[2]),
                  let brightness = Double(components[3]),
                  intensity.isFinite,
                  brightness.isFinite
            else { return nil }

            let colorValues = components.dropFirst(4).compactMap { Double($0) }
            let colorCount = colorValues.count / 2
            guard colorValues.count == components.count - 4,
                  colorValues.allSatisfy(\.isFinite),
                  colorCount >= Self.minimumColorCount,
                  colorCount <= Self.maximumColorCount,
                  activeColorCount >= Self.minimumColorCount,
                  activeColorCount <= colorCount
            else { return nil }

            let colors = stride(from: 0, to: colorValues.count, by: 2).map {
                SakuraCordThemeColor(
                    hue: colorValues[$0],
                    saturation: colorValues[$0 + 1]
                )
            }
            self.init(
                colors: colors,
                activeColorCount: activeColorCount,
                intensity: intensity,
                brightness: brightness
            )
            return
        }

        // Migrate the original two-color comma-separated representation.
        let values = components.compactMap { Double($0) }
        guard values.count == 6,
              values.count == components.count,
              values.allSatisfy(\.isFinite)
        else { return nil }
        self.init(
            colors: [
                .init(hue: values[0], saturation: values[1]),
                .init(hue: values[2], saturation: values[3]),
            ],
            intensity: values[4],
            brightness: values[5]
        )
    }

    func interpolated(to target: Self, progress: Double) -> Self {
        let progress = progress.clamped(to: 0 ... 1)
        let interpolatedColors = target.colors.enumerated().map { index, targetColor in
            let sourceColor = colors.indices.contains(index) ? colors[index] : targetColor
            return SakuraCordThemeColor(
                hue: Self.interpolatedHue(
                    from: sourceColor.hue,
                    to: targetColor.hue,
                    progress: progress
                ),
                saturation: sourceColor.saturation.interpolated(
                    to: targetColor.saturation,
                    progress: progress
                )
            )
        }
        return Self(
            colors: interpolatedColors,
            activeColorCount: target.activeColorCount,
            intensity: intensity.interpolated(to: target.intensity, progress: progress),
            brightness: brightness.interpolated(to: target.brightness, progress: progress)
        )
    }

    mutating func setHue(_ hue: Double, at index: Int) {
        guard activeColors.indices.contains(index) else { return }
        colors[index].hue = Self.normalizedHue(hue)
    }

    @discardableResult
    mutating func addColor() -> Bool {
        guard activeColorCount < Self.maximumColorCount else { return false }
        let newIndex = activeColorCount
        let existingHues = activeColors.map(\.hue)
        let suggestedHue = Self.hueInLargestGap(between: existingHues)

        if colors.indices.contains(newIndex) {
            if existingHues.contains(where: {
                Self.circularHueDistance($0, colors[newIndex].hue) < Self.minimumHueSpacing
            }) {
                colors[newIndex].hue = suggestedHue
            }
        } else {
            let averageSaturation = activeColors.reduce(0) { $0 + $1.saturation }
                / Double(activeColorCount)
            colors.append(
                SakuraCordThemeColor(
                    hue: suggestedHue,
                    saturation: averageSaturation
                )
            )
        }
        activeColorCount += 1
        return true
    }

    @discardableResult
    mutating func removeColor() -> Bool {
        guard activeColorCount > Self.minimumColorCount else { return false }
        activeColorCount -= 1
        return true
    }

    static func circularHueDistance(_ first: Double, _ second: Double) -> Double {
        let distance = abs(normalizedHue(first) - normalizedHue(second))
        return min(distance, 1 - distance)
    }

    private static func hueInLargestGap<S: Sequence>(between hues: S) -> Double
        where S.Element == Double
    {
        let sortedHues = hues.map(normalizedHue).sorted()
        guard !sortedHues.isEmpty else { return 0 }

        var largestGapStart = sortedHues[0]
        var largestGap = 0.0
        for index in sortedHues.indices {
            let start = sortedHues[index]
            let end = index == sortedHues.index(before: sortedHues.endIndex)
                ? sortedHues[0] + 1
                : sortedHues[sortedHues.index(after: index)]
            let gap = end - start
            if gap > largestGap {
                largestGap = gap
                largestGapStart = start
            }
        }
        return normalizedHue(largestGapStart + largestGap / 2)
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
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
        let linearSamples = activeColors.enumerated().map { index, color in
            backgroundTintRGB(color, for: appearance).composited(
                over: base,
                opacity: opacity * stopOpacityScale(at: index)
            )
        }
        guard let radialColor = activeColors.last else { return [base] }
        let radialTint = backgroundTintRGB(radialColor, for: appearance)
        let radialOpacity = opacity * 0.48
        return linearSamples + linearSamples.map {
            radialTint.composited(over: $0, opacity: radialOpacity)
        }
    }

    func stopOpacityScale(at index: Int) -> Double {
        guard activeColorCount > 1 else { return 1 }
        let progress = Double(index) / Double(activeColorCount - 1)
        return 1 - 0.14 * progress
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
        if preferences.containsStoredValue(for: .themeDesigner) {
            if case let .string(rawValue) = preferences.value(for: .themeDesigner),
               let stored = SakuraCordGradientTheme(storageValue: rawValue)
            {
                return stored
            }
            return .defaultTheme
        }

        let legacyAccent: LegacyAccentColorChoice
        if case let .string(rawValue) = preferences.value(
            for: .legacyAccentColorMigration
        ) {
            legacyAccent = LegacyAccentColorChoice(rawValue: rawValue) ?? .blurple
        } else {
            legacyAccent = .blurple
        }
        let migrated = SakuraCordGradientTheme(
            colors: [legacyAccent.themeColor],
            intensity: 0,
            brightness: 1
        )
        save(migrated)
        return migrated
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

    func setHue(_ hue: Double, at index: Int) {
        editTheme { $0.setHue(hue, at: index) }
    }

    func addColor() {
        editTheme { $0.addColor() }
        commit()
    }

    func removeColor() {
        editTheme { $0.removeColor() }
        commit()
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

    func apply(_ theme: SakuraCordGradientTheme) {
        interactionGeneration &+= 1
        activeTheme = theme
        commit()
    }

    func randomizedTheme() -> SakuraCordGradientTheme {
        let brightness = activeTheme.brightness
        var colors = activeTheme.colors
        let randomizedHues = Self.randomizedSeparatedHues(
            count: activeTheme.activeColorCount
        )
        for index in 0 ..< activeTheme.activeColorCount {
            colors[index] = SakuraCordThemeColor(
                hue: randomizedHues[index],
                saturation: .random(in: 0.60 ... 0.90)
            )
        }
        return SakuraCordGradientTheme(
            colors: colors,
            activeColorCount: activeTheme.activeColorCount,
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
        let accentColor = theme.activeColors.first ?? SakuraCordGradientTheme.defaultTheme.colors[0]
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let themeAppearance: SakuraCordThemeAppearance = isDark ? .dark : .light
            let source = SakuraCordThemeRGB(
                hue: accentColor.hue,
                saturation: max(0.54, accentColor.saturation),
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

    private static func randomizedSeparatedHues(count: Int) -> [Double] {
        guard count > 1 else { return [Double.random(in: 0 ..< 1)] }
        let spacing = 1 / Double(count)
        let jitterLimit = max(
            0,
            (spacing - SakuraCordGradientTheme.minimumHueSpacing) * 0.40
        )
        let phase = Double.random(in: 0 ..< 1)
        var hues = (0 ..< count).map { index in
            let jitter = Double.random(in: -jitterLimit ... jitterLimit)
            let hue = phase + Double(index) * spacing + jitter
            let remainder = hue.truncatingRemainder(dividingBy: 1)
            return remainder < 0 ? remainder + 1 : remainder
        }
        hues.shuffle()
        return hues
    }

}

extension Notification.Name {
    static let sakuraCordThemeDidCommit = Notification.Name(
        "dev.sakuracord.theme-did-commit"
    )
}

extension SakuraCordGradientTheme {
    @MainActor
    func colors(for colorScheme: ColorScheme) -> [Color] {
        // Interface color cues stay vivid while brightness remains exclusive
        // to the resulting theme surface.
        let interfaceTheme = SakuraCordGradientTheme(
            colors: colors,
            activeColorCount: activeColorCount,
            intensity: intensity,
            brightness: 1
        )
        return interfaceTheme.activeColors.map {
            interfaceTheme.renderedColor($0, for: colorScheme)
        }
    }

    @MainActor
    func backgroundColors(for colorScheme: ColorScheme) -> [Color] {
        let appearance: SakuraCordThemeAppearance = colorScheme == .dark ? .dark : .light
        return activeColors.map {
            let rgb = backgroundTintRGB($0, for: appearance)
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
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
        let linearColors = colors.enumerated().map { index, color in
            color.opacity(opacity * theme.stopOpacityScale(at: index))
        }
        let radialColor = colors.last ?? .clear

        ZStack {
            Color(nsColor: .windowBackgroundColor)
            theme.surfaceTargetColor(for: colorScheme)
                .opacity(theme.intensityProgress)

            LinearGradient(
                colors: linearColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [radialColor.opacity(opacity * 0.48), .clear],
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
