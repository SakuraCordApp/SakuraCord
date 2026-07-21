import SwiftUI

nonisolated enum ChatChromeMetrics {
    static let controlHeight: CGFloat = 48
    static let controlCornerRadius: CGFloat = 16
    static let serverRailWidth: CGFloat = 68
    static let sidebarIdentityLeadingOffset: CGFloat = serverRailWidth + 24
    static let memberListWidth: CGFloat = 280
    static let emojiPickerWidth: CGFloat = 520
}

nonisolated enum ChatDetailLayoutPolicy {
    static let timelineVerticalPadding: CGFloat = 12
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
