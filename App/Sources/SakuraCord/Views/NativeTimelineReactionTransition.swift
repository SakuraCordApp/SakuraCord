import AppKit
import SakuraCordModels

/// Where a reaction chip is drawn during a transition, in row coordinates.
nonisolated struct NativeTimelineReactionChipAppearance: Equatable {
    var frame: CGRect
    var opacity: CGFloat = 1
    var scale: CGFloat = 1

    /// A chip arrives from, and leaves to, a shrunken clear copy of itself.
    var hidden: Self {
        Self(frame: frame, opacity: 0, scale: 0.5)
    }

    func interpolated(to target: Self, progress: CGFloat) -> Self {
        func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            from + (to - from) * progress
        }
        return Self(
            frame: CGRect(
                x: mix(frame.minX, target.frame.minX),
                y: mix(frame.minY, target.frame.minY),
                width: mix(frame.width, target.frame.width),
                height: mix(frame.height, target.frame.height)
            ),
            opacity: mix(opacity, target.opacity),
            scale: mix(scale, target.scale)
        )
    }
}

/// One message's reactions moving from their previous layout to the current
/// one: chips that stay slide to their new places, new ones grow in, removed
/// ones shrink away, and changed counts roll.
///
/// The row's bitmap already holds the final reactions, so while this runs it
/// is drawn only above `bandTop`. Below it the canvas paints only the band's
/// highlight; the chips are Core Animation layers in the row's band view.
struct NativeTimelineReactionTransition {
    struct Chip {
        /// The add-reaction control's key; reaction IDs are never empty.
        static let addControlID = ""

        /// The reaction as it is now and as it was, or nil for the
        /// add-reaction control.
        let region: NativeTimelineRowLayout.ReactionRegion?
        let fromRegion: NativeTimelineRowLayout.ReactionRegion?
        let from: NativeTimelineReactionChipAppearance
        let to: NativeTimelineReactionChipAppearance

        var id: String {
            region?.reaction.id ?? Self.addControlID
        }

        var isStatic: Bool {
            from == to && fromRegion?.reaction == region?.reaction
        }
    }

    var rowIndex: Int
    /// When its layers were installed. The render server runs the motion
    /// from then on the same curve, so `progress` is what is on screen.
    let startUptime: TimeInterval
    let bandTop: CGFloat
    /// The row as it was before its reactions began to change. Its bitmap,
    /// identical above the band, serves until the row lands, so a burst of
    /// reaction updates does not rasterize the whole row for each one.
    let bitmapItem: NativeMessageTimelineItem
    let chips: [Chip]

    /// Ease-out quart as Core Animation draws it.
    static let curve = NativeTimelineGlideCurve(
        x1: 0.165, y1: 0.84, x2: 0.44, y2: 1, duration: NativeTimelineRowDisclosure.duration
    )

    func progress(at uptime: TimeInterval) -> CGFloat {
        CGFloat(Self.curve.progress(at: (uptime - startUptime) / Self.curve.duration))
    }
}

/// One update's reaction lines opening or closing. Rows keep the places they
/// had on screen before the update and ease onto the static layout: rows up to
/// the first changed one are displaced by `shift`, and each changed row hides
/// the part of its height change that has not happened yet, which displaces
/// every row after it. Updates overlap freely; each one's displacement simply
/// adds to the others'.
struct NativeTimelineReactionRowMotion {
    struct Step {
        let identifier: NativeMessageTimelineItem.Identifier
        var rowIndex: Int
        let delta: CGFloat
    }

    /// Set on the first frame, as for a chip transition.
    var startUptime: TimeInterval?
    let shift: CGFloat
    var steps: [Step]

    func progress(at uptime: TimeInterval) -> CGFloat {
        startUptime.map { NativeTimelineRowDisclosure.progress(at: uptime - $0) } ?? 0
    }
}

/// The rows around the viewport as they were before an update.
struct NativeTimelineReactionBaseline {
    struct Row {
        let index: Int
        /// The row's static top relative to the viewport.
        let top: CGFloat
        let item: NativeMessageTimelineItem
        let layout: NativeTimelineRowLayout
    }

    /// The canvas width the rows were laid out at.
    let width: CGFloat
    let rows: [NativeMessageTimelineItem.Identifier: Row]
}

extension MessageRowPresentation {
    /// Whether the two rows present the same message apart from its reactions.
    nonisolated func differsOnlyInReactions(from other: MessageRowPresentation) -> Bool {
        var message = other.message
        message.reactions = self.message.reactions
        return message == self.message
            && startsGroup == other.startsGroup
            && endsGroup == other.endsGroup
            && startsDay == other.startsDay
            && replyPreview == other.replyPreview
            && isReplyAvailable == other.isReplyAvailable
            && searchContext == other.searchContext
            && pinnedAt == other.pinnedAt
            && isResource == other.isResource
    }
}

extension NativeTimelineRowLayout.ReactionRegion {
    /// The same chip placed at `frame`; its contents keep their offsets from
    /// its leading edge.
    func moved(to frame: CGRect) -> Self {
        let dx = frame.minX - self.frame.minX
        let dy = frame.minY - self.frame.minY
        return Self(
            frame: frame,
            reaction: reaction,
            emojiFrame: emojiFrame.offsetBy(dx: dx, dy: dy),
            countFrame: countFrame?.offsetBy(dx: dx, dy: dy),
            avatarRegions: avatarRegions.map {
                AvatarRegion(frame: $0.frame.offsetBy(dx: dx, dy: dy), reactor: $0.reactor)
            },
            placeholderAvatarFrames: placeholderAvatarFrames.map { $0.offsetBy(dx: dx, dy: dy) }
        )
    }
}

extension NativeTimelineCanvasView {
    /// How far beyond the viewport rows are followed, so rows a change pulls
    /// into view start from where they were.
    private static let reactionBaselineMargin: CGFloat = 240

    private var reactionBaselineRect: CGRect {
        visibleRect.insetBy(dx: 0, dy: -Self.reactionBaselineMargin)
    }

    /// Records the rows around the viewport before the coordinator replaces
    /// them in the shared storage.
    func captureReactionBaseline() {
        pendingReactionBaseline = nil
        guard AppMotionPolicy.animatesUncategorized, window != nil, !items.isEmpty else { return }
        let originY = contentOriginY - viewportMinY
        var rows: [NativeMessageTimelineItem.Identifier: NativeTimelineReactionBaseline.Row] = [:]
        forEachDisplayedRow(in: reactionBaselineRect) { index in
            rows[items[index].identifier] = .init(
                index: index,
                top: originY + rowOrigins[index],
                item: items[index],
                layout: layouts[index]
            )
        }
        if !rows.isEmpty { pendingReactionBaseline = NativeTimelineReactionBaseline(width: bounds.width, rows: rows) }
    }

    /// Starts the motion of the update just applied, after the coordinator
    /// has settled the scroll position. Rows whose only change is their
    /// reactions animate; any other change near the viewport, such as a new
    /// or edited message, applies instantly as before.
    func beginReactionTransitions() {
        guard let baseline = pendingReactionBaseline else { return }
        pendingReactionBaseline = nil
        guard AppMotionPolicy.animatesUncategorized,
              abs(baseline.width - bounds.width) < 0.5,
              editingRowIndex == nil,
              rowDisclosure == nil,
              unreadDividerGap == nil,
              !sendTransitionBlocksInteractions
        else { return }
        refreshReactionMotionGeometry()
        let now = ProcessInfo.processInfo.systemUptime
        let originY = contentOriginY - viewportMinY
        var shift: CGFloat?
        var steps: [NativeTimelineReactionRowMotion.Step] = []
        var expectedShift: CGFloat?
        var previousIndex: Int?
        var describesUpdate = true
        var startedChips = false
        var pausesMedia = false
        var droppedMotion = false
        forEachDisplayedRow(in: reactionBaselineRect) { index in
            let identifier = items[index].identifier
            // Rows entering the followed area have no earlier place. One
            // inserted between followed rows fails the shift check below.
            guard let old = baseline.rows[identifier] else { return }
            // Rows removed or moved between two followed rows, or any height
            // change the steps do not explain, end the motion.
            let rowShift = old.top - (originY + rowOrigins[index])
            if let previousIndex, old.index != previousIndex + 1 { describesUpdate = false }
            if let expectedShift, abs(rowShift - expectedShift) >= 0.5 { describesUpdate = false }
            previousIndex = old.index
            shift = shift ?? rowShift
            let delta = layouts[index].height - old.layout.height
            expectedShift = rowShift - delta
            let changed = old.item != items[index]
            guard changed,
                  case let .message(oldRow, oldUnread, oldHighlighted) = old.item,
                  case let .message(row, unread, highlighted) = items[index],
                  unread == oldUnread, highlighted == oldHighlighted,
                  row.differsOnlyInReactions(from: oldRow)
            else {
                if abs(delta) >= 0.5 { describesUpdate = false }
                // Its chips belong to a row that changed in another way.
                if changed {
                    endReactionTransition(identifier)
                    let motionCount = reactionRowMotions.count
                    reactionRowMotions.removeAll { $0.steps.contains { $0.identifier == identifier } }
                    droppedMotion = droppedMotion || reactionRowMotions.count != motionCount
                }
                return
            }
            if abs(delta) >= 0.5 {
                steps.append(.init(identifier: identifier, rowIndex: index, delta: delta))
            }
            if rowFrame(at: index).intersects(visibleRect),
               beginReactionTransition(at: index, from: old, now: now)
            {
                startedChips = true
                pausesMedia = pausesMedia || animatedMediaRows[identifier] != nil
            }
        }
        // A row that changed in another way lands where the update put it.
        if droppedMotion {
            refreshReactionMotionGeometry(at: now)
            redrawForRowMotion()
        }
        // Live reaction media pauses on its still while the chips move.
        if pausesMedia { positionAnimatedMediaOverlays() }
        if describesUpdate, let shift, !steps.isEmpty {
            reactionRowMotions.append(.init(shift: shift, steps: steps))
            refreshReactionMotionGeometry(at: now)
            redrawForRowMotion()
        } else if !startedChips {
            return
        }
        reactionTransitionWidth = bounds.width
        if reactionTicker.displayLink == nil {
            reactionTicker.start(on: self) { [weak self] in self?.stepReactionTransitions() }
        }
    }

    /// Installs a row's chip transition, continuing a running one from what
    /// is on screen. False when its reactions look the same.
    private func beginReactionTransition(
        at index: Int,
        from old: NativeTimelineReactionBaseline.Row,
        now: TimeInterval
    ) -> Bool {
        let oldLayout = old.layout
        let layout = layouts[index]
        // Footers below the reactions would have to move with them.
        func hasFooter(_ layout: NativeTimelineRowLayout) -> Bool {
            layout.ephemeralRegion != nil || layout.failedFrame != nil || layout.pinnedAtFrame != nil
                || layout.searchCardFrame != nil || layout.postStarterDividerFrame != nil
        }
        guard !hasFooter(layout), !hasFooter(oldLayout) else { return false }
        typealias Current = (
            region: NativeTimelineRowLayout.ReactionRegion?,
            appearance: NativeTimelineReactionChipAppearance
        )
        var current: [String: Current] = [:]
        let identifier = items[index].identifier
        if let running = reactionTransitions[identifier] {
            let progress = running.progress(at: now)
            for chip in running.chips {
                let appearance = chip.from.interpolated(to: chip.to, progress: progress)
                guard appearance.opacity > 0.01 else { continue }
                // A count still rolling continues from the one mostly showing.
                current[chip.id] = (progress < 0.5 ? chip.fromRegion : chip.region, appearance)
            }
        } else {
            for region in oldLayout.reactionRegions {
                current[region.reaction.id] = (region, .init(frame: region.frame))
            }
            if let frame = oldLayout.addReactionFrame {
                current[NativeTimelineReactionTransition.Chip.addControlID] = (nil, .init(frame: frame))
            }
        }
        var arriving: [NativeTimelineReactionTransition.Chip] = []
        let targets = layout.reactionRegions.map { (region: Optional($0), frame: $0.frame) }
            + (layout.addReactionFrame.map { [(region: nil, frame: $0)] } ?? [])
        for target in targets {
            let to = NativeTimelineReactionChipAppearance(frame: target.frame)
            let from = current.removeValue(
                forKey: target.region?.reaction.id ?? NativeTimelineReactionTransition.Chip.addControlID
            )
            arriving.append(.init(
                region: target.region,
                fromRegion: from?.region ?? target.region,
                from: from?.appearance ?? to.hidden,
                to: to
            ))
        }
        // Leaving chips draw beneath the ones taking their place.
        let chips = current.values.map {
            NativeTimelineReactionTransition.Chip(
                region: $0.region,
                fromRegion: $0.region,
                from: $0.appearance,
                to: $0.appearance.hidden
            )
        } + arriving
        guard !chips.allSatisfy(\.isStatic) else {
            // A running transition toward reactions that are gone again ends here.
            if reactionTransitions[identifier] != nil {
                endReactionTransition(identifier)
                setNeedsDisplay(rowFrame(at: index))
            }
            return false
        }
        // Chip outlines are stroked on their edges, so the band starts above them.
        let chipTop = chips.map { min($0.from.frame.minY, $0.to.frame.minY) - Self.reactionPictureInset }.min()
            ?? layout.height
        reactionTransitions[identifier] = NativeTimelineReactionTransition(
            rowIndex: index,
            startUptime: now,
            bandTop: min(chipTop, layout.height, oldLayout.height),
            bitmapItem: reactionTransitions[identifier]?.bitmapItem ?? old.item,
            chips: chips
        )
        if let transition = reactionTransitions[identifier] { installReactionBandView(for: transition, at: index, now: now) }
        setNeedsDisplay(rowFrame(at: index))
        return true
    }

    private func stepReactionTransitions() {
        let now = ProcessInfo.processInfo.systemUptime
        let hadMotion = !reactionRowMotions.isEmpty
        for index in reactionRowMotions.indices where reactionRowMotions[index].startUptime == nil {
            reactionRowMotions[index].startUptime = now
        }
        reactionRowMotions.removeAll { $0.progress(at: now) >= 1 }
        // Frames that move no row by a whole pixel redraw only the chips; the
        // last one also hands hover back to the rows where they landed.
        let moved = refreshReactionMotionGeometry(at: now)
        let redrawsRows = hadMotion && (moved || reactionRowMotions.isEmpty)
        var reconcilesMedia = false
        for (identifier, transition) in reactionTransitions {
            guard let index = rowIndex(forIdentifier: identifier, hint: transition.rowIndex) else {
                endReactionTransition(identifier)
                continue
            }
            if index != transition.rowIndex { reactionTransitions[identifier]?.rowIndex = index }
            if transition.progress(at: now) >= 1 {
                // The row's bitmap takes over from the chip layers in the same frame.
                endReactionTransition(identifier)
                setNeedsDisplay(rowFrame(at: index))
                reconcilesMedia = reconcilesMedia || animatedMediaRows[identifier] != nil
            }
        }
        if redrawsRows { redrawForRowMotion(invalidating: reactionMotionFrame) }
        if reconcilesMedia { reconcileAnimatedMediaOverlays(reduceMotion: false) }
        if reactionTransitions.isEmpty, reactionRowMotions.isEmpty { reactionTicker.stop() }
    }

    /// Lands every reaction motion on the static layout, for another motion
    /// or a conversation change.
    func finishReactionTransitions() {
        pendingReactionBaseline = nil
        reactionTicker.stop()
        let hadMotion = !reactionRowMotions.isEmpty
        let hadChips = !reactionTransitions.isEmpty
        reactionRowMotions.removeAll()
        for identifier in reactionTransitions.keys { endReactionTransition(identifier) }
        refreshReactionMotionGeometry()
        if hadMotion {
            redrawForRowMotion()
        } else if hadChips {
            invalidateVisibleContent()
        }
        if hadChips { positionAnimatedMediaOverlays() }
    }

    /// Recomputes the cached displacement read by `displayedRowOrigin(at:)`,
    /// on whole device pixels so moving rows stay sharp. True when any row
    /// moved.
    @discardableResult
    func refreshReactionMotionGeometry(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !reactionRowMotions.isEmpty || !reactionMotionSteps.isEmpty else { return false }
        // A motion whose row is gone no longer describes the layout.
        reactionRowMotions.removeAll { motion in
            motion.steps.contains { rowIndex(forIdentifier: $0.identifier, hint: $0.rowIndex) == nil }
        }
        var shift: CGFloat = 0
        var steps: [(index: Int, offset: CGFloat)] = []
        for motionIndex in reactionRowMotions.indices {
            let motion = reactionRowMotions[motionIndex]
            let left = 1 - motion.progress(at: uptime)
            shift += motion.shift * left
            for stepIndex in motion.steps.indices {
                let step = motion.steps[stepIndex]
                guard let index = rowIndex(forIdentifier: step.identifier, hint: step.rowIndex) else { continue }
                reactionRowMotions[motionIndex].steps[stepIndex].rowIndex = index
                steps.append((index, step.delta * left))
            }
        }
        let scale = window?.backingScaleFactor ?? 2
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        steps.sort { $0.index < $1.index }
        var total: CGFloat = 0
        var cumulative: [(index: Int, cumulative: CGFloat)] = []
        for step in steps {
            total += step.offset
            if cumulative.last?.index == step.index { cumulative.removeLast() }
            cumulative.append((step.index, snapped(total)))
        }
        // A row's hidden height is the step its own change adds.
        var remaining: [Int: CGFloat] = [:]
        for (position, step) in cumulative.enumerated() {
            remaining[step.index] = step.cumulative - (position > 0 ? cumulative[position - 1].cumulative : 0)
        }
        let snappedShift = snapped(shift)
        let moved = snappedShift != reactionMotionShift
            || !cumulative.elementsEqual(reactionMotionSteps) { $0.index == $1.index && $0.cumulative == $1.cumulative }
        reactionMotionSteps = cumulative
        reactionMotionShift = snappedShift
        reactionMotionRemainingHeights = remaining
        return moved
    }

    /// The part of the viewport whose rows move: from the top when rows
    /// before the first changed one are displaced, to the bottom when rows
    /// after the last one are.
    private var reactionMotionFrame: CGRect {
        let visible = visibleRect
        guard let first = reactionMotionSteps.first, let last = reactionMotionSteps.last,
              items.indices.contains(first.index), items.indices.contains(last.index)
        else { return visible }
        let minY = reactionMotionShift == 0 ? displayedRowOrigin(at: first.index) : visible.minY
        let maxY = reactionMotionShift == last.cumulative
            ? displayedRowOrigin(at: last.index) + displayedRowHeight(at: last.index) + abs(last.cumulative)
            : visible.maxY
        return CGRect(x: visible.minX, y: minY, width: visible.width, height: max(0, maxY - minY))
            .intersection(visible)
    }

    /// Displacement of a row by the running reaction motions.
    func reactionMotionOffset(at index: Int) -> CGFloat {
        guard !reactionMotionSteps.isEmpty else { return 0 }
        var lower = 0
        var upper = reactionMotionSteps.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if reactionMotionSteps[middle].index < index { lower = middle + 1 } else { upper = middle }
        }
        return reactionMotionShift - (lower > 0 ? reactionMotionSteps[lower - 1].cumulative : 0)
    }

    /// The part of a row's height change that has not happened on screen yet.
    func reactionMotionRemainingHeight(at index: Int) -> CGFloat {
        reactionMotionRemainingHeights[index] ?? 0
    }

    private func reactionBandFrame(in rowFrame: CGRect, bandTop: CGFloat) -> CGRect {
        CGRect(x: rowFrame.minX, y: rowFrame.minY + bandTop, width: rowFrame.width, height: max(0, rowFrame.height - bandTop))
    }

    /// Where the row's chips and add-reaction control are on screen, in row
    /// coordinates, so a click lands on the chip under the pointer.
    func displayedReactionFrames(at index: Int) -> (reactions: [CGRect], add: CGRect?) {
        let layout = layouts[index]
        guard let transition = reactionTransitions[items[index].identifier] else {
            return (layout.reactionRegions.map(\.frame), layout.addReactionFrame)
        }
        let progress = transition.progress(at: ProcessInfo.processInfo.systemUptime)
        var frames: [String: CGRect] = [:]
        for chip in transition.chips where chip.to.opacity > 0 {
            frames[chip.id] = chip.from.interpolated(to: chip.to, progress: progress).frame
        }
        return (
            layout.reactionRegions.map { frames[$0.reaction.id] ?? $0.frame },
            layout.addReactionFrame.map { frames[NativeTimelineReactionTransition.Chip.addControlID] ?? $0 }
        )
    }

    /// The top of a transitioning row's live band, in canvas coordinates.
    func reactionBandTop(for item: NativeMessageTimelineItem, rowFrame: CGRect) -> CGFloat? {
        reactionTransitions[item.identifier].map { rowFrame.minY + $0.bandTop }
    }

    /// The row's bitmap from before its reactions began to change, which
    /// still shows everything above the band.
    func reactionTransitionBitmap(for item: NativeMessageTimelineItem, width: CGFloat) -> NSImage? {
        guard let transition = reactionTransitions[item.identifier],
              let cached = bitmapCache[item.identifier],
              cached.item == transition.bitmapItem,
              abs(cached.width - width) < 0.5,
              cached.appearanceName == effectiveAppearance.name
        else { return nil }
        return cached.images[-1]
    }

    /// Paints a transitioning row's band background, stretched to the row's
    /// height on screen. The chips move above it in the row's band view.
    func drawReactionBand(at index: Int, rowFrame: CGRect) {
        let item = items[index]
        guard let transition = reactionTransitions[item.identifier],
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let layout = layouts[index]
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: reactionBandFrame(in: rowFrame, bandTop: transition.bandTop))
        context.translateBy(x: rowFrame.minX, y: rowFrame.minY)
        NativeTimelineRowPainter.drawHighlight(
            for: item,
            in: layout.highlightFrame.map {
                CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + rowFrame.height - layout.height)
            },
            bubbleRegion: layout.bubbleRegion,
            model: model,
            isHovered: hoveredRow == index || mediaViewerHighlightedMessageID == item.messageID
        )
    }

    /// Hands a row's chip motion to Core Animation: a view over the band
    /// holds one layer per chip, built from the cached pictures and animated
    /// from where it is on screen now. The render server runs the motion, so
    /// the canvas does not redraw for it.
    private func installReactionBandView(for transition: NativeTimelineReactionTransition, at index: Int, now: TimeInterval) {
        let identifier = items[index].identifier
        guard case let .message(row, _, _) = items[index] else { return }
        let view = reactionBandViews[identifier] ?? NativeTimelineReactionBandView()
        if view.superview !== self { addSubview(view) }
        reactionBandViews[identifier] = view
        view.setBandFrame(reactionBandFrame(in: rowFrame(at: index), bandTop: transition.bandTop))
        // The transition's clock in media time, so hit-testing and retargeting
        // read the same point of the motion the render server shows.
        let begin = CACurrentMediaTime() - (ProcessInfo.processInfo.systemUptime - transition.startUptime)
        let progress = transition.progress(at: now)
        let showsAddControl = model?.canCreateReactions(on: row.message) != false
        var pills: [NativeTimelineReactionBandView.Pill] = []
        for chip in transition.chips where chip.region != nil || showsAddControl {
            let appearance = (chip.from.interpolated(to: chip.to, progress: progress), chip.to)
            let pill = if let region = chip.region, let fromRegion = chip.fromRegion {
                reactionChipLayer(region, from: fromRegion, appearance: appearance, begin: begin)
            } else {
                reactionPillLayer(appearance: appearance, begin: begin)
            }
            pills.append((pill, chip))
        }
        view.setPills(pills, bandTop: transition.bandTop)
        refreshReactionChipHover(at: index)
    }

    /// Colours a transitioning row's chips for the pointer, which can enter
    /// or leave a chip while it moves.
    func refreshReactionChipHover(at index: Int) {
        guard items.indices.contains(index),
              let view = reactionBandViews[items[index].identifier],
              case let .message(row, _, _) = items[index]
        else { return }
        let hoveredReactionID = hoveredReactionID(inMessageAt: index)
        let canUpdate = model?.canUpdateReactions(on: row.message) != false
        let isAddHovered = isAddReactionHovered(inMessageAt: index)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (pill, chip) in view.pills {
            let frame = chip.to.frame
            let picture = if let region = chip.region {
                reactionChipBackground(
                    frame,
                    selected: region.reaction.didCurrentUserReact,
                    isHovered: canUpdate && hoveredReactionID == region.reaction.id
                )
            } else {
                reactionPicture(["add", isAddHovered], covering: frame) {
                    NativeTimelineRowPainter.reactionAddControl(in: frame, isHovered: isAddHovered)
                }
            }
            pill.contents = picture.image
            pill.contentsScale = window?.backingScaleFactor ?? 2
            // A chip changing width stretches only between its rounded ends.
            let cap = (InterfaceScale.metric(9) + 2 * Self.reactionPictureInset) / picture.frame.width
            pill.contentsCenter = CGRect(x: cap, y: 0, width: 1 - 2 * cap, height: 1)
        }
    }

    /// Keeps band views on their rows while rows move, clipped to the height
    /// each row has on screen.
    func positionReactionBandViews() {
        for (identifier, view) in reactionBandViews {
            guard let transition = reactionTransitions[identifier],
                  let index = rowIndex(forIdentifier: identifier, hint: transition.rowIndex)
            else { continue }
            view.setBandFrame(reactionBandFrame(in: rowFrame(at: index), bandTop: transition.bandTop))
        }
    }

    func endReactionTransition(_ identifier: NativeMessageTimelineItem.Identifier) {
        reactionTransitions[identifier] = nil
        reactionBandViews.removeValue(forKey: identifier)?.removeFromSuperview()
    }

    private static let reactionTiming = NativeTimelineReactionTransition.curve.timingFunction

    private func animate(_ layer: CALayer, _ keyPath: String, from value: Any, begin: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.beginTime = begin
        animation.fillMode = .backwards
        animation.duration = NativeTimelineRowDisclosure.duration
        animation.timingFunction = Self.reactionTiming
        animation.preferredFrameRateRange = .fullRate(on: window?.screen)
        layer.add(animation, forKey: keyPath)
    }

    /// A chip's outline moving, scaling and fading between two appearances;
    /// its contents keep their offsets from its leading edge. The layer
    /// covers the chip's picture, so it lands on the pixels the row draws.
    private func reactionPillLayer(
        appearance: (from: NativeTimelineReactionChipAppearance, to: NativeTimelineReactionChipAppearance),
        begin: CFTimeInterval
    ) -> CALayer {
        let pill = CALayer()
        let (from, to) = appearance
        let frame = reactionPictureFrame(covering: to.frame)
        let fromFrame = CGRect(
            x: frame.minX + from.frame.minX - to.frame.minX,
            y: frame.minY + from.frame.minY - to.frame.minY,
            width: frame.width + from.frame.width - to.frame.width,
            height: frame.height + from.frame.height - to.frame.height
        )
        pill.bounds = CGRect(origin: .zero, size: frame.size)
        pill.position = CGPoint(x: frame.midX, y: frame.midY)
        pill.opacity = Float(to.opacity)
        pill.transform = CATransform3DMakeScale(to.scale, to.scale, 1)
        if from != to {
            animate(pill, "bounds.size", from: NSValue(size: fromFrame.size), begin: begin)
            animate(pill, "position", from: NSValue(point: CGPoint(x: fromFrame.midX, y: fromFrame.midY)), begin: begin)
            animate(pill, "opacity", from: Float(from.opacity), begin: begin)
            animate(pill, "transform", from: NSValue(caTransform3D: CATransform3DMakeScale(from.scale, from.scale, 1)), begin: begin)
        }
        return pill
    }

    private func reactionChipLayer(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        from source: NativeTimelineRowLayout.ReactionRegion,
        appearance: (from: NativeTimelineReactionChipAppearance, to: NativeTimelineReactionChipAppearance),
        begin: CFTimeInterval
    ) -> CALayer {
        let pill = reactionPillLayer(appearance: appearance, begin: begin)
        let selected = region.reaction.didCurrentUserReact
        let origin = reactionPictureFrame(covering: region.frame).origin
        func pictureLayer(_ picture: ReactionPicture, opacity: Float = 1) -> CALayer {
            let layer = CALayer()
            layer.contents = picture.image
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.frame = picture.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            layer.opacity = opacity
            return layer
        }
        pill.addSublayer(pictureLayer(emojiPicture(region)))
        if let digits = countPicture(region, selected: selected) {
            let source = source.moved(to: region.frame)
            let count = pictureLayer(digits)
            if source.reaction.count != region.reaction.count, let sourceDigits = countPicture(source, selected: selected) {
                // Digits roll through a window just inside the chip.
                let window = CALayer()
                window.frame = region.frame.insetBy(dx: 0, dy: InterfaceScale.metric(3))
                    .offsetBy(dx: -origin.x, dy: -origin.y)
                window.masksToBounds = true
                let travel = region.frame.height / 2
                let direction: CGFloat = region.reaction.count > source.reaction.count ? 1 : -1
                let leaving = pictureLayer(sourceDigits, opacity: 0)
                for layer in [leaving, count] {
                    layer.frame = layer.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
                    window.addSublayer(layer)
                }
                leaving.position.y -= direction * travel
                animate(leaving, "position", from: NSValue(point: CGPoint(x: leaving.position.x, y: leaving.position.y + direction * travel)), begin: begin)
                animate(leaving, "opacity", from: Float(1), begin: begin)
                animate(count, "position", from: NSValue(point: CGPoint(x: count.position.x, y: count.position.y + direction * travel)), begin: begin)
                animate(count, "opacity", from: Float(0), begin: begin)
                pill.addSublayer(window)
            } else {
                pill.addSublayer(count)
            }
        }
        let avatars = avatarsPicture(region)
        let sourceAvatars = avatarsPicture(source.moved(to: region.frame))
        if let avatars {
            let layer = pictureLayer(avatars.picture)
            pill.addSublayer(layer)
            if let sourceAvatars, sourceAvatars.key == avatars.key {
                let shift = sourceAvatars.picture.frame.minX - avatars.picture.frame.minX
                animate(layer, "position", from: NSValue(point: CGPoint(x: layer.position.x + shift, y: layer.position.y)), begin: begin)
            } else {
                animate(layer, "opacity", from: Float(0), begin: begin)
            }
        }
        if let sourceAvatars, sourceAvatars.key != avatars?.key {
            let layer = pictureLayer(sourceAvatars.picture, opacity: 0)
            pill.addSublayer(layer)
            animate(layer, "opacity", from: Float(1), begin: begin)
        }
        return pill
    }

    private func emojiPicture(_ region: NativeTimelineRowLayout.ReactionRegion) -> ReactionPicture {
        let url = MessageReactionPresentation.emojiURL(
            for: region.reaction,
            customEmojiURLsByID: model?.customEmojiURLsByID ?? [:]
        )
        let key: [AnyHashable] = [
            "emoji", region.reaction.emojiReference.name, url,
            url.map { NativeTimelineRowPainter.mediaImage(for: .media($0, maximumPixelDimension: 64)) != nil },
        ]
        return reactionPicture(key, covering: region.emojiFrame) {
            if region.reaction.emojiReference.id == nil {
                ComponentUnicodeEmojiRenderer.prepareImages(for: [region.reaction.emojiReference.name])
            }
            NativeTimelineRowPainter.drawReactionEmoji(region, model: model)
        }
    }

    private func reactionChipBackground(_ frame: CGRect, selected: Bool, isHovered: Bool) -> ReactionPicture {
        reactionPicture(["chip", selected, isHovered], covering: frame) {
            NativeTimelineRowPainter.drawReactionBackground(frame, selected: selected, isHovered: isHovered)
        }
    }

    private func countPicture(_ region: NativeTimelineRowLayout.ReactionRegion, selected: Bool) -> ReactionPicture? {
        guard let frame = region.countFrame else { return nil }
        return reactionPicture(["count", region.reaction.count, selected], covering: frame) {
            NativeTimelineRowPainter.reactionCount(
                region.reaction.count,
                in: frame,
                color: selected ? .sakuraCordAccentColor : .labelColor
            )
        }
    }

    private func avatarsPicture(_ region: NativeTimelineRowLayout.ReactionRegion) -> ReactionAvatarsPicture? {
        let frames = region.avatarRegions.map(\.frame) + region.placeholderAvatarFrames
        guard let first = frames.first else { return nil }
        let frame = frames.reduce(first) { $0.union($1) }
        let key: [AnyHashable] = ["avatars", region.placeholderAvatarFrames.count] + region.avatarRegions.map { avatar in
            [avatar.reactor.id, avatar.reactor.displayName, avatar.reactor.avatarURL, avatar.reactor.avatarURL.map {
                NativeTimelineRowPainter.mediaImage(for: .avatar($0)) != nil
            }] as [AnyHashable]
        }
        return ReactionAvatarsPicture(
            picture: reactionPicture(key, covering: frame) { NativeTimelineRowPainter.drawReactionAvatars(region) },
            key: key
        )
    }

    /// Room around a picture for antialiased edges and stroked outlines.
    private static let reactionPictureInset: CGFloat = 1

    /// The whole device pixels a picture of `frame` covers, in row
    /// coordinates. Rows start on whole pixels, so a picture drawn at the
    /// row's own subpixel offsets lands exactly on the pixels the row draws.
    private func reactionPictureFrame(covering frame: CGRect) -> CGRect {
        let scale = window?.backingScaleFactor ?? 2
        let outset = frame.insetBy(dx: -Self.reactionPictureInset, dy: -Self.reactionPictureInset)
        let minX = (outset.minX * scale).rounded(.down) / scale
        let minY = (outset.minY * scale).rounded(.down) / scale
        return CGRect(
            x: minX,
            y: minY,
            width: (outset.maxX * scale).rounded(.up) / scale - minX,
            height: (outset.maxY * scale).rounded(.up) / scale - minY
        )
    }

    /// Draws `draw`, which paints within `frame`, into a cached picture.
    /// `content` must identify everything the drawing depends on besides its
    /// size, subpixel offset, scale and appearance.
    private func reactionPicture(_ content: [AnyHashable], covering frame: CGRect, draw: () -> Void) -> ReactionPicture {
        let scale = window?.backingScaleFactor ?? 2
        let bounds = reactionPictureFrame(covering: frame)
        let key = ReactionPictureKey(
            content: content,
            frame: CGRect(origin: CGPoint(x: frame.minX - bounds.minX, y: frame.minY - bounds.minY), size: frame.size),
            scale: scale,
            appearance: effectiveAppearance.name,
            colorSpace: window?.colorSpace,
            accent: NSColor.sakuraCordAccentColor.cgColor.components ?? []
        )
        if let image = reactionPictures[key] { return ReactionPicture(image: image, frame: bounds) }
        guard let context = ForumCardRasterizer.makeContext(
            width: Int((bounds.width * scale).rounded()),
            height: Int((bounds.height * scale).rounded()),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { return ReactionPicture(image: nil, frame: bounds) }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        // The canvas draws into a context without a colour space, so its
        // pixels show as the display's own colours. Drawn in device RGB like
        // the row bitmaps and tagged with the display's colour space, the
        // picture shows the same colours.
        var image = context.makeImage()
        if let colorSpace = window?.colorSpace?.cgColorSpace { image = image?.copy(colorSpace: colorSpace) }
        if reactionPictures.count >= 512 { reactionPictures.removeAll(keepingCapacity: true) }
        reactionPictures[key] = image
        return ReactionPicture(image: image, frame: bounds)
    }

}

/// A transitioning row's chips above the canvas, clipped to the part of the
/// row's reaction band on screen. Its layers are in row coordinates.
final class NativeTimelineReactionBandView: NSView {
    private let content = CALayer()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// AppKit orients the hosted layer from this, so row coordinates are
    /// top-down like the canvas's.
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setBandFrame(_ frame: CGRect) {
        guard frame != self.frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        CATransaction.commit()
    }

    /// A chip's layer, with the chip it shows.
    typealias Pill = (layer: CALayer, chip: NativeTimelineReactionTransition.Chip)

    private(set) var pills: [Pill] = []

    func setPills(_ pills: [Pill], bandTop: CGFloat) {
        self.pills = pills
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = CGRect(x: 0, y: -bandTop, width: bounds.width, height: bandTop + bounds.height)
        content.sublayers = pills.map(\.layer)
        CATransaction.commit()
    }
}

/// A cached reaction picture and the row area it covers.
struct ReactionPicture {
    let image: CGImage?
    let frame: CGRect
}

/// A chip's reactor avatars as one picture, and what it shows.
struct ReactionAvatarsPicture {
    let picture: ReactionPicture
    let key: [AnyHashable]
}

/// A cached reaction picture's identity.
struct ReactionPictureKey: Hashable {
    let content: [AnyHashable]
    /// The drawing's frame within the picture.
    let frame: CGRect
    let scale: CGFloat
    let appearance: NSAppearance.Name
    let colorSpace: NSColorSpace?
    let accent: [CGFloat]
}
