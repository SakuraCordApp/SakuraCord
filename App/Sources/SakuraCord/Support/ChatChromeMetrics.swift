import SwiftUI

nonisolated enum ChatChromeMetrics {
    static let controlHeight: CGFloat = 48
    static let composerControlHeight: CGFloat = 36
    static let composerCornerRadius = composerControlHeight / 2
    static let composerTextVerticalInset: CGFloat = 9
    static let composerAccessoryButtonSize: CGFloat = 32
    static let composerAccessoryEdgeInset: CGFloat =
        (composerControlHeight - composerAccessoryButtonSize) / 2
    static let composerSegmentSpacing: CGFloat = 8
    static let controlCornerRadius: CGFloat = 16
    static let serverRailWidth: CGFloat = 68
    static let sidebarTitleLeadingOffset: CGFloat = serverRailWidth + 24
    static let sidebarTitleTopOffset: CGFloat = 11
    static let sidebarContentCornerRadius: CGFloat = 16
    static let composerWindowInset: CGFloat = 12
    /// Only a fallback for layouts where the composer isn't adjacent to a
    /// rounded container corner. macOS resolves the actual aligned radius.
    static let composerMinimumCornerRadius: CGFloat = 12
    static let channelListTopPadding: CGFloat = 10
    static let memberListWidth: CGFloat = 280
    static let emojiPickerWidth: CGFloat = 520
}

nonisolated enum ChatDetailLayoutPolicy {
    static let timelineTopPadding: CGFloat = 12
    static let timelineBottomPadding: CGFloat = 12
    /// The former SwiftUI scroll view retained its seven-point soft-edge
    /// overlap in addition to the stack padding when a width reflow exposed
    /// the first intersecting row.
    static let timelineWidthReflowTopInset: CGFloat =
        timelineTopPadding + 7
    static let newMessagesButtonSpacing: CGFloat = 10
    static let defaultFloatingFooterHeight: CGFloat =
        ChatChromeMetrics.composerControlHeight + 12 + 18

    static func bottomContentInset(measuredFooterHeight: CGFloat) -> CGFloat {
        guard measuredFooterHeight.isFinite else { return defaultFloatingFooterHeight }
        return max(defaultFloatingFooterHeight, measuredFooterHeight)
    }

    static func timelineMinimumContentHeight(viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight)
    }

    static func newMessagesButtonBottomPadding(bottomContentInset: CGFloat) -> CGFloat {
        max(0, bottomContentInset) + newMessagesButtonSpacing
    }
}
