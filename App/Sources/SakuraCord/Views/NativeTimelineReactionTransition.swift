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
        /// A deleted row hands its steps to the row before it.
        var identifier: NativeMessageTimelineItem.Identifier
        var rowIndex: Int
        let delta: CGFloat
        /// A step closing the gap of deleted rows below its row, as
        /// opposed to one of the row's own height.
        var closesGap = false
        /// A step of an edited row's text, which its band draws.
        var movesText = false
    }

    /// Tells the pieces of departed runs which motion they close with.
    var id = 0

    /// Set on the first frame, as for a chip transition.
    var startUptime: TimeInterval?
    var timing = NativeTimelineRowMotionTiming.chips
    let shift: CGFloat
    var steps: [Step]

    func progress(at uptime: TimeInterval) -> CGFloat {
        timing.progress(startedAt: startUptime, at: uptime)
    }
}

/// How an update's row motion and the fades drawn with it ease.
enum NativeTimelineRowMotionTiming {
    /// Chips move on Core Animation's quart curve, so rows moving with them
    /// keep it.
    case chips
    /// An edit or deletion can move rows by hundreds of points, which the
    /// quart curve covers in its first few frames. These glide as the
    /// transcript does when a message is sent.
    case glide

    func progress(at elapsed: TimeInterval) -> CGFloat {
        switch self {
        case .chips:
            return NativeTimelineRowDisclosure.progress(at: elapsed)
        case .glide:
            let curve = NativeTimelineSendTransitionTiming.verticalCurve
            return CGFloat(curve.progress(at: elapsed / curve.duration))
        }
    }

    /// Progress at `uptime` of something that started at `startUptime`, or
    /// none before its first frame.
    func progress(startedAt startUptime: TimeInterval?, at uptime: TimeInterval) -> CGFloat {
        startUptime.map { progress(at: uptime - $0) } ?? 0
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
        /// The row's cached bitmap, if it had one, for a fade without a raster.
        let bitmap: NativeTimelineCanvasView.CachedRowBitmap?
        let revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState
        /// Shown results or a choice in progress, which a deleted poll's
        /// state no longer holds by the time its picture is drawn.
        let pollPresentation: NativeTimelinePollPresentation
        /// The inline editor over a saved edit's row, which shows the row
        /// in place of its text.
        var editor: Editor?
    }

    struct Editor {
        let picture: NSImage
        /// Where the editor sits in the row.
        let frame: CGRect
    }

    /// The canvas width the rows were laid out at.
    let width: CGFloat
    let rows: [NativeMessageTimelineItem.Identifier: Row]
    let rowsByIndex: [Int: Row]

    init(width: CGFloat, rows: [NativeMessageTimelineItem.Identifier: Row]) {
        self.width = width
        self.rows = rows
        rowsByIndex = Dictionary(uniqueKeysWithValues: rows.values.map { ($0.index, $0) })
    }
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
        // An update during an inline edit lands at once: the editor already
        // shows its result. The saved edit hands the editor over to its row
        // as a remote edit would change it.
        guard AppMotionPolicy.animatesUncategorized, window != nil, !items.isEmpty,
              editingMessageID == nil || editing.committedContent != nil
        else { return }
        let originY = contentOriginY - viewportMinY
        // While scrolling, the editor shows as its snapshot.
        let editor = (editingRowScrollSnapshot ?? editingHostSnapshot()).flatMap { picture in
            editingOverlayLocalFrame.map { NativeTimelineReactionBaseline.Editor(picture: picture, frame: $0) }
        }
        var rows: [NativeMessageTimelineItem.Identifier: NativeTimelineReactionBaseline.Row] = [:]
        forEachDisplayedRow(in: reactionBaselineRect) { index in
            let item = items[index]
            let revealState = textSpoilerRevealState(at: index)
            let isEdited = item.messageID == editingMessageID
            rows[item.identifier] = .init(
                index: index,
                top: originY + transientRowOrigin(at: index),
                item: item,
                layout: layouts[index],
                // A bitmap leaves animated media to live overlays and keeps
                // spoilers hidden, so it is no picture of such a row.
                bitmap: animatedMediaRows[item.identifier] == nil && revealState.isEmpty && !isEdited
                    ? bitmapCache[item.identifier] : nil,
                revealedTextSpoilerState: revealState,
                pollPresentation: pollPresentation(for: item.messageID),
                editor: isEdited ? editor : nil
            )
        }
        if !rows.isEmpty { pendingReactionBaseline = NativeTimelineReactionBaseline(width: bounds.width, rows: rows) }
    }

    /// Starts the motion of the update just applied, after the coordinator
    /// has settled the scroll position. Rows whose only change is their
    /// reactions animate their chips; an edited message shows its new
    /// content at once while its neighbours glide to it, and a deleted one
    /// fades in the gap they close.
    /// Any other change near the viewport, such as a new message, applies
    /// instantly as before.
    func beginReactionTransitions() {
        guard let baseline = pendingReactionBaseline else { return }
        pendingReactionBaseline = nil
        // The whole update reads glides at one time, so a stall inside it,
        // such as rasterizing a tall row's picture, is made up on the next
        // frame as one.
        let now = ProcessInfo.processInfo.systemUptime
        deferGlides(pastStallBefore: now)
        let handOvers = self.handOvers
        self.handOvers = [:]
        guard AppMotionPolicy.animatesUncategorized,
              abs(baseline.width - bounds.width) < 0.5,
              editingRowIndex == nil,
              rowDisclosure == nil,
              unreadDividerGap == nil,
              sendTransitions.isEmpty
        else {
            placeDepartedPieces(handOvers.values.flatMap { handOver in
                (handOver.run?.pieces ?? []).map { (handOver.anchor, $0) }
            })
            return
        }
        var followed = Set<NativeMessageTimelineItem.Identifier>()
        forEachDisplayedRow(in: reactionBaselineRect) { followed.insert(items[$0].identifier) }
        // Only rows that left the followed area can have left the timeline,
        // and only those pay for a search of it.
        let gone = baseline.rows.values.filter {
            !followed.contains($0.item.identifier) && rowIndex(forIdentifier: $0.item.identifier) == nil
        }
        var update = NativeTimelineUpdateMotion(
            departedOldIndices: Set(gone.map(\.index)), handOvers: handOvers, motionID: nextReactionMotionID
        )
        refreshReactionMotionGeometry(at: now)
        let originY = contentOriginY - viewportMinY
        forEachDisplayedRow(in: reactionBaselineRect) { index in
            followRow(at: index, from: baseline, originY: originY, now: now, into: &update)
        }
        // Rows deleted after the last followed row close from below.
        if let previous = update.plan.previous {
            let departed = baseline.trailingDepartedRows(after: previous.oldIndex, in: update.departedOldIndices)
            if !departed.isEmpty { closeGap(departed, in: &update) }
        }
        // A row that changed in another way lands where the update put it.
        if update.droppedMotion {
            refreshReactionMotionGeometry(at: now)
            redrawForRowMotion()
        }
        // Live reaction media pauses on its still while the chips move.
        if update.pausesMedia { positionAnimatedMediaOverlays() }
        let timing: NativeTimelineRowMotionTiming = update.startedChips ? .chips : .glide
        // The lines of an edit fade with the motion that eases its height.
        editedTextBands = editedTextBands.filter { running in !update.textBands.contains { $0.identifier == running.key } }
        if update.plan.motion != nil {
            for band in update.textBands { editedTextBands[band.identifier] = band }
            if !update.textBands.isEmpty { positionAnimatedMediaOverlays() }
        }
        if var motion = update.plan.motion {
            motion.id = update.motionID
            motion.timing = timing
            nextReactionMotionID += 1
            reactionRowMotions.append(motion)
            refreshReactionMotionGeometry(at: now)
            redrawForRowMotion()
        }
        // A deleted row's piece belongs to the motion closing its gap and
        // shares its timing.
        placeDepartedPieces(
            update.departedPieces.filter { update.plan.describesUpdate || !$0.isNew }.map { entry in
                var piece = entry.piece
                if entry.isNew { piece.timing = timing }
                return (entry.anchor, piece)
            }
                + update.handOvers.values.flatMap { handOver in
                    (handOver.run?.pieces ?? []).map { (handOver.anchor, $0) }
                }
        )
        guard update.startedChips || !departedRuns.isEmpty || update.plan.motion != nil
        else { return }
        reactionTransitionWidth = bounds.width
        if reactionTicker.displayLink == nil {
            reactionStepUptime = nil
            reactionTicker.start(on: self) { [weak self] in self?.stepReactionTransitions() }
        }
    }

    /// Adds pieces to the runs below their rows, in order. A piece whose
    /// motion was dropped meanwhile has no gap left to fade in.
    private func placeDepartedPieces(_ pieces: [(anchor: NativeMessageTimelineItem.Identifier, piece: NativeTimelineDepartedRun.Piece)]) {
        let motionIDs = Set(reactionRowMotions.map(\.id))
        for (anchor, piece) in pieces where motionIDs.contains(piece.motionID) {
            departedRuns[anchor, default: .init()].pieces.append(piece)
        }
    }

    /// Follows one displayed row from where it was before the update.
    private func followRow(
        at index: Int,
        from baseline: NativeTimelineReactionBaseline,
        originY: CGFloat,
        now: TimeInterval,
        into update: inout NativeTimelineUpdateMotion
    ) {
        let identifier = items[index].identifier
        // Rows entering the followed area have no earlier place. One
        // inserted between followed rows fails the plan's shift check.
        guard let old = baseline.rows[identifier] else { return }
        let firstDeparted = update.departedPieces.count
        if let previous = update.plan.previous, old.index != previous.oldIndex + 1 {
            let departed = baseline.departedRows(after: previous.oldIndex, before: old.index, in: update.departedOldIndices)
            closeGap(departed, in: &update)
        }
        let row = NativeTimelineRowMotionPlan.FollowedRow(oldIndex: old.index, index: index, identifier: identifier)
        let delta = layouts[index].height - old.layout.height
        update.plan.follow(row, rowShift: old.top - (originY + rowOrigins[index]), delta: delta)
        // A saved edit's editor gives way to the row as an edit's content does.
        switch old.editor == nil ? items[index].change(from: old.item) : .content {
        case .none:
            if abs(delta) >= 0.5 { update.plan.invalidate() }
        case .reactions:
            update.plan.addStep(for: row, delta: delta)
            // Reactions changing under an edit's gliding lines move with
            // them instead of starting their chips at the final place.
            if editedTextBands[identifier] == nil, rowFrame(at: index).intersects(visibleRect),
               beginReactionTransition(at: index, from: old, now: now) {
                update.startedChips = true
                update.pausesMedia = update.pausesMedia || animatedMediaRows[identifier] != nil
            }
        case .regroup where !update.departedOldIndices.isDisjoint(with: [old.index - 1, old.index + 1]),
             .content:
            let band = editedTextBand(from: old, at: index, width: baseline.width, motionID: update.motionID)
            update.plan.addStep(for: row, delta: delta, movesText: band != nil)
            if let band {
                update.textBands.append(band)
                if band.slidingTextOrigin != nil {
                    for piece in update.departedPieces.indices.dropFirst(firstDeparted) {
                        update.departedPieces[piece].piece.fadeEnd = NativeTimelineDepartedRun.handoffFadeEnd
                    }
                }
            } else {
                // A band can't follow this change, and the running one would
                // part the new layout at the earlier text's end.
                editedTextBands[identifier] = nil
            }
            // A motion still running from an earlier change keeps going, so
            // this one starts from the height the row shows now.
            endReactionTransition(identifier)
        case .regroup, .other:
            if abs(delta) >= 0.5 { update.plan.invalidate() }
            update.droppedMotion = dropReactionMotion(of: identifier) || update.droppedMotion
        }
    }

    /// Deleted rows close their gap as a step of the followed row before
    /// them, each fading out in its own part of it.
    private func closeGap(_ rows: [NativeTimelineReactionBaseline.Row]?, in update: inout NativeTimelineUpdateMotion) {
        guard let rows, let previous = update.plan.previous else {
            update.plan.invalidate()
            return
        }
        var shown: CGFloat = 0
        for row in rows {
            let handOver = update.handOvers.removeValue(forKey: row.item.identifier)
            // A row still changing height leaves from the height it shows.
            let height = row.layout.height - (handOver?.residualHeight ?? 0)
            shown += height
            // A row deleted while still sliding in its header has no picture
            // of what it showed, so it leaves its space blank.
            let sliding = editedTextBands[row.item.identifier]?.slidingTextOrigin != nil
            let piece = NativeTimelineDepartedRun.Piece(
                image: sliding ? nil : rowFadeImage(row, width: bounds.width), height: height, motionID: update.motionID
            )
            update.departedPieces.append(.init(anchor: previous.identifier, piece: piece, isNew: true))
            // What was still closing below the row stays below it.
            for inherited in handOver?.run?.pieces ?? [] {
                update.departedPieces.append(.init(anchor: previous.identifier, piece: inherited, isNew: false))
            }
        }
        update.plan.closeGap(height: rows.reduce(0) { $0 + $1.layout.height }, shown: shown)
    }

    /// A deleted row hands what it still showed to the row before it: the
    /// steps closing gaps below it and their run, which keep closing from
    /// where they are, and the rest of its own height change, which leaves
    /// with it. Runs when the update lands, before motions whose rows are
    /// gone are dropped; the update that follows places what was handed.
    private func handOverDepartedMotion(in baseline: NativeTimelineReactionBaseline, at now: TimeInterval) {
        let gone = Set(reactionRowMotions.flatMap(\.steps).compactMap { step in
            rowIndex(forIdentifier: step.identifier, hint: step.rowIndex) == nil ? baseline.rows[step.identifier] : nil
        }.map(\.index))
        for oldIndex in gone.sorted() {
            guard let identifier = baseline.rowsByIndex[oldIndex]?.item.identifier else { continue }
            var anchorIndex = oldIndex - 1
            while let row = baseline.rowsByIndex[anchorIndex], rowIndex(forIdentifier: row.item.identifier) == nil {
                anchorIndex -= 1
            }
            guard let anchor = baseline.rowsByIndex[anchorIndex]?.item.identifier,
                  let index = rowIndex(forIdentifier: anchor)
            else { continue }
            var handOver = HandOver(anchor: anchor, run: departedRuns.removeValue(forKey: identifier))
            for motion in reactionRowMotions.indices {
                let left = 1 - reactionRowMotions[motion].progress(at: now)
                reactionRowMotions[motion].steps.removeAll { step in
                    guard step.identifier == identifier, !step.closesGap else { return false }
                    handOver.residualHeight += step.delta * left
                    return true
                }
                for step in reactionRowMotions[motion].steps.indices
                    where reactionRowMotions[motion].steps[step].identifier == identifier {
                    reactionRowMotions[motion].steps[step].identifier = anchor
                    reactionRowMotions[motion].steps[step].rowIndex = index
                }
            }
            handOvers[identifier] = handOver
        }
    }

    /// Ends a row's chips and the motions it takes part in, for a row that
    /// changed in another way. True when a motion was dropped.
    private func dropReactionMotion(of identifier: NativeMessageTimelineItem.Identifier) -> Bool {
        endReactionTransition(identifier)
        return removeReactionMotions { $0.steps.contains { $0.identifier == identifier } }
    }

    /// Removes motions, and the deleted rows fading in their gaps: the gaps
    /// close at once. True when any was removed.
    @discardableResult
    private func removeReactionMotions(where shouldRemove: (NativeTimelineReactionRowMotion) -> Bool) -> Bool {
        let removed = reactionRowMotions.filter(shouldRemove)
        guard !removed.isEmpty else { return false }
        reactionRowMotions.removeAll(where: shouldRemove)
        let removedIDs = Set(removed.map(\.id))
        editedTextBands = editedTextBands.filter { !removedIDs.contains($0.value.motionID) }
        departedRuns = departedRuns.compactMapValues { $0.removingPieces { removedIDs.contains($0.motionID) } }
        return true
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
        deferGlides(pastStallBefore: now)
        let hadMotion = !reactionRowMotions.isEmpty
        for index in reactionRowMotions.indices where reactionRowMotions[index].startUptime == nil {
            reactionRowMotions[index].startUptime = now
        }
        reactionRowMotions.removeAll { $0.progress(at: now) >= 1 }
        refreshDepartedRunIndices()
        let fadeFrame = departedRunFrame
        let runningMotionIDs = Set(reactionRowMotions.map(\.id))
        let bandCount = editedTextBands.count
        // A view the row gains over its content mid-glide, such as a hovered
        // audio player, sits at its final place: the row joins it there.
        editedTextBands = editedTextBands.reduce(into: [:]) { bands, entry in
            var band = entry.value
            guard runningMotionIDs.contains(band.motionID),
                  let index = rowIndex(forIdentifier: entry.key, hint: band.rowIndex), !hostsLiveViews(at: index)
            else { return }
            band.rowIndex = index
            bands[entry.key] = band
        }
        let endsBands = editedTextBands.count != bandCount
        departedRuns = departedRuns.compactMapValues { $0.advanced(to: now) }
        // Frames that move no row by a whole pixel redraw only the chips; the
        // last one also hands hover back to the rows where they landed.
        let moved = refreshReactionMotionGeometry(at: now)
        let redrawsRows = hadMotion && (moved || endsBands || reactionRowMotions.isEmpty)
        var reconcilesMedia = endsBands
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
        if !fadeFrame.isNull { setNeedsDisplay(fadeFrame.union(departedRunFrame)) }
        if reconcilesMedia { reconcileAnimatedMediaOverlays(reduceMotion: false) }
        if reactionTransitions.isEmpty, reactionRowMotions.isEmpty, departedRuns.isEmpty {
            reactionTicker.stop()
        }
    }

    /// A late frame moves glides by at most one 60 Hz frame of their curve.
    private static let reactionFrameAllowance: TimeInterval = 1.0 / 60

    /// The time row motion was last brought to. Drawing reads fades and
    /// gaps at it, so they stay with the rows' places when a draw stalls.
    var rowMotionUptime: TimeInterval {
        reactionStepUptime ?? ProcessInfo.processInfo.systemUptime
    }

    /// A late frame, such as one held up by the first draw of a tall row,
    /// delays glides instead of skipping part of them. Chip motions keep
    /// their clock, since Core Animation runs the chips through the stall.
    /// Runs before anything reads a glide's progress, so an update landing
    /// after a stall starts from where the rows still are.
    private func deferGlides(pastStallBefore now: TimeInterval) {
        guard let last = reactionStepUptime else {
            reactionStepUptime = now
            return
        }
        guard now > last else { return }
        reactionStepUptime = now
        let stall = now - last - Self.reactionFrameAllowance
        guard stall > 0 else { return }
        for index in reactionRowMotions.indices where reactionRowMotions[index].timing == .glide {
            reactionRowMotions[index].startUptime? += stall
        }
        for run in departedRuns.values.indices {
            let pieces = departedRuns.values[run].pieces
            for index in pieces.indices where pieces[index].timing == .glide {
                departedRuns.values[run].pieces[index].startUptime? += stall
            }
        }
        // Runs handed over by a deleted row wait here for the next update.
        for handOver in handOvers.values.indices {
            guard let pieces = handOvers.values[handOver].run?.pieces else { continue }
            for index in pieces.indices where pieces[index].timing == .glide {
                handOvers.values[handOver].run?.pieces[index].startUptime? += stall
            }
        }
    }

    /// Lands every reaction motion on the static layout, for another motion
    /// or a conversation change.
    func finishReactionTransitions() {
        pendingReactionBaseline = nil
        reactionTicker.stop()
        let hadMotion = !reactionRowMotions.isEmpty
        let hadChips = !reactionTransitions.isEmpty || !departedRuns.isEmpty || !editedTextBands.isEmpty
        reactionRowMotions.removeAll()
        editedTextBands.removeAll()
        departedRuns.removeAll()
        handOvers.removeAll()
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
        deferGlides(pastStallBefore: uptime)
        guard !reactionRowMotions.isEmpty || !reactionMotionSteps.isEmpty else { return false }
        if let pendingReactionBaseline { handOverDepartedMotion(in: pendingReactionBaseline, at: uptime) }
        // A motion whose row is gone no longer describes the layout.
        removeReactionMotions { motion in
            motion.steps.contains { rowIndex(forIdentifier: $0.identifier, hint: $0.rowIndex) == nil }
        }
        var shift: CGFloat = 0
        var steps: [(index: Int, offset: CGFloat)] = []
        var textRemaining: [Int: CGFloat] = [:]
        for motionIndex in reactionRowMotions.indices {
            let motion = reactionRowMotions[motionIndex]
            let left = 1 - motion.progress(at: uptime)
            shift += motion.shift * left
            for stepIndex in motion.steps.indices {
                let step = motion.steps[stepIndex]
                guard let index = rowIndex(forIdentifier: step.identifier, hint: step.rowIndex) else { continue }
                reactionRowMotions[motionIndex].steps[stepIndex].rowIndex = index
                steps.append((index, step.delta * left))
                if step.movesText { textRemaining[index, default: 0] += step.delta * left }
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
        reactionMotionTextRemainingHeights = textRemaining
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
