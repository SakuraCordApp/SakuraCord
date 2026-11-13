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

    /// Text and symbols drawn on the accent itself.
    static var labelOnFillNSColor: NSColor {
        AppAccentColorController.shared.labelOnAccent
    }

    static var labelOnFill: Color {
        Color(nsColor: labelOnFillNSColor)
    }

    /// Labels on a fill are white, as on macOS's own accent controls, unless
    /// white would fall below 3:1 against it (WCAG's minimum for UI
    /// components and large text); then they're black.
    nonisolated static func labelNSColor(on fill: SakuraCordThemeRGB) -> NSColor {
        fill.contrastRatio(with: .white) < 3 ? .black : .white
    }

    /// The label for `fill` as it's drawn in each appearance: a translucent
    /// fill, such as a faint glass tint, is measured over the window background.
    static func labelNSColor(on fill: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var label = NSColor.white
            appearance.performAsCurrentDrawingAppearance {
                func rgb(_ color: NSColor) -> SakuraCordThemeRGB {
                    let color = color.usingColorSpace(.sRGB) ?? color
                    return SakuraCordThemeRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
                }
                let drawn = rgb(fill).composited(over: rgb(.windowBackgroundColor), opacity: fill.alphaComponent)
                label = labelNSColor(on: drawn)
            }
            return label
        }
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
