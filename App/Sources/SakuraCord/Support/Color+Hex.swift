import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// The red of leaving a call and of a failed or lost connection.
    static let leaveCallRed = Color(hex: 0xDA373C)
}

extension NSColor {
    /// An opaque sRGB colour from 0xRRGGBB.
    nonisolated convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A role or accent colour as Discord sends it, where 0 means none.
    nonisolated convenience init?(discordColor value: UInt32?) {
        guard let value, value != 0 else { return nil }
        self.init(hex: value)
    }
}
