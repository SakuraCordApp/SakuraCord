import AppKit
import CoreText
import SakuraCordModels

extension NativeTimelineRowPainter {
    /// Draws a text preview: its box of text, scrolled when expanded past
    /// the box, and its footer in rest, hover, and pressed states.
    static func textPreview(_ preview: NativeTimelineTextPreview, input: NativeTimelineMessageDrawInput) {
        func target(_ part: NativeTimelineTextPreview.Part) -> NativeTimelineComponentButtonTarget {
            .textPreview(messageID: preview.messageID, attachmentID: preview.attachment.id, part: part)
        }
        let bubble = preview.isInBubble ? input.layout.bubbleRegion : nil
        let downloadState = input.model?.attachmentDownloads.states[preview.attachment.id]
        let palette = FileCardPalette(bubble: bubble, isFailed: false)
        let surfaceRadius = NativeTimelineBubbleDrawing.cornerRadius
        if bubble == nil {
            // A file card's surface, with the bubble's corner radius.
            NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.10).setFill()
            NSBezierPath(concentricRoundedRect: preview.frame, cornerRadius: surfaceRadius).fill()
        }
        let box = preview.boxFrame
        let boxRadius = bubbleConcentricCornerRadius(
            for: box, in: bubble, fallback: surfaceRadius - (box.minX - preview.frame.minX)
        )
        let boxShape = NSBezierPath(concentricRoundedRect: box, cornerRadius: boxRadius)
        // Rendered Markdown keeps the timeline's text colours, so it needs
        // an opaque neutral page even on an accent bubble.
        (preview.isMarkdown ? NSColor.controlBackgroundColor : discordCodeBackgroundColor).setFill()
        boxShape.fill()
        if let text = preview.text, let context = NSGraphicsContext.current?.cgContext {
            let stored = input.model?.attachmentTextPreviews.scrollOffsets[preview.attachment.id] ?? .zero
            let maximum = preview.maximumScroll
            let scroll = CGPoint(x: min(stored.x, maximum.x), y: min(stored.y, maximum.y))
            let frame = preview.textFrame.offsetBy(dx: -scroll.x, dy: -scroll.y)
            context.saveGState()
            boxShape.addClip()
            if preview.isMarkdown {
                // Markdown needs the message painter's list, quote, and code decorations.
                attributedText(text.value, framesetter: text.framesetter, in: frame, model: input.model)
            } else {
                context.translateBy(x: frame.minX, y: frame.maxY)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                CTFrameDraw(text.frame, context)
            }
            context.restoreGState()
            if maximum.y > 0 {
                textPreviewScrollbar(preview, scroll: scroll.y)
            }
        }
        if !preview.isMarkdown {
            // A message code block's border.
            discordCodeBorderColor.setStroke()
            let border = NSBezierPath(concentricRoundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: boxRadius - 0.5)
            border.lineWidth = 1
            border.stroke()
        }

        func chip(_ part: NativeTimelineTextPreview.Part, symbol: String, in frame: CGRect, accent: Bool = false) {
            let pressProgress = input.pressedComponentButton == target(part) ? input.componentButtonPressProgress : 0
            let isHovered = input.hoveredComponentButton == target(part)
            // The expand button is the footer's lead, like a file card's badge.
            (accent ? palette.badge : isHovered ? palette.chipHover : palette.chip).setFill()
            let scale = accent && isHovered ? 1.06 - 0.12 * pressProgress : 1
            let shape = frame.insetBy(dx: frame.width * (1 - scale) / 2, dy: frame.height * (1 - scale) / 2)
            NSBezierPath(ovalIn: shape).fill()
            if !accent, pressProgress > 0 {
                palette.highlight.withAlphaComponent(0.06 * pressProgress).setFill()
                NSBezierPath(ovalIn: shape).fill()
            }
            systemSymbol(
                symbol, in: shape, color: accent ? palette.glyph : palette.name,
                inset: shape.width * (accent ? 0.3 : 0.28), weight: .semibold
            )
        }
        if let frame = preview.expandFrame {
            chip(.expand, symbol: preview.isExpanded ? "chevron.up" : "chevron.down", in: frame, accent: true)
        }
        text(
            preview.attachment.filename, in: preview.nameFrame, font: NativeTimelineFileCard.nameFont,
            color: palette.name, lineBreakMode: .byTruncatingMiddle
        )
        // A download from the More menu reports here, as on a file card.
        let detail = NativeTimelineFileCard.detail(for: downloadState, size: preview.attachment.size)
        text(
            detail.text + (detail.link ?? ""), in: preview.sizeFrame, font: NativeTimelineFileCard.detailFont,
            color: downloadState == .failed ? palette.failure : palette.detail
        )
        let icons: [(NativeTimelineTextPreview.Part, String)] = [
            (.language, "chevron.left.forwardslash.chevron.right"),
            (.viewWholeFile, "arrow.up.left.and.arrow.down.right"),
            (.more, "ellipsis"),
        ]
        for (part, symbol) in icons {
            guard let frame = preview.frame(of: part) else { continue }
            chip(part, symbol: symbol, in: frame)
        }
    }

    /// The thin scroller in the box's gutter, shown while there is more to scroll.
    private static func textPreviewScrollbar(_ preview: NativeTimelineTextPreview, scroll: CGFloat) {
        let track = preview.boxFrame.insetBy(dx: 0, dy: InterfaceScale.metric(4))
        let contentHeight = preview.boxFrame.height + preview.maximumScroll.y
        let height = max(InterfaceScale.metric(24), track.height * preview.boxFrame.height / contentHeight)
        let width = InterfaceScale.metric(4)
        let thumb = CGRect(
            x: preview.boxFrame.maxX - InterfaceScale.metric(3) - width,
            y: track.minY + (track.height - height) * scroll / preview.maximumScroll.y,
            width: width, height: height
        )
        NSColor.white.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }
}
