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
/// is drawn only above `bandTop`. Everything below, every reaction line before
/// and after the change, is painted live each frame and is the only part of
/// the row that is redrawn.
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
    /// Set on the first frame, like the other row motions, so time the main
    /// thread spends finishing the update does not use up the motion.
    var startUptime: TimeInterval?
    let bandTop: CGFloat
    /// The row as it was before its reactions began to change. Its bitmap,
    /// identical above the band, serves until the row lands, so a burst of
    /// reaction updates does not rasterize the whole row for each one.
    let bitmapItem: NativeMessageTimelineItem
    let chips: [Chip]

    func progress(at uptime: TimeInterval) -> CGFloat {
        startUptime.map { NativeTimelineRowDisclosure.progress(at: uptime - $0) } ?? 0
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
                if changed { reactionTransitions[identifier] = nil }
                return
            }
            if abs(delta) >= 0.5 {
                steps.append(.init(identifier: identifier, rowIndex: index, delta: delta))
            }
            if rowFrame(at: index).intersects(visibleRect),
               beginReactionTransition(at: index, from: old, now: now)
            {
                startedChips = true
            }
        }
        // Live reaction media pauses on its still while the chips move.
        if startedChips { positionAnimatedMediaOverlays() }
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
            if reactionTransitions.removeValue(forKey: identifier) != nil { setNeedsDisplay(rowFrame(at: index)) }
            return false
        }
        let chipTop = chips.map { min($0.from.frame.minY, $0.to.frame.minY) }.min() ?? layout.height
        reactionTransitions[identifier] = NativeTimelineReactionTransition(
            rowIndex: index,
            bandTop: min(chipTop, layout.height, oldLayout.height),
            bitmapItem: reactionTransitions[identifier]?.bitmapItem ?? old.item,
            chips: chips
        )
        setNeedsDisplay(rowFrame(at: index))
        return true
    }

    private func stepReactionTransitions() {
        let now = ProcessInfo.processInfo.systemUptime
        let hadMotion = !reactionRowMotions.isEmpty
        for index in reactionRowMotions.indices where reactionRowMotions[index].startUptime == nil {
            reactionRowMotions[index].startUptime = now
        }
        for (identifier, transition) in reactionTransitions where transition.startUptime == nil {
            reactionTransitions[identifier]?.startUptime = now
        }
        reactionRowMotions.removeAll { $0.progress(at: now) >= 1 }
        // Frames that move no row by a whole pixel redraw only the chips; the
        // last one also hands hover back to the rows where they landed.
        let moved = refreshReactionMotionGeometry(at: now)
        let redrawsRows = hadMotion && (moved || reactionRowMotions.isEmpty)
        var reconcilesMedia = false
        for (identifier, transition) in reactionTransitions {
            guard let index = rowIndex(forIdentifier: identifier, hint: transition.rowIndex) else {
                reactionTransitions[identifier] = nil
                continue
            }
            if index != transition.rowIndex { reactionTransitions[identifier]?.rowIndex = index }
            setNeedsDisplay(reactionBandFrame(in: rowFrame(at: index), bandTop: transition.bandTop))
            if transition.progress(at: now) >= 1 {
                reactionTransitions[identifier] = nil
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
        reactionTransitions.removeAll()
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

    /// Paints a transitioning row's band: its background, stretched to the
    /// row's height on screen, and every chip where it is now.
    func drawReactionBand(at index: Int, rowFrame: CGRect) {
        let item = items[index]
        guard let transition = reactionTransitions[item.identifier],
              case let .message(row, _, _) = item,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let layout = layouts[index]
        let progress = transition.progress(at: ProcessInfo.processInfo.systemUptime)
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
        let hoveredReactionID = hoveredReactionID(inMessageAt: index)
        let canUpdate = model?.canUpdateReactions(on: row.message) != false
        let showsAddControl = model?.canCreateReactions(on: row.message) != false
        for chip in transition.chips {
            let appearance = chip.from.interpolated(to: chip.to, progress: progress)
            guard appearance.opacity > 0.01, chip.region != nil || showsAddControl else { continue }
            context.saveGState()
            if appearance.scale != 1 {
                let frame = appearance.frame
                context.translateBy(x: frame.midX, y: frame.midY)
                context.scaleBy(x: appearance.scale, y: appearance.scale)
                context.translateBy(x: -frame.midX, y: -frame.midY)
            }
            if appearance.opacity < 1 {
                context.setAlpha(appearance.opacity)
                context.beginTransparencyLayer(in: appearance.frame.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
            }
            if let region = chip.region, let fromRegion = chip.fromRegion {
                drawReactionChip(
                    region.moved(to: appearance.frame),
                    from: fromRegion.moved(to: appearance.frame),
                    progress: progress,
                    isHovered: canUpdate && hoveredReactionID == region.reaction.id,
                    in: context
                )
            } else {
                NativeTimelineRowPainter.reactionAddControl(
                    in: appearance.frame,
                    isHovered: isAddReactionHovered(inMessageAt: index)
                )
            }
            if appearance.opacity < 1 { context.endTransparencyLayer() }
            context.restoreGState()
        }
    }

    /// One chip, both placed at its frame on screen. Its pill is painted;
    /// its emoji, count and avatars are cached pictures, so a frame costs a
    /// few image copies. A changed count rolls, and changed avatars fade.
    private func drawReactionChip(
        _ region: NativeTimelineRowLayout.ReactionRegion,
        from source: NativeTimelineRowLayout.ReactionRegion,
        progress: CGFloat,
        isHovered: Bool,
        in context: CGContext
    ) {
        let selected = region.reaction.didCurrentUserReact
        NativeTimelineRowPainter.drawReactionBackground(region.frame, selected: selected, isHovered: isHovered)
        drawReactionPicture(emojiPicture(region), in: region.emojiFrame, context: context)
        if let countFrame = region.countFrame {
            if let sourceFrame = source.countFrame, source.reaction.count != region.reaction.count {
                let travel = region.frame.height / 2
                let direction: CGFloat = region.reaction.count > source.reaction.count ? 1 : -1
                context.saveGState()
                context.clip(to: region.frame.insetBy(dx: 0, dy: InterfaceScale.metric(3)))
                drawReactionPicture(
                    countPicture(source, selected: selected),
                    in: sourceFrame.offsetBy(dx: 0, dy: -direction * travel * progress),
                    alpha: 1 - progress,
                    context: context
                )
                drawReactionPicture(
                    countPicture(region, selected: selected),
                    in: countFrame.offsetBy(dx: 0, dy: direction * travel * (1 - progress)),
                    alpha: progress,
                    context: context
                )
                context.restoreGState()
            } else {
                drawReactionPicture(countPicture(region, selected: selected), in: countFrame, context: context)
            }
        }
        let avatars = avatarsPicture(region)
        let sourceAvatars = avatarsPicture(source)
        if avatars?.key == sourceAvatars?.key, let avatars, let frame = sourceAvatars?.frame {
            drawReactionPicture(
                avatars.image,
                in: frame.offsetBy(dx: (avatars.frame.minX - frame.minX) * progress, dy: 0),
                context: context
            )
        } else {
            if let sourceAvatars {
                drawReactionPicture(sourceAvatars.image, in: sourceAvatars.frame, alpha: 1 - progress, context: context)
            }
            if let avatars {
                drawReactionPicture(avatars.image, in: avatars.frame, alpha: progress, context: context)
            }
        }
    }

    private func emojiPicture(_ region: NativeTimelineRowLayout.ReactionRegion) -> CGImage? {
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

    private func countPicture(_ region: NativeTimelineRowLayout.ReactionRegion, selected: Bool) -> CGImage? {
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
            image: reactionPicture(key, covering: frame) { NativeTimelineRowPainter.drawReactionAvatars(region) },
            frame: frame,
            key: key
        )
    }

    /// Room around a picture for antialiased edges.
    private static let reactionPictureInset: CGFloat = 1

    /// Draws `draw`, which paints within `frame`, into a cached picture.
    /// `content` must identify everything the drawing depends on besides its
    /// size, scale and appearance.
    private func reactionPicture(_ content: [AnyHashable], covering frame: CGRect, draw: () -> Void) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let bounds = frame.insetBy(dx: -Self.reactionPictureInset, dy: -Self.reactionPictureInset)
        let key = ReactionPictureKey(
            content: content,
            size: frame.size,
            scale: scale,
            appearance: effectiveAppearance.name,
            accent: NSColor.sakuraCordAccentColor.cgColor.components ?? []
        )
        if let image = reactionPictures[key] { return image }
        guard let context = ForumCardRasterizer.makeContext(
            width: Int(ceil(bounds.width * scale)),
            height: Int(ceil(bounds.height * scale)),
            colorSpace: window?.colorSpace?.cgColorSpace ?? ForumCardRasterizer.defaultColorSpace
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if reactionPictures.count >= 512 { reactionPictures.removeAll(keepingCapacity: true) }
        reactionPictures[key] = image
        return image
    }

    private func drawReactionPicture(_ image: CGImage?, in frame: CGRect, alpha: CGFloat = 1, context: CGContext) {
        guard let image, alpha > 0.01 else { return }
        let bounds = frame.insetBy(dx: -Self.reactionPictureInset, dy: -Self.reactionPictureInset)
        context.saveGState()
        context.setAlpha(alpha)
        ForumCardRasterizer.drawUpright(image, in: bounds, context: context)
        context.restoreGState()
    }
}

/// A chip's reactor avatars as one picture, and what it shows.
struct ReactionAvatarsPicture {
    let image: CGImage?
    let frame: CGRect
    let key: [AnyHashable]
}

/// A cached reaction picture's identity.
struct ReactionPictureKey: Hashable {
    let content: [AnyHashable]
    let size: CGSize
    let scale: CGFloat
    let appearance: NSAppearance.Name
    let accent: [CGFloat]
}
