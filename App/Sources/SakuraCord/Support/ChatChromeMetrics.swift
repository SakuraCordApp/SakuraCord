import SwiftUI

nonisolated enum ChatChromeMetrics {
    static let controlHeight: CGFloat = 48
    static let controlCornerRadius: CGFloat = 16
    static let serverRailWidth: CGFloat = 68
    static let sidebarTitleLeadingOffset: CGFloat = serverRailWidth + 24
    static let sidebarTitleTopOffset: CGFloat = 11
    static let sidebarContentCornerRadius: CGFloat = 20
    static let channelListTopPadding: CGFloat = 12
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
        ChatChromeMetrics.controlHeight + 12 + 18

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
