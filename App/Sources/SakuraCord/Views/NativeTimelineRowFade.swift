import AppKit

/// A row's picture from before an update, fading out while the row motion
/// that update started runs: a deleted message in the gap its neighbours
/// close, or an edited message's previous content under its new content.
struct NativeTimelineRowFade {
    enum Placement: Equatable {
        /// Deleted rows, drawn below `after`, whose step reopens their height.
        case departed(after: NativeMessageTimelineItem.Identifier, height: CGFloat)
        /// The row's own previous picture, crossfading into the current one.
        case replaced(NativeMessageTimelineItem.Identifier)
    }

    let placement: Placement
    let image: NSImage
    /// Set on the first frame, as for a row motion.
    var startUptime: TimeInterval?

    var isReplacement: Bool {
        if case .replaced = placement { return true }
        return false
    }

    /// How much of the old picture still shows, from 1 down to 0.
    func remaining(at uptime: TimeInterval) -> CGFloat {
        1 - (startUptime.map { NativeTimelineRowDisclosure.progress(at: uptime - $0) } ?? 0)
    }
}

extension NativeTimelineRowFade.Placement {
    /// The row a fade is drawn against.
    var anchor: NativeMessageTimelineItem.Identifier {
        switch self {
        case let .departed(after, _): after
        case let .replaced(identifier): identifier
        }
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
            isHovered: false, spoilerRevealStore: spoilerRevealStore
        )
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    /// Deleted rows stacked as they were, for the gap they leave.
    func departedRowsImage(_ rows: [NativeTimelineReactionBaseline.Row]) -> NSImage? {
        // Each picture keeps its place in the gap, so one missing picture,
        // as a tall row's is, leaves the whole run without one.
        let images = rows.compactMap { rowFadeImage($0, width: bounds.width) }
        guard images.count == rows.count else { return nil }
        guard images.count > 1 else { return images.first }
        let size = NSSize(width: bounds.width, height: images.reduce(0) { $0 + $1.size.height })
        return NSImage(size: size, flipped: true) { _ in
            var originY: CGFloat = 0
            for image in images {
                image.draw(in: CGRect(x: 0, y: originY, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                originY += image.size.height
            }
            return true
        }
    }

    /// Draws a replaced row's new content fading in over the old picture.
    func drawCrossfadingRow(at index: Int, rowFrame: CGRect, drawRow: () -> Void) {
        let identifier = items[index].identifier
        guard let fade = rowFades.first(where: { $0.placement == .replaced(identifier) }),
              let context = NSGraphicsContext.current?.cgContext
        else {
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

    /// Draws deleted rows in the gaps closing after the rows they followed.
    func drawDepartedRows(in dirtyRect: CGRect) {
        guard !rowFades.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for fade in rowFades {
            guard case let .departed(after, height) = fade.placement,
                  let index = rowIndex(forIdentifier: after),
                  case let frame = CGRect(
                      x: 0, y: displayedRowOrigin(at: index) + layouts[index].height,
                      width: bounds.width, height: height * fade.remaining(at: now)
                  ),
                  frame.intersects(dirtyRect)
            else { continue }
            context.saveGState()
            context.clip(to: frame)
            fade.image.draw(
                in: CGRect(origin: frame.origin, size: fade.image.size), from: .zero, operation: .sourceOver,
                fraction: fade.remaining(at: now), respectFlipped: true, hints: nil
            )
            context.restoreGState()
        }
    }

    /// The region every running fade draws in, for the next frame.
    var rowFadeFrame: CGRect {
        let now = ProcessInfo.processInfo.systemUptime
        return rowFades.reduce(CGRect.null) { frame, fade in
            switch fade.placement {
            case let .departed(after, height):
                guard let index = rowIndex(forIdentifier: after) else { return frame }
                return frame.union(CGRect(
                    x: 0, y: displayedRowOrigin(at: index), width: bounds.width,
                    height: layouts[index].height + height * fade.remaining(at: now)
                ))
            case let .replaced(identifier):
                guard let index = rowIndex(forIdentifier: identifier) else { return frame }
                return frame.union(rowFrame(at: index)).union(CGRect(
                    origin: rowFrame(at: index).origin, size: fade.image.size
                ))
            }
        }
    }
}
