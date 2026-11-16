import AppKit

/// How the timeline pads its content around the window toolbar and the bars
/// over it, and keeps the reader in place when that padding changes.
extension NativeMessageTimelineCoordinator {
    /// Applies a change in the height the window toolbar covers, such
    /// as entering or leaving full screen, without moving the reader.
    /// The new top padding shifts every row, so the visible anchor is
    /// restored afterwards, as a resize does; the top and end stay put,
    /// and a timeline at both keeps the end its short content rests at.
    func updateInsetsForToolbarObscuredHeightChange() {
        guard let scrollView, !isApplyingUpdate,
              initialPositionConversation == parent.conversation
        else {
            updateInsets()
            return
        }
        let wasAtTop = scrollView.contentView.bounds.minY <= clampedDocumentY(-.greatestFiniteMagnitude, scrollView: scrollView) + 0.5
        isApplyingUpdate = true
        if wasAtTop {
            let wasNearBottom = lastReportedState?.isNearBottom ?? scrollState().isNearBottom
            let keepsTop = !wasNearBottom || parent.conversation.alignsUnderfilledContentToTop
            updateInsets()
            scroll(toDocumentY: keepsTop ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude, scrollView: scrollView)
        } else {
            preservingReadingPosition { updateInsets() }
        }
        positionViewportCanvas()
        isApplyingUpdate = false
        reportScrollState(force: true)
    }

    func updateInsets() {
        guard let scrollView, let canvas else { return }
        let viewportHeight = scrollView.contentView.bounds.height
        canvas.updateContentOriginY(
            contentOriginY(viewportHeight: viewportHeight),
            minimumHeight: max(1, viewportHeight),
            bottomSpacerHeight:
                bottomInset + trailingHistoryReserve
        )
        canvas.bottomObscuredHeight = parent.bottomContentInset
        let contentInsets = scrollView.contentInsets
        if contentInsets.top != 0
            || contentInsets.left != 0
            || contentInsets.bottom != 0
            || contentInsets.right != 0
        {
            scrollView.contentInsets = NSEdgeInsets()
        }
        updateVerticalScroller(of: scrollView, documentHeight: scrollableDocumentHeight, viewportHeight: viewportHeight)
    }

    /// Shows the scroller only while the document is taller than the viewport.
    func updateVerticalScroller(of scrollView: NSScrollView, documentHeight: CGFloat, viewportHeight: CGFloat) {
        let showsVerticalScroller = documentHeight > viewportHeight + 0.5
        if scrollView.hasVerticalScroller != showsVerticalScroller {
            scrollView.hasVerticalScroller = showsVerticalScroller
        }
    }

    var bottomInset: CGFloat {
        parent.bottomContentInset
            + ChatDetailLayoutPolicy.timelineBottomPadding
    }

    func contentOriginY(viewportHeight: CGFloat) -> CGFloat {
        // Content scrolls beneath the window toolbar but rests below it.
        let topPadding = ChatDetailLayoutPolicy.timelineTopPadding
            + (scrollView?.scrollerInsets.top ?? 0)
        let topInset = if parent.conversation.alignsUnderfilledContentToTop {
            topPadding
        } else {
            NativeMessageTimelineLayoutPolicy.shortContentTopInset(
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                bottomInset: bottomInset,
                verticalPadding: topPadding
            )
        }
        return leadingHistoryReserve
            + topInset
    }
}
