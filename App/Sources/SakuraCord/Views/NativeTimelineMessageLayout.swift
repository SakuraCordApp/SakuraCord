import AppKit
import CoreText
import MessageRendering
import SakuraCordModels

extension NativeTimelineRowLayout {
    /// Assembles a complete message in display order. Each phase owns one
    /// region; the shared cursor makes spacing and wrapping explicit.
    struct MessageBuilder {
        let row: MessageRowPresentation
        let isUnreadBoundary: Bool
        let width: CGFloat
        let model: AppModel?
        let metrics: Metrics

        private var result = NativeTimelineRowLayout()
        private var contentPresentation: NativeTimelineTextPresentation.Value
        private var usesBubbles = false
        private var isOutgoingBubble = false
        private var horizontalInset: CGFloat = 0
        private var contentX: CGFloat = 0
        private var contentWidth: CGFloat = 0
        private var ordinaryContentWidth: CGFloat = 0
        private let highlightInsets: MessageRowHighlightInsets
        private var highlightMinY: CGFloat = 0
        private var verticalOffset: CGFloat = 0
        private var showsIncomingIdentity = false
        private var showsIncomingAvatar = false
        private var bubbleStartY: CGFloat = 0
        private var inlineMediaMaximumWidth: CGFloat = 0
        private var hasRichContent = false
        private var forwardedBarStartY: CGFloat?

        private var message: Message { row.message }
        private var searchContext: MessageSearchRowContext? { row.searchContext }
        private var usesComponentsV2: Bool { message.flags.contains(.isComponentsV2) }
        private var isGenerated: Bool { message.type.hasGeneratedContent }
        private let bubbleContext: NativeTimelineBubbleLayout.Context
        private var messageSpacing: CGFloat {
            CGFloat(model?.appearanceSettings.messageSpacing ?? AppearanceSettingsSnapshot.defaultMessageSpacing)
        }
        private var avatarWidth: CGFloat { MessageRowLayoutMetrics.avatarDiameter }
        private var timestampGutterWidth: CGFloat { max(avatarWidth, metrics.timestampGutterWidth) }
        private let presentedReactions: [Reaction]

        init(row: MessageRowPresentation, isUnreadBoundary: Bool, width: CGFloat, model: AppModel?, metrics: Metrics, relativeTo date: Date = .now) {
            self.row = row
            self.isUnreadBoundary = isUnreadBoundary
            self.width = width
            self.model = model
            self.metrics = metrics
            bubbleContext = NativeTimelineBubbleLayout.context(for: row.message, model: model)
            presentedReactions = MessageReactionPresentation.items(from: row.message.reactions)
            contentPresentation = NativeTimelineTextPresentation.make(row: row, model: model, relativeTo: date)
            highlightInsets = MessageRowLayoutMetrics.highlightInsets(
                hasReplyPreview: row.replyMessageID != nil,
                isEditing: false,
                messageSpacing: CGFloat(model?.appearanceSettings.messageSpacing ?? AppearanceSettingsSnapshot.defaultMessageSpacing)
            )
        }

        mutating func make() -> NativeTimelineRowLayout {
            prepareColumns()
            appendPrefix()
            appendIdentity()
            appendTextAndPoll()
            appendLinkedImages()
            appendAttachments()
            appendCards()
            appendStickers()
            appendForwardedSource()
            appendThreadAndBubble()
            appendReactions()
            appendDeliveryState()
            finish()
            return result
        }

        private mutating func prepareColumns() {
            usesBubbles = bubbleContext.isEnabled && !row.isResource
            isOutgoingBubble = bubbleContext.isOutgoing && !row.isResource
            horizontalInset = searchContext == nil
                ? MessageRowLayoutMetrics.horizontalInset
                : 22
            let columnGap = MessageRowLayoutMetrics.avatarColumnGap + timestampGutterWidth - avatarWidth
            if isOutgoingBubble {
                contentPresentation = NativeTimelineTextPresentation.outgoingBubble(contentPresentation)
            }
            if message.flags.contains(.localInteractionFailure) {
                contentPresentation = NativeTimelineTextPresentation.interactionFailure(contentPresentation)
            }
            let authorName = (model?.authorPresentation(for: message).user ?? message.author).displayName
            if let status = MessageOutboxPresentation.interactionLoadingStatus(for: message, authorName: authorName) {
                contentPresentation = NativeTimelineTextPresentation.interactionLoading(status)
            }
            let preferredBubbleContentWidth =
                NativeTimelineBubbleLayout.preferredContentWidth(
                    for: message,
                    row: row,
                    content: contentPresentation,
                    availableWidth: width,
                    isEnabled: usesBubbles
                )
            let bubbleColumn = NativeTimelineBubbleLayout.column(
                availableWidth: width,
                horizontalInset: horizontalInset,
                avatarWidth: avatarWidth,
                columnGap: columnGap,
                isGenerated: isGenerated,
                context: bubbleContext,
                preferredContentWidth: preferredBubbleContentWidth
            )
            contentX = row.isResource ? horizontalInset : bubbleColumn.contentX
            contentWidth = row.isResource ? width - horizontalInset * 2 : bubbleColumn.contentWidth
            ordinaryContentWidth = max(
                80,
                width - contentX - horizontalInset
            )
        }

        private mutating func appendPrefix() {
            let searchPrefix = NativeTimelineSearchPrefixLayout.make(
                context: searchContext,
                width: width
            )
            result.searchSectionRegion = searchPrefix.region
            var prefixHeight = searchPrefix.height

            if row.startsDay {
                result.daySeparatorFrame = CGRect(
                    x: horizontalInset,
                    y: prefixHeight,
                    width: width - 28,
                    height: NativeTimelineDateSeparatorMetrics.rowHeight
                )
                prefixHeight += NativeTimelineDateSeparatorMetrics.rowHeight
            }

            if isUnreadBoundary {
                result.unreadSeparatorFrame = CGRect(
                    x: horizontalInset,
                    y: prefixHeight,
                    width: width - 24,
                    height: NativeTimelineUnreadSeparatorMetrics.rowHeight
                )
                prefixHeight += NativeTimelineUnreadSeparatorMetrics.rowHeight
            }

            let externalTopSeparation = MessageRowLayoutMetrics.separation(
                startsGroup: row.startsGroup,
                followsTimelineSeparator: row.startsDay || isUnreadBoundary,
                highlightTopInset: highlightInsets.top,
                messageSpacing: messageSpacing
            )
            highlightMinY = prefixHeight
                + (searchContext == nil ? externalTopSeparation : 4)
            verticalOffset = highlightMinY + highlightInsets.top

            if row.replyMessageID != nil, message.type != .pollResult {
                let frame = CGRect(
                    x: horizontalInset,
                    y: verticalOffset,
                    width: width - horizontalInset * 2,
                    height: 20
                )
                result.replyFrame = frame
                result.replyContentFrame = CGRect(
                    x: contentX,
                    y: frame.minY,
                    width: max(0, frame.maxX - contentX),
                    height: frame.height
                )
                verticalOffset += 20
            }

            if message.type == .chatInputCommand {
                result.commandInvocationRegion = NativeTimelineRowLayout.commandInvocation(
                    message,
                    origin: CGPoint(x: horizontalInset, y: verticalOffset),
                    maximumWidth: width - horizontalInset * 2,
                    cosmeticPolicy: model?.cosmeticPolicy ?? .init()
                )
                verticalOffset += MessageRowLayoutMetrics.commandInvocationHeight
            }

        }

        private mutating func appendIdentity() {
            showsIncomingIdentity = !row.isResource && (!usesBubbles || bubbleContext.showsAvatar)
            showsIncomingAvatar = !isGenerated
                && !isOutgoingBubble
                && showsIncomingIdentity
                && (usesBubbles ? row.endsGroup : row.startsGroup)
            if showsIncomingAvatar {
                result.avatarFrame = CGRect(
                    origin: CGPoint(x: horizontalInset, y: verticalOffset),
                    size: CGSize(width: avatarWidth, height: avatarWidth)
                )
            }
            if row.startsGroup, !row.isResource, !isGenerated, !isOutgoingBubble,
               showsIncomingIdentity
            {
                appendAuthorHeader()
                verticalOffset += MessageRowLayoutMetrics.authorLineHeight
                    + MessageRowLayoutMetrics.authorToContentSpacing(
                        isCommandResponse: message.type == .chatInputCommand
                    )
            } else if !isGenerated, !isOutgoingBubble, showsIncomingIdentity,
                      !showsIncomingAvatar
            {
                result.compactTimestampFrame = CGRect(
                    x: horizontalInset,
                    y: verticalOffset,
                    width: timestampGutterWidth,
                    height: MessageRowLayoutMetrics.compactContentHeight
                )
            }

            if isGenerated {
                result.systemIconFrame = CGRect(
                    x: horizontalInset + 36,
                    y: verticalOffset,
                    width: 16,
                    height: MessageRowLayoutMetrics.compactContentHeight
                )
            }

        }

        private mutating func appendAuthorHeader() {
            let author = model.map {
                $0.authorPresentation(for: message).user
            } ?? message.author
            let authorFont = ProfileNameFontLoader.shared.resolvedFont(for: author, fallback: metrics.authorFont)
            let showsRoleIndicator = model?.accessibilitySettings.roleColorDisplay == .nextToNames
                && model?.authorPresentation(for: message).roleColorHex != nil
            let indicatorWidth: CGFloat = showsRoleIndicator ? 14 : 0
            let authorWidth = min(
                max(0, ordinaryContentWidth - indicatorWidth),
                NativeTimelineRowLayout.measuredTextWidth(author.displayName, font: authorFont)
            )
            result.authorFrame = CGRect(
                x: contentX + indicatorWidth,
                y: verticalOffset,
                width: authorWidth,
                height: MessageRowLayoutMetrics.authorLineHeight
            )
            var headerX = contentX + authorWidth + indicatorWidth
            if author.isBot {
                headerX += 7
                let badgeFont = metrics.badgeFont
                let badgeWidth = NativeTimelineRowLayout.measuredTextWidth(
                    "APP",
                    font: badgeFont
                ) + 8
                result.botBadgeFrame = CGRect(
                    x: headerX,
                    // Discord gives the application badge enough vertical
                    // weight to read as a badge, while keeping it centered
                    // inside the fixed author line.
                    y: verticalOffset + 1,
                    width: badgeWidth,
                    height: 14
                )
                headerX += badgeWidth
            }
            appendTimestamp(at: headerX)
        }

        private mutating func appendTimestamp(at originX: CGFloat) {
            var headerX = originX
            headerX += 7
            let timestampFont = metrics.timestampFont
            let timestamp = NativeTimelineTimestamp.headerText(
                for: message.timestamp,
                settings: model?.interfaceSettings ?? .defaults
            )
            let timestampWidth = NativeTimelineRowLayout.measuredTextWidth(
                timestamp,
                font: timestampFont
            )
            result.timestampFrame = CGRect(
                x: headerX,
                y: verticalOffset + 3,
                width: min(timestampWidth, max(0, contentX + contentWidth - headerX)),
                height: 13
            )
            headerX = result.timestampFrame?.maxX ?? headerX
            if message.editedTimestamp != nil {
                headerX += 7
                let editedFont = metrics.editedFont
                result.editedFrame = CGRect(
                    x: headerX,
                    y: verticalOffset + 4,
                    width: min(
                        NativeTimelineRowLayout.measuredTextWidth("(edited)", font: editedFont),
                        max(0, contentX + contentWidth - headerX)
                    ),
                    height: 11
                )
                headerX = result.editedFrame?.maxX ?? headerX
            }
        }

        private mutating func appendTextAndPoll() {
            bubbleStartY = verticalOffset
            if usesBubbles {
                verticalOffset += 8
            }

            if message.forwardedSnapshot != nil {
                result.forwardedHeaderFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: contentWidth,
                    height: 18
                )
                forwardedBarStartY = verticalOffset
                verticalOffset += 22
            } else {
                forwardedBarStartY = nil
            }

            hasRichContent = false
            inlineMediaMaximumWidth = min(
                contentWidth,
                DiscordRichMessageMetrics.maximumWidth
            )
            result.attributedContent = contentPresentation.attributedContent
            result.contentFramesetter = contentPresentation.framesetter
            if let attributedContent = contentPresentation.attributedContent {
                let textHeight = NativeTimelineRowLayout.measuredTextHeight(
                    contentPresentation.framesetter,
                    value: attributedContent,
                    length: attributedContent.length,
                    width: contentWidth
                )
                result.contentFrame = CGRect(x: contentX, y: verticalOffset, width: contentWidth, height: textHeight)
                if message.flags.contains(.loading) {
                    let font = NSFont.systemFont(ofSize: InterfaceTypographyMetrics.messageTextSize)
                    let lineHeight = font.ascender - font.descender + font.leading
                    let dots = InteractionLoadingDots.size
                    result.activityIndicators.append(.init(
                        frame: CGRect(
                            x: contentX, y: verticalOffset + (lineHeight - dots.height) / 2,
                            width: dots.width, height: dots.height
                        ),
                        style: .dots(.content)
                    ))
                }
                verticalOffset += textHeight
                hasRichContent = true
            }

            if message.pollResultSummary != nil {
                if hasRichContent { verticalOffset += 8 }
                result.pollResultFrame = CGRect(x: contentX, y: verticalOffset, width: min(440, contentWidth), height: 66)
                verticalOffset += 66
                hasRichContent = true
            }
            if let poll = message.poll {
                if hasRichContent { verticalOffset += 6 }
                let layout = NativeTimelinePollLayout(poll: poll, x: contentX, y: verticalOffset, width: contentWidth)
                result.pollLayout = layout
                verticalOffset = layout.frame.maxY
                hasRichContent = true
            }
        }

        private mutating func appendLinkedImages() {
            if !contentPresentation.linkedImages.isEmpty {
                if hasRichContent {
                    verticalOffset += 6
                }
                let plan = InlineWrappingLayoutPlan.frames(
                    sizes: contentPresentation.linkedImages.map { $0.displaySize },
                    maximumWidth: inlineMediaMaximumWidth,
                    horizontalSpacing: 4,
                    verticalSpacing: 4
                )
                result.linkedImageRegions = zip(
                    contentPresentation.linkedImages,
                    plan.frames
                ).map { reference, frame in
                    LinkedImageRegion(
                        frame: frame.offsetBy(dx: contentX, dy: verticalOffset),
                        reference: reference
                    )
                }
                verticalOffset += plan.size.height
                hasRichContent = true
            }

        }

        private mutating func appendAttachments() {
            if !usesComponentsV2, !message.attachments.isEmpty {
                if hasRichContent {
                    verticalOffset += 8
                }
                let galleryWidth = min(500, max(180, inlineMediaMaximumWidth))
                let galleryFrames = MediaGalleryPlan.frames(
                    count: message.attachments.count,
                    width: galleryWidth,
                    aspectRatios: message.attachments.map {
                        guard let width = $0.width,
                              let height = $0.height,
                              width > 0,
                              height > 0
                        else { return 16 / 9 }
                        return CGFloat(width) / CGFloat(height)
                    },
                    intrinsicSizes: message.attachments.map {
                        guard let width = $0.width,
                              let height = $0.height,
                              width > 0,
                              height > 0
                        else { return .zero }
                        return CGSize(
                            width: CGFloat(width),
                            height: CGFloat(height)
                        )
                    },
                    spacing: 4
                )
                result.attachmentRegions = zip(
                    message.attachments,
                    galleryFrames
                ).map { attachment, frame in
                    AttachmentRegion(
                        frame: frame.offsetBy(dx: contentX, dy: verticalOffset),
                        attachment: attachment,
                        previewKey: attachment.mediaKind == .video
                            ? .videoPoster(attachment)
                            : .attachment(attachment)
                    )
                }
                verticalOffset += galleryFrames.map(\.maxY).max() ?? 0
                hasRichContent = true
            }

        }

        private mutating func appendCards() {
            if !usesComponentsV2 {
                for (index, reference) in row.serverInvites.enumerated() {
                    let region = NativeTimelineInviteLayout(reference: reference, index: index,
                        origin: CGPoint(x: contentX, y: verticalOffset + (hasRichContent ? 8 : 0)),
                        maximumWidth: inlineMediaMaximumWidth, model: model,
                        isOwnMessage: message.author.id == model?.snapshot?.currentUser.id)
                    result.inviteRegions.append(region)
                    verticalOffset = region.frame.maxY
                    hasRichContent = true
                }
            }
            if !usesComponentsV2 {
                for (index, deepLink) in row.sakuraCordDeepLinks.enumerated() {
                    let deepLinkY = verticalOffset + (hasRichContent ? 8 : 0)
                    let region = NativeTimelineSakuraCordDeepLinkLayout.make(
                        deepLink,
                        componentIndex: index,
                        origin: CGPoint(x: contentX, y: deepLinkY),
                        maximumWidth: inlineMediaMaximumWidth
                    )
                    result.sakuraCordDeepLinkRegions.append(region)
                    verticalOffset = region.frame.maxY
                    hasRichContent = true
                }
            }
            if !usesComponentsV2 {
                let visibleEmbeds =
                    MessageEmbedPresentation.visibleEmbeds(
                        for: message
                    )
                result.embedRegions.reserveCapacity(visibleEmbeds.count)
                for embed in visibleEmbeds {
                    let embedY = verticalOffset + (hasRichContent ? 8 : 0)
                    if embed.type == "components" {
                        if let region = NativeTimelineComponentLayout.make(
                            message: message,
                            components: embed.components ?? [],
                            model: model,
                            origin: CGPoint(x: contentX, y: embedY),
                            maximumWidth: inlineMediaMaximumWidth,
                            integratesWithBubble: usesBubbles,
                            drawsTopSeparator: usesBubbles && hasRichContent
                        ) {
                            result.componentLayouts.append(region)
                            verticalOffset = region.frame.maxY
                            hasRichContent = true
                        }
                        continue
                    }
                    guard let region = NativeTimelineEmbedLayout.make(
                        embed: embed,
                        message: message,
                        model: model,
                        attachments: message.attachments,
                        origin: CGPoint(x: contentX, y: embedY),
                        maximumWidth: inlineMediaMaximumWidth,
                        integratesWithBubble: usesBubbles,
                        drawsTopSeparator: usesBubbles && hasRichContent
                    ) else { continue }
                    result.embedRegions.append(region)
                    verticalOffset = region.frame.maxY
                    hasRichContent = true
                }
            }
            result.embedFrames = result.embedRegions.map(\.frame)

            let componentY = verticalOffset + (hasRichContent ? 8 : 0)
            if let componentLayout = NativeTimelineComponentLayout.make(
                message: message,
                model: model,
                origin: CGPoint(x: contentX, y: componentY),
                maximumWidth: inlineMediaMaximumWidth,
                integratesWithBubble: usesBubbles,
                drawsTopSeparator: usesBubbles && hasRichContent
            ) {
                result.componentLayouts.append(componentLayout)
                verticalOffset = componentLayout.frame.maxY
                hasRichContent = true
            }
            result.componentFrames = result.componentLayouts.map(\.frame)
            // An activated button shows the dots in place of its label, and a
            // committed select in place of its chevron.
            let dots = InteractionLoadingDots.size
            for button in result.componentLayouts.flatMap(\.buttons) where button.isLoading {
                result.activityIndicators.append(.init(
                    frame: CGRect(
                        x: button.frame.midX - dots.width / 2, y: button.frame.midY - dots.height / 2,
                        width: dots.width, height: dots.height
                    ),
                    style: .dots(.onFill)
                ))
            }
            for select in result.componentLayouts.flatMap(\.selects) where select.isLoading {
                let chevron = SelectionFieldRenderer.chevronRect(in: select.frame)
                result.activityIndicators.append(.init(
                    frame: CGRect(
                        x: chevron.maxX - dots.width, y: chevron.midY - dots.height / 2,
                        width: dots.width, height: dots.height
                    ),
                    style: .dots(.content)
                ))
            }
        }

        private mutating func appendStickers() {
            if !message.stickers.isEmpty {
                if hasRichContent {
                    verticalOffset += 8
                }
                let size = min(contentWidth, 112)
                var stickerX = contentX
                var rowHeight: CGFloat = 0
                for _ in message.stickers {
                    if stickerX + size > contentX + contentWidth,
                       stickerX > contentX
                    {
                        stickerX = contentX
                        verticalOffset += rowHeight + 8
                        rowHeight = 0
                    }
                    result.stickerFrames.append(
                        CGRect(x: stickerX, y: verticalOffset, width: size, height: size)
                    )
                    stickerX += size + 8
                    rowHeight = max(rowHeight, size)
                }
                verticalOffset += rowHeight
                hasRichContent = true
            }

        }

        private mutating func appendForwardedSource() {
            if let snapshot = message.forwardedSnapshot,
               let reference = message.messageReference,
               let sourceChannelID = reference.channelID,
               let sourceChannel = model?.snapshot?.channels.first(where: {
                   $0.id == sourceChannelID
               })
            {
                if hasRichContent { verticalOffset += 7 }
                let sourceGuild = reference.guildID.flatMap { sourceGuildID in
                    model?.snapshot?.guilds.first(where: { $0.id == sourceGuildID })
                }
                let sameGuild = message.guildID == reference.guildID
                let sourceLabel = sameGuild
                    ? "#\(sourceChannel.name)"
                    : (sourceGuild?.name ?? sourceChannel.name)
                let dateText = snapshot.timestamp.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
                let sourceText = "\(sourceLabel)  •  \(dateText)  ›"
                let sourceFont = NSFont.systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .medium
                )
                let iconWidth: CGFloat = sameGuild ? 0 : 24
                let sourceWidth = min(
                    contentWidth,
                    ceil((sourceText as NSString).size(withAttributes: [
                        .font: sourceFont
                    ]).width) + iconWidth + 12
                )
                result.forwardedSourceRegion = ForwardedSourceRegion(
                    frame: CGRect(
                        x: contentX,
                        y: verticalOffset,
                        width: sourceWidth,
                        height: 22
                    ),
                    label: sourceLabel,
                    iconURL: sameGuild ? nil : sourceGuild?.iconURL,
                    channelID: sourceChannelID,
                    guildID: reference.guildID,
                    messageID: reference.messageID,
                    timestamp: snapshot.timestamp
                )
                verticalOffset += 22
                hasRichContent = true
            }
            if let forwardedBarStartY {
                result.forwardedBarFrame = CGRect(
                    x: contentX - 11,
                    y: forwardedBarStartY,
                    width: 3,
                    height: max(18, verticalOffset - forwardedBarStartY)
                )
            }

        }

        private mutating func appendThreadAndBubble() {
            if message.thread != nil {
                if hasRichContent {
                    verticalOffset += 8
                }
                result.threadFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: min(contentWidth, 440),
                    height: NativeTimelineThreadCard.height
                )
                verticalOffset += NativeTimelineThreadCard.height
                hasRichContent = true
            }

            if usesBubbles, hasRichContent {
                verticalOffset += 8
                let region = NativeTimelineBubbleLayout.region(
                    contentX: contentX,
                    contentWidth: contentWidth,
                    minY: bubbleStartY,
                    maxY: verticalOffset,
                    isOutgoing: isOutgoingBubble,
                    showsTail: row.endsGroup
                )
                result.bubbleRegion = region
                result.avatarFrame = NativeTimelineBubbleLayout.bottomAlignedAvatarFrame(result.avatarFrame, to: region)
            }

        }

        private mutating func appendReactions() {
            if !presentedReactions.isEmpty {
                if hasRichContent {
                    verticalOffset += 4
                }
                let sizes = presentedReactions.map(reactionSize)
                    + [CGSize(
                        width: ReactionActionMenuPresentation.inline.width,
                        height: MessageReactionMetrics.pillHeight
                    )]
                let wrapping = InlineWrappingLayoutPlan.frames(
                    sizes: sizes,
                    maximumWidth: contentWidth,
                    horizontalSpacing: MessageReactionMetrics.horizontalSpacing,
                    verticalSpacing: MessageReactionMetrics.verticalSpacing
                )
                result.reactionRegions = zip(
                    presentedReactions,
                    wrapping.frames.prefix(presentedReactions.count)
                ).map { reaction, frame in
                    NativeTimelineRowLayout.reactionRegion(
                        reaction,
                        frame: frame.offsetBy(dx: contentX, dy: verticalOffset)
                    )
                }
                if let frame = wrapping.frames.last {
                    result.addReactionFrame = frame.offsetBy(dx: contentX, dy: verticalOffset)
                }
                verticalOffset += wrapping.size.height
            }

        }

        private mutating func appendDeliveryState() {
            if message.flags.contains(.ephemeral) {
                if hasRichContent || !presentedReactions.isEmpty {
                    verticalOffset += 4
                }
                result.ephemeralRegion = NativeTimelineRowLayout.ephemeral(
                    origin: CGPoint(x: contentX, y: verticalOffset),
                    maximumWidth: contentWidth
                )
                verticalOffset += 15
            }

            if message.outboxState == .failed {
                if hasRichContent
                    || !presentedReactions.isEmpty
                    || result.ephemeralRegion != nil
                {
                    verticalOffset += 4
                }
                result.failedFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: contentWidth,
                    height: 14
                )
                verticalOffset += 14
            }

            if row.pinnedAt != nil {
                if hasRichContent || !presentedReactions.isEmpty || result.ephemeralRegion != nil {
                    verticalOffset += 6
                }
                result.pinnedAtFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: contentWidth,
                    height: 16
                )
                verticalOffset += 16
            }

        }

        private mutating func finish() {
            let visibleContentMaxY = max(
                verticalOffset,
                result.avatarFrame?.maxY ?? 0,
                result.authorFrame?.maxY ?? 0
            )
            let searchBottomInset: CGFloat = searchContext == nil ? 0 : 8
            let rowHeight = ceil(
                max(
                    visibleContentMaxY + highlightInsets.bottom,
                    highlightMinY
                        + highlightInsets.top
                        + (showsIncomingAvatar
                            ? MessageRowLayoutMetrics.avatarDiameter
                            : MessageRowLayoutMetrics.compactContentHeight)
                        + highlightInsets.bottom
                ) + searchBottomInset
            )
            result.searchCardFrame = searchContext.flatMap { context -> CGRect? in
                guard !context.isInbox else { return nil }
                return CGRect(
                    x: 0,
                    y: highlightMinY,
                    width: width,
                    height: max(0, rowHeight - highlightMinY - searchBottomInset)
                )
            }
            result.highlightFrame = NativeTimelineBubbleLayout.highlightFrame(
                isEnabled: usesBubbles,
                bubbleRegion: result.bubbleRegion,
                stickerFrames: result.stickerFrames,
                searchCardFrame: result.searchCardFrame,
                highlightMinY: highlightMinY,
                rowHeight: rowHeight,
                width: width
            )

            result.height = rowHeight
        }
    }
}
