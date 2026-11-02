import AppKit

/// The red of the app's mention badges and counts, for anything that should
/// read as the same red.
enum MentionRed {
    static let hex: UInt32 = 0xF23F43

    static let nsColor = NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}
