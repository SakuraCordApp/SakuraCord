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

    static let horizontalPadding: CGFloat = 12

    static func context(
        for message: Message,
        model: AppModel?
    ) -> Context {
        let isEnabled =
            model?.appearanceSettings.messageAppearance == .bubbles
                && !message.type.hasGeneratedContent
        let channel = model?.snapshot?.channels.first {
            $0.id == message.channelID
        } ?? (model?.selectedChannel?.id == message.channelID
            ? model?.selectedChannel
            : nil)
        return Context(
            isEnabled: isEnabled,
            isOutgoing: isEnabled
                && message.author.id == model?.snapshot?.currentUser.id,
            showsAvatar: channel?.kind != .directMessage
        )
    }

    static func preferredContentWidth(
        for message: Message,
        row: MessageRowPresentation,
        content: NativeTimelineTextPresentation.Value,
        availableWidth: CGFloat,
        isEnabled: Bool
    ) -> CGFloat {
        guard isEnabled else { return 80 }
        let minimumWidth: CGFloat = 28
        let maximumWidth = max(
            minimumWidth,
            min(500, availableWidth * 0.68 - horizontalPadding * 2)
        )
        var preferredWidth = minimumWidth
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
                min(maximumWidth, max(180, attachmentWidth))
            )
        }
        if !message.embeds.isEmpty || !message.components.isEmpty
            || !row.sakuraCordDeepLinks.isEmpty || message.thread != nil
            || message.forwardedSnapshot != nil
        {
            preferredWidth = max(
                preferredWidth,
                min(420, maximumWidth)
            )
        }
        if !message.stickers.isEmpty {
            preferredWidth = max(
                preferredWidth,
                min(
                    maximumWidth,
                    CGFloat(message.stickers.count) * 120 - 8
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
            horizontalInset
                + (context.showsAvatar ? avatarWidth + columnGap : 0)
                + horizontalPadding
        }
        return Column(
            contentX: contentX,
            contentWidth: preferredContentWidth
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

    private static func measuredTextWidth(
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
    static let cornerRadius: CGFloat = 18

    static let incomingFillColor = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1)
        default:
            NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
        }
    }

    static func fillColor(for region: NativeTimelineBubbleRegion) -> NSColor {
        region.isOutgoing ? .sakuraCordAccentColor : incomingFillColor
    }

    static func fill(_ region: NativeTimelineBubbleRegion) {
        fillColor(for: region).setFill()
        if region.showsTail {
            tailPath(for: region).fill()
        }
        bodyPath(for: region).fill()
    }

    static func path(for region: NativeTimelineBubbleRegion) -> NSBezierPath {
        let path = bodyPath(for: region)
        if region.showsTail {
            path.append(tailPath(for: region))
        }
        return path
    }

    static func bodyPath(
        for region: NativeTimelineBubbleRegion
    ) -> NSBezierPath {
        NSBezierPath(
            concentricRoundedRect: region.frame,
            cornerRadius: cornerRadius
        )
    }

    static func tailPath(
        for region: NativeTimelineBubbleRegion
    ) -> NSBezierPath {
        let path = NSBezierPath()
        if region.isOutgoing {
            path.move(to: CGPoint(
                x: region.frame.maxX - 4,
                y: region.frame.maxY - 15
            ))
            path.curve(
                to: CGPoint(x: region.frame.maxX + 10, y: region.frame.maxY),
                controlPoint1: CGPoint(
                    x: region.frame.maxX - 2,
                    y: region.frame.maxY - 5
                ),
                controlPoint2: CGPoint(
                    x: region.frame.maxX + 2,
                    y: region.frame.maxY
                )
            )
            path.curve(
                to: CGPoint(
                    x: region.frame.maxX - 7,
                    y: region.frame.maxY - 3
                ),
                controlPoint1: CGPoint(
                    x: region.frame.maxX + 4,
                    y: region.frame.maxY
                ),
                controlPoint2: CGPoint(
                    x: region.frame.maxX - 2,
                    y: region.frame.maxY - 1
                )
            )
        } else {
            path.move(to: CGPoint(
                x: region.frame.minX + 4,
                y: region.frame.maxY - 15
            ))
            path.curve(
                to: CGPoint(x: region.frame.minX - 10, y: region.frame.maxY),
                controlPoint1: CGPoint(
                    x: region.frame.minX + 2,
                    y: region.frame.maxY - 5
                ),
                controlPoint2: CGPoint(
                    x: region.frame.minX - 2,
                    y: region.frame.maxY
                )
            )
            path.curve(
                to: CGPoint(
                    x: region.frame.minX + 7,
                    y: region.frame.maxY - 3
                ),
                controlPoint1: CGPoint(
                    x: region.frame.minX - 4,
                    y: region.frame.maxY
                ),
                controlPoint2: CGPoint(
                    x: region.frame.minX + 2,
                    y: region.frame.maxY - 1
                )
            )
        }
        path.close()
        return path
    }
}
