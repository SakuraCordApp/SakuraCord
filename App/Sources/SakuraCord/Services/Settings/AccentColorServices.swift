import AppKit
import Darwin
import Observation
import SwiftUI

nonisolated enum AccentColorChoice: String, CaseIterable, Identifiable, Sendable {
    case blurple
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case gray

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .blurple:
            LocalizedStringResource("Blurple", bundle: #bundle)
        case .blue:
            LocalizedStringResource("Blue", bundle: #bundle)
        case .purple:
            LocalizedStringResource("Purple", bundle: #bundle)
        case .pink:
            LocalizedStringResource("Pink", bundle: #bundle)
        case .red:
            LocalizedStringResource("Red", bundle: #bundle)
        case .orange:
            LocalizedStringResource("Orange", bundle: #bundle)
        case .yellow:
            LocalizedStringResource("Yellow", bundle: #bundle)
        case .green:
            LocalizedStringResource("Green", bundle: #bundle)
        case .gray:
            LocalizedStringResource("Graphite", bundle: #bundle)
        }
    }
}

@MainActor
extension AccentColorChoice {
    var color: Color {
        Color(nsColor: nsColor)
    }

    var effectiveColor: Color {
        Color(nsColor: effectiveNSColor)
    }

    var effectiveNSColor: NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.controlAccentColor
            appearance.performAsCurrentDrawingAppearance {
                result = NSTintConfiguration(preferredColor: nsColor)
                    .equivalentContentTintColor
                    ?? .controlAccentColor
            }
            return result
        }
    }

    var nsColor: NSColor {
        if let systemColor = SystemAccentPalette.accentColor(for: self) {
            return systemColor
        }
        return switch self {
        case .blurple:
            Self.paletteColor(0x58, 0x65, 0xF2)
        case .blue:
            Self.paletteColor(0x00, 0x7A, 0xFF)
        case .purple:
            Self.adaptivePaletteColor(
                light: PaletteColorComponents(red: 0x95, green: 0x3D, blue: 0x96),
                dark: PaletteColorComponents(red: 0xA5, green: 0x50, blue: 0xA7)
            )
        case .pink:
            Self.paletteColor(0xF7, 0x4F, 0x9E)
        case .red:
            Self.adaptivePaletteColor(
                light: PaletteColorComponents(red: 0xE0, green: 0x38, blue: 0x3E),
                dark: PaletteColorComponents(red: 0xFF, green: 0x52, blue: 0x57)
            )
        case .orange:
            Self.paletteColor(0xF7, 0x82, 0x1B)
        case .yellow:
            Self.adaptivePaletteColor(
                light: PaletteColorComponents(red: 0xFF, green: 0xC7, blue: 0x26),
                dark: PaletteColorComponents(red: 0xFF, green: 0xC6, blue: 0x00)
            )
        case .green:
            Self.paletteColor(0x62, 0xBA, 0x46)
        case .gray:
            Self.adaptivePaletteColor(
                light: PaletteColorComponents(red: 0x98, green: 0x98, blue: 0x98),
                dark: PaletteColorComponents(red: 0x8C, green: 0x8C, blue: 0x8C)
            )
        }
    }

    private static func paletteColor(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    private static func adaptivePaletteColor(
        light: PaletteColorComponents,
        dark: PaletteColorComponents
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let components = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
            let red = CGFloat(components.red) / 255
            let green = CGFloat(components.green) / 255
            let blue = CGFloat(components.blue) / 255

            return NSColor(
                srgbRed: red,
                green: green,
                blue: blue,
                alpha: 1
            )
        }
    }
}

private struct PaletteColorComponents {
    let red: Int
    let green: Int
    let blue: Int
}

@MainActor
enum SystemAccentPalette {
    // These AppKit providers back the system accent and highlight palettes. Reading
    // them at resolution time preserves AppKit's current appearance/accessibility variants.
    private typealias ImageProvider = @convention(c) (Int) -> Unmanaged<NSImage>?
    private typealias IntegerProvider = @convention(c) (Int) -> Int
    private typealias ColorProvider = @convention(c) (Int) -> Unmanaged<NSColor>?
    private typealias BooleanProvider = @convention(c) () -> Bool

    private static let imageProvider = function(
        named: "NSColorBaseDisplayImageForUserAccentKey",
        as: ImageProvider.self
    )
    private static let highlightKeyProvider = function(
        named: "NSUserHighlightColorForUserAccentKey",
        as: IntegerProvider.self
    )
    private static let highlightColorProvider = function(
        named: "NSColorDisplayColorForUserHighlightKey",
        as: ColorProvider.self
    )
    private static let multicolorProvider = function(
        named: "NSColorControlAccentIsMulticolor",
        as: BooleanProvider.self
    )

    private static let systemAccentColorSelectors = [
        "controlAccentRedColor",
        "controlAccentOrangeColor",
        "controlAccentYellowColor",
        "controlAccentGreenColor",
        "controlAccentBlueColor",
        "controlAccentPurpleColor",
        "controlAccentPinkColor",
    ]

    private static func function<T>(named name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            name
        ) else {
            return nil
        }

        return unsafeBitCast(symbol, to: type)
    }

    static func image(for choice: AccentColorChoice, refresh: UInt64) -> NSImage? {
        _ = refresh
        guard let systemAccentKey = choice.systemAccentKey else { return nil }
        return imageProvider?(systemAccentKey)?.takeUnretainedValue()
    }

    static func accentColor(for choice: AccentColorChoice) -> NSColor? {
        let selectorName: String
        switch choice {
        case .blurple:
            return nil
        case .gray:
            selectorName = "controlAccentNoColor"
        case .red, .orange, .yellow, .green, .blue, .purple, .pink:
            guard let systemAccentKey = choice.systemAccentKey,
                  systemAccentColorSelectors.indices.contains(systemAccentKey)
            else { return nil }
            selectorName = systemAccentColorSelectors[systemAccentKey]
        }

        let selector = NSSelectorFromString(selectorName)
        let colorClass = NSColor.self as AnyObject
        guard colorClass.responds(to: selector) else { return nil }
        return colorClass.perform(selector)?.takeUnretainedValue() as? NSColor
    }

    static func allowsPreferredAccentColor(refresh: UInt64) -> Bool {
        _ = refresh
        if let multicolorProvider {
            return multicolorProvider()
        }

        var allowsPreferredAccentColor = true
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let first = NSTintConfiguration(preferredColor: .systemRed)
                .equivalentContentTintColor?
                .usingColorSpace(.sRGB)
            let second = NSTintConfiguration(preferredColor: .systemGreen)
                .equivalentContentTintColor?
                .usingColorSpace(.sRGB)
            if let first, let second {
                allowsPreferredAccentColor = first != second
            }
        }
        return allowsPreferredAccentColor
    }

    static func textSelectionBackgroundColor(for choice: AccentColorChoice) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.selectedTextBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                guard allowsPreferredAccentColor(refresh: 0) else { return }
                if let systemAccentKey = choice.systemAccentKey,
                   let highlightKeyProvider,
                   let highlightColorProvider,
                   let color = highlightColorProvider(
                       highlightKeyProvider(systemAccentKey)
                   )?.takeUnretainedValue()
                {
                    result = color
                } else if choice == .blurple {
                    result = derivedCustomHighlightColor(
                        for: choice.nsColor,
                        appearance: appearance
                    )
                }
            }
            return result
        }
    }

    private static func derivedCustomHighlightColor(
        for accentColor: NSColor,
        appearance: NSAppearance
    ) -> NSColor {
        guard let target = accentColor.usingColorSpace(.sRGB),
              let highlightKeyProvider,
              let highlightColorProvider
        else {
            return verifiedBlurpleHighlightColor(for: appearance)
        }

        // AppKit doesn't expose a public runtime custom-accent highlight transform.
        // Infer its current per-channel transform from AppKit's own accent/highlight pairs.
        let samples: [(accent: NSColor, highlight: NSColor)] = systemAccentColorSelectors
            .enumerated().compactMap { index, name -> (accent: NSColor, highlight: NSColor)? in
            let selector = NSSelectorFromString(name)
            let colorClass = NSColor.self as AnyObject
            guard colorClass.responds(to: selector),
                let accent = colorClass
                .perform(selector)?
                .takeUnretainedValue() as? NSColor,
                let resolvedAccent = accent.usingColorSpace(.sRGB),
                let highlight = highlightColorProvider(
                    highlightKeyProvider(index)
                )?.takeUnretainedValue().usingColorSpace(.sRGB)
            else {
                return nil
            }
            return (accent: resolvedAccent, highlight: highlight)
        }
        guard samples.count == systemAccentColorSelectors.count else {
            return verifiedBlurpleHighlightColor(for: appearance)
        }

        let red = derivedHighlightComponent(
            target: target.redComponent,
            samples: samples.map { ($0.accent.redComponent, $0.highlight.redComponent) }
        )
        let green = derivedHighlightComponent(
            target: target.greenComponent,
            samples: samples.map { ($0.accent.greenComponent, $0.highlight.greenComponent) }
        )
        let blue = derivedHighlightComponent(
            target: target.blueComponent,
            samples: samples.map { ($0.accent.blueComponent, $0.highlight.blueComponent) }
        )
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func derivedHighlightComponent(
        target: CGFloat,
        samples: [(accent: CGFloat, highlight: CGFloat)]
    ) -> CGFloat {
        let count = CGFloat(samples.count)
        let meanAccent = samples.reduce(0) { $0 + $1.accent } / count
        let meanHighlight = samples.reduce(0) { $0 + $1.highlight } / count
        let variance = samples.reduce(0) {
            $0 + pow($1.accent - meanAccent, 2)
        }
        guard variance > 0 else { return meanHighlight }
        let covariance = samples.reduce(0) {
            $0 + ($1.accent - meanAccent) * ($1.highlight - meanHighlight)
        }
        let value = covariance / variance * (target - meanAccent) + meanHighlight
        return min(max((value * 255).rounded(), 0), 255) / 255
    }

    private static func verifiedBlurpleHighlightColor(for appearance: NSAppearance) -> NSColor {
        // Last-resort values measured from a native app whose asset accent is #5865F2.
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 89.0 / 255, green: 93.0 / 255, blue: 135.0 / 255, alpha: 1)
            : NSColor(srgbRed: 205.0 / 255, green: 209.0 / 255, blue: 251.0 / 255, alpha: 1)
    }
}

private extension AccentColorChoice {
    var systemAccentKey: Int? {
        switch self {
        case .blurple:
            nil
        case .gray:
            -1
        case .red:
            0
        case .orange:
            1
        case .yellow:
            2
        case .green:
            3
        case .blue:
            4
        case .purple:
            5
        case .pink:
            6
        }
    }
}

@MainActor
@Observable
private final class SakuraCordAccentColorState {
    static let shared = SakuraCordAccentColorState()

    var selection = AppearanceSettingsStore.shared.load().accentColor
}

@MainActor
enum SakuraCordAccentColor {
    private static var state: SakuraCordAccentColorState { .shared }

    static var selection: AccentColorChoice { state.selection }

    static var color: Color {
        selection.effectiveColor
    }

    static var nsColor: NSColor {
        selection.effectiveNSColor
    }

    static var textSelectionNSColor: NSColor {
        SystemAccentPalette.textSelectionBackgroundColor(for: selection)
    }

    static func apply(_ selection: AccentColorChoice) {
        state.selection = selection
    }
}

@MainActor
extension NSColor {
    static var sakuraCordAccentColor: NSColor {
        SakuraCordAccentColor.nsColor
    }

    static var sakuraCordTextSelectionBackgroundColor: NSColor {
        SakuraCordAccentColor.textSelectionNSColor
    }
}
