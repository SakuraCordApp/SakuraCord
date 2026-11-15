import AppKit
import SakuraCordModels

extension NativeTimelineCanvasView {
    var editingHeightDelta: CGFloat {
        guard let index = editingRowIndex,
              let editingRowHeight = editing.layout?.height
        else { return 0 }
        return editingRowHeight - storage.layouts[index].height
    }

    var transientContentOriginY: CGFloat {
        NativeTimelineTransientRowGeometry.contentOriginY(
            base: baseContentOriginY,
            heightDelta: editingHeightDelta,
            minimum: ChatDetailLayoutPolicy.timelineTopPadding
        )
    }

    var displayedContentHeight: CGFloat {
        contentOriginY
            + NativeTimelineTransientRowGeometry.contentHeight(
                base: contentHeight,
                replacementHeight: editing.layout?.height,
                baseRowHeight: editingRowIndex.map { storage.layouts[$0].height }
            )
            + bottomSpacerHeight
    }

    func displayedRowOrigin(at index: Int) -> CGFloat {
        contentOriginY + rowMotionOffset(at: index) + transientRowOrigin(at: index)
    }

    /// A row's top within the content with the edited row at its editing
    /// height, before any motion.
    func transientRowOrigin(at index: Int) -> CGFloat {
        NativeTimelineTransientRowGeometry.rowOrigin(
            base: rowOrigins[index],
            rowIndex: index,
            replacementIndex: editingRowIndex,
            replacementHeight: editing.layout?.height,
            baseRowHeight: editingRowIndex.map { storage.layouts[$0].height }
        )
    }

    func displayedRowHeight(at index: Int) -> CGFloat {
        NativeTimelineTransientRowGeometry.rowHeight(
            base: layouts[index].height,
            rowIndex: index,
            replacementIndex: editingRowIndex,
            replacementHeight: editing.layout?.height
        ) - rowMotionRemainingHeight(at: index)
    }

    /// Displacement of a row by the running row motions.
    func rowMotionOffset(at index: Int) -> CGFloat {
        guard !rowMotion.steps.isEmpty else { return 0 }
        var lower = 0
        var upper = rowMotion.steps.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rowMotion.steps[middle].index < index { lower = middle + 1 } else { upper = middle }
        }
        return rowMotion.shift - (lower > 0 ? rowMotion.steps[lower - 1].cumulative : 0)
    }

    /// The part of a row's height change that has not happened on screen yet.
    func rowMotionRemainingHeight(at index: Int) -> CGFloat {
        rowMotion.remainingHeights[index] ?? 0
    }

    /// The row with this identifier. `hint` is where it last was.
    func rowIndex(forIdentifier identifier: NativeMessageTimelineItem.Identifier, hint: Int? = nil) -> Int? {
        if let hint, items.indices.contains(hint), items[hint].identifier == identifier { return hint }
        return items.lastIndex { $0.identifier == identifier }
    }

    /// Visits displayed rows intersecting `rect` in index order. Rows hidden
    /// outside an animating gap's or group's clip do not end the walk early.
    func forEachDisplayedRow(in rect: CGRect, _ body: (Int) -> Void) {
        guard !items.isEmpty, var index = rowIndex(at: max(0, rect.minY)) else { return }
        while items.indices.contains(index) {
            let span = visibleRowSpan(at: index)
            if span.lowerBound >= rect.maxY { return }
            if rowMotion.clippedRows.contains(index), span.lowerBound >= clippedRowsMaxY {
                index = rowMotion.clippedRows.upperBound
                continue
            }
            if span.upperBound > span.lowerBound { body(index) }
            index += 1
        }
    }

    /// Clip both ends into the reveal interval, including empty rows. The
    /// resulting spans remain ordered while the surrounding rows move.
    func visibleRowSpan(at index: Int) -> Range<CGFloat> {
        let minY = displayedRowOrigin(at: index)
        let maxY = minY + displayedRowHeight(at: index)
        guard rowMotion.clippedRows.contains(index) else { return minY ..< maxY }
        let clippedMin = min(clippedRowsMaxY, max(clippedRowsMinY, minY))
        let clippedMax = min(clippedRowsMaxY, max(clippedRowsMinY, maxY))
        return clippedMin ..< clippedMax
    }

    func rowFrame(at index: Int) -> CGRect {
        guard items.indices.contains(index) else { return .zero }
        return CGRect(
            x: 0,
            y: displayedRowOrigin(at: index),
            width: bounds.width,
            height: displayedRowHeight(at: index)
        )
    }

    func rowIndex(at documentY: CGFloat) -> Int? {
        guard !rowOrigins.isEmpty else { return nil }
        var lower = 0
        var upper = rowOrigins.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if visibleRowSpan(at: middle).upperBound <= documentY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return items.indices.contains(lower) ? lower : nil
    }

    /// The row under a pointer's y whose item and layout are both present.
    func hitRowIndex(at documentY: CGFloat) -> Int? {
        guard let index = rowIndex(at: documentY), items.indices.contains(index), layouts.indices.contains(index)
        else { return nil }
        return index
    }

    /// The row of the message with this ID.
    func rowIndex(forMessageID messageID: MessageID) -> Int? {
        items.firstIndex { $0.messageID == messageID }
    }

    /// The row under `point`, and `point` in that row's coordinates.
    func rowHit(at point: CGPoint) -> (index: Int, local: CGPoint)? {
        guard let index = hitRowIndex(at: point.y) else { return nil }
        return (index, CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index)))
    }

    /// The message under `point` when it falls inside the row-local frame
    /// `frame` picks for the row's index.
    func messageID(at point: CGPoint, frame: (Int) -> CGRect?) -> MessageID? {
        guard case let (index, local)? = rowHit(at: point), let target = frame(index), target.contains(local)
        else { return nil }
        return items[index].messageID
    }
}
