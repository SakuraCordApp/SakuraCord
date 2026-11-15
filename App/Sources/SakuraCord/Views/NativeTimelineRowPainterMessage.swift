import AppKit
import SakuraCordModels

/// What the pointer hovers or presses in a row as it is drawn; `idle` for
/// rows drawn without it, such as bitmaps and transition pictures.
struct NativeTimelineRowInteraction {
    var isHovered = false
    var showsCompactTimestamp = false
    var isAuthorHovered = false
    var isServerTagHovered = false
    var isCommandPillHovered = false
    var hoveredMention: NativeTimelineMentionHover?
    var hoveredTextLink: NativeTimelineTextLinkHover?
    /// How far each text spoiler is hovered, easing in and out.
    var textSpoilerHover: [NativeTimelineTextSpoilerHover: CGFloat] = [:]
    var hoveredComponentButton: NativeTimelineComponentButtonTarget?
    var activeComponentChoiceTarget: NativeTimelineComponentSelectTarget?
    var pressedComponentButton: NativeTimelineComponentButtonTarget?
    var componentButtonPressProgress: CGFloat = 0
    /// How far each file card part's hover has eased in.
    var fileCardHoverProgress: [NativeTimelineComponentButtonTarget: CGFloat] = [:]
    /// How far each just-finished download's button has crossfaded.
    var fileCardFinishProgress: [NativeTimelineComponentButtonTarget: CGFloat] = [:]
    var isForwardedSourceHovered = false
    var threadCardInteraction: NativeTimelineThreadCard.Interaction = .idle
    var isEphemeralDismissHovered = false
    var isTranslationActionHovered = false
    /// A hovered upload cancel or Retry of a local send.
    var hoveredDeliveryAction: NativeTimelineFooterActionTarget.Kind?
    var isSuppressedToggleHovered = false
    var hoveredReactionID: String?
    var isAddReactionHovered = false

    static let idle = NativeTimelineRowInteraction()
}

struct NativeTimelineMessageDrawInput {
    let row: MessageRowPresentation
    let layout: NativeTimelineRowLayout
    let model: AppModel?
    let interaction: NativeTimelineRowInteraction
    let textSelection: NativeTimelineTextSelection?
    let revealedTextSpoilerState: NativeTimelineTextSpoilerRevealState
    var spoilerRevealStore: NativeTimelineSpoilerRevealStore?
    let pollPresentation: NativeTimelinePollPresentation
    let animatedOverlayRoles: Set<NativeTimelineCanvasView.AnimatedMediaOverlayRole>
}

extension NativeTimelineRowPainter {
    static func drawMessage(_ input: NativeTimelineMessageDrawInput) {
        drawMessageSearchContext(input)
        drawMessageSeparators(input)
        drawAutoModAlert(input)
        drawMessageIdentity(input)
        drawMessageReplyAndCommand(input)
        drawMessageBubbleTint(input)
        drawForwardedHeaderAndSystemIcon(input)
        drawMessageContent(input)
        drawMessageTranslation(input)
        drawPoll(input)
        drawPollResult(input)
        drawMessageLinkedImages(input)
        drawMessageAttachments(input)
        drawMessageVoiceMessage(input)
        drawMessageEmbeds(input)
        drawMessageComponentsAndStickers(input)
        drawMessageFooter(input)
    }

    private static func drawMessageBubbleTint(_ input: NativeTimelineMessageDrawInput) {
        guard let bubbleRegion = input.layout.bubbleRegion else { return }
        // An Activity card sits on the bubble itself; its cover tile sets it apart.
        let integratedSectionFrames = input.layout.inviteRegions.filter { $0.content?.activity == nil }.map(\.frame)
            + input.layout.sakuraCordDeepLinkRegions.map(\.frame)
            + [input.layout.threadFrame, input.layout.pollLayout?.frame].compactMap { $0 }
            + input.layout.embedRegions.compactMap {
            $0.kind == .bubbleIntegratedCard ? $0.frame : nil
        } + input.layout.componentLayouts.flatMap { componentLayout in
            componentLayout.containers.compactMap { container in
                container.chrome == .bubbleSection ? container.chromeFrame : nil
            }
        }
        bubbleIntegratedSectionsTint(
            integratedSectionFrames + [fileSectionFrame(input.layout)].compactMap { $0 },
            bubbleRegion: bubbleRegion
        )
    }

    /// Files below other bubble content share one integrated section, as
    /// thread cards and invites do; a bubble holding only files is their card.
    private static func fileSectionFrame(_ layout: NativeTimelineRowLayout) -> CGRect? {
        let files = layout.attachmentRegions.filter { !$0.attachment.mediaKind.isVisual }.map(\.frame)
        guard let bubble = layout.bubbleRegion, let first = files.first,
              first.minY - bubble.frame.minY > NativeTimelineBubbleLayout.verticalPadding + 0.5
        else { return nil }
        return files.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func drawMessageSearchContext(_ input: NativeTimelineMessageDrawInput) {
        if let context = input.row.searchContext,
           let region = input.layout.searchSectionRegion {
            // Symbol palettes ignore alpha, so fade the drawing instead.
            let cgContext = NSGraphicsContext.current?.cgContext
            cgContext?.saveGState()
            cgContext?.setAlpha(0.7)
            NativeTimelineRowPainter.systemSymbol(
                context.systemImage,
                in: region.iconFrame,
                color: .labelColor,
                inset: 1,
                weight: .semibold
            )
            cgContext?.restoreGState()
            let titleFont = NSFont.interfaceSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize,
                weight: .semibold
            )
            var titleFrame = region.titleFrame
            titleFrame.size.width = min(titleFrame.width, ceil(measuredTextWidth(context.sectionTitle, font: titleFont)))
            text(context.sectionTitle, in: titleFrame, font: titleFont, color: .labelColor)
            guard let subtitle = context.sectionSubtitle else { return }
            let subtitleFont = NSFont.interfacePreferredFont(forTextStyle: .caption1)
            // Text is centred in its frame by line height, so shift the
            // smaller subtitle to share the title's baseline.
            func baselineFromBottom(_ font: NSFont) -> CGFloat {
                (titleFrame.height - font.ascender + font.descender - font.leading) / 2 - font.descender
            }
            let subtitleMinX = titleFrame.maxX + InterfaceScale.metric(6)
            text(
                subtitle,
                in: CGRect(
                    x: subtitleMinX,
                    y: titleFrame.minY + baselineFromBottom(subtitleFont) - baselineFromBottom(titleFont),
                    // A full-width title leaves none; a negative width
                    // would read as positive and draw over the title.
                    width: max(0, region.titleFrame.maxX - subtitleMinX),
                    height: titleFrame.height
                ),
                font: subtitleFont,
                color: .secondaryLabelColor
            )
        }
    }

    private static func drawMessageSeparators(_ input: NativeTimelineMessageDrawInput) {
        if let frame = input.layout.daySeparatorFrame {
            dateSeparator(date: input.row.message.timestamp, frame: frame, isUnread: input.layout.foldedUnreadDay != nil)
        }
        if let frame = input.layout.unreadSeparatorFrame {
            newMessagesSeparator(frame: frame)
        }
        if let frame = input.layout.postStarterDividerFrame {
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: 1).fill()
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
            let display = input.model?.accessibilitySettings.roleColorDisplay
            let gradientColors = presentedAuthor.isBot ? nil : roleGradientColors(author)
            if let context = NSGraphicsContext.current?.cgContext {
                if display == .inNames, let gradientColors {
                    input.layout.authorText?.draw(
                        in: frame, gradientColors: gradientColors, context: context, isUnderlined: input.interaction.isAuthorHovered
                    )
                } else {
                    input.layout.authorText?.draw(
                        in: frame,
                        color: presentedAuthor.isBot
                            ? .sakuraCordAccentColor
                            : display != .inNames
                            ? .labelColor : NSColor(discordColor: author?.roleColorHex) ?? .labelColor,
                        context: context, isUnderlined: input.interaction.isAuthorHovered
                    )
                }
            }
            if display == .nextToNames, let color = NSColor(discordColor: author?.roleColorHex) {
                roleDot(gradientColors ?? [color], in: CGRect(
                    x: frame.minX - InterfaceScale.metric(15),
                    y: frame.midY - InterfaceScale.metric(4.5),
                    width: InterfaceScale.metric(9),
                    height: InterfaceScale.metric(9)
                ))
            }
        }
        drawMessageIdentityMetadata(input)
    }

    static func roleGradientColors(_ author: MessageAuthorPresentation?) -> [NSColor]? {
        RoleGradientPaint.colors(
            primary: NSColor(discordColor: author?.roleColorHex),
            secondary: NSColor(discordColor: author?.roleSecondaryColorHex),
            tertiary: NSColor(discordColor: author?.roleTertiaryColorHex)
        )
    }

    private static func roleDot(_ colors: [NSColor], in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        RoleGradientPaint.fillDot(colors, in: rect, context: context)
    }

    private static func drawMessageIdentityMetadata(
        _ input: NativeTimelineMessageDrawInput
    ) {
        if let frame = input.layout.botBadgeFrame,
           let context = NSGraphicsContext.current?.cgContext {
            NativeAppBadgePresentation.draw(
                in: frame, color: .sakuraCordAccentColor, context: context,
                text: input.layout.botBadgeText, isVerified: input.layout.botBadgeIsVerified
            )
        }
        if let region = input.layout.serverTagRegion,
           let context = NSGraphicsContext.current?.cgContext {
            region.presentation.draw(in: region.frame, badgeImage: nil,
                                     isHighlighted: input.interaction.isServerTagHovered, context: context)
            if let url = region.presentation.identity.badgeURL,
               let frame = region.presentation.badgeFrame(in: region.frame),
               let image = MediaImageStore.shared.stillImage(for: .media(url, maximumPixelDimension: 32)) {
                drawImage(image, in: frame, cornerRadius: 0, fillsFrame: false)
            }
        }
        if let region = input.layout.roleIconRegion {
            if let url = region.role.iconURL,
               let image = MediaImageStore.shared.stillImage(for: .media(url, maximumPixelDimension: 48)) {
                drawImage(image, in: region.frame, cornerRadius: 0, fillsFrame: false)
            } else if let emoji = region.role.unicodeEmoji, !emoji.isEmpty {
                text(
                    emoji,
                    in: region.frame,
                    font: .systemFont(ofSize: region.frame.height * 0.85),
                    color: .labelColor,
                    alignment: .center,
                    lineBreakMode: .byClipping
                )
            }
        }
        if let frame = input.layout.timestampFrame,
           let context = NSGraphicsContext.current?.cgContext {
            input.layout.timestampText?.draw(in: frame, color: .secondaryLabelColor, context: context)
        }
        if let frame = input.layout.silentBadgeFrame {
            NativeTimelineSilentBadge.draw(in: frame)
        }
        if input.interaction.showsCompactTimestamp || input.model?.interfaceSettings.alwaysShowsTimestamps == true,
           let frame = input.layout.compactTimestampFrame
        {
            let settings = input.model?.interfaceSettings ?? .defaults
            text(
                InterfaceTimestampFormatter.text(
                    for: input.row.message.timestamp,
                    format: settings.timestampFormat,
                    includesSeconds: settings.includesTimestampSeconds
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
                font: .interfacePreferredFont(forTextStyle: .caption1),
                color: .secondaryLabelColor
            )
        }
        if let frame = input.layout.editedFrame,
           let prepared = input.layout.editedText,
           let context = NSGraphicsContext.current?.cgContext {
            prepared.draw(in: frame, color: .tertiaryLabelColor, context: context)
        } else if let frame = input.layout.editedFrame {
            text("(edited)", in: frame, font: .interfacePreferredFont(forTextStyle: .caption2), color: .tertiaryLabelColor)
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
                    bubbleConnector: input.layout.bubbleReferenceConnector,
                    message: input.row.message,
                    model: input.model
                )
            } else {
                unavailableReplyContext(
                    frame: frame,
                    contentFrame: contentFrame,
                    bubbleConnector: input.layout.bubbleReferenceConnector
                )
            }
        }
        if let region = input.layout.commandInvocationRegion {
            commandInvocation(
                region,
                bubbleConnector: input.layout.bubbleReferenceConnector,
                message: input.row.message,
                cosmeticPolicy: input.model?.cosmeticPolicy ?? .init(),
                isPillHovered: input.interaction.isCommandPillHovered
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
            text(
                "↗ Forwarded",
                in: headerFrame,
                font: NSFont.messageSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .semibold
                ).italic,
                color: .secondaryLabelColor
            )
        }
        if let frame = input.layout.systemIconFrame {
            let currentUserID = input.model?.currentUser?.id
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
                inset: input.row.message.type == .threadCreated ? 0 : 1
            )
        }
    }

    private static func drawMessageContent(_ input: NativeTimelineMessageDrawInput) {
        let row = input.row
        let layout = input.layout
        if let frame = layout.contentFrame, let contentText = layout.contentText {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(
                CGFloat(
                    MessageOutboxPresentation.textOpacity(for: row.message)
                )
            )
            // CoreText requires the full fractional typographic line box to
            // produce a CTLine. The established compact row is 18 points high,
            // so give the frame a little layout headroom without changing the
            // visible row geometry or adding spacing between grouped messages.
            let drawingFrame = NativeTimelineTextGeometry
                .messageContentDrawingFrame(frame)
            attributedText(contentText, in: drawingFrame, region: .content, bubble: layout.bubbleRegion, input: input)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws one of the message's text regions with the selection, hovers
    /// and spoiler reveals the pointer has in that region.
    static func attributedText(
        _ box: NativeTimelineAttributedTextBox,
        in frame: CGRect,
        region: NativeTimelineTextRegion,
        bubble: NativeTimelineBubbleRegion?,
        input: NativeTimelineMessageDrawInput
    ) {
        let item = NativeMessageTimelineItem.Identifier.message(input.row.identity)
        attributedText(
            box,
            in: frame,
            model: input.model,
            bubble: bubble,
            selectionRange: input.textSelection.scoped(to: item, region: region)?.range,
            hoveredMentionCharacterIndex: input.interaction.hoveredMention.scoped(to: item, region: region)?.characterIndex,
            hoveredLinkCharacterIndex: input.interaction.hoveredTextLink.scoped(to: item, region: region)?.characterIndex,
            spoilerHoverProgress: input.interaction.textSpoilerHover.progress(in: item, region: region),
            revealedSpoilerLocations: input.revealedTextSpoilerState.locations(in: region)
        )
    }

    private static func drawMessageLinkedImages(_ input: NativeTimelineMessageDrawInput) {
        let layout = input.layout
        for region in layout.linkedImageRegions {
            if let image = MediaImageStore.shared.stillImage(for: region.mediaKey) {
                drawImage(
                    image,
                    in: region.frame,
                    cornerRadius: region.cornerRadius,
                    fillsFrame: region.fillsFrame
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
                    in: region.frame.insetBy(dx: InterfaceScale.metric(12), dy: InterfaceScale.metric(10)),
                    font: .interfaceSystemFont(ofSize: 12, weight: .medium),
                    color: .secondaryLabelColor,
                    lineBreakMode: .byTruncatingMiddle
                )
            }
        }
    }

    static var attachmentCornerRadius: CGFloat { InterfaceScale.metric(8) }

    private static func drawMessageVoiceMessage(_ input: NativeTimelineMessageDrawInput) {
        guard let region = input.layout.voiceMessageRegion else { return }
        let playback = input.model?.voiceMessagePlayback
        let opacity = CGFloat(MessageOutboxPresentation.mediaOpacity(for: input.row.message.outboxState))
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        defer { context?.restoreGState() }
        drawing(opacity: opacity, in: context) {
            NativeTimelineVoiceMessagePainter.drawIdle(region, playback: playback)
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
        drawing(opacity: opacity, in: attachmentContext) {
            let attachmentFillsFrame =
                MediaGalleryImagePresentation.fillsFrame(
                    itemCount: layout.mediaGalleryItemCount
                )
            if let bubble = layout.bubbleRegion, let section = fileSectionFrame(layout) {
                bubbleIntegratedSection(
                    section, bubbleRegion: bubble, accentColor: nil, drawsTopSeparator: true
                )
            }
            for region in layout.attachmentRegions {
                let isConcealed = spoilerRevealStore?.isConcealed(region.attachment, in: message.id) ?? false
                NativeTimelineSpoilerCover.draw(covering: isConcealed, in: region.frame, cornerRadius: layout.cornerRadius(of: region)) {
                    drawAttachment(region, fillsFrame: attachmentFillsFrame, input: input)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawAttachment(
        _ region: NativeTimelineRowLayout.AttachmentRegion,
        fillsFrame: Bool,
        input: NativeTimelineMessageDrawInput
    ) {
        let attachment = region.attachment
        let layout = input.layout
        let message = input.row.message
        switch attachment.mediaKind {
        case .image, .animatedImage, .video:
            let isVideo = attachment.mediaKind == .video
            drawMediaSurface(
                in: region.frame,
                cornerRadius: attachmentCornerRadius,
                backdrop: NSColor.secondaryLabelColor.withAlphaComponent(0.10),
                image: region.previewKey.flatMap(MediaImageStore.shared.stillImage(for:)),
                fillsFrame: fillsFrame,
                placeholder: region.placeholder,
                fallbackSymbol: isVideo ? ("film", InterfaceScale.metric(30)) : nil,
                isVideo: isVideo
            )
        case .audio, .file:
            fileCard(
                .init(
                    frame: region.frame, attachment: attachment, isInBubble: layout.bubbleRegion != nil
                ),
                messageID: message.id,
                bubbleRegion: layout.bubbleRegion,
                state: input.model?.attachmentDownloads.states[attachment.id],
                upload: uploadState(of: attachment, in: input),
                finishProgress: input.interaction.fileCardFinishProgress,
                pointer: .init(
                    hovered: input.interaction.hoveredComponentButton, hoverProgress: input.interaction.fileCardHoverProgress,
                    pressed: input.interaction.pressedComponentButton, pressProgress: input.interaction.componentButtonPressProgress
                )
            )
            if let player = layout.audioFilePlayers.first(where: { $0.attachment.id == attachment.id }) {
                NativeTimelineVoiceMessagePainter.drawIdle(player, playback: input.model?.voiceMessagePlayback)
            }
        }
    }

    private static func drawMessageEmbeds(_ input: NativeTimelineMessageDrawInput) {
        let layout = input.layout
        let concealedEmbeds = input.spoilerRevealStore.map {
            NativeTimelineSpoilerConcealmentPolicy.concealedEmbeds(in: input.row.message, store: $0)
        } ?? [:]
        var coveredKeys = Set<NativeTimelineComponentRevealKey>()
        for (index, region) in layout.embedRegions.enumerated() {
            let key = concealedEmbeds[region.embedID]
            // A multi-image post's images follow their card, share its key
            // and draw under the card's one cover, which spans the grid.
            if let key, !coveredKeys.insert(key).inserted { continue }
            let members = key.map { key in layout.embedRegions[index...].prefix { concealedEmbeds[$0.embedID] == key } }
                ?? [region]
            NativeTimelineSpoilerCover.draw(
                covering: key != nil, in: region.frame, cornerRadius: region.cornerRadius
            ) {
                for member in members {
                    drawEmbedChrome(member, bubbleRegion: layout.bubbleRegion)
                    drawEmbedText(member, input: input)
                    drawEmbedMedia(member, isCovered: key != nil)
                }
            }
        }
    }

    private static func drawEmbedChrome(
        _ region: NativeTimelineRowLayout.EmbedRegion,
        bubbleRegion: NativeTimelineBubbleRegion?
    ) {
        if region.kind == .card {
            discordCard(
                region.frame,
                cornerRadius: region.cornerRadius,
                accent: NSColor(discordColor: region.accentColor) ?? DiscordEmbedPalette.defaultAccent
            )
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
            attributedText(
                textRegion.text,
                in: textRegion.frame,
                region: textRegionID,
                bubble: region.kind == .bubbleIntegratedCard ? input.layout.bubbleRegion : nil,
                input: input
            )
        }
    }

    /// `isCovered`: a spoiler cover blurs the embed, so it draws the poster
    /// of a video that otherwise plays in its own view.
    private static func drawEmbedMedia(_ region: NativeTimelineRowLayout.EmbedRegion, isCovered: Bool) {
        for imageRegion in region.imageRegions {
            drawMediaSurface(
                in: imageRegion.frame,
                cornerRadius: imageRegion.cornerRadius,
                backdrop: nil,
                image: MediaImageStore.shared.stillImage(for: imageRegion.mediaKey),
                fillsFrame: false,
                placeholder: imageRegion.placeholder,
                placeholderFillsFrame: false,
                fallbackSymbol: (
                    imageRegion.fallbackSystemImage,
                    imageRegion.frame.width >= InterfaceScale.metric(70) ? InterfaceScale.metric(22) : InterfaceScale.metric(2)
                )
            )
        }
        // An inline-playing video draws its own loading surface.
        guard let frame = region.mediaFrame,
              let url = region.mediaURL,
              isCovered || !region.mediaIsVideo || !region.mediaAutoplaysInline
        else { return }
        drawMediaSurface(
            in: frame,
            cornerRadius: InterfaceScale.metric(8),
            backdrop: NativeTimelineSemanticColor.opacity(.secondaryLabelColor, 0.10),
            image: MediaImageStore.shared.stillImage(for: .media(region.mediaPreviewURL ?? url)),
            fillsFrame: region.mediaFillsFrame || region.mediaPosterFillsFrame,
            placeholder: region.mediaPlaceholder,
            fallbackSymbol: region.mediaIsVideo ? ("film", InterfaceScale.metric(30)) : nil,
            isVideo: region.mediaIsVideo
        )
    }

    private static func drawMessageComponentsAndStickers(
        _ input: NativeTimelineMessageDrawInput
    ) {
        let layout = input.layout
        let message = input.row.message
        for card in layout.inviteRegions {
            let target = NativeTimelineComponentButtonTarget(messageID: message.id, componentID: card.componentID)
            inviteCard(card, bubbleRegion: layout.bubbleRegion, isHovered: input.interaction.hoveredComponentButton == target,
                       pressProgress: input.interaction.pressedComponentButton == target ? input.interaction.componentButtonPressProgress : 0)
        }
        for region in layout.sakuraCordDeepLinkRegions {
            let target = NativeTimelineComponentButtonTarget(
                messageID: message.id,
                componentID: region.componentID
            )
            sakuraCordDeepLinkCard(
                region,
                bubbleRegion: layout.bubbleRegion,
                isButtonHovered: input.interaction.hoveredComponentButton == target,
                buttonPressProgress:
                    input.interaction.pressedComponentButton == target
                        ? input.interaction.componentButtonPressProgress
                        : 0
            )
        }
        for (layoutIndex, componentLayout) in layout.componentLayouts.enumerated() {
            drawComponents(.init(layout: componentLayout, layoutIndex: layoutIndex, message: input))
        }
        guard !layout.stickerFrames.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let stickerContext = NSGraphicsContext.current?.cgContext
        let opacity = CGFloat(
            MessageOutboxPresentation.mediaOpacity(for: message.outboxState)
        )
        drawing(opacity: opacity, in: stickerContext) {
            for (index, frame) in layout.stickerFrames.enumerated() {
                let sticker = message.stickers.indices.contains(index)
                    ? message.stickers[index]
                    : nil
                if let sticker,
                   input.animatedOverlayRoles.contains(.sticker(sticker.id)) {
                    continue
                }
                let image = sticker?.mediaURL.flatMap {
                    MediaImageStore.shared.stillImage(
                        for: .media($0, maximumPixelDimension: 384)
                    )
                }
                if let image {
                    drawImage(image, in: frame, cornerRadius: InterfaceScale.metric(8), fillsFrame: false)
                } else {
                    card(frame, tint: .systemPink)
                    text(
                        sticker?.name ?? "Sticker",
                        in: frame.insetBy(dx: InterfaceScale.metric(12), dy: InterfaceScale.metric(10)),
                        font: .interfaceSystemFont(ofSize: 13, weight: .medium),
                        color: .secondaryLabelColor
                    )
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawMessageFooter(_ input: NativeTimelineMessageDrawInput) {
        let layout = input.layout
        let message = input.row.message
        let model = input.model
        let hoveredReactionID = input.interaction.hoveredReactionID
        let isAddReactionHovered = input.interaction.isAddReactionHovered
        drawForwardedSource(input)
        if let frame = layout.threadFrame, let thread = message.thread {
            if message.type == .threadCreated, let iconFrame = layout.systemIconFrame {
                elbowConnector(
                    stemX: iconFrame.midX,
                    fromY: iconFrame.maxY + 3,
                    cornerY: frame.midY,
                    toX: frame.minX - 4
                )
            }
            threadCard(
                thread,
                preview: model?.threadPreviewMessages[thread.id],
                model: model,
                in: frame,
                bubbleRegion: layout.bubbleRegion,
                drawsTopSeparator: layout.threadDrawsTopSeparator,
                interaction: input.interaction.threadCardInteraction
            )
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
                isHovered: hoveredReactionID == region.reaction.id && model?.canUpdateReactions(on: message) != false,
                hasAnimatedEmojiOverlay: input.animatedOverlayRoles.contains(.reaction(region.reaction.id))
            )
        }
        if let frame = layout.addReactionFrame, model?.canCreateReactions(on: message) != false {
            reactionAddControl(
                in: frame,
                isHovered: isAddReactionHovered
            )
        }
        if let region = layout.ephemeralRegion {
            ephemeralFooter(region, isDismissHovered: input.interaction.isEphemeralDismissHovered)
        }
        if let frame = layout.failedFrame {
            failureNotice(
                MessageOutboxPresentation.failureText(for: input.row.message),
                in: frame,
                font: .interfacePreferredFont(forTextStyle: .caption2),
                color: .systemRed
            )
        }
        if let frame = layout.failedRetryFrame {
            text(
                MessageOutboxPresentation.retryTitle,
                in: frame,
                font: .interfacePreferredFont(forTextStyle: .caption2),
                color: .sakuraCordAccentColor,
                isInteractiveHovered: input.interaction.hoveredDeliveryAction == .retrySend
            )
        }
    }

    /// A failed send's icon and wording, so the state also reads without colour.
    static func failureNotice(_ notice: String, in frame: CGRect, font: NSFont, color: NSColor) {
        let iconSize = InterfaceScale.metric(12)
        let inset = InterfaceScale.metric(16)
        systemSymbol(
            "exclamationmark.circle",
            in: CGRect(x: frame.minX, y: frame.minY + 1, width: iconSize, height: iconSize),
            color: color,
            inset: 0
        )
        text(
            notice,
            in: CGRect(x: frame.minX + inset, y: frame.minY, width: max(0, frame.width - inset), height: frame.height),
            font: font,
            color: color,
            lineBreakMode: .byWordWrapping
        )
    }

    private static func drawForwardedSource(_ input: NativeTimelineMessageDrawInput) {
        if let source = input.layout.forwardedSourceRegion {
            if input.interaction.isForwardedSourceHovered {
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
                        x: source.frame.minX + InterfaceScale.metric(6),
                        y: source.frame.midY - InterfaceScale.metric(9),
                        width: InterfaceScale.metric(18),
                        height: InterfaceScale.metric(18)
                    )
                )
            }
            let labelX = source.frame.minX + InterfaceScale.metric(6) + iconWidth + (iconWidth > 0 ? InterfaceScale.metric(6) : 0)
            text(
                source.text,
                in: CGRect(
                    x: labelX,
                    y: source.frame.minY,
                    width: max(1, source.frame.maxX - labelX),
                    height: source.frame.height
                ),
                font: source.font,
                color: input.interaction.isForwardedSourceHovered ? .labelColor : .secondaryLabelColor,
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
           let image = MediaImageStore.shared.stillImage(for: .avatar(url))
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
                dx: InterfaceScale.metric(4),
                dy: frame.height * 0.26
            ),
            font: .systemFont(
                ofSize: frame.height * 0.42,
                weight: .semibold
            ),
            color: .sakuraCordLabelOnAccentColor,
            alignment: .center
        )
    }

    static func avatarDecoration(
        url: URL,
        around avatarFrame: CGRect
    ) {
        guard let image = MediaImageStore.shared.stillImage(for: .avatarDecoration(url)) else {
            return
        }
        drawImage(
            image,
            in:
                UserAvatarPresentation
                    .decorationFrame(around: avatarFrame),
            cornerRadius: 0,
            fillsFrame: false
        )
    }

    static func replyContext(
        preview: MessageReplyPreview,
        frame: CGRect,
        contentFrame: CGRect,
        bubbleConnector: NativeTimelineRowLayout.ReferenceConnector?,
        message: Message,
        model: AppModel?
    ) {
        referenceConnector(bubbleConnector, frame: frame, contentFrame: contentFrame)
        // A bubble's preview is laid out at its natural width.
        replyPreviewLine(
            preview,
            frame: bubbleConnector == nil
                ? CGRect(x: frame.minX, y: contentFrame.minY, width: frame.width, height: frame.height)
                : contentFrame,
            avatarFrame: NativeTimelineReplyMetrics.avatarFrame(in: contentFrame),
            trailingInset: bubbleConnector == nil ? 48 : 0,
            reservesSummary: bubbleConnector != nil,
            message: message,
            model: model
        )
    }

    private static func referenceConnector(
        _ bubbleConnector: NativeTimelineRowLayout.ReferenceConnector?,
        frame: CGRect,
        contentFrame: CGRect
    ) {
        if let bubbleConnector {
            elbowConnector(
                stemX: bubbleConnector.stemX,
                fromY: bubbleConnector.fromY,
                cornerY: bubbleConnector.cornerY,
                toX: bubbleConnector.toX
            )
            return
        }
        replyConnector(in: CGRect(
            x: frame.minX,
            y: frame.minY,
            width: max(
                0,
                contentFrame.minX - frame.minX
                    - NativeTimelineReplyMetrics.horizontalSpacing
            ),
            height: NativeTimelineReplyMetrics.lineHeight
        ))
    }

    /// One line of a referenced message: avatar, author, and a plain summary.
    static func replyPreviewLine(
        _ preview: MessageReplyPreview,
        frame: CGRect,
        avatarFrame: CGRect,
        trailingInset: CGFloat,
        reservesSummary: Bool = false,
        showsReplyMention: Bool = true,
        message: Message,
        model: AppModel?,
        foregroundColor: NSColor? = nil
    ) {
        let replySummary = NativeTimelineReplyMetrics.summary(for: preview, in: message, model: model)
        let mediaSymbol = NativeTimelineReplyMetrics.mediaSymbol(for: preview)
        let mediaReserve = NativeTimelineReplyMetrics.mediaSymbolReserve
        let summaryWidthMeasured = NativeTimelineReplyMetrics.summaryWidth(replySummary, font: NativeTimelineReplyMetrics.summaryFont)
        // A preview narrower than its natural width keeps part of the line
        // for the summary and media symbol instead of giving it all to a
        // long author name.
        let summaryReserve = reservesSummary
            ? min(
                frame.width * 0.45,
                NativeTimelineReplyMetrics.horizontalSpacing
                    + summaryWidthMeasured
                    + (mediaSymbol == nil ? 0 : mediaReserve)
            )
            : 0
        let authorFrame = replyAuthor(
            preview: preview,
            frame: CGRect(
                x: frame.minX,
                y: frame.minY,
                width: max(0, frame.width - summaryReserve),
                height: frame.height
            ),
            avatarFrame: avatarFrame,
            showsReplyMention: showsReplyMention,
            message: message,
            model: model,
            foregroundColor: foregroundColor
        )
        let summaryX = authorFrame.maxX + NativeTimelineReplyMetrics.horizontalSpacing
        let summaryWidth = max(
            0,
            min(
                summaryWidthMeasured,
                // A media symbol takes 26 points, from the trailing inset when there is one.
                frame.maxX - summaryX - (mediaSymbol == nil ? trailingInset : max(mediaReserve, trailingInset - mediaReserve))
            )
        )
        drawReplySummary(
            replySummary,
            in: CGRect(
                x: summaryX,
                y: frame.minY,
                width: summaryWidth,
                height: NativeTimelineReplyMetrics.lineHeight
            ),
            font: NativeTimelineReplyMetrics.summaryFont,
            color: foregroundColor?.withAlphaComponent(0.72) ?? .secondaryLabelColor,
            model: model
        )
        let mediaSymbolFrame = CGRect(
            x: summaryX + summaryWidth + InterfaceScale.metric(4),
            y: frame.minY + (NativeTimelineReplyMetrics.lineHeight - InterfaceScale.metric(20)) / 2,
            width: InterfaceScale.metric(20), height: InterfaceScale.metric(20)
        )
        if let mediaSymbol, !reservesSummary || mediaSymbolFrame.maxX <= frame.maxX + 1 {
            systemSymbol(
                mediaSymbol,
                in: mediaSymbolFrame,
                color: foregroundColor?.withAlphaComponent(0.72) ?? .secondaryLabelColor,
                inset: InterfaceScale.metric(2)
            )
        }
    }

    static func unavailableReplyContext(
        frame: CGRect,
        contentFrame: CGRect,
        bubbleConnector: NativeTimelineRowLayout.ReferenceConnector?
    ) {
        referenceConnector(bubbleConnector, frame: frame, contentFrame: contentFrame)
        text(
            NativeTimelineReplyMetrics.unavailableText,
            in: CGRect(
                x: contentFrame.minX,
                y: contentFrame.minY,
                width: contentFrame.width,
                height: NativeTimelineReplyMetrics.lineHeight
            ),
            font: NativeTimelineReplyMetrics.unavailableFont,
            color: .secondaryLabelColor
        )
    }

    static func drawReplySummary(
        _ replySummary: MessageReplySummary.Prepared,
        in frame: CGRect,
        font: NSFont,
        color: NSColor,
        model: AppModel?
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if replySummary.emojis.isEmpty {
            text(
                replySummary.text,
                in: frame,
                font: font,
                color: color,
                concealedSpoilerRanges: replySummary.spoilerRanges
            )
            return
        }

        let placement = singleLineText(
            CTLineCreateWithAttributedString(NativeTimelineReplyMetrics.coreTextSummary(
                replySummary,
                font: font,
                color: color
            )),
            in: frame,
            font: font,
            color: color,
            concealedSpoilerRanges: replySummary.spoilerRanges,
            context: context
        )
        drawReplySummaryEmojis(
            line: placement.line,
            spoilerRanges: replySummary.spoilerRanges,
            frame: frame,
            baseline: placement.baseline,
            horizontalPosition: placement.horizontalPosition,
            model: model
        )
    }

    private static func drawReplySummaryEmojis(
        line: CTLine,
        spoilerRanges: [NSRange],
        frame: CGRect,
        baseline: CGFloat,
        horizontalPosition: CGFloat = 0,
        model: AppModel?
    ) {
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let rawToken = attributes[NSAttributedString.Key.discordEmojiToken] as? String else {
                continue
            }
            let stringRange = CTRunGetStringRange(run)
            guard stringRange.location >= 0 else { continue }
            let isConcealed = spoilerRanges.contains { spoilerRange in
                NSLocationInRange(stringRange.location, spoilerRange)
            }
            guard !isConcealed else { continue }

            var runAscent: CGFloat = 0
            var runDescent: CGFloat = 0
            let runWidth = CGFloat(CTRunGetTypographicBounds(
                run,
                CFRange(location: 0, length: 0),
                &runAscent,
                &runDescent,
                nil
            ))
            let xOffset = CTLineGetOffsetForStringIndex(line, stringRange.location, nil)
            let emojiFrame = CGRect(
                x: frame.minX + horizontalPosition + xOffset,
                y: frame.maxY - baseline - runAscent,
                width: max(1, runWidth),
                height: max(1, runAscent + runDescent)
            )
            if let image = inlineEmojiImage(token: rawToken, model: model) {
                drawImage(image, in: emojiFrame, cornerRadius: 0, fillsFrame: false)
            } else {
                text(
                    "🙂",
                    in: emojiFrame,
                    font: .systemFont(ofSize: max(11, emojiFrame.height * 0.8)),
                    color: .labelColor,
                    alignment: .center
                )
            }
        }
    }

    static func replyAuthor(
        preview: MessageReplyPreview,
        frame: CGRect,
        avatarFrame: CGRect,
        showsReplyMention: Bool,
        message: Message,
        model: AppModel?,
        foregroundColor: NSColor? = nil
    ) -> CGRect {
        let presentation = model?.authorPresentation(for: preview, in: message)
        let author = presentation?.user ?? preview.author
        avatar(
            name: author.displayName,
            url: author.avatarURL,
            in: avatarFrame
        )
        let font = ProfileNameFontCache.font(id: author.displayNameStyle?.fontID, fallback: NativeTimelineReplyMetrics.authorFont)
        let displayName = showsReplyMention
            ? NativeTimelineReplyMetrics.authorDisplayName(author, in: message)
            : author.displayName
        let width = NativeTimelineReplyMetrics.textWidth(
            displayName,
            font: font
        )
        let roleColor = NSColor(discordColor: presentation?.roleColorHex)
        let showsIndicator = model?.accessibilitySettings.roleColorDisplay == .nextToNames && roleColor != nil
        let indicatorWidth: CGFloat = showsIndicator ? InterfaceScale.metric(16) : 0
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
            height: NativeTimelineReplyMetrics.lineHeight
        )
        let gradientColors = author.isBot ? nil : roleGradientColors(presentation)
        if foregroundColor == nil,
           model?.accessibilitySettings.roleColorDisplay == .inNames,
           let gradientColors,
           let context = NSGraphicsContext.current?.cgContext
        {
            NativeIdentityTextPresentation(displayName, font: font, maximumWidth: authorFrame.width)
                .draw(in: authorFrame, gradientColors: gradientColors, context: context)
        } else {
            text(
                displayName,
                in: authorFrame,
                font: font,
                color: foregroundColor ?? (author.isBot
                    ? .sakuraCordAccentColor
                    : model?.accessibilitySettings.roleColorDisplay == .inNames ? roleColor ?? .labelColor : .labelColor)
            )
        }
        if showsIndicator, let roleColor {
            roleDot(gradientColors ?? [roleColor], in: CGRect(
                x: authorFrame.minX - indicatorWidth,
                y: authorFrame.midY - InterfaceScale.metric(5),
                width: InterfaceScale.metric(10),
                height: InterfaceScale.metric(10)
            ))
        }
        return CGRect(x: authorFrame.minX - indicatorWidth, y: authorFrame.minY, width: authorFrame.width + indicatorWidth, height: authorFrame.height)
    }

    static func replyConnector(in connectorFrame: CGRect) {
        elbowConnector(
            stemX: connectorFrame.minX + 19,
            fromY: connectorFrame.maxY,
            cornerY: connectorFrame.minY + connectorFrame.height * 0.46,
            toX: connectorFrame.maxX
        )
    }

    /// A rounded elbow: a vertical stem from `fromY` that turns toward `toX`
    /// at `cornerY`. The stem may run up or down, and the arm left or right.
    static func elbowConnector(stemX: CGFloat, fromY: CGFloat, cornerY: CGFloat, toX: CGFloat) {
        let direction: CGFloat = fromY > cornerY ? 1 : -1
        let horizontalDirection: CGFloat = toX >= stemX ? 1 : -1
        let connector = NSBezierPath()
        connector.lineWidth = 1.25
        connector.lineCapStyle = .round
        connector.move(to: CGPoint(x: stemX, y: fromY))
        connector.line(to: CGPoint(x: stemX, y: cornerY + 4 * direction))
        connector.curve(
            to: CGPoint(x: stemX + InterfaceScale.metric(4) * horizontalDirection, y: cornerY),
            controlPoint1: CGPoint(x: stemX, y: cornerY + 1.8 * direction),
            controlPoint2: CGPoint(x: stemX + InterfaceScale.metric(2.2) * horizontalDirection, y: cornerY)
        )
        connector.line(to: CGPoint(x: toX, y: cornerY))
        NSColor.tertiaryLabelColor.setStroke()
        connector.stroke()
    }

    static func commandInvocation(
        _ region: NativeTimelineRowLayout.CommandInvocationRegion,
        bubbleConnector: NativeTimelineRowLayout.ReferenceConnector?,
        message: Message,
        cosmeticPolicy: ProfileCosmeticPolicy,
        isPillHovered: Bool
    ) {
        if let bubbleConnector {
            elbowConnector(
                stemX: bubbleConnector.stemX,
                fromY: bubbleConnector.fromY,
                cornerY: bubbleConnector.cornerY,
                toX: bubbleConnector.toX
            )
        } else {
            replyConnector(in: region.connectorFrame)
        }
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
            font: ProfileNameFontCache.font(id: user?.displayNameStyle?.fontID, fallback: .interfaceSystemFont(
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
            font: .interfacePreferredFont(forTextStyle: .caption1),
            color: .secondaryLabelColor
        )
        // Like Discord, hovering fills the pill and turns its content white.
        let pillContentColor: NSColor = isPillHovered ? .sakuraCordLabelOnAccentColor : .sakuraCordAccentColor
        NSColor.sakuraCordAccentColor.withAlphaComponent(isPillHovered ? 1 : 0.16).setFill()
        NSBezierPath(
            roundedRect: region.pillFrame,
            xRadius: InterfaceScale.metric(4),
            yRadius: InterfaceScale.metric(4)
        ).fill()
        systemSymbol(
            SakuraCordSystemSymbol.applicationCommands,
            in: region.commandSymbolFrame,
            color: pillContentColor,
            inset: 0,
            weight: .semibold
        )
        text(
            NativeTimelineRowLayout.commandLabel(for: message),
            in: region.commandFrame,
            font: .interfaceSystemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .caption1
                ).pointSize,
                weight: .semibold
            ),
            color: pillContentColor,
            lineBreakMode: .byTruncatingTail
        )
    }

    static func ephemeralFooter(
        _ region: NativeTimelineRowLayout.EphemeralRegion,
        isDismissHovered: Bool
    ) {
        systemSymbol(
            "eye",
            in: region.eyeFrame,
            color: .secondaryLabelColor,
            inset: 0
        )
        let font = NSFont.interfacePreferredFont(forTextStyle: .caption1)
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
            color: .sakuraCordAccentColor,
            isInteractiveHovered: isDismissHovered
        )
    }
}
