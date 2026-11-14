import AppKit

enum Pasteboard {
    /// Replaces the general pasteboard's contents with plain text.
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
