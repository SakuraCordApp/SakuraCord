import AppKit

/// The text of an edited message whose line count changed. As the row's
/// height glides, the text's space eases from its old height to its new
/// one: lines the edit removed fade out as it closes and lines it added
/// fade in as it opens, while what follows the text moves with its end,
/// as a deleted row's neighbours do.
struct NativeTimelineEditedTextBand {
    let identifier: NativeMessageTimelineItem.Identifier
    /// Where the text starts in the row, the same before and after.
    let top: CGFloat
    /// The text's height when the glide starts: its old height, or what an
    /// interrupted glide of an earlier edit showed.
    let oldHeight: CGFloat
    let newHeight: CGFloat
    /// The old text as it was drawn; nil for text too tall for one
    /// picture, whose old lines then leave at once.
    let picture: NSImage?
    /// The motion easing the row's height.
    var motionID = 0
}

extension NativeTimelineCanvasView {
    /// The band of an edit that only changed its text's height, with the
    /// row's header and everything after its text the same. Text added to
    /// or removed from an attachment counts, with what follows it taken
    /// from the side that has text. Nil for any other change, which moves
    /// as one piece.
    func editedTextBand(
        from old: NativeTimelineReactionBaseline.Row,
        at index: Int,
        width: CGFloat
    ) -> NativeTimelineEditedTextBand? {
        let layout = layouts[index]
        guard old.editor == nil, let text = old.layout.contentFrame ?? layout.contentFrame else { return nil }
        let after = old.layout.contentFrame.map { old.layout.height - $0.maxY } ?? layout.height - text.maxY
        if let oldText = old.layout.contentFrame, let newText = layout.contentFrame {
            guard abs(oldText.minY - newText.minY) < 0.5, abs(layout.height - newText.maxY - after) < 0.5 else { return nil }
        }
        let oldHeight = old.layout.height - text.minY - after
        let newHeight = layout.height - text.minY - after
        guard oldHeight > -0.5, newHeight > -0.5, abs(oldHeight - newHeight) >= 0.5,
              rowFrame(at: index).intersects(visibleRect)
        else { return nil }
        let identifier = items[index].identifier
        // A glide this one interrupts starts it from what it shows.
        let running = editedTextBands[identifier]
        let startHeight = running.map { shownHeight(of: $0, at: index) } ?? max(0, oldHeight)
        let size = NSSize(width: width, height: startHeight)
        let picture = fadePictureScale(for: size).flatMap { scale in
            NativeTimelineSendTransitionSnapshot.render(size: size, scale: scale) {
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                let progress = running.map { progress(of: $0, shown: startHeight) } ?? 1
                if let picture = running?.picture {
                    picture.draw(
                        in: CGRect(origin: .zero, size: picture.size), from: .zero, operation: .sourceOver,
                        fraction: 1 - progress, respectFlipped: true, hints: nil
                    )
                }
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: 0, width: width, height: min(startHeight, running?.newHeight ?? startHeight)))
                context.setAlpha(progress)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                NativeTimelineRowPainter.draw(
                    item: old.item, layout: old.layout,
                    in: CGRect(x: 0, y: -text.minY, width: width, height: old.layout.height), model: model,
                    isHovered: false, revealedTextSpoilerState: old.revealedTextSpoilerState,
                    spoilerRevealStore: spoilerRevealStore, pollPresentation: old.pollPresentation
                )
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        return .init(
            identifier: identifier, top: text.minY, oldHeight: startHeight,
            newHeight: max(0, newHeight), picture: picture
        )
    }

    /// How tall the band's text is drawn now: its target less the part of
    /// the row's text steps still to come.
    private func shownHeight(of band: NativeTimelineEditedTextBand, at index: Int) -> CGFloat {
        let shown = band.newHeight - (reactionMotionTextRemainingHeights[index] ?? 0)
        return min(max(shown, min(band.oldHeight, band.newHeight)), max(band.oldHeight, band.newHeight))
    }

    /// How far the band's new text has faded in at `shown`.
    private func progress(of band: NativeTimelineEditedTextBand, shown: CGFloat) -> CGFloat {
        abs(band.newHeight - band.oldHeight) < 0.5 ? 1 : (shown - band.oldHeight) / (band.newHeight - band.oldHeight)
    }

    /// Draws an edited row with its text's space at the height the glide
    /// has reached: the header as it is, the text between its old picture
    /// fading out and its new lines fading in, and the rest after it.
    func drawEditedRow(
        _ band: NativeTimelineEditedTextBand,
        at index: Int,
        paintFrame: CGRect,
        drawPicture: (CGRect) -> Void
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            drawPicture(paintFrame)
            return
        }
        let shown = shownHeight(of: band, at: index)
        let progress = progress(of: band, shown: shown)
        let textTop = paintFrame.minY + band.top
        func clipped(from minY: CGFloat, to maxY: CGFloat, draw: () -> Void) {
            guard maxY > minY else { return }
            context.saveGState()
            context.clip(to: CGRect(x: paintFrame.minX, y: minY, width: paintFrame.width, height: maxY - minY))
            draw()
            context.restoreGState()
        }
        clipped(from: paintFrame.minY, to: textTop) { drawPicture(paintFrame) }
        clipped(from: textTop, to: textTop + shown) {
            if let picture = band.picture {
                picture.draw(
                    in: CGRect(origin: CGPoint(x: paintFrame.minX, y: textTop), size: picture.size),
                    from: .zero, operation: .sourceOver, fraction: 1 - progress, respectFlipped: true, hints: nil
                )
            }
        }
        // The new text ends where it does: below it, the rest follows.
        clipped(from: textTop, to: textTop + min(shown, band.newHeight)) {
            context.setAlpha(progress)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawPicture(paintFrame)
            context.endTransparencyLayer()
        }
        clipped(from: textTop + shown, to: paintFrame.maxY + max(0, shown - band.newHeight)) {
            drawPicture(paintFrame.offsetBy(dx: 0, dy: shown - band.newHeight))
        }
    }
}
