// Stand-ins for macOS 27 SDK APIs so the app builds with Xcode 26.
// Skipped automatically when building with Xcode 27 (Swift 6.4).
#if !compiler(>=6.4)
import AppKit
import SwiftUI

enum MenuItemImageVisibilityCompat {
    case automatic, visible, hidden
}

extension NSMenuItem {
    // macOS 26 has no per-item override; menus use the system default.
    var preferredImageVisibility: MenuItemImageVisibilityCompat {
        get { .automatic }
        set {}
    }
}

extension NSGlassEffectView {
    // macOS 26 glass can't react to clicks; the button still works.
    var effectIsInteractive: Bool {
        get { false }
        set {}
    }
}

extension PickerStyle where Self == SegmentedPickerStyle {
    // The macOS 27 tab picker falls back to a segmented control.
    static var tabs: SegmentedPickerStyle { .segmented }
}

extension NSWindow {
    nonisolated struct DidEnterFullScreenMessage: NotificationCenter.MainActorMessage {
        typealias Subject = NSWindow
        static var name: Notification.Name { NSWindow.didEnterFullScreenNotification }
        static func makeMessage(_ notification: Notification) -> Self? { Self() }
    }

    nonisolated struct DidExitFullScreenMessage: NotificationCenter.MainActorMessage {
        typealias Subject = NSWindow
        static var name: Notification.Name { NSWindow.didExitFullScreenNotification }
        static func makeMessage(_ notification: Notification) -> Self? { Self() }
    }
}
#endif
