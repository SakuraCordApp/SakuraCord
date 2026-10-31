import AppKit
import SakuraCordModels

/// The pointer over a message's file cards: the hovered and pressed parts,
/// each part's eased hover, and the press animation.
struct FileCardPointer {
    let hovered: NativeTimelineComponentButtonTarget?
    let hoverProgress: [NativeTimelineComponentButtonTarget: CGFloat]
    let pressed: NativeTimelineComponentButtonTarget?
    let pressProgress: CGFloat
}

extension NativeTimelineRowPainter {
    /// Draws a file card in its rest, hover, pressed, downloading, finished,
    /// or failed state. The card, its button, and its link each take their
    /// own hover and press.
    static func fileCard(
        _ card: NativeTimelineFileCard,
        messageID: MessageID,
        bubbleRegion: NativeTimelineBubbleRegion?,
        state: AttachmentDownloadStore.State?,
        upload: FileCardUpload? = nil,
        finishProgress: [NativeTimelineComponentButtonTarget: CGFloat] = [:],
        pointer: FileCardPointer
    ) {
        // A local send's file is not downloadable until it is posted, so it
        // takes no hover or press.
        let state = upload == nil ? state : nil
        let hoveredPart = upload == nil ? card.part(of: pointer.hovered, messageID: messageID) : nil
        let pressedPart = card.part(of: pointer.pressed, messageID: messageID)
        // A press shows while the pointer stays on the part it pressed.
        func press(_ part: NativeTimelineFileCard.Part) -> CGFloat {
            hoveredPart == part && pressedPart == part ? min(max(pointer.pressProgress, 0), 1) : 0
        }
        // Each part's hover eases in and out.
        func hover(_ part: NativeTimelineFileCard.Part) -> CGFloat {
            guard upload == nil else { return 0 }
            return pointer.hoverProgress[.fileCard(messageID: messageID, attachmentID: card.attachment.id, part: part)] ?? 0
        }
        let bubble = card.isInBubble ? bubbleRegion : nil
        let palette = FileCardPalette(bubble: bubble, isFailed: state == .failed || upload == .failed)
        let highlight = 0.04 * (min(1, hover(.card) + hover(.button) + hover(.link)) + press(.card))
        if let bubble {
            if highlight > 0 {
                let frame = card.highlightFrame
                palette.highlight.withAlphaComponent(highlight * (bubble.isOutgoing ? 3 : 1.5)).setFill()
                NSBezierPath(
                    concentricRoundedRect: frame,
                    cornerRadius: bubbleConcentricCornerRadius(for: frame, in: bubble, fallback: frame.height / 2)
                ).fill()
            }
        } else {
            // A plain voice message's capsule, deepening under the pointer;
            // an audio card keeps its ends' radius over two rows.
            NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.10 + highlight).setFill()
            NSBezierPath(
                concentricRoundedRect: card.frame,
                cornerRadius: NativeTimelineFileCard.height(isInBubble: false) / 2
            ).fill()
        }
        fileCardIcon(card)
        fileCardButton(
            card, state: state, symbol: buttonSymbol(state: state, upload: upload), palette: palette,
            hover: hover(.button), pressProgress: press(.button),
            finish: finishProgress[.fileCard(messageID: messageID, attachmentID: card.attachment.id, part: .button)]
        )

        text(
            card.attachment.filename, in: card.nameFrame, font: NativeTimelineFileCard.nameFont,
            color: palette.name, lineBreakMode: .byTruncatingMiddle
        )
        let detail = upload == .failed
            ? (text: String(localized: "Upload failed"), link: nil)
            : NativeTimelineFileCard.detail(for: state, size: card.attachment.size)
        let detailColor = palette.isFailed ? palette.failure : palette.detail
        text(detail.text, in: card.detailFrame, font: NativeTimelineFileCard.detailFont, color: detailColor)
        if let link = detail.link {
            text(
                link, in: card.linkFrame(after: detail.text, link: link), font: NativeTimelineFileCard.linkFont,
                color: (state == .failed ? palette.failure : palette.link).withAlphaComponent(1 - 0.4 * press(.link)),
                isInteractiveHovered: hoveredPart == .link
            )
        }
    }

    /// The file type's Finder icon, from a bitmap cached per type and size.
    private static func fileCardIcon(_ card: NativeTimelineFileCard) {
        let frame = card.iconFrame
        let scale = NSGraphicsContext.current?.cgContext.convertToDeviceSpace(CGSize(width: 1, height: 1)).width ?? 2
        guard let icon = FileTypeIconCache.image(
            forFilename: card.attachment.filename, pixels: Int(ceil(frame.width * abs(scale)))
        ) else { return }
        drawImage(icon, in: frame, cornerRadius: 0, fillsFrame: false)
    }

    /// The round download button, which shows the next step, takes the
    /// round buttons' shared hover and press, and rings its progress while
    /// downloading. A finished download's full ring and cancel fade out as
    /// its next step grows in.
    private static func fileCardButton(
        _ card: NativeTimelineFileCard,
        state: AttachmentDownloadStore.State?,
        symbol: String?,
        palette: FileCardPalette,
        hover: CGFloat,
        pressProgress: CGFloat,
        finish: CGFloat?
    ) {
        let button = card.buttonFrame
        let scale = NativeTimelineComponentButtonVisualState.roundButtonScale(hover: hover, press: pressProgress)
        drawingRoundButton(button, scale: scale) {
            palette.button.setFill()
            NSBezierPath(ovalIn: button).fill()
            guard let symbol else { return }
            if case let .downloading(fraction) = state {
                downloadRing(in: button, fraction: fraction, color: palette.glyph)
                systemSymbol(symbol, in: button, color: palette.glyph, inset: button.width * 0.34, weight: .bold)
                return
            }
            guard let finish, let context = NSGraphicsContext.current?.cgContext else {
                systemSymbol(symbol, in: button, color: palette.glyph, inset: button.width * 0.3, weight: .semibold)
                return
            }
            context.saveGState()
            context.setAlpha(1 - finish)
            downloadRing(in: button, fraction: 1, color: palette.glyph)
            systemSymbol("xmark", in: button, color: palette.glyph, inset: button.width * 0.34, weight: .bold)
            context.setAlpha(finish)
            drawingRoundButton(button, scale: 0.8 + 0.2 * finish) {
                systemSymbol(symbol, in: button, color: palette.glyph, inset: button.width * 0.3, weight: .semibold)
            }
            context.restoreGState()
        }
    }

    /// Draws a round button and its glyph scaled together about the
    /// button's centre. The glyph keeps the size it is rasterized at, so it
    /// grows and shrinks with the circle rather than snapping between sizes.
    static func drawingRoundButton(_ frame: CGRect, scale: CGFloat, _ draw: () -> Void) {
        guard scale != 1, let context = NSGraphicsContext.current?.cgContext else { return draw() }
        context.saveGState()
        context.translateBy(x: frame.midX, y: frame.midY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -frame.midX, y: -frame.midY)
        draw()
        context.restoreGState()
    }

    /// The button's next step. While a file uploads, its ring and cancel
    /// draw over the row instead.
    private static func buttonSymbol(state: AttachmentDownloadStore.State?, upload: FileCardUpload?) -> String? {
        switch (upload, state) {
        case (.uploading, _): nil
        case (.failed, _), (nil, .failed): "arrow.clockwise"
        case (nil, nil): "arrow.down"
        case (nil, .downloading): "xmark"
        case (nil, .finished): "magnifyingglass"
        }
    }

    /// A local send's file still uploading, or whose upload failed.
    enum FileCardUpload {
        case uploading
        case failed
    }

    static func uploadState(of attachment: Attachment, in input: NativeTimelineMessageDrawInput) -> FileCardUpload? {
        input.layout.activeUploadRing(
            for: attachment.id, uploads: input.model?.attachmentUploads, nonce: input.row.message.nonce
        ).map { $0.isFailed ? .failed : .uploading }
    }

    private static func downloadRing(in circle: CGRect, fraction: Double, color: NSColor) {
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: InterfaceScale.metric(4), dy: InterfaceScale.metric(4)))
        ring.lineWidth = AttachmentUploadRing.lineWidth
        color.withAlphaComponent(AttachmentUploadRing.trackOpacity).setStroke()
        ring.stroke()
        let radius = circle.width / 2 - InterfaceScale.metric(4)
        let arc = NSBezierPath()
        // Flipped rows: -90° is the top, and positive angles turn clockwise.
        arc.appendArc(
            withCenter: CGPoint(x: circle.midX, y: circle.midY), radius: radius,
            startAngle: -90, endAngle: -90 + 360 * AttachmentUploadRing.visibleFraction(fraction)
        )
        arc.lineWidth = ring.lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    /// A file card's colours: SakuraCord's accent button with a white glyph,
    /// inverted on an outgoing bubble as its voice messages are.
    private struct FileCardPalette {
        let button: NSColor
        let glyph: NSColor
        let name: NSColor
        let detail: NSColor
        let link: NSColor
        let failure: NSColor
        let highlight: NSColor
        let isFailed: Bool

        init(bubble: NativeTimelineBubbleRegion?, isFailed: Bool) {
            self.isFailed = isFailed
            let accent = NSColor.sakuraCordAccentColor
            if bubble?.isOutgoing == true {
                button = .white
                glyph = isFailed ? .systemRed : accent
                link = .white
                failure = .white
                highlight = .white
            } else {
                button = isFailed ? .systemRed : accent
                glyph = .white
                link = accent
                failure = .systemRed
                highlight = .labelColor
            }
            name = NativeTimelineBubbleDrawing.foregroundColor(for: bubble)
            detail = NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubble)
        }
    }
}
