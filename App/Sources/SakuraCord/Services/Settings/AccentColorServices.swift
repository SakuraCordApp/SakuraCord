import AppKit
import SwiftUI

nonisolated enum SakuraCordAccentColor {
    static var color: Color {
        Color(nsColor: nsColor)
    }

    static var nsColor: NSColor {
        SakuraCordThemeStore.accentNSColor(theme: committedTheme)
    }

    /// On main, the shared store's theme, so SwiftUI views reading an accent
    /// observe theme changes; off main, as the row painter reads it, its
    /// snapshot.
    private static var committedTheme: SakuraCordGradientTheme {
        guard Thread.isMainThread else {
            return SakuraCordThemeStore.committedThemeSnapshot.withLock { $0 }
        }
        return MainActor.assumeIsolated { SakuraCordThemeStore.shared.committedTheme }
    }

    static var textSelectionNSColor: NSColor {
        SakuraCordThemeStore.textSelectionNSColor(theme: committedTheme)
    }

    static func color(forRoleColorHex colorHex: UInt32?) -> Color {
        guard !usesAccentFallback(forRoleColorHex: colorHex), let colorHex else {
            return color
        }
        return Color(nsColor: SakuraCordThemeStore.roleNSColor(for: colorHex, theme: committedTheme))
    }

    static func nsColor(forRoleColorHex colorHex: UInt32?) -> NSColor {
        guard !usesAccentFallback(forRoleColorHex: colorHex), let colorHex else {
            return nsColor
        }
        return SakuraCordThemeStore.roleNSColor(for: colorHex, theme: committedTheme)
    }

    static func usesAccentFallback(forRoleColorHex colorHex: UInt32?) -> Bool {
        colorHex == nil || colorHex == 0
    }
}

nonisolated extension NSColor {
    convenience init(_ color: SakuraCordThemeRGB) {
        self.init(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        )
    }

    static var sakuraCordAccentColor: NSColor {
        SakuraCordAccentColor.nsColor
    }

    static var sakuraCordTextSelectionBackgroundColor: NSColor {
        SakuraCordAccentColor.textSelectionNSColor
    }
}
