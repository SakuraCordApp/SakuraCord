import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

struct NativeTimelineMessageDrawInput {
    let row: MessageRowPresentation
    let layout: NativeTimelineRowLayout
    let model: AppModel?
    let isHovered: Bool
    let showsCompactTimestamp: Bool
    let hoveredMention: NativeTimelineMentionHover?
    let hoveredTextLink: NativeTimelineTextLinkHover?
    let hoveredTextSpoiler: NativeTimelineTextSpoilerHover?
    let hoveredComponentButton: NativeTimelineComponentButtonTarget?
    let activeComponentChoiceTarget: NativeTimelineComponentSelectTarget?
    let pressedComponentButton: NativeTimelineComponentButtonTarget?
    let componentButtonPressProgress: CGFloat
    let isForwardedSourceHovered: Bool
    let hidesMessageContent: Bool
    let hoveredReactionID: String?
    let isAddReactionHovered: Bool
    let textSelection: NativeTimelineTextSelection?
    let revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState
    let spoilerRevealStore: NativeTimelineSpoilerRevealStore?
    let reactionCountTransitions: [String: NativeTimelineReactionCountTransition]
}

extension NativeTimelineRowPainter {
    static var messageDrawOperation:
        @MainActor (NativeTimelineMessageDrawInput) -> Void
    {
        { input in
            let row = input.row
            let layout = input.layout
            let model = input.model
            let showsCompactTimestamp = input.showsCompactTimestamp
            let hoveredMention = input.hoveredMention
            let hoveredTextLink = input.hoveredTextLink
            let hoveredTextSpoiler = input.hoveredTextSpoiler
            let hoveredComponentButton = input.hoveredComponentButton
            let activeComponentChoiceTarget =
                input.activeComponentChoiceTarget
            let pressedComponentButton = input.pressedComponentButton
            let componentButtonPressProgress = input.componentButtonPressProgress
            let isForwardedSourceHovered = input.isForwardedSourceHovered
            let hidesMessageContent = input.hidesMessageContent
            let hoveredReactionID = input.hoveredReactionID
            let isAddReactionHovered = input.isAddReactionHovered
            let textSelection = input.textSelection
            let revealedTextSpoilerState = input.revealedTextSpoilerState
            let spoilerRevealStore = input.spoilerRevealStore
            let reactionCountTransitions = input.reactionCountTransitions
        let message = row.message
        if let context = row.searchContext,
           let region = layout.searchSectionRegion
        {
            NativeTimelineRowPainter.systemSymbol(
                context.systemImage,
                in: region.iconFrame,
                color: .secondaryLabelColor,
                inset: 1,
                weight: .semibold
            )
            text(
                context.sectionTitle,
                in: region.titleFrame,
                font: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                    weight: .semibold
                ),
                color: .labelColor,
                lineBreakMode: .byTruncatingTail
            )
            if let subtitle = context.sectionSubtitle,
               let subtitleFrame = region.subtitleFrame
            {
                text(
                    subtitle,
                    in: subtitleFrame,
                    font: .preferredFont(forTextStyle: .caption1),
                    color: .secondaryLabelColor,
                    lineBreakMode: .byTruncatingTail
                )
            }
        }
        if let frame = layout.daySeparatorFrame {
            dateSeparator(date: message.timestamp, frame: frame)
        }
        if let frame = layout.unreadSeparatorFrame {
            newMessagesSeparator(frame: frame)
        }

        let author = model?.authorPresentation(for: message)
        if let frame = layout.avatarFrame {
            let presentedAuthor =
                author?.user
                ?? message.author
            avatar(
                name: presentedAuthor.displayName,
                url:
                    presentedAuthor.avatarURL
                        ?? message.author.avatarURL,
                in: frame
            )
            if let decorationURL =
                presentedAuthor.avatarDecorationURL
                    ?? message.author.avatarDecorationURL
            {
                avatarDecoration(
                    url: decorationURL,
                    around: frame
                )
            }
        }
        if let frame = layout.authorFrame {
            let presentedAuthor =
                author?.user
                ?? message.author
            text(
                presentedAuthor.displayName,
                in: frame,
                font: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                    weight: .semibold
                ),
                color: presentedAuthor.isBot
                    ? .sakuraCordAccentColor
                    : model?.interfaceSettings.showsRoleColors == false
                    ? .labelColor
                    : roleColor(author?.roleColorHex) ?? .labelColor
            )
        }
        if let frame = layout.botBadgeFrame {
            NSColor.sakuraCordAccentColor.setFill()
            NSBezierPath(
                concentricRoundedRect: frame,
                cornerRadius: 3
            ).fill()
            text(
                "APP",
                in: frame,
                font: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .bold
                ),
                color: .white,
                alignment: .center
            )
        }
        if let frame = layout.timestampFrame {
            text(
                NativeTimelineTimestamp.text(
                    for: message.timestamp,
                    settings: model?.interfaceSettings ?? .defaults
                ),
                in: frame,
                font: .preferredFont(forTextStyle: .caption1),
                color: .secondaryLabelColor
            )
        }
        if showsCompactTimestamp,
           let frame = layout.compactTimestampFrame
        {
            text(
                NativeTimelineTimestamp.text(
                    for: message.timestamp,
                    settings: model?.interfaceSettings ?? .defaults,
                    includesSeconds: false
                ),
                in: frame,
                font: NativeTimelineCompactTimestampMetrics.font,
                color: .tertiaryLabelColor,
                alignment: .center,
                lineBreakMode: .byClipping
            )
        }
        if let frame = layout.editedFrame {
            text(
                "(edited)",
                in: frame,
                font: .preferredFont(forTextStyle: .caption2),
                color: .tertiaryLabelColor
            )
        }
        if let frame = layout.replyFrame,
           let contentFrame = layout.replyContentFrame
        {
            if let preview = row.replyPreview {
                replyContext(
                    preview: preview,
                    frame: frame,
                    contentFrame: contentFrame,
                    model: model
                )
            } else {
                unavailableReplyContext(
                    frame: frame,
                    contentFrame: contentFrame
                )
            }
        }
        if let region = layout.commandInvocationRegion {
            commandInvocation(
                region,
                message: message
            )
        }
        if hidesMessageContent {
            return
        }
        if let barFrame = layout.forwardedBarFrame {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.72).setFill()
            NSBezierPath(
                concentricRoundedRect: barFrame,
                cornerRadius: barFrame.width / 2
            ).fill()
        }
        if let headerFrame = layout.forwardedHeaderFrame {
            let baseFont = NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .semibold
            )
            let italicFont = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize
            ) ?? baseFont
            text(
                "↗ Forwarded",
                in: headerFrame,
                font: italicFont,
                color: .secondaryLabelColor
            )
        }
        if let frame = layout.systemIconFrame {
            let currentUserID = model?.snapshot?.currentUser.id
            systemSymbol(
                SystemMessagePresentation.systemImage(
                    for: message,
                    currentUserID: currentUserID
                ),
                in: frame,
                color:
                    SystemMessagePresentation.usesSuccessColor(
                        for: message,
                        currentUserID: currentUserID
                    )
                        ? .systemGreen
                        : .secondaryLabelColor,
                inset: 1
            )
        }
        if let frame = layout.contentFrame,
           let attributedContent = layout.attributedContent,
           let contentFramesetter = layout.contentFramesetter
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(
                CGFloat(
                    MessageOutboxPresentation.textOpacity(
                        for: message.outboxState
                    )
                )
            )
            // CoreText requires the full fractional typographic line box to
            // produce a CTLine. The established compact row is 18 points high,
            // so give the frame a little layout headroom without changing the
            // visible row geometry or adding spacing between grouped messages.
            let drawingFrame = NativeTimelineTextGeometry
                .messageContentDrawingFrame(frame)
            attributedText(
                attributedContent,
                framesetter: contentFramesetter,
                in: drawingFrame,
                model: model,
                selectionRange:
                    textSelection?.itemIdentifier == .message(row.identity)
                        && textSelection?.region == .content
                    ? textSelection?.range
                    : nil,
                hoveredMentionCharacterIndex:
                    hoveredMention?.itemIdentifier == .message(row.identity)
                        && hoveredMention?.region == .content
                    ? hoveredMention?.characterIndex
                    : nil,
                hoveredLinkCharacterIndex:
                    hoveredTextLink?.itemIdentifier == .message(row.identity)
                        && hoveredTextLink?.region == .content
                    ? hoveredTextLink?.characterIndex
                    : nil,
                hoveredSpoilerRangeLocation:
                    hoveredTextSpoiler?.itemIdentifier
                        == .message(row.identity)
                        && hoveredTextSpoiler?.region == .content
                    ? hoveredTextSpoiler?.rangeLocation
                    : nil,
                revealedSpoilerLocations:
                    revealedTextSpoilerState.locations(in: .content)
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        for region in layout.linkedImageRegions {
            let key = NativeTimelineMediaKey.media(
                region.reference.displayURL,
                maximumPixelDimension: region.reference.isEmoji ? 96 : 720
            )
            if let image = mediaImage(for: key) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: region.reference.isEmoji ? 7 : 10,
                    fillsFrame: !region.reference.isEmoji && !region.reference.isSticker
                )
            } else {
                card(
                    region.frame,
                    tint: region.reference.isEmoji || region.reference.isSticker
                        ? .clear
                        : .secondaryLabelColor
                )
                text(
                    region.reference.label,
                    in: region.frame.insetBy(dx: 12, dy: 10),
                    font: .systemFont(ofSize: 12, weight: .medium),
                    color: .secondaryLabelColor,
                    lineBreakMode: .byTruncatingMiddle
                )
            }
        }

        NSGraphicsContext.saveGraphicsState()
        let attachmentContext = NSGraphicsContext.current?.cgContext
        attachmentContext?.setAlpha(
            CGFloat(MessageOutboxPresentation.mediaOpacity(
                for: message.outboxState
            ))
        )
        // AppKit's NSImage drawing does not consistently inherit a CGContext's
        // global alpha. Composite the complete attachment gallery as one layer
        // so bitmap images, symbols, text, and placeholders share the pending
        // message presentation instead of only dimming Quartz-drawn pieces.
        attachmentContext?.beginTransparencyLayer(auxiliaryInfo: nil)
        let attachmentFillsFrame =
            MediaGalleryImagePresentation.fillsFrame(
                itemCount: layout.attachmentRegions.count
            )
        for region in layout.attachmentRegions {
            let attachment = region.attachment
            let isConcealed =
                spoilerRevealStore.map {
                    NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                        messageID: message.id,
                        contentID: "attachment:\(attachment.id)",
                        isSpoiler: attachment.isSpoiler,
                        store: $0
                    )
                } ?? false
            if isConcealed {
                spoilerConcealedBase(
                    in: region.frame,
                    cornerRadius: 8
                )
                continue
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                concentricRoundedRect: region.frame,
                cornerRadius: 8
            ).fill()
            switch attachment.mediaKind {
            case .image, .animatedImage:
                if let key = NativeTimelineMediaKey.attachment(attachment),
                   let image = mediaImage(for: key)
                {
                    drawImage(
                        image,
                        in: region.frame,
                        cornerRadius: 8,
                        fillsFrame: attachmentFillsFrame
                    )
                }
            case .video:
                systemSymbol(
                    "film",
                    in: region.frame,
                    color: .secondaryLabelColor,
                    inset: 30
                )
                mediaPlayGlyph(in: region.frame)
            case .audio:
                attachmentAudio(
                    attachment,
                    in: region.frame
                )
            case .file:
                systemSymbol(
                    "doc",
                    in: CGRect(
                        x: region.frame.midX - 19,
                        y: region.frame.midY - 34,
                        width: 38,
                        height: 38
                    ),
                    color: .labelColor,
                    inset: 1
                )
                text(
                    attachment.filename,
                    in: CGRect(
                        x: region.frame.minX + 12,
                        y: region.frame.midY + 11,
                        width: max(1, region.frame.width - 24),
                        height: 38
                    ),
                    font: .preferredFont(forTextStyle: .body),
                    color: .labelColor,
                    alignment: .center,
                    lineBreakMode: .byTruncatingTail
                )
            }
        }
        attachmentContext?.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        for region in layout.embedRegions {
            if region.kind == .card {
                embedCard(region.frame, accentColor: region.accentColor)
            }
            for (textIndex, textRegion) in
                region.textRegions.enumerated()
            {
                attributedText(
                    textRegion.text,
                    in: textRegion.frame,
                    model: model,
                    selectionRange:
                        textSelection?.itemIdentifier
                            == .message(row.identity)
                            && textSelection?.region == .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        ? textSelection?.range
                        : nil,
                    hoveredMentionCharacterIndex:
                        hoveredMention?.itemIdentifier
                            == .message(row.identity)
                            && hoveredMention?.region == .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        ? hoveredMention?.characterIndex
                        : nil,
                    hoveredLinkCharacterIndex:
                        hoveredTextLink?.itemIdentifier
                            == .message(row.identity)
                            && hoveredTextLink?.region == .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        ? hoveredTextLink?.characterIndex
                        : nil,
                    hoveredSpoilerRangeLocation:
                        hoveredTextSpoiler?.itemIdentifier
                            == .message(row.identity)
                            && hoveredTextSpoiler?.region == .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        ? hoveredTextSpoiler?.rangeLocation
                        : nil,
                    revealedSpoilerLocations:
                        revealedTextSpoilerState.locations(
                            in: .embed(
                                embedID: region.embedID,
                                textIndex: textIndex
                            )
                        )
                )
            }
            for imageRegion in region.imageRegions {
                if let image = mediaImage(
                    for: .media(
                        imageRegion.url,
                        maximumPixelDimension:
                            imageRegion.maximumPixelDimension
                    )
                ) {
                    drawImage(
                        image,
                        in: imageRegion.frame,
                        cornerRadius: imageRegion.cornerRadius,
                        fillsFrame: false
                    )
                } else {
                    systemSymbol(
                        imageRegion.fallbackSystemImage,
                        in: imageRegion.frame,
                        color: .secondaryLabelColor,
                        inset: imageRegion.frame.width >= 70 ? 22 : 2
                    )
                }
            }
            if let frame = region.mediaFrame,
               let url = region.mediaURL
            {
                // The native player overlay owns both the loading surface and
                // playback for autoplay video. Painting another rounded
                // placeholder into the cached row leaves a highlighted slice
                // behind if the bottom-anchored row moves before the player
                // layer is repositioned.
                if TimelineInlineVideoPolicy
                    .canvasOwnsLoadingSurface(
                        mediaIsVideo: region.mediaIsVideo,
                        autoplaysInline: region.mediaAutoplaysInline
                    )
                {
                    NativeTimelineSemanticColor.opacity(
                        .secondaryLabelColor,
                        0.10
                    ).setFill()
                    NSBezierPath(
                        concentricRoundedRect: frame,
                        cornerRadius: 8
                    ).fill()
                    let image = mediaImage(for: .media(url))
                    if let image {
                        drawImage(
                            image,
                            in: frame,
                            cornerRadius: 8,
                            fillsFrame: false
                        )
                        if region.mediaIsVideo {
                            mediaPlayGlyph(in: frame)
                        }
                    } else if region.mediaIsVideo {
                        systemSymbol(
                            "film",
                            in: frame,
                            color: .secondaryLabelColor,
                            inset: 30
                        )
                        mediaPlayGlyph(in: frame)
                    }
                }
            }
        }
        if let region = layout.sakuraCordDeepLinkRegion {
            let target = NativeTimelineComponentButtonTarget(
                messageID: message.id,
                componentID: region.action.componentID
            )
            sakuraCordDeepLinkCard(
                region,
                isButtonHovered: hoveredComponentButton == target,
                buttonPressProgress:
                    pressedComponentButton == target
                        ? componentButtonPressProgress
                        : 0
            )
        }
        for (layoutIndex, componentLayout) in
            layout.componentLayouts.enumerated()
        {
            drawComponents(.init(
                layout: componentLayout,
                model: model,
                messageID: message.id,
                itemIdentifier: .message(row.identity),
                layoutIndex: layoutIndex,
                textSelection: textSelection,
                hoveredMention: hoveredMention,
                hoveredTextLink: hoveredTextLink,
                hoveredTextSpoiler: hoveredTextSpoiler,
                revealedTextSpoilerState:
                    revealedTextSpoilerState,
                spoilerRevealStore: spoilerRevealStore,
                hoveredComponentButton: hoveredComponentButton,
                activeComponentChoiceTarget: activeComponentChoiceTarget,
                pressedComponentButton: pressedComponentButton,
                componentButtonPressProgress:
                    componentButtonPressProgress
            ))
        }
        for (index, frame) in layout.stickerFrames.enumerated() {
            let sticker = message.stickers.indices.contains(index)
                ? message.stickers[index]
                : nil
            if sticker?.format == .lottie {
                // A bounded native Lottie overlay owns loading, playback, and
                // reduced-motion presentation for this exact layout frame.
                continue
            }
            let image = sticker?.mediaURL.flatMap {
                mediaImage(
                    for: .media($0, maximumPixelDimension: 384)
                )
            }
            if let image {
                drawImage(image, in: frame, cornerRadius: 8, fillsFrame: false)
            } else {
                card(frame, tint: .systemPink)
                text(
                    sticker?.name ?? "Sticker",
                    in: frame.insetBy(dx: 12, dy: 10),
                    font: .systemFont(ofSize: 13, weight: .medium),
                    color: .secondaryLabelColor
                )
            }
        }
        if let source = layout.forwardedSourceRegion {
            if isForwardedSourceHovered {
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(
                    concentricRoundedRect: source.frame,
                    cornerRadius: source.frame.height / 2
                ).fill()
            }
            let iconWidth: CGFloat = source.iconURL == nil ? 0 : 18
            if iconWidth > 0 {
                avatar(
                    name: source.label,
                    url: source.iconURL,
                    in: CGRect(
                        x: source.frame.minX + 6,
                        y: source.frame.minY + 2,
                        width: 18,
                        height: 18
                    )
                )
            }
            let labelX = source.frame.minX + 6 + iconWidth + (iconWidth > 0 ? 6 : 0)
            let dateText = source.timestamp.formatted(date: .abbreviated, time: .shortened)
            let label = "\(source.label)  •  \(dateText)  ›"
            text(
                label,
                in: CGRect(
                    x: labelX,
                    y: source.frame.minY,
                    width: max(1, source.frame.maxX - labelX),
                    height: source.frame.height
                ),
                font: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .medium
                ),
                color: isForwardedSourceHovered ? .labelColor : .secondaryLabelColor,
                lineBreakMode: .byTruncatingTail
            )
        }
        if let frame = layout.threadFrame {
            if let thread = message.thread {
                threadSummary(thread, in: frame)
            }
        }
        ComponentUnicodeEmojiRenderer.prepareImages(
            for: layout.reactionRegions.compactMap { region in
                let reference = region.reaction.emojiReference
                return reference.id == nil ? reference.name : nil
            }
        )
        for region in layout.reactionRegions {
            reaction(
                region,
                model: model,
                isHovered: hoveredReactionID == region.reaction.id,
                countTransition: reactionCountTransitions[
                    region.reaction.id
                ]
            )
        }
        if let frame = layout.addReactionFrame {
            reactionAddControl(
                in: frame,
                isHovered: isAddReactionHovered
            )
        }
        if let region = layout.ephemeralRegion {
            ephemeralFooter(region)
        }
        if let frame = layout.failedFrame {
            systemSymbol(
                "exclamationmark.circle",
                in: CGRect(
                    x: frame.minX,
                    y: frame.minY + 1,
                    width: 12,
                    height: 12
                ),
                color: .systemRed,
                inset: 0
            )
            text(
                "Failed",
                in: CGRect(
                    x: frame.minX + 16,
                    y: frame.minY,
                    width: max(0, frame.width - 16),
                    height: frame.height
                ),
                font: .preferredFont(forTextStyle: .caption2),
                color: .systemRed
            )
        }

        }
    }

    static func drawMessage(_ input: NativeTimelineMessageDrawInput) {
        messageDrawOperation(input)
    }

    static func avatar(
        name: String,
        url: URL?,
        in frame: CGRect
    ) {
        if let url,
           let image = mediaImage(for: .avatar(url))
        {
            drawImage(image, in: frame, cornerRadius: frame.width / 2, fillsFrame: true)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: frame).addClip()
        let accent = NSColor.sakuraCordAccentColor
        let lighter =
            accent.blended(withFraction: 0.28, of: .white)
            ?? accent
        let darker =
            accent.blended(withFraction: 0.18, of: .black)
            ?? accent
        NSGradient(starting: darker, ending: lighter)?
            .draw(in: frame, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        text(
            String(name.prefix(1)).uppercased(),
            in: frame.insetBy(
                dx: 4,
                dy: frame.height * 0.26
            ),
            font: .systemFont(
                ofSize: frame.height * 0.42,
                weight: .semibold
            ),
            color: .labelColor,
            alignment: .center
        )
    }

    static func avatarDecoration(
        url: URL,
        around avatarFrame: CGRect
    ) {
        guard let image = mediaImage(for: .avatarDecoration(url)) else {
            return
        }
        drawImage(
            image,
            in:
                NativeTimelineAvatarPresentation
                    .decorationFrame(around: avatarFrame),
            cornerRadius: 0,
            fillsFrame: false
        )
    }

    static func replyContext(
        preview: MessageReplyPreview,
        frame: CGRect,
        contentFrame: CGRect,
        model: AppModel?
    ) {
        let connectorFrame = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: max(
                0,
                contentFrame.minX - frame.minX
                    - NativeTimelineReplyMetrics.horizontalSpacing
            ),
            height: 20
        )
        replyConnector(in: connectorFrame)

        let avatarFrame =
            NativeTimelineAvatarPresentation
                .replyAvatarFrame(in: contentFrame)
        let authorFrame = replyAuthor(
            preview: preview,
            frame: frame,
            avatarFrame: avatarFrame,
            model: model
        )

        let summary = if let model {
            MessageReplySummary.text(
                content: preview.content,
                mentionLabel: MessageMentionResolver(model: model).label
            )
        } else {
            MessageReplySummary.text(content: preview.content)
        }
        text(
            summary,
            in: CGRect(
                x: authorFrame.maxX
                    + NativeTimelineReplyMetrics.horizontalSpacing,
                y: frame.minY,
                width: max(
                    0,
                    frame.maxX - 48 - authorFrame.maxX
                        - NativeTimelineReplyMetrics.horizontalSpacing
                ),
                height: 20
            ),
            font: NativeTimelineReplyMetrics.summaryFont,
            color: .secondaryLabelColor
        )
    }

    static func unavailableReplyContext(
        frame: CGRect,
        contentFrame: CGRect
    ) {
        replyConnector(in: CGRect(
            x: frame.minX,
            y: frame.minY,
            width: max(
                0,
                contentFrame.minX - frame.minX
                    - NativeTimelineReplyMetrics.horizontalSpacing
            ),
            height: 20
        ))
        let baseFont = NativeTimelineReplyMetrics.summaryFont
        let italicFont = NSFont(
            descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
            size: baseFont.pointSize
        ) ?? baseFont
        text(
            "Message could not be loaded",
            in: CGRect(
                x: contentFrame.minX,
                y: frame.minY,
                width: contentFrame.width,
                height: 20
            ),
            font: italicFont,
            color: .secondaryLabelColor
        )
    }

    static func replyAuthor(
        preview: MessageReplyPreview,
        frame: CGRect,
        avatarFrame: CGRect,
        model: AppModel?
    ) -> CGRect {
        let presentation = model?.authorPresentation(for: preview)
        let author = presentation?.user ?? preview.author
        avatar(
            name: author.displayName,
            url: author.avatarURL,
            in: avatarFrame
        )
        let font = NativeTimelineReplyMetrics.authorFont
        let width = NativeTimelineReplyMetrics.textWidth(
            author.displayName,
            font: font
        )
        let authorFrame = CGRect(
            x: avatarFrame.maxX
                + NativeTimelineReplyMetrics.horizontalSpacing,
            y: frame.minY,
            width: min(
                width,
                max(
                    0,
                    frame.maxX - avatarFrame.maxX
                        - NativeTimelineReplyMetrics.horizontalSpacing
                )
            ),
            height: 20
        )
        text(
            author.displayName,
            in: authorFrame,
            font: font,
            color: author.isBot
                ? .sakuraCordAccentColor
                : roleColor(presentation?.roleColorHex) ?? .labelColor
        )
        return authorFrame
    }

    static func replyConnector(in connectorFrame: CGRect) {
        let stemX = connectorFrame.minX + 19
        let horizontalY = connectorFrame.minY + connectorFrame.height * 0.46
        let connector = NSBezierPath()
        connector.lineWidth = 1.25
        connector.lineCapStyle = .round
        connector.move(to: CGPoint(x: stemX, y: connectorFrame.maxY))
        connector.line(to: CGPoint(x: stemX, y: horizontalY + 4))
        connector.curve(
            to: CGPoint(x: stemX + 4, y: horizontalY),
            controlPoint1: CGPoint(x: stemX, y: horizontalY + 1.8),
            controlPoint2: CGPoint(x: stemX + 2.2, y: horizontalY)
        )
        connector.line(to: CGPoint(x: connectorFrame.maxX, y: horizontalY))
        NSColor.tertiaryLabelColor.setStroke()
        connector.stroke()
    }

    static func commandInvocation(
        _ region: NativeTimelineRowLayout.CommandInvocationRegion,
        message: Message
    ) {
        replyConnector(in: region.connectorFrame)
        let user = message.interactionMetadata?.user
        if let frame = region.avatarFrame, let user {
            avatar(
                name: user.displayName,
                url: user.avatarURL,
                in: frame
            )
        } else if let frame = region.fallbackAvatarFrame {
            systemSymbol(
                "person.crop.circle",
                in: frame,
                color: .secondaryLabelColor,
                inset: 0
            )
        }
        text(
            user?.displayName ?? "Someone",
            in: region.userFrame,
            font: .systemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .caption2
                ).pointSize,
                weight: .semibold
            ),
            color: .labelColor
        )
        text(
            "used",
            in: region.usedFrame,
            font: .preferredFont(forTextStyle: .caption1),
            color: .secondaryLabelColor
        )
        NSColor.sakuraCordAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(
            roundedRect: region.pillFrame,
            xRadius: 4,
            yRadius: 4
        ).fill()
        systemSymbol(
            "xmark.triangle.circle.square.fill",
            in: region.commandSymbolFrame,
            color: .sakuraCordAccentColor,
            inset: 0,
            weight: .semibold
        )
        text(
            message.interactionMetadata?.displayName ?? "command",
            in: region.commandFrame,
            font: .systemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .caption1
                ).pointSize,
                weight: .semibold
            ),
            color: .sakuraCordAccentColor,
            lineBreakMode: .byTruncatingTail
        )
    }

    static func ephemeralFooter(
        _ region: NativeTimelineRowLayout.EphemeralRegion
    ) {
        systemSymbol(
            "eye",
            in: region.eyeFrame,
            color: .secondaryLabelColor,
            inset: 0
        )
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        text(
            "Only you can see this",
            in: region.visibilityFrame,
            font: font,
            color: .secondaryLabelColor
        )
        text(
            "•",
            in: region.bulletFrame,
            font: font,
            color: .secondaryLabelColor
        )
        text(
            "Dismiss message",
            in: region.dismissFrame,
            font: font,
            color: .sakuraCordAccentColor
        )
    }

    static func dateSeparator(date: Date, frame: CGRect) {
        let label = date.formatted(
            .dateTime.day().month(.wide).year()
        )
        let labelFrame = NativeTimelineDateSeparatorMetrics.labelFrame(
            for: label,
            in: frame
        )
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        CGRect(
            x: frame.minX,
            y: frame.midY,
            width: max(
                0,
                labelFrame.minX
                    - NativeTimelineDateSeparatorMetrics.lineSpacing
                    - frame.minX
            ),
            height: 1
        ).fill()
        CGRect(
            x: labelFrame.maxX
                + NativeTimelineDateSeparatorMetrics.lineSpacing,
            y: frame.midY,
            width: max(
                0,
                frame.maxX
                    - labelFrame.maxX
                    - NativeTimelineDateSeparatorMetrics.lineSpacing
            ),
            height: 1
        ).fill()
        text(
            label,
            in: labelFrame,
            font: NativeTimelineDateSeparatorMetrics.font,
            color: .secondaryLabelColor,
            alignment: .center,
            lineBreakMode: .byClipping
        )
    }

    static func newMessagesSeparator(frame: CGRect) {
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let labelWidth = ceil(
            measuredTextWidth("NEW", font: font) + 14
        )
        let capsuleFrame = CGRect(
            x: frame.maxX - labelWidth,
            y: frame.minY
                + NativeTimelineUnreadSeparatorMetrics.verticalPadding,
            width: labelWidth,
            height: NativeTimelineUnreadSeparatorMetrics.capsuleHeight
        )
        NSColor.systemRed.setFill()
        CGRect(
            x: frame.minX,
            y: frame.midY,
            width: max(0, capsuleFrame.minX - 8 - frame.minX),
            height: 1
        ).fill()
        NSBezierPath(
            roundedRect: capsuleFrame,
            xRadius: capsuleFrame.height / 2,
            yRadius: capsuleFrame.height / 2
        ).fill()
        text(
            "NEW",
            in: capsuleFrame,
            font: font,
            color: .white,
            alignment: .center,
            lineBreakMode: .byClipping
        )
    }

    static func card(_ frame: CGRect, tint: NSColor) {
        tint.withAlphaComponent(0.09).setFill()
        NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 8
        ).fill()
        tint.withAlphaComponent(0.55).setStroke()
        let edge = NSBezierPath()
        edge.lineWidth = 3
        edge.move(to: CGPoint(x: frame.minX + 1.5, y: frame.minY + 7))
        edge.line(to: CGPoint(x: frame.minX + 1.5, y: frame.maxY - 7))
        edge.stroke()
    }

    static func embedCard(
        _ frame: CGRect,
        accentColor: UInt32?
    ) {
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius
        )
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NativeTimelineSemanticColor.opacity(
            .secondaryLabelColor,
            0.08
        ).setFill()
        frame.fill()
        (
            roleColor(accentColor)
                ?? NativeTimelineSemanticColor.opacity(
                    .secondaryLabelColor,
                    0.5
                )
        ).setFill()
        CGRect(
            x: frame.minX,
            y: frame.minY,
            width: 4,
            height: frame.height
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        NativeTimelineSemanticColor.opacity(
            .labelColor,
            0.08
        ).setStroke()
        let border = NSBezierPath(
            concentricRoundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius - 0.5
        )
        border.lineWidth = 1
        border.stroke()
    }

    static func sakuraCordDeepLinkCard(
        _ region: NativeTimelineRowLayout.SakuraCordDeepLinkRegion,
        isButtonHovered: Bool,
        buttonPressProgress: CGFloat
    ) {
        let colors = sakuraCordDeepLinkColors(for: region.action)
        let accent = colors.first ?? NSColor.sakuraCordAccentColor
        let cardCornerRadius = ChatChromeMetrics.composerCornerRadius
        let shape = NSBezierPath(
            concentricRoundedRect: region.cardFrame,
            cornerRadius: cardCornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.28)
        glow.shadowBlurRadius = 13
        glow.shadowOffset = .zero
        glow.set()
        accent.withAlphaComponent(0.20).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        sakuraCordGradient(colors)?.draw(in: shape, angle: 0)
        NativeTimelineSemanticColor.opacity(
            .controlBackgroundColor,
            0.94
        ).setFill()
        NSBezierPath(
            concentricRoundedRect:
                region.cardFrame.insetBy(dx: 1, dy: 1),
            cornerRadius: cardCornerRadius - 1
        ).fill()

        accent.withAlphaComponent(0.16).setFill()
        NSBezierPath(
            ovalIn: region.symbolBackgroundFrame
        ).fill()
        systemSymbol(
            region.action.systemImage,
            in: region.symbolFrame,
            color: accent,
            inset: 2,
            weight: .semibold
        )
        text(
            region.action.title,
            in: region.titleFrame,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor,
            lineBreakMode: .byTruncatingTail
        )

        for (frame, color) in zip(region.paletteFrames, colors) {
            color.setFill()
            NSBezierPath(ovalIn: frame).fill()
            NativeTimelineSemanticColor.opacity(
                .controlBackgroundColor,
                0.92
            ).setStroke()
            let outline = NSBezierPath(ovalIn: frame.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }

        sakuraCordDeepLinkButton(
            region,
            isHovered: isButtonHovered,
            pressProgress: buttonPressProgress,
            colors: colors
        )
    }

    static func sakuraCordDeepLinkButton(
        _ region: NativeTimelineRowLayout.SakuraCordDeepLinkRegion,
        isHovered: Bool,
        pressProgress: CGFloat,
        colors: [NSColor]
    ) {
        let pressProgress = min(max(pressProgress, 0), 1)
        let scale = NativeTimelineComponentButtonVisualState.scale(
            pressProgress: pressProgress
        )
        let brightness = NativeTimelineComponentButtonVisualState.brightness(
            isHovered: isHovered,
            pressProgress: pressProgress
        )
        let buttonColors = colors.map {
            adjustedBrightness($0, amount: brightness)
        }
        NSGraphicsContext.saveGraphicsState()
        if abs(scale - 1) > 0.0001 {
            let transform = NSAffineTransform()
            transform.translateX(
                by: region.buttonFrame.midX,
                yBy: region.buttonFrame.midY
            )
            transform.scaleX(by: scale, yBy: scale)
            transform.translateX(
                by: -region.buttonFrame.midX,
                yBy: -region.buttonFrame.midY
            )
            transform.concat()
        }
        let buttonPath = NSBezierPath(
            concentricRoundedRect: region.buttonFrame,
            cornerRadius: region.buttonFrame.height / 2
        )
        sakuraCordGradient(buttonColors)?.draw(in: buttonPath, angle: 0)
        NSColor.black.withAlphaComponent(0.12).setFill()
        buttonPath.fill()
        adjustedBrightness(
            .white,
            amount: brightness
        ).withAlphaComponent(
            NativeTimelineComponentButtonVisualState.borderAlpha(
                isHovered: isHovered,
                isEnabled: true
            )
        ).setStroke()
        let buttonBorder = NSBezierPath(
            concentricRoundedRect:
                region.buttonFrame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: region.buttonFrame.height / 2 - 0.5
        )
        buttonBorder.lineWidth = 1
        buttonBorder.stroke()
        text(
            region.action.buttonTitle,
            in: region.buttonFrame,
            font: NativeTimelineComponentButtonMetrics.font,
            color: adjustedBrightness(
                .white,
                amount: brightness
            ),
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    static func sakuraCordDeepLinkColors(
        for action: SakuraCordDeepLinkAction
    ) -> [NSColor] {
        guard let preview = action.themePreview else {
            return [.sakuraCordAccentColor]
        }
        let appearance = NSAppearance.currentDrawing()
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? SakuraCordThemeAppearance.dark
            : .light
        return preview.theme.activeColors.map {
            NSColor(preview.theme.renderedRGB($0, for: appearance))
        }
    }

    static func sakuraCordGradient(_ colors: [NSColor]) -> NSGradient? {
        guard let first = colors.first else { return nil }
        return NSGradient(colors: colors.count == 1 ? [first, first] : colors)
    }

}
