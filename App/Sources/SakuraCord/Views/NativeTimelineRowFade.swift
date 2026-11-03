import AppKit

/// An edited row's previous picture, fading out under its new content
/// while the motion its update started runs.
struct NativeTimelineRowFade {
    let identifier: NativeMessageTimelineItem.Identifier
    let image: NSImage
    /// Set on the first frame, as for a row motion.
    var startUptime: TimeInterval?

    /// How much of the old picture still shows, from 1 down to 0.
    func remaining(at uptime: TimeInterval) -> CGFloat {
        Self.remaining(startedAt: startUptime, at: uptime)
    }

    static func remaining(startedAt startUptime: TimeInterval?, at uptime: TimeInterval) -> CGFloat {
        1 - (startUptime.map { NativeTimelineRowDisclosure.progress(at: uptime - $0) } ?? 0)
    }
}

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
        var startUptime: TimeInterval?

        func remaining(at uptime: TimeInterval) -> CGFloat {
            NativeTimelineRowFade.remaining(startedAt: startUptime, at: uptime)
        }
    }

    var pieces: [Piece] = []

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
        run.pieces.removeAll { $0.remaining(at: uptime) <= 0 }
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
        // A tall row is drawn in tiles; one picture of all of it costs too
        // much for a fade, so it changes without one.
        guard layout.height <= Self.wholeRowBitmapMaximumHeight else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let size = NSSize(width: width, height: layout.height)
        guard size.height >= 1,
              let representation = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: max(1, Int(ceil(width * scale))),
                  pixelsHigh: max(1, Int(ceil(size.height * scale))),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        graphics.cgContext.scaleBy(x: scale, y: scale)
        graphics.cgContext.translateBy(x: 0, y: size.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
        NativeTimelineRowPainter.draw(
            item: item, layout: layout, in: CGRect(origin: .zero, size: size), model: model,
            isHovered: false, revealedTextSpoilerState: row.revealedTextSpoilerState,
            spoilerRevealStore: spoilerRevealStore
        )
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    /// Draws a replaced row's new content fading in over the old picture.
    func drawCrossfadingRow(_ fade: NativeTimelineRowFade, rowFrame: CGRect, drawRow: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            drawRow()
            return
        }
        let remaining = fade.remaining(at: ProcessInfo.processInfo.systemUptime)
        fade.image.draw(
            in: CGRect(origin: rowFrame.origin, size: fade.image.size), from: .zero, operation: .sourceOver,
            fraction: remaining, respectFlipped: true, hints: nil
        )
        context.saveGState()
        context.setAlpha(1 - remaining)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawRow()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// How much of a row's displayed height is the gap of the deleted run
    /// below it.
    func departedGapHeight(
        below identifier: NativeMessageTimelineItem.Identifier,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CGFloat {
        departedRuns[identifier]?.gap(at: uptime) ?? 0
    }

    /// Draws deleted rows in the gaps closing after the rows they followed.
    func drawDepartedRows(in dirtyRect: CGRect) {
        guard !departedRuns.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for (anchor, run) in departedRuns {
            guard let index = rowIndex(forIdentifier: anchor) else { continue }
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
                    fraction: remaining, respectFlipped: true, hints: nil
                )
                context.restoreGState()
            }
        }
    }

    /// The region every running fade draws in, for the next frame.
    var rowFadeFrame: CGRect {
        let crossfades = rowFades.reduce(CGRect.null) { frame, fade in
            guard let index = rowIndex(forIdentifier: fade.identifier) else { return frame }
            return frame.union(rowFrame(at: index)).union(CGRect(origin: rowFrame(at: index).origin, size: fade.image.size))
        }
        let now = ProcessInfo.processInfo.systemUptime
        return departedRuns.reduce(crossfades) { frame, entry in
            guard let index = rowIndex(forIdentifier: entry.key) else { return frame }
            return frame.union(CGRect(
                x: 0, y: displayedRowOrigin(at: index), width: bounds.width,
                height: max(displayedRowHeight(at: index), layouts[index].height + entry.value.gap(at: now))
            ))
        }
    }
}
