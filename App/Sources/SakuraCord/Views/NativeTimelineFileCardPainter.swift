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
        // An audio card's own button takes the hover, not the whole card.
        let highlight = card.isAudio ? 0 : 0.04 * ((isHovered ? 1 : 0) + pressProgress)
        if let bubble {
            if highlight > 0 {
                let frame = card.frame.insetBy(dx: -InterfaceScale.metric(6), dy: -InterfaceScale.metric(4))
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
        if card.isAudio {
            fileCardDownloadButton(card, state: state, palette: palette, isHovered: isHovered, pressProgress: pressProgress)
        } else {
            fileCardBadge(card, state: state, palette: palette, isHovered: isHovered, pressProgress: pressProgress)
        }

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
                link, in: frame, font: .interfaceSystemFont(ofSize: 12, weight: .semibold),
                color: state == .failed ? palette.failure : palette.link
            )
        }
    }

    /// The type badge, which turns into the card's action under the pointer
    /// and rings its progress while downloading.
    private static func fileCardBadge(
        _ card: NativeTimelineFileCard,
        state: AttachmentDownloadStore.State?,
        palette: FileCardPalette,
        isHovered: Bool,
        pressProgress: CGFloat
    ) {
        let symbol: String
        let fraction: Double?
        switch state {
        case nil:
            (symbol, fraction) = (isHovered ? "arrow.down" : NativeTimelineFileCard.symbolName(for: card.attachment), nil)
        case let .downloading(progress):
            (symbol, fraction) = ("xmark", progress)
        case .finished:
            (symbol, fraction) = (isHovered ? "magnifyingglass" : NativeTimelineFileCard.symbolName(for: card.attachment), nil)
        case .failed:
            (symbol, fraction) = (isHovered ? "arrow.clockwise" : "exclamationmark", nil)
        }
        // The voice message play button's hover growth, then a press dip.
        let scale = isHovered ? 1.06 - 0.12 * pressProgress : 1
        let base = card.badgeFrame
        let badge = base.insetBy(dx: base.width * (1 - scale) / 2, dy: base.height * (1 - scale) / 2)
        palette.badge.setFill()
        NSBezierPath(ovalIn: badge).fill()
        guard let fraction else {
            systemSymbol(symbol, in: badge, color: palette.glyph, inset: badge.width * 0.27, weight: .semibold)
            return
        }
        downloadRing(in: badge, fraction: fraction, color: palette.glyph)
        systemSymbol(symbol, in: badge, color: palette.glyph, inset: badge.width * 0.34, weight: .bold)
    }

    /// An audio card's download button: a voice message's chip, ringed
    /// while downloading.
    private static func fileCardDownloadButton(
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
        let chip = card.downloadFrame
        (isHovered ? palette.chipHover : palette.chip).setFill()
        NSBezierPath(ovalIn: chip).fill()
        if pressProgress > 0 {
            palette.highlight.withAlphaComponent(0.06 * pressProgress).setFill()
            NSBezierPath(ovalIn: chip).fill()
        }
        let glyph = state == .failed ? palette.failure : palette.name
        if case let .downloading(fraction) = state {
            downloadRing(in: chip, fraction: fraction, color: palette.link)
        }
        systemSymbol(symbol, in: chip, color: glyph, inset: chip.width * 0.3, weight: .semibold)
    }

    private static func downloadRing(in badge: CGRect, fraction: Double, color: NSColor) {
        let ring = NSBezierPath(ovalIn: badge.insetBy(dx: InterfaceScale.metric(4), dy: InterfaceScale.metric(4)))
        ring.lineWidth = InterfaceScale.metric(2.5)
        color.withAlphaComponent(0.3).setStroke()
        ring.stroke()
        let radius = badge.width / 2 - InterfaceScale.metric(4)
        let arc = NSBezierPath()
        // Flipped rows: -90° is the top, and positive angles turn clockwise.
        arc.appendArc(
            withCenter: CGPoint(x: badge.midX, y: badge.midY), radius: radius,
            startAngle: -90, endAngle: -90 + 360 * min(max(fraction, 0.02), 1)
        )
        arc.lineWidth = ring.lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    /// A file card's colours: SakuraCord's accent badge with a white glyph,
    /// inverted on an outgoing bubble as its voice messages are.
    struct FileCardPalette {
        let badge: NSColor
        let glyph: NSColor
        let name: NSColor
        let detail: NSColor
        let link: NSColor
        let failure: NSColor
        let highlight: NSColor
        let chip: NSColor
        let chipHover: NSColor

        init(bubble: NativeTimelineBubbleRegion?, isFailed: Bool) {
            let accent = NSColor.sakuraCordAccentColor
            if bubble?.isOutgoing == true {
                badge = .white
                glyph = isFailed ? .systemRed : accent
                link = .white
                failure = .white
                highlight = .white
                chip = NSColor.white.withAlphaComponent(0.2)
                chipHover = NSColor.white.withAlphaComponent(0.32)
            } else {
                badge = isFailed ? .systemRed : accent
                glyph = .white
                link = accent
                failure = .systemRed
                highlight = .labelColor
                chip = NSColor.labelColor.withAlphaComponent(0.09)
                chipHover = NSColor.labelColor.withAlphaComponent(0.16)
            }
            name = NativeTimelineBubbleDrawing.foregroundColor(for: bubble)
            detail = NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubble)
        }
    }
}
