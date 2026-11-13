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

    /// Text and symbols drawn on an accent fill. Like Tahoe's own controls,
    /// labels stay white until the fill is light enough (relative luminance
    /// above 0.5) that black reads better.
    static var labelOnFillNSColor: NSColor {
        labelNSColor(on: nsColor)
    }

    static func labelNSColor(on fill: NSColor) -> NSColor {
        let fill = fill.usingColorSpace(.sRGB) ?? fill
        let rgb = SakuraCordThemeRGB(red: fill.redComponent, green: fill.greenComponent, blue: fill.blueComponent)
        return rgb.relativeLuminance > 0.5 ? .black : .white
    }

    static var labelOnFill: Color {
        Color(nsColor: labelOnFillNSColor)
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

    static var sakuraCordLabelOnAccentColor: NSColor {
        SakuraCordAccentColor.labelOnFillNSColor
    }
}
