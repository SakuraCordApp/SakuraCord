import SwiftUI

/// Which column of the conversation workspace a view fills.
nonisolated enum WorkspaceColumn: LayoutValueKey {
    case conversation
    case sideConversation
    case inspector

    static let defaultValue = WorkspaceColumn.conversation
}

/// Lays out the conversation, a side chat and the inspector in a row, like
/// an `HStack`, except that a full-width side chat covers the conversation
/// instead of sharing the row. The side chat keeps its identity, timeline
/// and scroll position when it moves between the pane and full width.
///
/// The layout reads what each column should be from its parameters rather
/// than from which subviews exist, because a column that is sliding away is
/// still a subview until it has left. While a motion runs, two animatable
/// widths drive it on every frame: how much of the trailing edge the moving
/// columns cover, which the conversation gives up live, and a widening side
/// chat's width. Only the conversation and a widening side chat lay out
/// again per frame; the columns themselves slide as offsets.
nonisolated struct WorkspaceColumnsLayout: Layout {
    var showsSideConversation: Bool
    var sideConversationIsFullWidth: Bool
    var showsInspector: Bool
    /// The pane's width when it was last beside the conversation.
    var paneWidth: CGFloat
    /// The inspector's width when it was last measured.
    var measuredInspectorWidth: CGFloat = 0
    /// How much of the trailing edge moving columns cover, or a negative
    /// value at rest.
    var coveredWidth: CGFloat = -1
    /// A widening side chat's width, or a negative value at rest.
    var wideningWidth: CGFloat = -1

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(coveredWidth, wideningWidth) }
        set {
            coveredWidth = newValue.first
            wideningWidth = newValue.second
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let height = bounds.height
        let conversation = subviews.filter { $0[WorkspaceColumn.self] == .conversation }
        let sideConversations = subviews.filter { $0[WorkspaceColumn.self] == .sideConversation }
        let inspectors = subviews.filter { $0[WorkspaceColumn.self] == .inspector }

        // While a motion runs, every frame lays the columns out again; their
        // widths are known, and measuring them each time cost most of a frame.
        let isMoving = coveredWidth >= 0
        let inspectorWidths = inspectors.map {
            isMoving && measuredInspectorWidth > 0
                ? measuredInspectorWidth
                : $0.sizeThatFits(ProposedViewSize(width: nil, height: height)).width
        }
        let inspectorWidth = showsInspector ? inspectorWidths.last ?? 0 : 0

        var paneWidth = paneWidth
        if !isMoving || paneWidth <= 0, showsSideConversation, !sideConversationIsFullWidth,
           let pane = sideConversations.last
        {
            let conversationMinimum = conversation.map {
                $0.sizeThatFits(ProposedViewSize(width: 0, height: height)).width
            }.max() ?? 0
            // As an HStack does, give the pane its widest size the
            // conversation's minimum width leaves room for.
            let available = max(0, bounds.width - inspectorWidth - conversationMinimum)
            paneWidth = pane.sizeThatFits(ProposedViewSize(width: available, height: height)).width
        }
        let trailingWidth = coveredWidth >= 0
            ? coveredWidth
            : inspectorWidth + (showsSideConversation && !sideConversationIsFullWidth ? paneWidth : 0)

        // A full-width side chat covers the conversation, which keeps the
        // width it had beside the pane while the side chat widens over it.
        let conversationWidth = sideConversationIsFullWidth
            ? max(0, bounds.width - paneWidth)
            : max(0, bounds.width - trailingWidth)
        for view in conversation {
            place(view, minX: bounds.minX, width: conversationWidth, in: bounds)
        }
        for view in sideConversations {
            if showsSideConversation, sideConversationIsFullWidth {
                let trailingEdge = bounds.maxX - (coveredWidth >= 0 ? coveredWidth : inspectorWidth)
                let width = wideningWidth >= 0 ? wideningWidth : trailingEdge - bounds.minX
                place(view, minX: trailingEdge - width, width: width, in: bounds)
            } else {
                // A pane keeps its width at the trailing edge, beneath any
                // inspector arriving in its place as it leaves.
                let trailingEdge = showsSideConversation ? bounds.maxX - inspectorWidth : bounds.maxX
                place(view, minX: trailingEdge - paneWidth, width: paneWidth, in: bounds)
            }
        }
        for (view, width) in zip(inspectors, inspectorWidths) {
            place(view, minX: bounds.maxX - width, width: width, in: bounds)
        }
    }

    private func place(_ view: LayoutSubview, minX: CGFloat, width: CGFloat, in bounds: CGRect) {
        view.place(
            at: CGPoint(x: minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}
