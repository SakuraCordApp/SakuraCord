import AppKit
import SwiftUI

/// The app-owned motion the reader can turn off in Settings > Accessibility.
nonisolated enum AppMotionCategory: Sendable {
    /// The channel sidebar, the member list, and search results beside the
    /// conversation.
    case sidebar
    /// Side chat panes opening, closing and swapping, and full width.
    case sideChats
    /// Search, popovers, menus and overlays.
    case overlays
}

/// Answers whether a category of motion plays. macOS Reduce Motion, the
/// master switch and the category's own switch each turn it off, and a
/// motion that does not play snaps, as it does under Reduce Motion.
@MainActor
enum AppMotionPolicy {
    /// The reader's settings, kept by `AppModel`, for AppKit code and views
    /// that present when they are created and have no model at hand. Views
    /// that update with a setting read `AppModel.animates(_:)` instead.
    static var settings = AccessibilitySettingsSnapshot.defaults

    /// Whether `category` plays under the reader's settings.
    static func animates(_ category: AppMotionCategory) -> Bool {
        animates([category], settings: settings)
    }

    /// Whether motion that belongs to no category plays: only macOS Reduce
    /// Motion and the master switch turn it off.
    static var animatesUncategorized: Bool {
        animates([], settings: settings)
    }

    /// Whether every one of `categories` plays under `settings`.
    static func animates(
        _ categories: [AppMotionCategory],
        settings: AccessibilitySettingsSnapshot,
        reducesMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) -> Bool {
        !reducesMotion && !settings.disablesAllAnimations
            && !categories.contains { settings.disablesAnimations($0) }
    }
}

extension AccessibilitySettingsSnapshot {
    /// Whether the category's own switch is on, not counting the master
    /// switch or Reduce Motion.
    nonisolated func disablesAnimations(_ category: AppMotionCategory) -> Bool {
        switch category {
        case .sidebar: disablesSidebarAnimations
        case .sideChats: disablesSideChatAnimations
        case .overlays: disablesOverlayAnimations
        }
    }
}

extension EnvironmentValues {
    /// Whether the reader turned off sidebar motion, or all motion, in the
    /// sidebar column: its views snap as they do under Reduce Motion.
    @Entry var reducesSidebarMotion = false
}
