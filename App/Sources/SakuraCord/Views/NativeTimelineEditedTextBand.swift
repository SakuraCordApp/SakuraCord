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
    /// row's header and everything after its text the same. Nil for any
    /// other change, which moves as one piece.
    func editedTextBand(
        from old: NativeTimelineReactionBaseline.Row,
        at index: Int,
        width: CGFloat
    ) -> NativeTimelineEditedTextBand? {
        let layout = layouts[index]
        guard old.editor == nil,
              let oldText = old.layout.contentFrame, let newText = layout.contentFrame,
              abs(oldText.height - newText.height) >= 0.5,
              abs(oldText.minY - newText.minY) < 0.5,
              abs((old.layout.height - oldText.maxY) - (layout.height - newText.maxY)) < 0.5,
              rowFrame(at: index).intersects(visibleRect)
        else { return nil }
        let size = NSSize(width: width, height: oldText.height)
        let picture = fadePictureScale(for: size).flatMap { scale in
            NativeTimelineSendTransitionSnapshot.render(size: size, scale: scale) {
                NativeTimelineRowPainter.draw(
                    item: old.item, layout: old.layout,
                    in: CGRect(x: 0, y: -oldText.minY, width: width, height: old.layout.height), model: model,
                    isHovered: false, revealedTextSpoilerState: old.revealedTextSpoilerState,
                    spoilerRevealStore: spoilerRevealStore, pollPresentation: old.pollPresentation
                )
            }
        }
        return .init(
            identifier: items[index].identifier, top: newText.minY,
            oldHeight: oldText.height, newHeight: newText.height, picture: picture
        )
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
        // The row's own change still to come; a deleted run below it adds
        // a gap of its own.
        let remaining = reactionMotionRemainingHeight(at: index) + departedGapHeight(below: band.identifier)
        let shown = min(max(band.newHeight - remaining, min(band.oldHeight, band.newHeight)), max(band.oldHeight, band.newHeight))
        let progress = (shown - band.oldHeight) / (band.newHeight - band.oldHeight)
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
            band.picture?.draw(
                in: CGRect(x: paintFrame.minX, y: textTop, width: band.picture?.size.width ?? 0, height: band.oldHeight),
                from: .zero, operation: .sourceOver, fraction: 1 - progress, respectFlipped: true, hints: nil
            )
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
