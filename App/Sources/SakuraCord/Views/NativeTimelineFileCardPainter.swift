import AppKit
import SakuraCordModels

extension NativeTimelineRowPainter {
    private static var fileIcons: [String: NSImage] = [:]

    /// Draws a file card in its rest, hover, pressed, downloading, finished,
    /// or failed state.
    static func fileCard(
        _ card: NativeTimelineFileCard,
        messageID: MessageID,
        state: AttachmentDownloadStore.State?,
        hovered: NativeTimelineComponentButtonTarget?,
        pressed: NativeTimelineComponentButtonTarget?
    ) {
        func target(_ part: NativeTimelineFileCard.Part?) -> NativeTimelineComponentButtonTarget {
            .fileCard(messageID: messageID, attachmentID: card.attachment.id, part: part)
        }
        let radius = NativeTimelineFileCard.cornerRadius
        let shape = NSBezierPath(roundedRect: card.frame, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowOffset = NSSize(width: 0, height: -InterfaceScale.metric(1))
        shadow.shadowBlurRadius = InterfaceScale.metric(4)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NativeTimelineSemanticColor.opacity(.labelColor, 0.10).setStroke()
        let border = NSBezierPath(
            roundedRect: card.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5
        )
        border.lineWidth = 1
        border.stroke()

        if let icon = fileIcon(named: NativeTimelineFileCard.iconName(for: card.attachment)) {
            icon.draw(in: card.iconFrame, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        if case let .downloading(fraction) = state {
            fileCardProgress(card, fraction: fraction, isCancelHovered: hovered == target(.action))
            return
        }
        text(
            card.attachment.filename,
            in: card.nameLineFrame(isDownloading: false),
            font: NativeTimelineFileCard.nameFont,
            color: .linkColor,
            isInteractiveHovered: hovered == target(.name)
        )
        let detail = NativeTimelineFileCard.detail(for: state, size: card.attachment.size)
        text(
            detail.text,
            in: card.detailLineFrame(isDownloading: false),
            font: NativeTimelineFileCard.detailFont,
            color: state == .failed ? .systemRed : .secondaryLabelColor
        )
        if let link = detail.link, let frame = card.detailLinkFrame(for: state) {
            text(
                link, in: frame, font: NativeTimelineFileCard.detailFont, color: .linkColor,
                isInteractiveHovered: hovered == target(.detailLink)
            )
        }
        let isCardHovered = hovered.map { [nil, .name, .action, .detailLink].map(target).contains($0) } ?? false
        guard isCardHovered else { return }
        fileCardHoverButton(
            card,
            symbol: state.map { if case .finished = $0 { "magnifyingglass" } else { "arrow.down.to.line" } }
                ?? "arrow.down.to.line",
            isHovered: hovered == target(.action),
            isPressed: pressed == target(.action)
        )
    }

    /// Discord's in-progress card: a bar under the plain filename and a
    /// trailing cancel button.
    private static func fileCardProgress(_ card: NativeTimelineFileCard, fraction: Double, isCancelHovered: Bool) {
        text(
            card.attachment.filename,
            in: card.nameLineFrame(isDownloading: true),
            font: NativeTimelineFileCard.nameFont,
            color: .labelColor
        )
        let line = card.detailLineFrame(isDownloading: true)
        let track = CGRect(
            x: line.minX, y: line.midY - InterfaceScale.metric(4),
            width: max(0, line.width - InterfaceScale.metric(8)), height: InterfaceScale.metric(8)
        )
        let radius = track.height / 2
        NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.24).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var fill = track
        fill.size.width = max(track.height, track.width * min(max(fraction, 0), 1))
        NSColor.sakuraCordAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        systemSymbol(
            "xmark", in: card.cancelFrame,
            color: isCancelHovered ? .labelColor : .secondaryLabelColor, inset: InterfaceScale.metric(5)
        )
    }

    /// The button group Discord overlays on a hovered card's corner.
    private static func fileCardHoverButton(
        _ card: NativeTimelineFileCard, symbol: String, isHovered: Bool, isPressed: Bool
    ) {
        let frame = card.hoverButtonFrame
        let radius = InterfaceScale.metric(5)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        if isHovered || isPressed {
            NativeTimelineSemanticColor.opacity(.secondaryLabelColor, isPressed ? 0.16 : 0.12).setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        }
        NativeTimelineSemanticColor.opacity(.labelColor, 0.10).setStroke()
        let outline = NSBezierPath(
            roundedRect: frame.insetBy(dx: -0.5, dy: -0.5), xRadius: radius + 0.5, yRadius: radius + 0.5
        )
        outline.lineWidth = 1
        outline.stroke()
        systemSymbol(
            symbol, in: frame.insetBy(dx: InterfaceScale.metric(6), dy: InterfaceScale.metric(6)),
            color: isHovered || isPressed ? .labelColor : .secondaryLabelColor, inset: 0, weight: .medium
        )
    }

    private static func fileIcon(named name: String) -> NSImage? {
        if let icon = fileIcons[name] { return icon }
        let icon = Bundle.module.url(forResource: "file-icon-\(name)", withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:))
        fileIcons[name] = icon
        return icon
    }
}
