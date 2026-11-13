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

    /// Text and symbols drawn on an accent fill, chosen as macOS chooses them
    /// for its own accent-filled controls: white unless the flat fill
    /// colour's relative luminance is above 0.5, then black. The same in
    /// light, dark and Increase Contrast; the material over the fill doesn't
    /// count.
    static var labelOnFillNSColor: NSColor {
        AppAccentColorController.shared.labelOnAccent
    }

    static func labelNSColor(on fill: NSColor) -> NSColor {
        let fill = fill.usingColorSpace(.sRGB) ?? fill
        let rgb = SakuraCordThemeRGB(red: fill.redComponent, green: fill.greenComponent, blue: fill.blueComponent)
        return rgb.relativeLuminance > 0.5 ? .black : .white
    }

    static var labelOnFill: Color {
        Color(nsColor: labelOnFillNSColor)
    }

    static func label(on fill: Color) -> Color {
        Color(nsColor: labelNSColor(on: NSColor(fill)))
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

    /// Resolved when drawn, so cached text layouts follow accent changes.
    static let sakuraCordLabelOnAccentColor = NSColor(name: nil) { _ in
        MainActor.assumeIsolated { SakuraCordAccentColor.labelOnFillNSColor }
    }
}
