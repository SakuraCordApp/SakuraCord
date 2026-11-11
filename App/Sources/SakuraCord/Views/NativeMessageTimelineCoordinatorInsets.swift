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
            let wasNearBottom = lastReportedState?.isNearBottom ?? scrollState().isNearBottom
            let anchor = wasAtTop || wasNearBottom ? nil : visibleAnchor()
            isApplyingUpdate = true
            updateInsets()
            if wasAtTop || wasNearBottom {
                let keepsTop = wasAtTop && (!wasNearBottom || parent.conversation.alignsUnderfilledContentToTop)
                scroll(toDocumentY: keepsTop ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude, scrollView: scrollView)
            } else if let anchor {
                restore(anchor)
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
            let contentInsets = scrollView.contentInsets
            if contentInsets.top != 0
                || contentInsets.left != 0
                || contentInsets.bottom != 0
                || contentInsets.right != 0
            {
                scrollView.contentInsets = NSEdgeInsets()
            }
            let showsVerticalScroller =
                scrollableDocumentHeight > viewportHeight + 0.5
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
