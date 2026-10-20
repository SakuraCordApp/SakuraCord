import AppKit
import SwiftUI

/// Animates the workspace layout changes the reader asks for (opening,
/// closing or widening a side chat, toggling the member list) with the member
/// list's spring. Navigation changes the layout without it and appears at once.
@MainActor
enum WorkspaceLayoutMotion {
    static var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil : .spring(ChatChromeMetrics.sidebarSpring)
    }

    static func perform(_ change: () -> Void) {
        withAnimation(animation, change)
    }
}
