import AppKit
import SwiftUI

@MainActor
enum SakuraCordAccentColor {
    /// The system accent, so custom accent drawing matches native controls.
    static var color: Color {
        Color(nsColor: nsColor)
    }

    static var nsColor: NSColor {
        AppAccentColorController.shared.accent
    }

    /// Custom focus outlines, drawn in the colour of AppKit's focus ring.
    static var focusRing: Color {
        Color(nsColor: .keyboardFocusIndicatorColor)
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
}
