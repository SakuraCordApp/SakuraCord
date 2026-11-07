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
        var after = old.layout.contentFrame.map { old.layout.height - $0.maxY } ?? layout.height - text.maxY
        // A running glide keeps its origin; text that starts with a block,
        // such as code, starts lower.
        let identifier = items[index].identifier
        let running = editedTextBands[identifier]
        var top = min(text.minY, running?.top ?? text.minY)
        if let oldText = old.layout.contentFrame, let newText = layout.contentFrame {
            // A short row is padded to its avatar's height below everything
            // else: the padding its text grows into, or leaves, belongs to
            // its space. Each row's height is rounded up to a whole point.
            let newAfter = layout.height - newText.maxY
            guard abs(newAfter - layout.avatarPadding - after + old.layout.avatarPadding) < 1 else { return nil }
            after = min(after, newAfter)
            top = min(top, oldText.minY, newText.minY)
        }
        // Text on one side only brings the gap before what follows it,
        // which belongs to its space.
        let gap = min(0, old.layout.height - top - after, layout.height - top - after)
        let oldHeight = old.layout.height - top - after - gap
        let newHeight = layout.height - top - after - gap
        guard after + gap >= 0, abs(oldHeight - newHeight) >= 0.5,
              rowFrame(at: index).intersects(visibleRect), !hostsLiveViews(at: index)
        else { return nil }
        // A glide this one interrupts starts it from what it shows, below
        // its own origin.
        let runningOffset = running.map { $0.top - top } ?? 0
        let startHeight = running.map { shownHeight(of: $0, at: index) + runningOffset } ?? oldHeight
        let size = NSSize(width: width, height: startHeight)
        let picture = fadePictureScale(for: size).flatMap { scale in
            NativeTimelineSendTransitionSnapshot.render(size: size, scale: scale) {
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                let progress = running.map { progress(of: $0, shown: startHeight - runningOffset) } ?? 1
                if let picture = running?.picture {
                    picture.draw(
                        in: CGRect(origin: CGPoint(x: 0, y: runningOffset), size: picture.size), from: .zero,
                        operation: .sourceOver, fraction: 1 - progress, respectFlipped: true, hints: nil
                    )
                }
                context.saveGState()
                context.clip(to: CGRect(
                    x: 0, y: runningOffset, width: width,
                    height: min(startHeight, runningOffset + (running?.newHeight ?? startHeight)) - runningOffset
                ))
                context.setAlpha(progress)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                NativeTimelineRowPainter.draw(
                    item: old.item, layout: old.layout,
                    in: CGRect(x: 0, y: -top, width: width, height: old.layout.height), model: model,
                    isHovered: false, revealedTextSpoilerState: old.revealedTextSpoilerState,
                    spoilerRevealStore: spoilerRevealStore, pollPresentation: old.pollPresentation
                )
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        return .init(
            identifier: identifier, top: top, oldHeight: startHeight,
            newHeight: newHeight, picture: picture
        )
    }

    /// Whether views of the row's own sit over what it draws: a playing
    /// video, an audio player, a spoiler cover, a control's loading dots or
    /// an upload's ring. They keep their final places, so the row moves as
    /// one piece instead of parting from them.
    private func hostsLiveViews(at index: Int) -> Bool {
        let identifier = items[index].identifier
        let messageID = items[index].messageID
        return inlinePlayers.keys.contains { $0.row == identifier }
            || inlineVideoOverlays.keys.contains { $0.row == identifier }
            || spoilerOverlays.keys.contains { $0.messageID == messageID }
            || activityIndicators.keys.contains { $0.row == identifier }
            || uploadRings.keys.contains { $0.row == identifier }
            || [voiceMessageOverlay, voiceMessageHoverOverlay].contains { overlay in
                overlay.map { overlay in layouts[index].audioPlayers.contains { $0.playbackID == overlay.region.playbackID } } ?? false
            }
    }

    /// How tall the band's text is drawn now: its target less the part of
    /// the row's text steps still to come, which an interrupted edit's
    /// step can carry past where this band started.
    private func shownHeight(of band: NativeTimelineEditedTextBand, at index: Int) -> CGFloat {
        max(0, band.newHeight - (reactionMotionTextRemainingHeights[index] ?? 0))
    }

    /// How far the band's new text has faded in at `shown`.
    private func progress(of band: NativeTimelineEditedTextBand, shown: CGFloat) -> CGFloat {
        guard abs(band.newHeight - band.oldHeight) >= 0.5 else { return 1 }
        return min(1, max(0, (shown - band.oldHeight) / (band.newHeight - band.oldHeight)))
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
