import AppKit
import SwiftUI

/// The red of the app's mention badges and counts, for anything that should
/// read as the same red.
enum MentionRed {
    static let hex: UInt32 = 0xF23F43

    static let nsColor = NSColor(hex: hex)
    static let color = Color(hex: hex)
}
