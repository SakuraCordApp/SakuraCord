import AppKit
import CoreText
import SakuraCordModels

extension NativeTimelineRowPainter {
    /// Discord's secondary button, which the expand button is.
    private static let secondaryButtonColor = NSColor(srgbRed: 151 / 255, green: 151 / 255, blue: 159 / 255, alpha: 1)

    /// Draws a text preview: its box of text, scrolled when expanded past
    /// the box, and its footer in rest, hover, and pressed states.
    static func textPreview(_ preview: NativeTimelineTextPreview, input: NativeTimelineMessageDrawInput) {
        func target(_ part: NativeTimelineTextPreview.Part) -> NativeTimelineComponentButtonTarget {
            .textPreview(messageID: preview.messageID, attachmentID: preview.attachment.id, part: part)
        }
        let radius = NativeTimelineFileCard.cornerRadius
        let box = preview.boxFrame
        let boxShape = NSBezierPath(roundedRect: box, topRadius: radius)
        (preview.isMarkdown ? NativeTimelineFileCard.audioBackgroundColor : discordCodeBackgroundColor).setFill()
        boxShape.fill()
        if let text = preview.text, let context = NSGraphicsContext.current?.cgContext {
            let stored = input.model?.attachmentTextPreviews.scrollOffsets[preview.attachment.id] ?? .zero
            let maximum = preview.maximumScroll
            let scroll = CGPoint(x: min(stored.x, maximum.x), y: min(stored.y, maximum.y))
            let frame = preview.textFrame.offsetBy(dx: -scroll.x, dy: -scroll.y)
            context.saveGState()
            context.clip(to: box.insetBy(dx: 1, dy: 1))
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
        (preview.isMarkdown ? NativeTimelineSemanticColor.opacity(.labelColor, 0.10) : discordCodeBorderColor).setStroke()
        let boxBorder = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), topRadius: radius - 0.5)
        boxBorder.lineWidth = 1
        boxBorder.stroke()

        let footer = preview.footerFrame
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: footer, bottomRadius: radius).fill()
        NativeTimelineSemanticColor.opacity(.labelColor, 0.10).setStroke()
        // The box's border closes the footer's top.
        let footerBorder = NSBezierPath(openRoundedRect: footer.insetBy(dx: 0.5, dy: 0.5), bottomRadius: radius - 0.5)
        footerBorder.lineWidth = 1
        footerBorder.stroke()

        if let frame = preview.expandFrame {
            let isPressed = input.pressedComponentButton == target(.expand)
            let isHovered = input.hoveredComponentButton == target(.expand)
            let button = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            secondaryButtonColor.withAlphaComponent(isPressed ? 0.24 : isHovered ? 0.20 : 0.12).setFill()
            button.fill()
            secondaryButtonColor.withAlphaComponent(0.16).setStroke()
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            outline.stroke()
            systemSymbol(
                preview.isExpanded ? "chevron.up" : "chevron.down",
                in: frame.insetBy(dx: InterfaceScale.metric(12), dy: InterfaceScale.metric(12)),
                color: .labelColor, inset: 0, weight: .semibold
            )
        }
        text(preview.attachment.filename, in: preview.nameFrame, font: NativeTimelineTextPreview.nameFont, color: .labelColor)
        // A download from the More menu reports here, in place of the size.
        switch input.model?.attachmentDownloads.states[preview.attachment.id] {
        case let .downloading(fraction):
            downloadProgressBar(in: preview.sizeFrame, fraction: fraction)
        case .failed:
            text("Download failed", in: preview.sizeFrame, font: NativeTimelineTextPreview.sizeFont, color: .systemRed)
        case .finished, nil:
            text(
                NativeTimelineTextPreview.sizeText(preview.attachment.size),
                in: preview.sizeFrame, font: NativeTimelineTextPreview.sizeFont, color: .secondaryLabelColor
            )
        }
        let icons: [(NativeTimelineTextPreview.Part, String)] = [
            (.language, "chevron.left.forwardslash.chevron.right"),
            (.viewWholeFile, "arrow.up.left.and.arrow.down.right"),
            (.more, "ellipsis"),
        ]
        for (part, symbol) in icons {
            guard let frame = preview.frame(of: part) else { continue }
            systemSymbol(symbol, in: frame, color: .labelColor, inset: 0, weight: .semibold)
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

private extension NSBezierPath {
    /// A rectangle rounded only at its top corners, in a flipped context.
    convenience init(roundedRect rect: CGRect, topRadius radius: CGFloat) {
        self.init()
        move(to: CGPoint(x: rect.minX, y: rect.maxY))
        line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        appendArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        appendArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
        line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        close()
    }

    /// A rectangle rounded only at its bottom corners, in a flipped context.
    convenience init(roundedRect rect: CGRect, bottomRadius radius: CGFloat) {
        self.init(openRoundedRect: rect, bottomRadius: radius)
        close()
    }

    /// The sides and rounded bottom of a rectangle, leaving its top open.
    convenience init(openRoundedRect rect: CGRect, bottomRadius radius: CGFloat) {
        self.init()
        move(to: CGPoint(x: rect.minX, y: rect.minY))
        line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        appendArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        line(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        appendArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        line(to: CGPoint(x: rect.maxX, y: rect.minY))
    }
}
