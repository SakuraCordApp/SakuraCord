import AppKit

/// Geometry of the NEW divider's space opening or closing in place.
///
/// The divider is the top `spaceHeight` of its row, so the static layout
/// already holds its final size. The motion displaces rows instead of laying
/// them out again (see `NativeTimelineUnreadDividerGap`).
nonisolated enum NativeTimelineUnreadDividerGapGeometry {
    /// How far rows before the divider must still be displaced for the
    /// picture to match what was on screen before the update.
    static func startBeforeShift(
        topInViewport: CGFloat,
        viewportMinY: CGFloat,
        staticTop: CGFloat
    ) -> CGFloat {
        topInViewport + viewportMinY - staticTop
    }

    /// The most the divider's row may change by and still be described by the
    /// motion: the divider plus the author header the row gains or loses with
    /// it, since a divider breaks a message group.
    static func maximumSpace(dividerHeight: CGFloat) -> CGFloat {
        dividerHeight * 3
    }

    /// The space the divider opens or closes: how much its row grew or shrank.
    /// That is less than the divider itself when the divider replaces the
    /// spacing a message normally has above it, and more when the row also
    /// gains an author header. Nil when the row changed in any other way, so
    /// the motion would not describe the update.
    static func spaceHeight(
        isAppearing: Bool,
        dividerHeight: CGFloat,
        heightBefore: CGFloat,
        heightAfter: CGFloat
    ) -> CGFloat? {
        let change = (heightAfter - heightBefore) * (isAppearing ? 1 : -1)
        return change > 0.5 && change <= maximumSpace(dividerHeight: dividerHeight) + 0.5 ? change : nil
    }

    /// Whether the space holds more than the divider: an author header that
    /// the row on the other side of the update does not have.
    static func includesHeader(spaceHeight: CGFloat, dividerHeight: CGFloat) -> Bool {
        spaceHeight > dividerHeight + 0.5
    }

    /// The update must not have scrolled the timeline by more than the space.
    static func isFeasible(spaceHeight: CGFloat, startBeforeShift: CGFloat) -> Bool {
        abs(startBeforeShift) <= spaceHeight + 1
    }

    /// The part of the divider that may show: from the top of the gap down to
    /// the top of the message below, which sits `dividerHeight - spaceHeight`
    /// under the open gap. A closing divider that took its header with it is a
    /// picture of the whole space, which fills the open gap.
    static func overlayHeight(
        gap: CGFloat,
        spaceHeight: CGFloat,
        dividerHeight: CGFloat,
        showsSpaceSnapshot: Bool = false,
        snapshotTailHeight: CGFloat = 0
    ) -> CGFloat {
        if showsSpaceSnapshot { return min(spaceHeight, max(0, gap)) + snapshotTailHeight }
        return min(dividerHeight, max(0, gap + dividerHeight - spaceHeight))
    }
}

/// An in-flight opening or closing of the divider's space: a row motion
/// whose one step, above the divider's row, is the part of the space still
/// to open or close, while its shift keeps the rows before it where they were
/// on screen. Both reach zero together, so it lands on the static layout.
struct NativeTimelineUnreadDividerGap {
    let isAppearing: Bool
    let spaceHeight: CGFloat
    let dividerHeight: CGFloat
    /// The divider and header that are closing, as they were on screen, when
    /// the space holds a header the row no longer paints.
    let snapshot: NativeTimelineUnreadDividerSnapshot?
    /// The closing author avatar's part below `snapshot`.
    let snapshotTail: NativeTimelineUnreadDividerSnapshot?
    /// A divider a send acknowledged stays open until the send lands, so the
    /// message arrives where it was aimed before the space above it closes.
    /// Its motion starts then.
    var waitsForSend: Bool
    var motion: NativeTimelineRowMotion

    var identifier: NativeMessageTimelineItem.Identifier { motion.steps[0].identifier }
    var rowIndex: Int { motion.steps[0].rowIndex }
    /// The space the static layout holds above the divider's row.
    var staticGap: CGFloat { isAppearing ? spaceHeight : 0 }
}

extension NativeTimelineCanvasView {
    /// The top of the divider's gap in canvas coordinates: where the rows
    /// before it end, displaced as they are.
    var unreadDividerGapTop: CGFloat {
        guard let gap = unreadDividerGap, rowOrigins.indices.contains(gap.rowIndex) else { return 0 }
        return contentOriginY + rowOrigins[gap.rowIndex] + rowMotionOffset(at: gap.rowIndex - 1)
    }

    /// How much of the divider's space is open on screen: what the static
    /// layout holds, less what the divider's row is still displaced by
    /// against the rows before it.
    var unreadDividerGapOpening: CGFloat {
        guard let gap = unreadDividerGap else { return 0 }
        return gap.staticGap - rowMotionOffset(at: gap.rowIndex - 1) + rowMotionOffset(at: gap.rowIndex)
    }

    /// The divider's own row never draws above its gap while it slides in.
    func unreadDividerGapSpan(at index: Int, minY: CGFloat, maxY: CGFloat) -> Range<CGFloat> {
        guard unreadDividerGap?.rowIndex == index else { return minY ..< maxY }
        let top = unreadDividerGapTop
        return max(top, minY) ..< max(top, maxY)
    }

    func drawTimelineRowClippedToUnreadDividerGap(
        at index: Int,
        rowFrame: CGRect,
        dirtyRect: CGRect,
        visibleMediaKeys: [NativeMessageTimelineItem.Identifier: Set<MediaImageKey>]
    ) {
        let top = unreadDividerGapTop
        guard unreadDividerGap?.rowIndex == index,
              rowFrame.minY < top,
              let context = NSGraphicsContext.current?.cgContext
        else {
            drawTimelineRow(at: index, rowFrame: rowFrame, dirtyRect: dirtyRect, visibleMediaKeys: visibleMediaKeys)
            return
        }
        guard top < rowFrame.maxY else { return }
        context.saveGState()
        context.clip(to: CGRect(x: rowFrame.minX, y: top, width: rowFrame.width, height: rowFrame.maxY - top))
        drawTimelineRow(at: index, rowFrame: rowFrame, dirtyRect: dirtyRect, visibleMediaKeys: visibleMediaKeys)
        context.restoreGState()
    }

    /// Starts the divider's space opening or closing from the picture on
    /// screen before the update. Returns false when the change must apply
    /// instantly: Reduce Motion, another motion running (a closing divider
    /// waits out a send instead), the divider off screen, a row that is new,
    /// or an update that moved more than the divider's own space.
    func beginUnreadDividerGap(
        from source: NativeTimelineUnreadDividerSource,
        appearing: Bool
    ) -> Bool {
        guard !unreadDividerReducesMotion,
              window != nil,
              rowDisclosure == nil,
              !appearing || !sendTransitionBlocksInteractions,
              editingRowIndex == nil,
              let index = rowIndex(forIdentifier: source.identifier),
              layouts.indices.contains(index),
              rowOrigins.indices.contains(index)
        else { return false }
        let layout = layouts[index]
        // A row with a date separator above the divider keeps it in place
        // while the rest moves; that cannot be split out of one bitmap.
        guard let frame = appearing ? layout.unreadSeparatorFrame : source.frameInRow,
              abs(frame.minY) < 0.5,
              appearing || layout.unreadSeparatorFrame == nil
        else { return false }
        guard let space = NativeTimelineUnreadDividerGapGeometry.spaceHeight(
            isAppearing: appearing,
            dividerHeight: frame.height,
            heightBefore: source.height,
            heightAfter: layout.height
        ) else { return false }
        // A header that goes with the divider is no longer in the row, so
        // its picture from before the update closes with the divider.
        var snapshot: NativeTimelineUnreadDividerSnapshot?
        var snapshotTail: NativeTimelineUnreadDividerSnapshot?
        if !appearing, NativeTimelineUnreadDividerGapGeometry.includesHeader(
            spaceHeight: space, dividerHeight: frame.height
        ) {
            guard let picture = source.topSnapshot, let image = picture.top(space) else { return false }
            snapshot = image
            snapshotTail = picture.avatarTail(below: space)
        }
        let startGap = source.startGap ?? (appearing ? 0 : space)
        let staticTop = contentOriginY + rowOrigins[index]
        let startShift = NativeTimelineUnreadDividerGapGeometry.startBeforeShift(
            topInViewport: source.topInViewport,
            viewportMinY: viewportMinY,
            staticTop: staticTop
        )
        guard NativeTimelineUnreadDividerGapGeometry.isFeasible(spaceHeight: space, startBeforeShift: startShift),
              CGRect(x: 0, y: staticTop - space, width: 1, height: space * 3).intersects(visibleRect)
        else { return false }
        // Two row motions would fight over the same displacement.
        finishRowMotions()
        unreadDividerGap = NativeTimelineUnreadDividerGap(
            isAppearing: appearing,
            spaceHeight: space,
            dividerHeight: frame.height,
            snapshot: snapshot,
            snapshotTail: snapshotTail,
            waitsForSend: !appearing && sendTransitionBlocksInteractions,
            motion: NativeTimelineRowMotion(shift: startShift, steps: [.init(
                identifier: source.identifier, rowIndex: index, delta: (appearing ? space : 0) - startGap, edge: .aboveRow
            )])
        )
        startRowMotionTicker()
        refreshRowMotionGeometry()
        redrawForRowMotion()
        return true
    }

    /// Starts the gap's motion once nothing holds it, and lands it when done.
    /// The row motion geometry follows its row meanwhile.
    func stepUnreadDividerGap(at now: TimeInterval) {
        guard let gap = unreadDividerGap else { return }
        guard rowIndex(forIdentifier: gap.identifier, hint: gap.rowIndex) != nil else {
            finishUnreadDividerGap()
            return
        }
        if gap.waitsForSend {
            guard !sendTransitionBlocksInteractions else { return }
            unreadDividerGap?.waitsForSend = false
            if let fade = unreadDividerFades[gap.identifier] {
                beginUnreadDividerFade(
                    identifier: gap.identifier, frameInRow: fade.frameInRow, appearing: false, usesGap: true
                )
            }
        }
        if gap.motion.startUptime == nil {
            unreadDividerGap?.motion.startUptime = now
        } else if gap.motion.progress(at: now) >= 1 {
            finishUnreadDividerGap()
        }
    }

    /// Lands on the static layout. The divider on the gap's overlay goes with
    /// it: the row paints it again once it opens, and a fading one has
    /// nowhere left to be. Not when its row is reversing on `identifier`,
    /// where it carries on from its current opacity.
    func finishUnreadDividerGap(preservingFadeFor identifier: NativeMessageTimelineItem.Identifier? = nil) {
        guard let gap = unreadDividerGap else { return }
        unreadDividerGap = nil
        stopRowMotionTickerIfIdle()
        refreshRowMotionGeometry()
        if gap.identifier != identifier {
            finishUnreadDividerFade(gap.identifier)
        }
        redrawForRowMotion()
    }
}
