import AppKit
import SakuraCordModels

/// One update's rows changing height, such as reaction lines opening or
/// closing or an edit or deletion. Rows keep the places they
/// had on screen before the update and ease onto the static layout: rows up to
/// the first changed one are displaced by `shift`, and each changed row hides
/// the part of its height change that has not happened yet, which displaces
/// every row after it. Updates overlap freely; each one's displacement simply
/// adds to the others'. The NEW divider's gap and a group opening or closing
/// are row motions too, held with what they draw besides by
/// `NativeTimelineUnreadDividerGap` and `NativeTimelineRowDisclosure`.
struct NativeTimelineRowMotion {
    struct Step {
        /// Where the step displaces rows from.
        enum Edge {
            /// The row's own height change: the rows after it move, and the
            /// row hides the part that has not happened yet.
            case height
            /// The rows after the row move, as a group opens or closes below
            /// its header.
            case belowRow
            /// The row and the rows after it move, as the NEW divider's space
            /// opens or closes above its row.
            case aboveRow
        }

        /// A deleted row hands its steps to the row before it.
        var identifier: NativeMessageTimelineItem.Identifier
        var rowIndex: Int
        let delta: CGFloat
        /// A step closing the gap of deleted rows below its row, as
        /// opposed to one of the row's own height.
        var closesGap = false
        /// A step of an edited row's text, which its band draws.
        var movesText = false
        var edge = Edge.height
    }

    /// A step's displacement while the geometry is summed: rows after `index`
    /// are displaced `value` less than those before, its own offset and then
    /// the running total.
    struct Offset {
        let index: Int
        var value: CGFloat
        /// Part of the height of the row at `index`, which hides it.
        var hidesHeight: Bool
    }

    /// Tells the pieces of departed runs which motion they close with.
    var id = 0

    /// Set on the first frame, as for a chip transition.
    var startUptime: TimeInterval?
    var timing = NativeTimelineRowMotionTiming.quart
    var shift: CGFloat
    var steps: [Step]

    func progress(at uptime: TimeInterval) -> CGFloat {
        timing.progress(startedAt: startUptime, at: uptime)
    }
}

/// How an update's row motion and the fades drawn with it ease.
enum NativeTimelineRowMotionTiming {
    /// Reaction chips move on Core Animation's quart curve, so rows moving
    /// with them keep it. Its ease-out with a soft landing is close to
    /// AppKit's disclosure motion, so groups opening or closing use it too.
    case quart
    /// An edit or deletion can move rows by hundreds of points, which the
    /// quart curve covers in its first few frames. These glide as the
    /// transcript does when a message is sent.
    case glide

    static let quartDuration: TimeInterval = 0.3

    func progress(at elapsed: TimeInterval) -> CGFloat {
        switch self {
        case .quart:
            let fraction = min(1, max(0, elapsed / Self.quartDuration))
            return 1 - pow(1 - fraction, 4)
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
struct NativeTimelineRowMotionBaseline {
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

/// The canvas's running row motions and the geometry they produce each frame.
@MainActor
final class NativeTimelineRowMotionState {
    /// What a row deleted by the update landing now was still showing:
    /// the run closing below it and the part of its own height change
    /// still to come, both now the row before it's.
    struct HandOver {
        let anchor: NativeMessageTimelineItem.Identifier
        var run: NativeTimelineDepartedRun?
        var residualHeight: CGFloat = 0
    }

    var pendingBaseline: NativeTimelineRowMotionBaseline?
    var motions: [NativeTimelineRowMotion] = []
    /// Per-frame geometry of `motions`: the displacement of rows up
    /// to the first changed one, and how much less each changed row and the
    /// rows after it are displaced.
    var shift: CGFloat = 0
    var steps: [(index: Int, cumulative: CGFloat)] = []
    /// Each step's offset, then their running totals, while the geometry is
    /// refreshed: kept between refreshes so they reuse its storage.
    var stepScratch: [NativeTimelineRowMotion.Offset] = []
    var remainingHeights: [Int: CGFloat] = [:]
    /// The part of each row's remaining height that its edited text's band still has to glide.
    var textRemainingHeights: [Int: CGFloat] = [:]
    /// Rows an opening or closing gap or group shows only part of, and the
    /// span they show, relative to the first one's static top, so a content-origin
    /// change can never leave the clip behind the rows.
    var clippedRows: Range<Int> = 0 ..< 0
    var clippedRowsRelativeMinY = -CGFloat.greatestFiniteMagnitude
    var clippedRowsRelativeMaxY = CGFloat.greatestFiniteMagnitude
    var departedRuns: [NativeMessageTimelineItem.Identifier: NativeTimelineDepartedRun] = [:]
    /// By deleted row, for the update that deleted it to place.
    var handOvers: [NativeMessageTimelineItem.Identifier: HandOver] = [:]
    var nextID = 1
    /// Steps every row motion: updates', the divider gap's and a group's.
    let ticker = DisplayLinkTicker()
    /// When the ticker last stepped, to tell a late frame.
    var stepUptime: TimeInterval?
    /// The width the running motions were laid out at.
    var layoutWidth: CGFloat = 0
    /// The display scale and colour space moving rows and chips were drawn
    /// for; a change finishes the motions.
    var backing: (scale: CGFloat, colorSpace: NSColorSpace?) = (0, nil)
}

extension NativeTimelineCanvasView {
    /// How far beyond the viewport rows are followed, so rows a change pulls
    /// into view start from where they were.
    private static let rowMotionBaselineMargin: CGFloat = 240

    private var rowMotionBaselineRect: CGRect {
        visibleRect.insetBy(dx: 0, dy: -Self.rowMotionBaselineMargin)
    }

    /// Records the rows around the viewport before the coordinator replaces
    /// them in the shared storage.
    func captureRowMotionBaseline() {
        rowMotion.pendingBaseline = nil
        // An update during an inline edit lands at once: the editor already
        // shows its result. The saved edit hands the editor over to its row
        // as a remote edit would change it.
        guard AppMotionPolicy.animatesUncategorized, window != nil, !items.isEmpty,
              editing.messageID == nil || editing.committedContent != nil
        else { return }
        let originY = contentOriginY - viewportMinY
        // While scrolling, the editor shows as its snapshot.
        let editor = (editing.scrollSnapshot ?? editingHostSnapshot()).flatMap { picture in
            editing.overlayLocalFrame.map { NativeTimelineRowMotionBaseline.Editor(picture: picture, frame: $0) }
        }
        var rows: [NativeMessageTimelineItem.Identifier: NativeTimelineRowMotionBaseline.Row] = [:]
        forEachDisplayedRow(in: rowMotionBaselineRect) { index in
            let item = items[index]
            let revealState = textSpoilerRevealState(at: index)
            let isEdited = item.messageID == editing.messageID
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
        if !rows.isEmpty { rowMotion.pendingBaseline = NativeTimelineRowMotionBaseline(width: bounds.width, rows: rows) }
    }

    /// Starts the motion of the update just applied, after the coordinator
    /// has settled the scroll position. Rows whose only change is their
    /// reactions animate their chips; an edited message shows its new
    /// content at once while its neighbours glide to it, and a deleted one
    /// fades in the gap they close.
    /// Any other change near the viewport, such as a new message, applies
    /// instantly as before.
    func beginRowMotions() {
        guard let baseline = rowMotion.pendingBaseline else { return }
        rowMotion.pendingBaseline = nil
        // The whole update reads glides at one time, so a stall inside it,
        // such as rasterizing a tall row's picture, is made up on the next
        // frame as one.
        let now = ProcessInfo.processInfo.systemUptime
        deferGlides(pastStallBefore: now)
        let handOvers = rowMotion.handOvers
        rowMotion.handOvers = [:]
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
        forEachDisplayedRow(in: rowMotionBaselineRect) { followed.insert(items[$0].identifier) }
        // Only rows that left the followed area can have left the timeline,
        // and only those pay for a search of it.
        let gone = baseline.rows.values.filter {
            !followed.contains($0.item.identifier) && rowIndex(forIdentifier: $0.item.identifier) == nil
        }
        var update = NativeTimelineUpdateMotion(
            departedOldIndices: Set(gone.map(\.index)), handOvers: handOvers, motionID: rowMotion.nextID
        )
        refreshRowMotionGeometry(at: now)
        let originY = contentOriginY - viewportMinY
        forEachDisplayedRow(in: rowMotionBaselineRect) { index in
            followRow(at: index, from: baseline, originY: originY, now: now, into: &update)
        }
        // Rows deleted after the last followed row close from below.
        if let previous = update.plan.previous {
            let departed = baseline.trailingDepartedRows(after: previous.oldIndex, in: update.departedOldIndices)
            if !departed.isEmpty { closeGap(departed, in: &update) }
        }
        // A row that changed in another way lands where the update put it.
        if update.droppedMotion {
            refreshRowMotionGeometry(at: now)
            redrawForRowMotion()
        }
        // Live reaction media pauses on its still while the chips move.
        if update.pausesMedia { positionAnimatedMediaOverlays() }
        let timing: NativeTimelineRowMotionTiming = update.startedChips ? .quart : .glide
        // The lines of an edit fade with the motion that eases its height.
        editedTextBands = editedTextBands.filter { running in !update.textBands.contains { $0.identifier == running.key } }
        if update.plan.motion != nil {
            for band in update.textBands { editedTextBands[band.identifier] = band }
            if !update.textBands.isEmpty { positionAnimatedMediaOverlays() }
        }
        if var motion = update.plan.motion {
            motion.id = update.motionID
            motion.timing = timing
            rowMotion.nextID += 1
            rowMotion.motions.append(motion)
            refreshRowMotionGeometry(at: now)
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
        guard update.startedChips || !rowMotion.departedRuns.isEmpty || update.plan.motion != nil
        else { return }
        rowMotion.layoutWidth = bounds.width
        startRowMotionTicker()
    }

    /// Adds pieces to the runs below their rows, in order. A piece whose
    /// motion was dropped meanwhile has no gap left to fade in.
    private func placeDepartedPieces(_ pieces: [(anchor: NativeMessageTimelineItem.Identifier, piece: NativeTimelineDepartedRun.Piece)]) {
        let motionIDs = Set(rowMotion.motions.map(\.id))
        for (anchor, piece) in pieces where motionIDs.contains(piece.motionID) {
            rowMotion.departedRuns[anchor, default: .init()].pieces.append(piece)
        }
    }

    /// Follows one displayed row from where it was before the update.
    private func followRow(
        at index: Int,
        from baseline: NativeTimelineRowMotionBaseline,
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
            update.droppedMotion = dropRowMotion(of: identifier) || update.droppedMotion
        }
    }

    /// Deleted rows close their gap as a step of the followed row before
    /// them, each fading out in its own part of it.
    private func closeGap(_ rows: [NativeTimelineRowMotionBaseline.Row]?, in update: inout NativeTimelineUpdateMotion) {
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
    private func handOverDepartedMotion(in baseline: NativeTimelineRowMotionBaseline, at now: TimeInterval) {
        let gone = Set(rowMotion.motions.flatMap(\.steps).compactMap { step in
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
            var handOver = NativeTimelineRowMotionState.HandOver(anchor: anchor, run: rowMotion.departedRuns.removeValue(forKey: identifier))
            for motion in rowMotion.motions.indices {
                let left = 1 - rowMotion.motions[motion].progress(at: now)
                rowMotion.motions[motion].steps.removeAll { step in
                    guard step.identifier == identifier, !step.closesGap else { return false }
                    handOver.residualHeight += step.delta * left
                    return true
                }
                for step in rowMotion.motions[motion].steps.indices
                    where rowMotion.motions[motion].steps[step].identifier == identifier {
                    rowMotion.motions[motion].steps[step].identifier = anchor
                    rowMotion.motions[motion].steps[step].rowIndex = index
                }
            }
            rowMotion.handOvers[identifier] = handOver
        }
    }

    /// Ends a row's chips and the motions it takes part in, for a row that
    /// changed in another way. True when a motion was dropped.
    private func dropRowMotion(of identifier: NativeMessageTimelineItem.Identifier) -> Bool {
        endReactionTransition(identifier)
        return removeRowMotions { $0.steps.contains { $0.identifier == identifier } }
    }

    /// Removes motions, and the deleted rows fading in their gaps: the gaps
    /// close at once. True when any was removed.
    @discardableResult
    private func removeRowMotions(where shouldRemove: (NativeTimelineRowMotion) -> Bool) -> Bool {
        let removed = rowMotion.motions.filter(shouldRemove)
        guard !removed.isEmpty else { return false }
        rowMotion.motions.removeAll(where: shouldRemove)
        let removedIDs = Set(removed.map(\.id))
        editedTextBands = editedTextBands.filter { !removedIDs.contains($0.value.motionID) }
        rowMotion.departedRuns = rowMotion.departedRuns.compactMapValues { $0.removingPieces { removedIDs.contains($0.motionID) } }
        return true
    }

    /// Starts stepping row motions from the next frame, unless they already are.
    func startRowMotionTicker() {
        guard rowMotion.ticker.displayLink == nil else { return }
        rowMotion.stepUptime = nil
        rowMotion.ticker.start(on: self) { [weak self] in self?.stepRowMotions() }
    }

    /// The divider's gap or a group opening or closing, whose rows show only
    /// part of themselves. A closed group holding its rows until they go
    /// stands still.
    var clipsMovingRows: Bool {
        unreadDividerGap != nil || rowDisclosure?.isFinished == false
    }

    /// Whether any row motion is moving rows.
    var rowMotionIsRunning: Bool {
        !rowMotion.motions.isEmpty || clipsMovingRows
    }

    func stopRowMotionTickerIfIdle() {
        guard !rowMotionIsRunning, reactionTransitions.isEmpty, rowMotion.departedRuns.isEmpty else { return }
        rowMotion.ticker.stop()
    }

    /// Whether views of the row's own sit over what it draws: a playing
    /// video, an audio player, a spoiler cover, a control's loading dots,
    /// an upload's ring or a hovered code block's copy button. They keep
    /// their final places, so the row moves as one piece instead of parting
    /// from them.
    func hostsLiveViews(at index: Int) -> Bool {
        let identifier = items[index].identifier
        let messageID = items[index].messageID
        return inlinePlayers.keys.contains { $0.row == identifier }
            || inlineVideoOverlays.keys.contains { $0.row == identifier }
            || spoilerOverlays.keys.contains { $0.messageID == messageID }
            || activityIndicators.keys.contains { $0.row == identifier }
            || uploadRings.keys.contains { $0.row == identifier }
            || pointer.hoveredCodeBlock?.itemIdentifier == identifier
            || [voiceMessageOverlay, voiceMessageHoverOverlay].contains { overlay in
                overlay.map { overlay in layouts[index].audioPlayers.contains { $0.playbackID == overlay.region.playbackID } } ?? false
            }
    }

    /// Steps every row motion at one time, in a fixed order: the divider's
    /// gap, a group, then updates and what moves with them.
    private func stepRowMotions() {
        let now = ProcessInfo.processInfo.systemUptime
        deferGlides(pastStallBefore: now)
        stepUnreadDividerGap(at: now)
        stepDisclosure(at: now)
        let hadMotion = !rowMotion.motions.isEmpty
        for index in rowMotion.motions.indices where rowMotion.motions[index].startUptime == nil {
            rowMotion.motions[index].startUptime = now
        }
        rowMotion.motions.removeAll { $0.progress(at: now) >= 1 }
        refreshDepartedRunIndices()
        let fadeFrame = departedRunFrame
        let runningMotionIDs = Set(rowMotion.motions.map(\.id))
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
        rowMotion.departedRuns = rowMotion.departedRuns.compactMapValues { $0.advanced(to: now) }
        // Frames that move no row by a whole pixel redraw only the chips; the
        // last one also hands hover back to the rows where they landed.
        let moved = refreshRowMotionGeometry(at: now)
        let redrawsRows = moved || (hadMotion && (endsBands || rowMotion.motions.isEmpty))
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
        if redrawsRows { redrawForRowMotion(invalidating: rowMotionFrame) }
        if !fadeFrame.isNull { setNeedsDisplay(fadeFrame.union(departedRunFrame)) }
        if reconcilesMedia { reconcileAnimatedMediaOverlays(reduceMotion: false) }
        stopRowMotionTickerIfIdle()
    }

    /// A late frame moves glides by at most one 60 Hz frame of their curve.
    private static let rowMotionFrameAllowance: TimeInterval = 1.0 / 60

    /// The time row motion was last brought to. Drawing reads fades and
    /// gaps at it, so they stay with the rows' places when a draw stalls.
    var rowMotionUptime: TimeInterval {
        rowMotion.stepUptime ?? ProcessInfo.processInfo.systemUptime
    }

    /// A late frame, such as one held up by the first draw of a tall row,
    /// delays glides instead of skipping part of them. Chip motions keep
    /// their clock, since Core Animation runs the chips through the stall.
    /// Runs before anything reads a glide's progress, so an update landing
    /// after a stall starts from where the rows still are.
    private func deferGlides(pastStallBefore now: TimeInterval) {
        guard let last = rowMotion.stepUptime else {
            rowMotion.stepUptime = now
            return
        }
        guard now > last else { return }
        rowMotion.stepUptime = now
        let stall = now - last - Self.rowMotionFrameAllowance
        guard stall > 0 else { return }
        for index in rowMotion.motions.indices where rowMotion.motions[index].timing == .glide {
            rowMotion.motions[index].startUptime? += stall
        }
        for run in rowMotion.departedRuns.values.indices {
            let pieces = rowMotion.departedRuns.values[run].pieces
            for index in pieces.indices where pieces[index].timing == .glide {
                rowMotion.departedRuns.values[run].pieces[index].startUptime? += stall
            }
        }
        // Runs handed over by a deleted row wait here for the next update.
        for handOver in rowMotion.handOvers.values.indices {
            guard let pieces = rowMotion.handOvers.values[handOver].run?.pieces else { continue }
            for index in pieces.indices where pieces[index].timing == .glide {
                rowMotion.handOvers.values[handOver].run?.pieces[index].startUptime? += stall
            }
        }
    }

    /// Lands every row motion on the static layout, for another motion
    /// or a conversation change.
    func finishRowMotions() {
        rowMotion.pendingBaseline = nil
        let hadMotion = !rowMotion.motions.isEmpty
        let hadChips = !reactionTransitions.isEmpty || !rowMotion.departedRuns.isEmpty || !editedTextBands.isEmpty
        rowMotion.motions.removeAll()
        editedTextBands.removeAll()
        rowMotion.departedRuns.removeAll()
        rowMotion.handOvers.removeAll()
        for identifier in reactionTransitions.keys { endReactionTransition(identifier) }
        stopRowMotionTickerIfIdle()
        refreshRowMotionGeometry()
        if hadMotion {
            redrawForRowMotion()
        } else if hadChips {
            invalidateVisibleContent()
        }
        if hadChips { positionAnimatedMediaOverlays() }
    }

    /// Recomputes the cached displacement read by `displayedRowOrigin(at:)`
    /// from every row motion, and the clip of the rows a gap or group shows
    /// only part of. True when any row moved.
    @discardableResult
    func refreshRowMotionGeometry(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        deferGlides(pastStallBefore: uptime)
        guard !rowMotion.motions.isEmpty || unreadDividerGap != nil || rowDisclosure != nil || !rowMotion.steps.isEmpty
        else { return false }
        if let baseline = rowMotion.pendingBaseline { handOverDepartedMotion(in: baseline, at: uptime) }
        // A motion whose row is gone no longer describes the layout.
        removeRowMotions { motion in
            motion.steps.contains { rowIndex(forIdentifier: $0.identifier, hint: $0.rowIndex) == nil }
        }
        var shift: CGFloat = 0
        rowMotion.stepScratch.removeAll(keepingCapacity: true)
        rowMotion.textRemainingHeights.removeAll(keepingCapacity: true)
        func add(_ motion: inout NativeTimelineRowMotion) {
            let left = 1 - motion.progress(at: uptime)
            shift += motion.shift * left
            for stepIndex in motion.steps.indices {
                let step = motion.steps[stepIndex]
                guard let index = rowIndex(forIdentifier: step.identifier, hint: step.rowIndex) else { continue }
                if index != step.rowIndex { motion.steps[stepIndex].rowIndex = index }
                rowMotion.stepScratch.append(.init(
                    index: step.edge == .aboveRow ? index - 1 : index, value: step.delta * left, hidesHeight: step.edge == .height
                ))
                if step.movesText { rowMotion.textRemainingHeights[index, default: 0] += step.delta * left }
            }
        }
        for motionIndex in rowMotion.motions.indices { add(&rowMotion.motions[motionIndex]) }
        if unreadDividerGap != nil { add(&unreadDividerGap!.motion) }
        if rowDisclosure != nil { add(&rowDisclosure!.motion) }
        let moved = storeRowMotionSteps(shift: shift)
        refreshClippedRows()
        return moved
    }

    /// Sums the step offsets just collected into the displacement rows read,
    /// on whole device pixels so moving rows stay sharp. Works in place, so a
    /// running motion allocates nothing per frame. True when any row moved.
    private func storeRowMotionSteps(shift: CGFloat) -> Bool {
        let scale = window?.backingScaleFactor ?? 2
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        rowMotion.stepScratch.sort { $0.index < $1.index }
        // Offsets at one index become one running total.
        var count = 0
        var total: CGFloat = 0
        for position in rowMotion.stepScratch.indices {
            let step = rowMotion.stepScratch[position]
            total += step.value
            var hidesHeight = step.hidesHeight
            if count > 0, rowMotion.stepScratch[count - 1].index == step.index {
                count -= 1
                hidesHeight = hidesHeight || rowMotion.stepScratch[count].hidesHeight
            }
            rowMotion.stepScratch[count] = .init(index: step.index, value: snapped(total), hidesHeight: hidesHeight)
            count += 1
        }
        rowMotion.stepScratch.removeLast(rowMotion.stepScratch.count - count)
        let snappedShift = snapped(shift)
        let moved = snappedShift != rowMotion.shift
            || !rowMotion.stepScratch.elementsEqual(rowMotion.steps) { $0.index == $1.index && $0.value == $1.cumulative }
        rowMotion.shift = snappedShift
        rowMotion.steps.removeAll(keepingCapacity: true)
        rowMotion.remainingHeights.removeAll(keepingCapacity: true)
        for position in rowMotion.stepScratch.indices {
            let step = rowMotion.stepScratch[position]
            rowMotion.steps.append((step.index, step.value))
            // A row's hidden height is the step its own change adds.
            if step.hidesHeight {
                rowMotion.remainingHeights[step.index] = step.value - (position > 0 ? rowMotion.stepScratch[position - 1].value : 0)
            }
        }
        return moved
    }

    /// The rows an opening or closing gap or group shows only part of, and
    /// the span they show: from where the rows before them end to where the
    /// rows after them start. The divider's row never draws above its gap.
    private func refreshClippedRows() {
        if let gap = unreadDividerGap, rowOrigins.indices.contains(gap.rowIndex) {
            rowMotion.clippedRows = gap.rowIndex ..< gap.rowIndex + 1
            rowMotion.clippedRowsRelativeMinY = rowMotionOffset(at: gap.rowIndex - 1)
            rowMotion.clippedRowsRelativeMaxY = .greatestFiniteMagnitude
        } else if let disclosure = rowDisclosure, !disclosure.rows.isEmpty {
            rowMotion.clippedRows = disclosure.rows
            rowMotion.clippedRowsRelativeMinY = rowMotionOffset(at: disclosure.rows.lowerBound - 1)
            rowMotion.clippedRowsRelativeMaxY = disclosure.rowsHeight + rowMotionOffset(at: disclosure.rows.upperBound)
        } else {
            rowMotion.clippedRows = 0 ..< 0
            rowMotion.clippedRowsRelativeMinY = -.greatestFiniteMagnitude
            rowMotion.clippedRowsRelativeMaxY = .greatestFiniteMagnitude
        }
    }

    var clippedRowsMinY: CGFloat {
        guard !rowMotion.clippedRows.isEmpty else { return -.greatestFiniteMagnitude }
        return contentOriginY + rowOrigins[rowMotion.clippedRows.lowerBound] + rowMotion.clippedRowsRelativeMinY
    }

    var clippedRowsMaxY: CGFloat {
        guard !rowMotion.clippedRows.isEmpty else { return .greatestFiniteMagnitude }
        return contentOriginY + rowOrigins[rowMotion.clippedRows.lowerBound] + rowMotion.clippedRowsRelativeMaxY
    }

    /// The part of the viewport whose rows move: from the top when rows
    /// before the first changed one are displaced, to the bottom when rows
    /// after the last one are. A gap or group also clips rows and moves
    /// overlays.
    private var rowMotionFrame: CGRect {
        let visible = visibleRect
        guard unreadDividerGap == nil, rowDisclosure == nil, let first = rowMotion.steps.first, let last = rowMotion.steps.last,
              items.indices.contains(first.index), items.indices.contains(last.index)
        else { return visible }
        let minY = rowMotion.shift == 0 ? displayedRowOrigin(at: first.index) : visible.minY
        let maxY = rowMotion.shift == last.cumulative
            ? displayedRowOrigin(at: last.index) + displayedRowHeight(at: last.index) + abs(last.cumulative)
            : visible.maxY
        return CGRect(x: visible.minX, y: minY, width: visible.width, height: max(0, maxY - minY))
            .intersection(visible)
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

    func redrawForRowMotion(invalidating rect: CGRect? = nil) {
        // Hover regions are cached at the rows' displaced positions.
        clearPointerRegionCaches()
        if !rowMotionIsRunning, !pointer.suppressesHoverPresentation {
            // The motion has landed: tracking areas and cursor rects follow the rows.
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if let rect { setNeedsDisplay(rect) } else { invalidateVisibleContent() }
        reconcileInboxHeaders()
        positionAnimatedMediaOverlays()
        positionInlineVideoOverlays()
        // The copy button can't follow its block as rows move and clip, so
        // it leaves until the pointer next moves over a block.
        if clipsMovingRows { setHoveredCodeBlock(nil) }
        reconcileVoiceMessageOverlay()
        reconcileActivityIndicators()
        positionSpoilerOverlays()
        positionReactionBandViews()
        maskDisclosureSubviews()
    }

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
}
