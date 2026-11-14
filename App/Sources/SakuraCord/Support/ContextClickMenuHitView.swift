import AppKit

/// A transparent overlay that takes only context clicks, so the SwiftUI
/// content beneath keeps every other event.
@MainActor
final class ContextClickMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else {
            return nil
        }
        return event.isContextClick ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}
