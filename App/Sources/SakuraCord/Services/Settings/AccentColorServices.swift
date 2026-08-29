import AppKit
import SwiftUI

@MainActor
enum SakuraCordAccentColor {
    static var color: Color {
        Color(nsColor: nsColor)
    }

    static var nsColor: NSColor {
        SakuraCordThemeStore.shared.accentNSColor()
    }

    static var textSelectionNSColor: NSColor {
        SakuraCordThemeStore.shared.textSelectionNSColor()
    }

    static func color(forRoleColorHex colorHex: UInt32?) -> Color {
        guard !usesAccentFallback(forRoleColorHex: colorHex), let colorHex else {
            return color
        }
        return Color(nsColor: SakuraCordThemeStore.shared.roleNSColor(for: colorHex))
    }

    static func nsColor(forRoleColorHex colorHex: UInt32?) -> NSColor {
        guard !usesAccentFallback(forRoleColorHex: colorHex), let colorHex else {
            return nsColor
        }
        return SakuraCordThemeStore.shared.roleNSColor(for: colorHex)
    }

    static func usesAccentFallback(forRoleColorHex colorHex: UInt32?) -> Bool {
        colorHex == nil || colorHex == 0
    }
}

@MainActor
extension NSColor {
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
