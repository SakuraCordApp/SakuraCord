import AppKit

/// The deleted rows below one row, in their order, each fading and giving
/// up its height as the step its deletion added to that row runs. Rows
/// deleted later beside the same row join the run, so every one of them
/// keeps its place in the gap as it closes.
struct NativeTimelineDepartedRun {
    struct Piece {
        /// Nil for a row too tall for one picture, which leaves its
        /// space blank.
        let image: NSImage?
        let height: CGFloat
        /// The motion whose step closes this piece's height.
        let motionID: Int
        var startUptime: TimeInterval?
        var timing = NativeTimelineRowMotionTiming.chips
        /// How far through the motion the piece is fully faded, which a
        /// header taking its place in the next row waits for.
        var fadeEnd: CGFloat = 1

        func remaining(at uptime: TimeInterval) -> CGFloat {
            1 - timing.progress(startedAt: startUptime, at: uptime)
        }

        func opacity(at uptime: TimeInterval) -> CGFloat {
            max(0, 1 - (1 - remaining(at: uptime)) / fadeEnd)
        }
    }

    /// The share of its motion a deleted row takes to fade out before the
    /// next row's new header fades in.
    static let handoffFadeEnd: CGFloat = 0.5

    var pieces: [Piece] = []
    /// Where the row above the run was last found.
    var anchorIndex: Int?

    /// The height the run still takes below its row.
    func gap(at uptime: TimeInterval) -> CGFloat {
        pieces.reduce(0) { $0 + $1.height * $1.remaining(at: uptime) }
    }

    /// The run on the frame at `uptime`, with new pieces started and
    /// finished ones gone; nil once none is left.
    func advanced(to uptime: TimeInterval) -> Self? {
        var run = self
        for index in run.pieces.indices where run.pieces[index].startUptime == nil {
            run.pieces[index].startUptime = uptime
        }
        return run.removingPieces { $0.remaining(at: uptime) <= 0 }
    }

    /// The run without the pieces matching `shouldRemove`; nil once none
    /// is left.
    func removingPieces(where shouldRemove: (Piece) -> Bool) -> Self? {
        var run = self
        run.pieces.removeAll(where: shouldRemove)
        return run.pieces.isEmpty ? nil : run
    }
}

extension NativeTimelineCanvasView {
    /// A row's picture as it was, for a fade that outlives its layout: the
    /// cached bitmap when it had one, otherwise a fresh raster.
    func rowFadeImage(_ row: NativeTimelineReactionBaseline.Row, width: CGFloat) -> NSImage? {
        if let cached = row.bitmap, cached.item == row.item, abs(cached.width - width) < 0.5,
           cached.appearanceName == effectiveAppearance.name, let picture = cached.images[-1] {
            return picture
        }
        let item = row.item
        let layout = row.layout
        let size = NSSize(width: width, height: layout.height)
        guard let scale = fadePictureScale(for: size) else { return nil }
        return NativeTimelineSendTransitionSnapshot.render(size: size, scale: scale) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                NativeTimelineRowPainter.draw(
                    item: item, layout: layout, in: CGRect(origin: .zero, size: size), model: model,
                    isHovered: false, revealedTextSpoilerState: row.revealedTextSpoilerState,
                    spoilerRevealStore: spoilerRevealStore, pollPresentation: row.pollPresentation
                )
            }
            if let editor = row.editor {
                editor.picture.draw(in: editor.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// The scale for a fading picture of `size`: a tall one is drawn lower
    /// to stay within its share of the bitmap budget, since it only shows
    /// while it fades. Nil when that would be below 1x.
    func fadePictureScale(for size: NSSize) -> CGFloat? {
        let pointCost = Self.estimatedBitmapCost(width: size.width, height: size.height, scale: 1)
        let scale = min(rowBitmapScale, (CGFloat(Self.bitmapCostLimit / 4) / CGFloat(pointCost)).squareRoot())
        return scale >= 1 ? scale : nil
    }

    /// How much of a row's displayed height is the gap of the deleted run
    /// below it.
    func departedGapHeight(below identifier: NativeMessageTimelineItem.Identifier) -> CGFloat {
        departedRuns[identifier]?.gap(at: rowMotionUptime) ?? 0
    }

    /// Draws deleted rows in the gaps closing after the rows they followed.
    func drawDepartedRows(in dirtyRect: CGRect) {
        guard !departedRuns.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let now = rowMotionUptime
        for (anchor, run) in departedRuns {
            guard let index = rowIndex(forIdentifier: anchor, hint: run.anchorIndex) else { continue }
            // The gap is the end of the row's displayed height, which may
            // also be easing from a change of the row's own.
            var originY = displayedRowOrigin(at: index) + displayedRowHeight(at: index) - run.gap(at: now)
            for piece in run.pieces {
                let remaining = piece.remaining(at: now)
                let frame = CGRect(x: 0, y: originY, width: bounds.width, height: piece.height * remaining)
                originY = frame.maxY
                guard let image = piece.image, frame.intersects(dirtyRect) else { continue }
                context.saveGState()
                context.clip(to: frame)
                image.draw(
                    in: CGRect(origin: frame.origin, size: image.size), from: .zero, operation: .sourceOver,
                    fraction: piece.opacity(at: now), respectFlipped: true, hints: nil
                )
                context.restoreGState()
            }
        }
    }

    /// Finds the rows the deleted rows fade after again, from where they
    /// were, and drops the runs of rows that are gone.
    func refreshDepartedRunIndices() {
        departedRuns = departedRuns.reduce(into: [:]) { runs, entry in
            var run = entry.value
            run.anchorIndex = rowIndex(forIdentifier: entry.key, hint: run.anchorIndex)
            if run.anchorIndex != nil { runs[entry.key] = run }
        }
    }

    /// The region the deleted rows fade in, for the next frame.
    var departedRunFrame: CGRect {
        let now = rowMotionUptime
        return departedRuns.reduce(CGRect.null) { frame, entry in
            guard let index = rowIndex(forIdentifier: entry.key, hint: entry.value.anchorIndex) else { return frame }
            return frame.union(CGRect(
                x: 0, y: displayedRowOrigin(at: index), width: bounds.width,
                height: max(displayedRowHeight(at: index), layouts[index].height + entry.value.gap(at: now))
            ))
        }
    }
}
