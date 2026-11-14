import SwiftUI

/// The soundboard and Activity shelf tiles' surface and hover outline.
enum PickerTileStyle {
    static func surface(_ scheme: ColorScheme, isHovering: Bool) -> Color {
        scheme == .dark
            ? Color(hex: isHovering ? 0x28292C : 0x202023)
            : Color(hex: isHovering ? 0xD8D7DC : 0xE2E1E6)
    }

    static func outline(_ scheme: ColorScheme, isHovering: Bool) -> Color {
        guard isHovering else { return .clear }
        return Color(hex: scheme == .dark ? 0x44454A : 0xAFAEB4)
    }
}
