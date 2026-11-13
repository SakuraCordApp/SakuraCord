import SwiftUI

nonisolated enum ChatChromeMetrics {
    static let sidebarSpring = Spring.smooth(duration: 0.24)
    static var controlHeight: CGFloat { InterfaceScale.metric(48) }
    /// The input bar grows with the message text it holds and stays a capsule.
    static var composerControlHeight: CGFloat { composerMetric(36) }
    static var composerCornerRadius: CGFloat { composerControlHeight / 2 }
    static var composerTextVerticalInset: CGFloat { composerMetric(9) }
    static var composerTextLeadingInset: CGFloat { composerMetric(11) }
    /// Modal text fields hold interface text, so they keep the input bar's
    /// default radius at every message font size.
    static var modalFieldCornerRadius: CGFloat { InterfaceScale.metric(18) }
    /// Buttons beside and inside the input bar keep the interface size, so a
    /// larger message font doesn't take typing width from narrow panes.
    static var composerButtonSize: CGFloat { InterfaceScale.metric(36) }
    static var composerAccessoryButtonSize: CGFloat { InterfaceScale.metric(32) }
    static var composerAccessoryEdgeInset: CGFloat {
        (composerButtonSize - composerAccessoryButtonSize) / 2
    }
    static var composerSegmentSpacing: CGFloat { InterfaceScale.metric(8) }
    static var controlCornerRadius: CGFloat { InterfaceScale.metric(16) }
    static var serverRailWidth: CGFloat { InterfaceScale.metric(68) }
    /// The window controls are fixed-size system chrome, so the sidebar title
    /// stays clear of them and centred on their line at every interface size.
    static var sidebarTitleLeadingOffset: CGFloat {
        max(92, serverRailWidth + InterfaceScale.metric(24))
    }
    static let sidebarTitleCenterY: CGFloat = 25

    /// The workspace minimum grows with the interface size so the chat column
    /// keeps its default share at the narrowest width, within the screen.
    @MainActor
    static var windowMinimumSize: CGSize {
        CGSize(
            width: InterfaceScale.windowLength(860, axis: .horizontal),
            height: InterfaceScale.windowLength(560, axis: .vertical)
        )
    }

    /// Kept on the half-point grid, like `InterfaceScale.metric`, so the bar's
    /// edges stay crisp at every font size.
    private static func composerMetric(_ value: CGFloat) -> CGFloat {
        (InterfaceScale.metric(InterfaceTypographyMetrics.messageLength(value)) * 2).rounded() / 2
    }

    static func sidebarTitleTopOffset(height: CGFloat) -> CGFloat {
        sidebarTitleCenterY - height / 2
    }
    static var sidebarContentCornerRadius: CGFloat { InterfaceScale.metric(16) }
    static var composerWindowInset: CGFloat { InterfaceScale.metric(12) }
    /// Only a fallback for layouts where the composer isn't adjacent to a
    /// rounded container corner. macOS resolves the actual aligned radius.
    static var composerMinimumCornerRadius: CGFloat { InterfaceScale.metric(12) }
    static var channelListTopPadding: CGFloat { InterfaceScale.metric(10) }
    static var memberListWidth: CGFloat { InterfaceScale.metric(280) }
    /// A side chat pane's narrowest width; the workspace's column placement
    /// and width path read it as the pane itself does.
    static var sideConversationMinimumWidth: CGFloat { InterfaceScale.metric(340) }
    /// Native toolbar search keeps its own outer item margin. An eight-point
    /// field inset centers the visible glass inside the fixed inspector pane.
    static var toolbarPaneEdgeInset: CGFloat { InterfaceScale.metric(8) }
    /// The window toolbar's own edge margin. Toolbar items keep system sizing,
    /// so a pane title uses the same unscaled inset from the pane edge.
    static let toolbarItemEdgeInset: CGFloat = 8
    /// System toolbar metrics that bound a pane title before it is measured.
    static let toolbarIconButtonWidth: CGFloat = 37
    static let toolbarTitleActionSpacing: CGFloat = 8
    static var toolbarSearchMaximumFieldWidth: CGFloat {
        memberListWidth - (toolbarPaneEdgeInset * 2)
    }
    static var emojiPickerWidth: CGFloat { InterfaceScale.metric(520) }
    static var pickerSearchHeaderHeight: CGFloat { InterfaceScale.metric(48) }
    static var pickerSearchHeaderInset: CGFloat { InterfaceScale.metric(15) }
    static var pickerSearchHeaderSpacing: CGFloat { InterfaceScale.metric(9) }
    static let pickerSearchHeaderIconSize: CGFloat = 14
    static let pickerSearchHeaderFontSize: CGFloat = 15
}

nonisolated enum ChatDetailLayoutPolicy {
    static var timelineTopPadding: CGFloat { InterfaceScale.metric(12) }
    static var timelineBottomPadding: CGFloat { InterfaceScale.metric(12) }
    /// The former SwiftUI scroll view retained its seven-point soft-edge
    /// overlap in addition to the stack padding when a width reflow exposed
    /// the first intersecting row.
    static var timelineWidthReflowTopInset: CGFloat {
        timelineTopPadding + InterfaceScale.metric(7)
    }
    static var newMessagesButtonSpacing: CGFloat { InterfaceScale.metric(10) }
    static var defaultFloatingFooterHeight: CGFloat {
        ChatChromeMetrics.composerControlHeight + InterfaceScale.metric(12 + 18)
    }

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
