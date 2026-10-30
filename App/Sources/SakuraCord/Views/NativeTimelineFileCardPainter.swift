import AppKit
import SakuraCordModels

extension NativeTimelineRowPainter {
    /// Draws a file card in its rest, hover, pressed, downloading, finished,
    /// or failed state.
    static func fileCard(
        _ card: NativeTimelineFileCard,
        messageID: MessageID,
        bubbleRegion: NativeTimelineBubbleRegion?,
        state: AttachmentDownloadStore.State?,
        hovered: NativeTimelineComponentButtonTarget?,
        pressProgress: CGFloat
    ) {
        let isHovered = hovered == .fileCard(messageID: messageID, attachmentID: card.attachment.id)
        let pressProgress = isHovered ? min(max(pressProgress, 0), 1) : 0
        let bubble = card.isInBubble ? bubbleRegion : nil
        let palette = FileCardPalette(bubble: bubble, isFailed: state == .failed)
        let highlight = 0.04 * ((isHovered ? 1 : 0) + pressProgress)
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
            // A plain voice message's capsule, deepening under the pointer.
            NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.10 + highlight).setFill()
            NSBezierPath(concentricRoundedRect: card.frame, cornerRadius: card.frame.height / 2).fill()
        }
        fileCardIcon(card)
        fileCardButton(card, state: state, palette: palette, isHovered: isHovered, pressProgress: pressProgress)

        text(
            card.attachment.filename, in: card.nameFrame, font: NativeTimelineFileCard.nameFont,
            color: palette.name, lineBreakMode: .byTruncatingMiddle
        )
        let detail = NativeTimelineFileCard.detail(for: state, size: card.attachment.size)
        let detailColor = state == .failed ? palette.failure : palette.detail
        text(detail.text, in: card.detailFrame, font: NativeTimelineFileCard.detailFont, color: detailColor)
        if let link = detail.link {
            var frame = card.detailFrame
            let offset = NativeTimelineRowLayout.measuredTextWidth(detail.text, font: NativeTimelineFileCard.detailFont)
            frame.origin.x += offset
            frame.size.width = max(0, frame.width - offset)
            text(
                link, in: frame, font: NativeTimelineFileCard.linkFont,
                color: state == .failed ? palette.failure : palette.link
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

    /// The round download button, which shows the next step, grows under
    /// the pointer like a voice message's play button, dips when pressed,
    /// and rings its progress while downloading.
    private static func fileCardButton(
        _ card: NativeTimelineFileCard,
        state: AttachmentDownloadStore.State?,
        palette: FileCardPalette,
        isHovered: Bool,
        pressProgress: CGFloat
    ) {
        let symbol = switch state {
        case nil: "arrow.down"
        case .downloading: "xmark"
        case .finished: "magnifyingglass"
        case .failed: "arrow.clockwise"
        }
        let scale = isHovered ? 1.06 - 0.12 * pressProgress : 1
        let base = card.buttonFrame
        let button = base.insetBy(dx: base.width * (1 - scale) / 2, dy: base.height * (1 - scale) / 2)
        palette.button.setFill()
        NSBezierPath(ovalIn: button).fill()
        guard case let .downloading(fraction) = state else {
            systemSymbol(symbol, in: button, color: palette.glyph, inset: button.width * 0.3, weight: .semibold)
            return
        }
        let ring = NSBezierPath(ovalIn: button.insetBy(dx: InterfaceScale.metric(4), dy: InterfaceScale.metric(4)))
        ring.lineWidth = InterfaceScale.metric(2.5)
        palette.glyph.withAlphaComponent(0.3).setStroke()
        ring.stroke()
        let radius = button.width / 2 - InterfaceScale.metric(4)
        let arc = NSBezierPath()
        // Flipped rows: -90° is the top, and positive angles turn clockwise.
        arc.appendArc(
            withCenter: CGPoint(x: button.midX, y: button.midY), radius: radius,
            startAngle: -90, endAngle: -90 + 360 * min(max(fraction, 0.02), 1)
        )
        arc.lineWidth = ring.lineWidth
        arc.lineCapStyle = .round
        palette.glyph.setStroke()
        arc.stroke()
        systemSymbol(symbol, in: button, color: palette.glyph, inset: button.width * 0.34, weight: .bold)
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

        init(bubble: NativeTimelineBubbleRegion?, isFailed: Bool) {
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
