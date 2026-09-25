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
    let isAuthorHovered: Bool
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
    let pollPresentation: NativeTimelinePollPresentation
    let animatedReactionIDs: Set<String>
    let reactionCountTransitions: [String: NativeTimelineReactionCountTransition]
}

extension NativeTimelineRowPainter {
    static func drawMessage(_ input: NativeTimelineMessageDrawInput) {
        drawMessageBubbleTint(input)
        drawMessageSearchContext(input)
        drawMessageSeparators(input)
        drawMessageIdentity(input)
        drawMessageReplyAndCommand(input)
        if input.hidesMessageContent { return }
        drawForwardedHeaderAndSystemIcon(input)
        drawMessageContent(input)
        drawMessageTranslation(input)
        drawPoll(input)
        drawPollResult(input)
        drawMessageLinkedImages(input)
        drawMessageAttachments(input)
        drawMessageEmbeds(input)
        drawMessageComponentsAndStickers(input)
        drawMessageFooter(input)
    }

    private static func drawMessageBubbleTint(_ input: NativeTimelineMessageDrawInput) {
        guard let bubbleRegion = input.layout.bubbleRegion else { return }
        let integratedSectionFrames = input.layout.embedRegions.compactMap {
            $0.kind == .bubbleIntegratedCard ? $0.frame : nil
        } + input.layout.componentLayouts.flatMap { componentLayout in
            componentLayout.containers.compactMap { container in
                container.chrome == .bubbleSection ? container.chromeFrame : nil
            }
        }
        bubbleIntegratedSectionsTint(integratedSectionFrames, bubbleRegion: bubbleRegion)
    }

    private static func drawMessageSearchContext(_ input: NativeTimelineMessageDrawInput) {
        if let context = input.row.searchContext,
           let region = input.layout.searchSectionRegion {
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
    }

    private static func drawMessageSeparators(_ input: NativeTimelineMessageDrawInput) {
        if let frame = input.layout.daySeparatorFrame {
            dateSeparator(date: input.row.message.timestamp, frame: frame)
        }
        if let frame = input.layout.unreadSeparatorFrame {
            newMessagesSeparator(frame: frame)
        }
    }

    private static func drawMessageIdentity(_ input: NativeTimelineMessageDrawInput) {
        let message = input.row.message
        let author = input.model?.authorPresentation(for: message)
        if let frame = input.layout.avatarFrame {
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
            {
                avatarDecoration(
                    url: decorationURL,
                    around: frame
                )
            }
        }
        if let frame = input.layout.authorFrame {
            let presentedAuthor =
                author?.user
                ?? message.author
            text(
                presentedAuthor.displayName,
                in: frame,
                font: ProfileNameFontLoader.shared.resolvedFont(for: presentedAuthor, fallback: .systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                    weight: .semibold
                )),
                color: presentedAuthor.isBot
                    ? .sakuraCordAccentColor
                    : input.model?.accessibilitySettings.roleColorDisplay != .inNames
                    ? .labelColor
                    : roleColor(author?.roleColorHex) ?? .labelColor,
                isInteractiveHovered: input.isAuthorHovered
            )
            if input.model?.accessibilitySettings.roleColorDisplay == .nextToNames,
               let color = roleColor(author?.roleColorHex) {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: frame.minX - 14, y: frame.midY - 4, width: 8, height: 8)).fill()
            }
        }
        drawMessageIdentityMetadata(input)
    }

    private static func drawMessageIdentityMetadata(
        _ input: NativeTimelineMessageDrawInput
    ) {
        if let frame = input.layout.botBadgeFrame {
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
        if let frame = input.layout.timestampFrame {
            text(
                NativeTimelineTimestamp.headerText(
                    for: input.row.message.timestamp,
                    settings: input.model?.interfaceSettings ?? .defaults
                ),
                in: frame,
                font: .preferredFont(forTextStyle: .caption1),
                color: .secondaryLabelColor
            )
        }
        if input.showsCompactTimestamp || input.model?.interfaceSettings.alwaysShowsTimestamps == true,
           let frame = input.layout.compactTimestampFrame
        {
            text(
                NativeTimelineTimestamp.text(
                    for: input.row.message.timestamp,
                    settings: input.model?.interfaceSettings ?? .defaults
                ),
                in: frame,
                font: NativeTimelineCompactTimestampMetrics.font,
                color: .tertiaryLabelColor,
                alignment: .center,
                lineBreakMode: .byClipping
            )
        }
        if let pinnedAt = input.row.pinnedAt,
           let frame = input.layout.pinnedAtFrame
        {
            text(
                "Pinned \(pinnedAt.formatted(date: .abbreviated, time: .shortened))",
                in: frame,
                font: .preferredFont(forTextStyle: .caption1),
                color: .secondaryLabelColor
            )
        }
        if let frame = input.layout.editedFrame {
            text(
                "(edited)",
                in: frame,
                font: .preferredFont(forTextStyle: .caption2),
                color: .tertiaryLabelColor
            )
        }
    }

    private static func drawMessageReplyAndCommand(_ input: NativeTimelineMessageDrawInput) {
        if let frame = input.layout.replyFrame,
           let contentFrame = input.layout.replyContentFrame
        {
            if let preview = input.row.replyPreview {
                replyContext(
                    preview: preview,
                    frame: frame,
                    contentFrame: contentFrame,
                    message: input.row.message,
                    model: input.model
                )
            } else {
                unavailableReplyContext(
                    frame: frame,
                    contentFrame: contentFrame
                )
            }
        }
        if let region = input.layout.commandInvocationRegion {
            commandInvocation(
                region,
                message: input.row.message,
                cosmeticPolicy: input.model?.cosmeticPolicy ?? .init()
            )
        }
    }

    private static func drawForwardedHeaderAndSystemIcon(
        _ input: NativeTimelineMessageDrawInput
    ) {
        if let barFrame = input.layout.forwardedBarFrame {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.72).setFill()
            NSBezierPath(
                concentricRoundedRect: barFrame,
                cornerRadius: barFrame.width / 2
            ).fill()
        }
        if let headerFrame = input.layout.forwardedHeaderFrame {
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
        if let frame = input.layout.systemIconFrame {
            let currentUserID = input.model?.snapshot?.currentUser.id
            systemSymbol(
                SystemMessagePresentation.systemImage(
                    for: input.row.message,
                    currentUserID: currentUserID
                ),
                in: frame,
                color:
                    SystemMessagePresentation.usesSuccessColor(
                        for: input.row.message,
                        currentUserID: currentUserID
                    )
                        ? .systemGreen
                        : .secondaryLabelColor,
                inset: 1
            )
        }
    }

    private static func drawMessageContent(_ input: NativeTimelineMessageDrawInput) {
        let row = input.row
        let layout = input.layout
        let model = input.model
        let message = row.message
        let textSelection = input.textSelection
        let hoveredMention = input.hoveredMention
        let hoveredTextLink = input.hoveredTextLink
        let hoveredTextSpoiler = input.hoveredTextSpoiler
        let revealedTextSpoilerState = input.revealedTextSpoilerState
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
    }

    private static func drawMessageLinkedImages(_ input: NativeTimelineMessageDrawInput) {
        let layout = input.layout
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
    }

    private static func drawMessageAttachments(_ input: NativeTimelineMessageDrawInput) {
        let layout = input.layout
        guard !layout.attachmentRegions.isEmpty else { return }
        let message = input.row.message
        let spoilerRevealStore = input.spoilerRevealStore
        NSGraphicsContext.saveGraphicsState()
        let attachmentContext = NSGraphicsContext.current?.cgContext
        let opacity = CGFloat(
            MessageOutboxPresentation.mediaOpacity(for: message.outboxState)
        )
        // AppKit's NSImage drawing does not consistently inherit a CGContext's
        // global alpha. Composite the complete attachment gallery as one layer
        // so bitmap images, symbols, text, and placeholders share the pending
        // message presentation instead of only dimming Quartz-drawn pieces.
        if opacity < 1 {
            attachmentContext?.setAlpha(opacity)
            attachmentContext?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
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
        if opacity < 1 { attachmentContext?.endTransparencyLayer() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawMessageEmbeds(_ input: NativeTimelineMessageDrawInput) {
        let layout = input.layout
        for region in layout.embedRegions {
            drawEmbedChrome(region, bubbleRegion: layout.bubbleRegion)
            drawEmbedText(region, input: input)
            drawEmbedMedia(region)
        }
    }

    private static func drawEmbedChrome(
        _ region: NativeTimelineRowLayout.EmbedRegion,
        bubbleRegion: NativeTimelineBubbleRegion?
    ) {
        if region.kind == .card {
            embedCard(region.frame, accentColor: region.accentColor)
        } else if region.kind == .bubbleIntegratedCard, let bubbleRegion {
            bubbleIntegratedSection(
                region.frame,
                bubbleRegion: bubbleRegion,
                accentColor: region.accentColor,
                drawsTopSeparator: region.drawsTopSeparator,
                drawsNeutralRail: true
            )
        }
    }

    private static func drawEmbedText(
        _ region: NativeTimelineRowLayout.EmbedRegion,
        input: NativeTimelineMessageDrawInput
    ) {
        for (textIndex, textRegion) in region.textRegions.enumerated() {
            let textRegionID = NativeTimelineTextRegion.embed(
                embedID: region.embedID,
                textIndex: textIndex
            )
            let itemIdentifier = NativeMessageTimelineItem.Identifier.message(input.row.identity)
            attributedText(
                textRegion.text,
                in: textRegion.frame,
                model: input.model,
                selectionRange: input.textSelection?.itemIdentifier == itemIdentifier
                    && input.textSelection?.region == textRegionID
                    ? input.textSelection?.range : nil,
                hoveredMentionCharacterIndex: input.hoveredMention?.itemIdentifier == itemIdentifier
                    && input.hoveredMention?.region == textRegionID
                    ? input.hoveredMention?.characterIndex : nil,
                hoveredLinkCharacterIndex: input.hoveredTextLink?.itemIdentifier == itemIdentifier
                    && input.hoveredTextLink?.region == textRegionID
                    ? input.hoveredTextLink?.characterIndex : nil,
                hoveredSpoilerRangeLocation: input.hoveredTextSpoiler?.itemIdentifier == itemIdentifier
                    && input.hoveredTextSpoiler?.region == textRegionID
                    ? input.hoveredTextSpoiler?.rangeLocation : nil,
                revealedSpoilerLocations: input.revealedTextSpoilerState.locations(in: textRegionID)
            )
        }
    }

    private static func drawEmbedMedia(_ region: NativeTimelineRowLayout.EmbedRegion) {
        for imageRegion in region.imageRegions {
            if let image = mediaImage(for: .media(
                imageRegion.url,
                maximumPixelDimension: imageRegion.maximumPixelDimension
            )) {
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
        guard let frame = region.mediaFrame,
              let url = region.mediaURL,
              TimelineInlineVideoPolicy.canvasOwnsLoadingSurface(
                  mediaIsVideo: region.mediaIsVideo,
                  autoplaysInline: region.mediaAutoplaysInline
              )
        else { return }
        NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.10).setFill()
        NSBezierPath(concentricRoundedRect: frame, cornerRadius: 8).fill()
        if let image = mediaImage(for: .media(url)) {
            drawImage(image, in: frame, cornerRadius: 8, fillsFrame: false)
            if region.mediaIsVideo { mediaPlayGlyph(in: frame) }
        } else if region.mediaIsVideo {
            systemSymbol("film", in: frame, color: .secondaryLabelColor, inset: 30)
            mediaPlayGlyph(in: frame)
        }
    }

    private static func drawMessageComponentsAndStickers(
        _ input: NativeTimelineMessageDrawInput
    ) {
        let row = input.row
        let layout = input.layout
        let model = input.model
        let message = row.message
        let textSelection = input.textSelection
        let hoveredMention = input.hoveredMention
        let hoveredTextLink = input.hoveredTextLink
        let hoveredTextSpoiler = input.hoveredTextSpoiler
        let revealedTextSpoilerState = input.revealedTextSpoilerState
        let spoilerRevealStore = input.spoilerRevealStore
        let hoveredComponentButton = input.hoveredComponentButton
        let activeComponentChoiceTarget = input.activeComponentChoiceTarget
        let pressedComponentButton = input.pressedComponentButton
        let componentButtonPressProgress = input.componentButtonPressProgress
        for card in layout.inviteRegions {
            let target = NativeTimelineComponentButtonTarget(messageID: message.id, componentID: card.componentID)
            inviteCard(card, isHovered: hoveredComponentButton == target,
                       pressProgress: pressedComponentButton == target ? componentButtonPressProgress : 0)
        }
        for region in layout.sakuraCordDeepLinkRegions {
            let target = NativeTimelineComponentButtonTarget(
                messageID: message.id,
                componentID: region.componentID
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
                bubbleRegion: layout.bubbleRegion,
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
        guard !layout.stickerFrames.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let stickerContext = NSGraphicsContext.current?.cgContext
        let opacity = CGFloat(
            MessageOutboxPresentation.mediaOpacity(for: message.outboxState)
        )
        if opacity < 1 {
            stickerContext?.setAlpha(opacity)
            stickerContext?.beginTransparencyLayer(auxiliaryInfo: nil)
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
        if opacity < 1 { stickerContext?.endTransparencyLayer() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawMessageFooter(_ input: NativeTimelineMessageDrawInput) {
        let layout = input.layout
        let message = input.row.message
        let model = input.model
        let hoveredReactionID = input.hoveredReactionID
        let isAddReactionHovered = input.isAddReactionHovered
        let reactionCountTransitions = input.reactionCountTransitions
        drawForwardedSource(input)
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
                ],
                hasAnimatedEmojiOverlay: input.animatedReactionIDs.contains(region.reaction.id)
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

    private static func drawForwardedSource(_ input: NativeTimelineMessageDrawInput) {
        if let source = input.layout.forwardedSourceRegion {
            if input.isForwardedSourceHovered {
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
                color: input.isForwardedSourceHovered ? .labelColor : .secondaryLabelColor,
                lineBreakMode: .byTruncatingTail
            )
        }
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
        message: Message,
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
            message: message,
            model: model
        )

        let summary = if let model {
            MessageReplySummary.text(
                content: preview.content,
                mentionLabel: MessageMentionResolver(model: model, message: message).label
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
        message: Message,
        model: AppModel?
    ) -> CGRect {
        let presentation = model?.authorPresentation(for: preview, in: message)
        let author = presentation?.user ?? preview.author
        avatar(
            name: author.displayName,
            url: author.avatarURL,
            in: avatarFrame
        )
        let font = ProfileNameFontLoader.shared.resolvedFont(for: author, fallback: NativeTimelineReplyMetrics.authorFont)
        let width = NativeTimelineReplyMetrics.textWidth(
            author.displayName,
            font: font
        )
        let roleColor = roleColor(presentation?.roleColorHex)
        let showsIndicator = model?.accessibilitySettings.roleColorDisplay == .nextToNames && roleColor != nil
        let indicatorWidth: CGFloat = showsIndicator ? 14 : 0
        let authorFrame = CGRect(
            x: avatarFrame.maxX
                + NativeTimelineReplyMetrics.horizontalSpacing + indicatorWidth,
            y: frame.minY,
            width: min(
                width,
                max(
                    0,
                    frame.maxX - avatarFrame.maxX
                        - NativeTimelineReplyMetrics.horizontalSpacing - indicatorWidth
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
                : model?.accessibilitySettings.roleColorDisplay == .inNames ? roleColor ?? .labelColor : .labelColor
        )
        if showsIndicator, let roleColor {
            roleColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: authorFrame.minX - indicatorWidth, y: authorFrame.midY - 4, width: 8, height: 8)).fill()
        }
        return CGRect(x: authorFrame.minX - indicatorWidth, y: authorFrame.minY, width: authorFrame.width + indicatorWidth, height: authorFrame.height)
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
        message: Message,
        cosmeticPolicy: ProfileCosmeticPolicy
    ) {
        replyConnector(in: region.connectorFrame)
        let user = message.interactionMetadata?.user.map(cosmeticPolicy.user)
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
            font: ProfileNameFontLoader.shared.resolvedFont(for: user, fallback: .systemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .caption2
                ).pointSize,
                weight: .semibold
            )),
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
        sakuraCordButton(title: region.action.buttonTitle, frame: region.buttonFrame,
                         isHovered: isHovered, pressProgress: pressProgress, colors: colors)
    }

    static func sakuraCordButton(
        title: String, frame: CGRect, isHovered: Bool, pressProgress: CGFloat = 0,
        colors: [NSColor], foreground: NSColor = .white, isEnabled: Bool = true
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
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        if abs(scale - 1) > 0.0001 {
            let transform = NSAffineTransform()
            transform.translateX(
                by: frame.midX,
                yBy: frame.midY
            )
            transform.scaleX(by: scale, yBy: scale)
            transform.translateX(
                by: -frame.midX,
                yBy: -frame.midY
            )
            transform.concat()
        }
        let buttonPath = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: frame.height / 2
        )
        sakuraCordGradient(buttonColors)?.draw(in: buttonPath, angle: 0)
        NSColor.black.withAlphaComponent(0.12).setFill()
        buttonPath.fill()
        adjustedBrightness(
            foreground,
            amount: brightness
        ).withAlphaComponent(
            NativeTimelineComponentButtonVisualState.borderAlpha(
                isHovered: isHovered,
                isEnabled: isEnabled
            )
        ).setStroke()
        let buttonBorder = NSBezierPath(
            concentricRoundedRect:
                frame.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: frame.height / 2 - 0.5
        )
        buttonBorder.lineWidth = 1
        buttonBorder.stroke()
        text(
            title,
            in: frame,
            font: NativeTimelineComponentButtonMetrics.font,
            color: adjustedBrightness(
                foreground,
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
