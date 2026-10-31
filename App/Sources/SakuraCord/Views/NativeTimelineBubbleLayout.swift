import AppKit
import CoreText
import SakuraCordModels

struct NativeTimelineBubbleRegion {
    let frame: CGRect
    let isOutgoing: Bool
    let showsTail: Bool
}

@MainActor
enum NativeTimelineBubbleLayout {
    struct Context {
        let isEnabled: Bool
        let isOutgoing: Bool
        let showsAvatar: Bool
    }

    struct Column {
        let contentX: CGFloat
        let contentWidth: CGFloat
    }

    static var horizontalPadding: CGFloat { InterfaceScale.metric(12) }
    static var verticalPadding: CGFloat { InterfaceScale.metric(8) }
    /// The height of a bubble holding one line of text.
    static var oneLineHeight: CGFloat {
        MessageRowLayoutMetrics.compactContentHeight + verticalPadding * 2
    }
    /// No taller than a one-line bubble, which the avatar is bottom-aligned to.
    static var avatarDiameter: CGFloat { InterfaceScale.metric(32) }

    static func context(
        for message: Message,
        source: AppModel?
    ) -> Context {
        // An AutoMod alert's card holds its member's avatar, which a bubble
        // would move to its own bottom edge.
        (message.type == .autoModerationAction ? nil : source?.bubbleContext(for: message))
            ?? Context(isEnabled: false, isOutgoing: false, showsAvatar: true)
    }

    /// One-to-one conversations leave incoming bubbles without avatars.
    static func showsAvatar(in channel: Channel?) -> Bool {
        channel?.kind != .directMessage
    }

    /// The widest a bubble's content column may grow in a timeline row.
    static func maximumContentWidth(availableWidth: CGFloat) -> CGFloat {
        max(
            InterfaceScale.metric(28),
            min(InterfaceScale.metric(500), availableWidth * 0.68 - horizontalPadding * 2)
        )
    }

    static func preferredContentWidth(
        for message: Message,
        row: MessageRowPresentation,
        content: NativeTimelineTextPresentation.Value,
        availableWidth: CGFloat,
        isEnabled: Bool,
        translation: NativeTimelineTranslationPresentation? = nil
    ) -> CGFloat {
        guard isEnabled else { return InterfaceScale.metric(80) }
        let minimumWidth: CGFloat = InterfaceScale.metric(28)
        let maximumWidth = maximumContentWidth(availableWidth: availableWidth)
        var preferredWidth = message.hasPoll ? min(InterfaceScale.metric(456), maximumWidth) : minimumWidth
        if let attributedContent = content.attributedContent {
            preferredWidth = max(
                preferredWidth,
                measuredTextWidth(
                    content.framesetter,
                    length: attributedContent.length,
                    maximumWidth: maximumWidth
                )
            )
        }
        if let translation {
            preferredWidth = max(preferredWidth, translation.preferredWidth(maximumWidth: maximumWidth))
        }
        if let linkedImageWidth = content.linkedImages
            .map(\.displaySize.width).max()
        {
            preferredWidth = max(
                preferredWidth,
                min(maximumWidth, linkedImageWidth)
            )
        }
        if !message.attachments.isEmpty {
            let attachmentWidth = message.attachments.compactMap(\.width)
                .map(CGFloat.init).max() ?? 360
            preferredWidth = max(
                preferredWidth,
                min(maximumWidth, max(InterfaceScale.metric(180), attachmentWidth))
            )
        }
        if !message.embeds.isEmpty || !message.components.isEmpty
            || !row.sakuraCordDeepLinks.isEmpty || !row.serverInvites.isEmpty || message.thread != nil
            || message.forwardedSnapshot != nil
        {
            preferredWidth = max(
                preferredWidth,
                min(InterfaceScale.metric(420), maximumWidth)
            )
        }
        if !message.stickers.isEmpty {
            preferredWidth = max(
                preferredWidth,
                min(
                    maximumWidth,
                    CGFloat(message.stickers.count) * InterfaceScale.metric(120) - InterfaceScale.metric(8)
                )
            )
        }
        return min(maximumWidth, ceil(preferredWidth))
    }

    static func column(
        availableWidth: CGFloat,
        horizontalInset: CGFloat,
        avatarWidth: CGFloat,
        columnGap: CGFloat,
        isGenerated: Bool,
        context: Context,
        preferredContentWidth: CGFloat
    ) -> Column {
        guard context.isEnabled else {
            let contentX = isGenerated
                ? horizontalInset + avatarWidth + 20
                : horizontalInset + avatarWidth + columnGap
            return Column(
                contentX: contentX,
                contentWidth: max(
                    80,
                    availableWidth - contentX - horizontalInset
                )
            )
        }
        let contentX = if isGenerated {
            horizontalInset + horizontalPadding
        } else if context.isOutgoing {
            availableWidth - horizontalInset - horizontalPadding
                - preferredContentWidth
        } else {
            incomingBubbleMinX(
                horizontalInset: horizontalInset,
                avatarWidth: avatarWidth,
                columnGap: columnGap,
                showsAvatar: context.showsAvatar
            ) + horizontalPadding
        }
        return Column(
            contentX: contentX,
            contentWidth: preferredContentWidth
        )
    }

    /// Where an incoming bubble's leading edge sits, past the avatar column
    /// when one shows.
    static func incomingBubbleMinX(
        horizontalInset: CGFloat,
        avatarWidth: CGFloat,
        columnGap: CGFloat,
        showsAvatar: Bool
    ) -> CGFloat {
        horizontalInset + (showsAvatar ? avatarWidth + columnGap : 0)
    }

    /// The conversation timeline's incoming bubble edge, so chrome outside
    /// the timeline can line up with the bubbles.
    static func incomingBubbleMinX(showsAvatar: Bool, settings: InterfaceSettingsSnapshot) -> CGFloat {
        incomingBubbleMinX(
            horizontalInset: MessageRowLayoutMetrics.horizontalInset,
            avatarWidth: MessageRowLayoutMetrics.avatarDiameter,
            columnGap: MessageRowLayoutMetrics.columnGap(
                timestampGutterWidth: NativeTimelineCompactTimestampMetrics.width(settings: settings)
            ),
            showsAvatar: showsAvatar
        )
    }

    static func bottomAlignedAvatarFrame(
        _ frame: CGRect?,
        to region: NativeTimelineBubbleRegion
    ) -> CGRect? {
        frame.map {
            CGRect(
                origin: CGPoint(
                    x: $0.minX,
                    y: region.frame.maxY - $0.height
                ),
                size: $0.size
            )
        }
    }

    static func region(
        contentX: CGFloat,
        contentWidth: CGFloat,
        minY: CGFloat,
        maxY: CGFloat,
        isOutgoing: Bool,
        showsTail: Bool
    ) -> NativeTimelineBubbleRegion {
        NativeTimelineBubbleRegion(
            frame: CGRect(
                x: contentX - horizontalPadding,
                y: minY,
                width: contentWidth + horizontalPadding * 2,
                height: max(1, maxY - minY)
            ),
            isOutgoing: isOutgoing,
            showsTail: showsTail
        )
    }

    static func highlightFrame(
        isEnabled: Bool,
        bubbleRegion: NativeTimelineBubbleRegion?,
        stickerFrames: [CGRect],
        searchCardFrame: CGRect?,
        highlightMinY: CGFloat,
        rowHeight: CGFloat,
        width: CGFloat
    ) -> CGRect {
        let defaultFrame = CGRect(
            x: searchCardFrame?.minX ?? 0,
            y: highlightMinY,
            width: searchCardFrame?.width ?? width,
            height: searchCardFrame?.height ?? max(0, rowHeight - highlightMinY)
        )
        guard isEnabled else { return defaultFrame }
        return bubbleRegion?.frame
            ?? stickerFrames.reduce(nil as CGRect?) { partial, frame in
                partial.map { $0.union(frame) } ?? frame
            }
            ?? defaultFrame
    }

    static func measuredTextWidth(
        _ framesetter: CTFramesetter,
        length: Int,
        maximumWidth: CGFloat
    ) -> CGFloat {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: length),
            nil,
            CGSize(
                width: max(1, maximumWidth),
                height: .greatestFiniteMagnitude
            ),
            nil
        )
        return min(maximumWidth, ceil(size.width + 1))
    }
}

@MainActor
enum NativeTimelineBubbleDrawing {
    static var cornerRadius: CGFloat { InterfaceScale.metric(18) }

    static func foregroundColor(for region: NativeTimelineBubbleRegion?) -> NSColor {
        region?.isOutgoing == true ? .white : .labelColor
    }

    static func secondaryForegroundColor(for region: NativeTimelineBubbleRegion?) -> NSColor {
        region?.isOutgoing == true ? .white.withAlphaComponent(0.72) : .secondaryLabelColor
    }

    static let incomingFillColor = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1)
        default:
            NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
        }
    }

    static func fillColor(for region: NativeTimelineBubbleRegion) -> NSColor {
        return region.isOutgoing ? .sakuraCordAccentColor : incomingFillColor
    }

    static func fill(_ region: NativeTimelineBubbleRegion) {
        fillColor(for: region).setFill()
        path(for: region).fill()
    }

    /// The bubble's complete outline. The tail is merged into the body as a
    /// single contour, so translucent fills and clips cover every point once.
    static func path(for region: NativeTimelineBubbleRegion) -> NSBezierPath {
        let body = bodyPath(for: region)
        guard region.showsTail else { return body }
        return NSBezierPath(cgPath: body.cgPath.union(tailPath(for: region).cgPath))
    }

    static func bodyPath(
        for region: NativeTimelineBubbleRegion
    ) -> NSBezierPath {
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: cornerRadius
        )
    }

    /// Fills only the part of the tail that extends past the body, for
    /// treatments that already cover the body's own bottom corner.
    static func fillTailProtrusion(of region: NativeTimelineBubbleRegion) {
        guard region.showsTail else { return }
        NSGraphicsContext.saveGraphicsState()
        let outsideBody = NSBezierPath(rect: region.frame.insetBy(
            dx: -cornerRadius,
            dy: -cornerRadius
        ))
        outsideBody.append(bodyPath(for: region))
        outsideBody.windingRule = .evenOdd
        outsideBody.addClip()
        tailPath(for: region).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The tail at the bubble's bottom outer corner. Its inner points lie
    /// inside the body so the union with the body has no seam or notch.
    static func tailPath(
        for region: NativeTimelineBubbleRegion
    ) -> NSBezierPath {
        let frame = region.frame
        let edgeX = region.isOutgoing ? frame.maxX : frame.minX
        let inward: CGFloat = region.isOutgoing ? -1 : 1
        func point(_ inset: CGFloat, _ rise: CGFloat) -> CGPoint {
            CGPoint(
                x: edgeX + inward * InterfaceScale.metric(inset),
                y: frame.maxY - InterfaceScale.metric(rise)
            )
        }
        // Start where the straight outer edge meets the bottom corner.
        let startRise = min(18, frame.height / InterfaceScale.metric(1) / 2)
        let path = NSBezierPath()
        path.move(to: point(16, startRise))
        path.line(to: point(0, startRise))
        path.curve(
            to: point(-6, 0),
            controlPoint1: point(0, 6),
            controlPoint2: point(-2.5, 0.8)
        )
        path.curve(
            to: point(16, 2.2),
            controlPoint1: point(4, 0.4),
            controlPoint2: point(10, 1.4)
        )
        path.close()
        return path
    }
}
