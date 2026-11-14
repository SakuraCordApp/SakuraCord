import AppKit
import SakuraCordModels

/// A cubic Bézier curve the transcript can glide on, readable at any moment
/// so a glide that is interrupted continues from where its rows are drawn.
struct NativeTimelineGlideCurve {
    let x1: Float
    let y1: Float
    let x2: Float
    let y2: Float
    let duration: CFTimeInterval

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
    }

    /// The curve's progress after `fraction` of the duration.
    func progress(at fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        func bezier(_ parameter: Double, _ first: Float, _ second: Float) -> Double {
            let inverse = 1 - parameter
            return 3 * inverse * inverse * parameter * Double(first)
                + 3 * inverse * parameter * parameter * Double(second)
                + parameter * parameter * parameter
        }
        var lower = 0.0
        var upper = 1.0
        for _ in 0 ..< 24 {
            let middle = (lower + upper) / 2
            if bezier(middle, x1, x2) < fraction {
                lower = middle
            } else {
                upper = middle
            }
        }
        return bezier((lower + upper) / 2, y1, y2)
    }
}

/// Renders transition snapshots in the timeline's flipped coordinates.
@MainActor
enum NativeTimelineSnapshotRenderer {
    static func render(size: CGSize, scale: CGFloat, draw: () -> Void) -> NSImage? {
        let scale = max(1, scale)
        guard size.width > 0, size.height > 0,
              let representation = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: max(1, Int(ceil(size.width * scale))),
                  pixelsHigh: max(1, Int(ceil(size.height * scale))),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }
}

/// Easing curves timeline motions and fades share.
nonisolated enum NativeTimelineEasing {
    static func easeOut(_ progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return 1 - pow(1 - progress, 3)
    }

    static func easeInOut(_ progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return progress < 0.5 ? 4 * pow(progress, 3) : 1 - pow(2 - 2 * progress, 3) / 2
    }
}

/// One update's rows changing height, such as reaction lines opening or
/// closing or an edit or deletion. Rows keep the places they
/// had on screen before the update and ease onto the static layout: rows up to
/// the first changed one are displaced by `shift`, and each changed row hides
/// the part of its height change that has not happened yet, which displaces
/// every row after it. Updates overlap freely; each one's displacement simply
/// adds to the others'.
struct NativeTimelineRowMotion {
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
    var timing = NativeTimelineRowMotionTiming.quart
    let shift: CGFloat
    var steps: [Step]

    func progress(at uptime: TimeInterval) -> CGFloat {
        timing.progress(startedAt: startUptime, at: uptime)
    }
}

/// How an update's row motion and the fades drawn with it ease.
enum NativeTimelineRowMotionTiming {
    /// Reaction chips move on Core Animation's quart curve, so rows moving
    /// with them keep it.
    case quart
    /// An edit or deletion can move rows by hundreds of points, which the
    /// quart curve covers in its first few frames. These glide as the
    /// transcript does when a message is sent.
    case glide

    func progress(at elapsed: TimeInterval) -> CGFloat {
        switch self {
        case .quart:
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
            editingOverlayLocalFrame.map { NativeTimelineRowMotionBaseline.Editor(picture: picture, frame: $0) }
        }
        var rows: [NativeMessageTimelineItem.Identifier: NativeTimelineRowMotionBaseline.Row] = [:]
        forEachDisplayedRow(in: rowMotionBaselineRect) { index in
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
        if !rows.isEmpty { pendingReactionBaseline = NativeTimelineRowMotionBaseline(width: bounds.width, rows: rows) }
    }

    /// Starts the motion of the update just applied, after the coordinator
    /// has settled the scroll position. Rows whose only change is their
    /// reactions animate their chips; an edited message shows its new
    /// content at once while its neighbours glide to it, and a deleted one
    /// fades in the gap they close.
    /// Any other change near the viewport, such as a new message, applies
    /// instantly as before.
    func beginRowMotions() {
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
        forEachDisplayedRow(in: rowMotionBaselineRect) { followed.insert(items[$0].identifier) }
        // Only rows that left the followed area can have left the timeline,
        // and only those pay for a search of it.
        let gone = baseline.rows.values.filter {
            !followed.contains($0.item.identifier) && rowIndex(forIdentifier: $0.item.identifier) == nil
        }
        var update = NativeTimelineUpdateMotion(
            departedOldIndices: Set(gone.map(\.index)), handOvers: handOvers, motionID: nextRowMotionID
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
            nextRowMotionID += 1
            rowMotions.append(motion)
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
        guard update.startedChips || !departedRuns.isEmpty || update.plan.motion != nil
        else { return }
        reactionTransitionWidth = bounds.width
        if rowMotionTicker.displayLink == nil {
            reactionStepUptime = nil
            rowMotionTicker.start(on: self) { [weak self] in self?.stepRowMotions() }
        }
    }

    /// Adds pieces to the runs below their rows, in order. A piece whose
    /// motion was dropped meanwhile has no gap left to fade in.
    private func placeDepartedPieces(_ pieces: [(anchor: NativeMessageTimelineItem.Identifier, piece: NativeTimelineDepartedRun.Piece)]) {
        let motionIDs = Set(rowMotions.map(\.id))
        for (anchor, piece) in pieces where motionIDs.contains(piece.motionID) {
            departedRuns[anchor, default: .init()].pieces.append(piece)
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
        let gone = Set(rowMotions.flatMap(\.steps).compactMap { step in
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
            for motion in rowMotions.indices {
                let left = 1 - rowMotions[motion].progress(at: now)
                rowMotions[motion].steps.removeAll { step in
                    guard step.identifier == identifier, !step.closesGap else { return false }
                    handOver.residualHeight += step.delta * left
                    return true
                }
                for step in rowMotions[motion].steps.indices
                    where rowMotions[motion].steps[step].identifier == identifier {
                    rowMotions[motion].steps[step].identifier = anchor
                    rowMotions[motion].steps[step].rowIndex = index
                }
            }
            handOvers[identifier] = handOver
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
        let removed = rowMotions.filter(shouldRemove)
        guard !removed.isEmpty else { return false }
        rowMotions.removeAll(where: shouldRemove)
        let removedIDs = Set(removed.map(\.id))
        editedTextBands = editedTextBands.filter { !removedIDs.contains($0.value.motionID) }
        departedRuns = departedRuns.compactMapValues { $0.removingPieces { removedIDs.contains($0.motionID) } }
        return true
    }

    private func stepRowMotions() {
        let now = ProcessInfo.processInfo.systemUptime
        deferGlides(pastStallBefore: now)
        let hadMotion = !rowMotions.isEmpty
        for index in rowMotions.indices where rowMotions[index].startUptime == nil {
            rowMotions[index].startUptime = now
        }
        rowMotions.removeAll { $0.progress(at: now) >= 1 }
        refreshDepartedRunIndices()
        let fadeFrame = departedRunFrame
        let runningMotionIDs = Set(rowMotions.map(\.id))
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
        let moved = refreshRowMotionGeometry(at: now)
        let redrawsRows = hadMotion && (moved || endsBands || rowMotions.isEmpty)
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
        if reactionTransitions.isEmpty, rowMotions.isEmpty, departedRuns.isEmpty {
            rowMotionTicker.stop()
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
        for index in rowMotions.indices where rowMotions[index].timing == .glide {
            rowMotions[index].startUptime? += stall
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
    func finishRowMotions() {
        pendingReactionBaseline = nil
        rowMotionTicker.stop()
        let hadMotion = !rowMotions.isEmpty
        let hadChips = !reactionTransitions.isEmpty || !departedRuns.isEmpty || !editedTextBands.isEmpty
        rowMotions.removeAll()
        editedTextBands.removeAll()
        departedRuns.removeAll()
        handOvers.removeAll()
        for identifier in reactionTransitions.keys { endReactionTransition(identifier) }
        refreshRowMotionGeometry()
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
    func refreshRowMotionGeometry(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        deferGlides(pastStallBefore: uptime)
        guard !rowMotions.isEmpty || !reactionMotionSteps.isEmpty else { return false }
        if let pendingReactionBaseline { handOverDepartedMotion(in: pendingReactionBaseline, at: uptime) }
        // A motion whose row is gone no longer describes the layout.
        removeRowMotions { motion in
            motion.steps.contains { rowIndex(forIdentifier: $0.identifier, hint: $0.rowIndex) == nil }
        }
        var shift: CGFloat = 0
        var steps: [(index: Int, offset: CGFloat)] = []
        var textRemaining: [Int: CGFloat] = [:]
        for motionIndex in rowMotions.indices {
            let motion = rowMotions[motionIndex]
            let left = 1 - motion.progress(at: uptime)
            shift += motion.shift * left
            for stepIndex in motion.steps.indices {
                let step = motion.steps[stepIndex]
                guard let index = rowIndex(forIdentifier: step.identifier, hint: step.rowIndex) else { continue }
                rowMotions[motionIndex].steps[stepIndex].rowIndex = index
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
    func rowMotionOffset(at index: Int) -> CGFloat {
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
    func rowMotionRemainingHeight(at index: Int) -> CGFloat {
        reactionMotionRemainingHeights[index] ?? 0
    }

    /// The row with this identifier. `hint` is where it last was.
    func rowIndex(forIdentifier identifier: NativeMessageTimelineItem.Identifier, hint: Int? = nil) -> Int? {
        if let hint, items.indices.contains(hint), items[hint].identifier == identifier { return hint }
        return items.lastIndex { $0.identifier == identifier }
    }

    func redrawForRowMotion(invalidating rect: CGRect? = nil) {
        // Hover regions are cached at the rows' displaced positions.
        clearPointerRegionCaches()
        if rowDisclosure?.isFinished ?? true, unreadDividerGap == nil, rowMotions.isEmpty,
           !suppressesHoverPresentation {
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
        if !(rowDisclosure?.isFinished ?? true) || unreadDividerGap != nil { setHoveredCodeBlock(nil) }
        reconcileVoiceMessageOverlay()
        reconcileActivityIndicators()
        positionSpoilerOverlays()
        positionReactionBandViews()
        maskDisclosureSubviews()
    }

    var editingHeightDelta: CGFloat {
        guard let index = editingRowIndex,
              let editingRowHeight
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
                replacementHeight: editingRowHeight,
                baseRowHeight: editingRowIndex.map { storage.layouts[$0].height }
            )
            + bottomSpacerHeight
    }

    func displayedRowOrigin(at index: Int) -> CGFloat {
        contentOriginY
            + (index >= disclosureRange.upperBound ? disclosureShiftAfter
                : index < disclosureRange.lowerBound ? disclosureShiftBefore : 0)
            + unreadDividerGapShift(at: index)
            + rowMotionOffset(at: index)
            + transientRowOrigin(at: index)
    }

    /// A row's top within the content with the edited row at its editing
    /// height, before any motion.
    func transientRowOrigin(at index: Int) -> CGFloat {
        NativeTimelineTransientRowGeometry.rowOrigin(
            base: rowOrigins[index],
            rowIndex: index,
            replacementIndex: editingRowIndex,
            replacementHeight: editingRowHeight,
            baseRowHeight: editingRowIndex.map { storage.layouts[$0].height }
        )
    }

    func displayedRowHeight(at index: Int) -> CGFloat {
        NativeTimelineTransientRowGeometry.rowHeight(
            base: layouts[index].height,
            rowIndex: index,
            replacementIndex: editingRowIndex,
            replacementHeight: editingRowHeight
        ) - rowMotionRemainingHeight(at: index)
    }
}
