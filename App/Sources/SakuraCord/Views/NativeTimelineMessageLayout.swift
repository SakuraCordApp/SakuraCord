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
        private var translationPresentation: NativeTimelineTranslationPresentation?
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

        init(row: MessageRowPresentation, isUnreadBoundary: Bool, width: CGFloat, model: AppModel?, metrics: Metrics) {
            self.row = row
            self.isUnreadBoundary = isUnreadBoundary
            self.width = width
            self.model = model
            self.metrics = metrics
            bubbleContext = NativeTimelineBubbleLayout.context(for: row.message, model: model)
            presentedReactions = MessageReactionPresentation.items(from: row.message.reactions)
            contentPresentation = NativeTimelineTextPresentation.make(row: row, model: model)
            highlightInsets = MessageRowLayoutMetrics.highlightInsets(
                hasReplyPreview: row.replyMessageID != nil,
                isEditing: false,
                messageSpacing: CGFloat(model?.appearanceSettings.messageSpacing ?? AppearanceSettingsSnapshot.defaultMessageSpacing)
            )
        }

        /// Replaces the estimated bubble width once the real content extent
        /// is known.
        private var fittedBubbleContentWidth: CGFloat?

        mutating func make() -> NativeTimelineRowLayout {
            let unmeasured = self
            let layout = assemble()
            // Media bubbles start from an estimate. When the media renders
            // narrower, lay the row out again so the bubble hugs it.
            guard let fittedWidth = mediaBubbleContentWidth(of: layout) else { return layout }
            self = unmeasured
            fittedBubbleContentWidth = fittedWidth
            return assemble()
        }

        private func mediaBubbleContentWidth(of layout: NativeTimelineRowLayout) -> CGFloat? {
            guard usesBubbles, layout.bubbleRegion != nil,
                  layout.pollLayout == nil, layout.pollResultFrame == nil,
                  layout.translationRegion == nil, layout.threadFrame == nil,
                  layout.forwardedSourceRegion == nil, layout.forwardedHeaderFrame == nil,
                  layout.componentLayouts.isEmpty, layout.inviteRegions.isEmpty,
                  layout.sakuraCordDeepLinkRegions.isEmpty,
                  layout.embedRegions.allSatisfy({ $0.kind == .bareMedia })
            else { return nil }
            var extent = InterfaceScale.metric(28)
            if let attributedContent = layout.attributedContent, let framesetter = layout.contentFramesetter {
                extent = max(extent, NativeTimelineBubbleLayout.measuredTextWidth(
                    framesetter,
                    length: attributedContent.length,
                    maximumWidth: contentWidth
                ))
            }
            let mediaFrames = layout.linkedImageRegions.map(\.frame)
                + layout.attachmentRegions.map(\.frame)
                + [layout.voiceMessageRegion?.frame].compactMap { $0 }
                + layout.embedFrames
                + layout.stickerFrames
            for frame in mediaFrames {
                extent = max(extent, ceil(frame.maxX - contentX))
            }
            return extent < contentWidth - 1 ? extent : nil
        }

        private mutating func assemble() -> NativeTimelineRowLayout {
            prepareColumns()
            appendPrefix()
            appendIdentity()
            appendBubbleReference()
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
            translationPresentation = NativeTimelineTranslationPresentation.make(
                row: row, model: model, isOutgoingBubble: isOutgoingBubble
            )
            let preferredBubbleContentWidth = fittedBubbleContentWidth ??
                NativeTimelineBubbleLayout.preferredContentWidth(
                    for: message,
                    row: row,
                    content: contentPresentation,
                    availableWidth: width,
                    isEnabled: usesBubbles,
                    translation: translationPresentation
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
                    width: width - InterfaceScale.metric(28),
                    height: NativeTimelineDateSeparatorMetrics.rowHeight
                )
                prefixHeight += NativeTimelineDateSeparatorMetrics.rowHeight
            }

            if isUnreadBoundary {
                result.unreadSeparatorFrame = CGRect(
                    x: horizontalInset,
                    y: prefixHeight,
                    width: width - InterfaceScale.metric(24),
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

            // Bubbles place the reference after the author header instead.
            if !usesBubbleReference, row.replyMessageID != nil, message.type != .pollResult {
                let frame = CGRect(
                    x: horizontalInset,
                    y: verticalOffset,
                    width: width - horizontalInset * 2,
                    height: InterfaceScale.metric(20)
                )
                result.replyFrame = frame
                result.replyContentFrame = CGRect(
                    x: contentX,
                    y: frame.minY,
                    width: max(0, frame.maxX - contentX),
                    height: frame.height
                )
                verticalOffset += InterfaceScale.metric(20)
            }

            if !usesBubbleReference, message.type == .chatInputCommand {
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
                // A bubble avatar keeps its gap to the bubble's tail.
                let diameter = usesBubbles ? NativeTimelineBubbleLayout.avatarDiameter : avatarWidth
                result.avatarFrame = CGRect(
                    origin: CGPoint(x: horizontalInset + avatarWidth - diameter, y: verticalOffset),
                    size: CGSize(width: diameter, height: diameter)
                )
            }
            if row.startsGroup, !row.isResource, !isGenerated, !isOutgoingBubble,
               showsIncomingIdentity
            {
                appendAuthorHeader()
                verticalOffset += (result.authorFrame?.height ?? MessageRowLayoutMetrics.authorLineHeight)
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
                    x: horizontalInset + InterfaceScale.metric(36),
                    y: verticalOffset,
                    width: InterfaceScale.metric(16),
                    height: MessageRowLayoutMetrics.compactContentHeight
                )
            }

        }

        /// A bubble joins one reference to itself. A reply that is also a
        /// command, or a command sent by the current user, keeps the
        /// standard reference rows, which can show both and fit any width.
        private var usesBubbleReference: Bool {
            let isReply = row.replyMessageID != nil && message.type != .pollResult
            let isCommand = message.type == .chatInputCommand
            return usesBubbles
                && isReply != isCommand
                && !(isCommand && isOutgoingBubble)
        }

        /// A bubble's reply or command sits directly above the bubble, on the
        /// bubble's own side, and its elbow meets the bubble's top edge.
        private mutating func appendBubbleReference() {
            guard usesBubbleReference else { return }
            let isReply = row.replyMessageID != nil && message.type != .pollResult
            let height = InterfaceScale.metric(20)
            let padding = NativeTimelineBubbleLayout.horizontalPadding
            // The stem lands where the bubble's top corner has flattened out.
            let stemInset = InterfaceScale.metric(14)
            let stemX = isOutgoingBubble
                ? contentX + contentWidth + padding - stemInset
                : contentX - padding + stemInset
            let leadingGap = InterfaceScale.metric(4) + NativeTimelineReplyMetrics.horizontalSpacing
            let referenceX = isOutgoingBubble ? stemX - leadingGap : stemX + leadingGap
            let connectorEndX = isOutgoingBubble
                ? referenceX + NativeTimelineReplyMetrics.horizontalSpacing
                : referenceX - NativeTimelineReplyMetrics.horizontalSpacing
            if isReply {
                let naturalWidth = NativeTimelineReplyMetrics.previewWidth(
                    row.replyPreview, in: message, model: model
                )
                // Outgoing previews grow leftward, up to the incoming avatar
                // column, and neither side outgrows the bubble column.
                let availableWidth = min(
                    NativeTimelineBubbleLayout.maximumContentWidth(availableWidth: width),
                    isOutgoingBubble
                        ? referenceX - horizontalInset - avatarWidth
                        : width - horizontalInset - referenceX
                )
                let previewWidth = max(0, min(ceil(naturalWidth), availableWidth))
                let previewFrame = CGRect(
                    x: isOutgoingBubble ? referenceX - previewWidth : referenceX,
                    y: verticalOffset,
                    width: previewWidth,
                    height: height
                )
                result.replyContentFrame = previewFrame
                result.replyFrame = previewFrame.union(CGRect(
                    x: min(stemX, connectorEndX),
                    y: verticalOffset,
                    width: abs(connectorEndX - stemX),
                    height: height
                ))
            } else {
                let connectorReserve = InterfaceScale.metric(30) + 5
                let origin = CGPoint(x: referenceX - connectorReserve, y: verticalOffset)
                result.commandInvocationRegion = NativeTimelineRowLayout.commandInvocation(
                    message,
                    origin: origin,
                    maximumWidth: width - horizontalInset - origin.x,
                    cosmeticPolicy: model?.cosmeticPolicy ?? .init()
                )
            }
            // A short gap keeps the stem legible between reference and bubble.
            let bubbleGap = InterfaceScale.metric(3)
            result.bubbleReferenceConnector = .init(
                stemX: stemX,
                fromY: verticalOffset + height + bubbleGap + 1,
                cornerY: verticalOffset + height * 0.46,
                toX: connectorEndX
            )
            verticalOffset += height + bubbleGap
        }

        private mutating func appendAuthorHeader() {
            let presentation = model?.authorPresentation(for: message)
            let author = presentation?.user ?? message.author
            result.authorPrimaryGuild = author.primaryGuild
            let authorFont = ProfileNameFontLoader.shared.resolvedFont(for: author, fallback: metrics.authorFont)
            let showsRoleIndicator = model?.accessibilitySettings.roleColorDisplay == .nextToNames
                && presentation?.roleColorHex != nil
            let indicatorWidth: CGFloat = showsRoleIndicator ? InterfaceScale.metric(14) : 0
            let availableWidth = max(0, ordinaryContentWidth - indicatorWidth)
            let timestamp = NativeTimelineTimestamp.headerText(
                for: message.timestamp, settings: model?.interfaceSettings ?? .defaults
            )
            let timestampWidth = NativeTimelineRowLayout.measuredTextWidth(timestamp, font: metrics.timestampFont)
            // Keep the adjacent controls visible while long decorative names
            // truncate. At narrow widths the tag is omitted before the name.
            let timestampReserve = min(timestampWidth, availableWidth / 3) + 7
            let naturalBotWidth = author.isBot ? NativeAppBadgePresentation.width : 0
            let botWidth = availableWidth >= naturalBotWidth + 7 + 12 ? naturalBotWidth : 0
            let botReserve = botWidth > 0 ? botWidth + 7 : 0
            let tag = author.primaryGuild.flatMap { NativeServerTagPresentation(identity: $0) }?
                .fitting(maximumWidth: availableWidth - botReserve - timestampReserve - 32 - 7)
            let tagReserve = tag.map { $0.width + 7 } ?? 0
            let authorText = NativeIdentityTextPresentation(
                author.displayName, font: authorFont,
                maximumWidth: max(0, availableWidth - botReserve - tagReserve - timestampReserve)
            )
            let headerHeight = tag == nil && botWidth == 0
                ? MessageRowLayoutMetrics.authorLineHeight : ServerTagAppearance.height
            result.authorText = authorText
            result.authorFrame = CGRect(
                x: contentX + indicatorWidth, y: verticalOffset,
                width: authorText.width, height: headerHeight
            )
            var headerX = contentX + indicatorWidth + authorText.width
            if botWidth > 0 {
                headerX += InterfaceScale.metric(7)
                result.botBadgeFrame = CGRect(
                    x: headerX, y: verticalOffset,
                    width: botWidth, height: ServerTagAppearance.height
                )
                headerX += botWidth
            }
            if let tag {
                headerX += InterfaceScale.metric(7)
                result.serverTagRegion = .init(
                    frame: CGRect(x: headerX, y: verticalOffset, width: tag.width, height: headerHeight),
                    presentation: tag
                )
                headerX += tag.width
            }
            headerX += InterfaceScale.metric(7)
            let timestampText = NativeIdentityTextPresentation(
                timestamp, font: metrics.timestampFont,
                maximumWidth: max(0, contentX + contentWidth - headerX)
            )
            result.timestampText = timestampText
            result.timestampFrame = CGRect(
                x: headerX, y: verticalOffset, width: timestampText.width, height: headerHeight
            )
            headerX += timestampText.width
            if message.editedTimestamp != nil {
                headerX += InterfaceScale.metric(7)
                let editedText = NativeIdentityTextPresentation(
                    "(edited)", font: metrics.editedFont,
                    maximumWidth: max(0, contentX + contentWidth - headerX)
                )
                result.editedText = editedText
                result.editedFrame = CGRect(
                    x: headerX, y: verticalOffset, width: editedText.width, height: headerHeight
                )
            }
        }

        private mutating func appendTextAndPoll() {
            bubbleStartY = verticalOffset
            if usesBubbles {
                verticalOffset += InterfaceScale.metric(8)
            }

            if message.forwardedSnapshot != nil {
                result.forwardedHeaderFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: contentWidth,
                    height: InterfaceScale.metric(18)
                )
                forwardedBarStartY = verticalOffset
                verticalOffset += InterfaceScale.metric(22)
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
                    let font = NSFont.interfaceSystemFont(ofSize: InterfaceTypographyMetrics.messageTextSize)
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

            if let translationPresentation {
                if hasRichContent { verticalOffset += 4 }
                let region = NativeTimelineRowLayout.translation(
                    translationPresentation, messageID: message.id, isOutgoingBubble: isOutgoingBubble,
                    origin: CGPoint(x: contentX, y: verticalOffset), width: contentWidth
                )
                result.translationRegion = region
                verticalOffset = region.frame.maxY
                hasRichContent = true
            }

            if message.pollResultSummary != nil {
                if hasRichContent { verticalOffset += InterfaceScale.metric(8) }
                result.pollResultFrame = CGRect(x: contentX, y: verticalOffset, width: min(InterfaceScale.metric(440), contentWidth), height: InterfaceScale.metric(66))
                verticalOffset += InterfaceScale.metric(66)
                hasRichContent = true
            }
            if let poll = message.poll {
                if hasRichContent { verticalOffset += InterfaceScale.metric(6) }
                let layout = NativeTimelinePollLayout(poll: poll, x: contentX, y: verticalOffset, width: contentWidth)
                result.pollLayout = layout
                verticalOffset = layout.frame.maxY
                hasRichContent = true
            }
        }

        private mutating func appendLinkedImages() {
            if !contentPresentation.linkedImages.isEmpty {
                if hasRichContent {
                    verticalOffset += InterfaceScale.metric(6)
                }
                let plan = InlineWrappingLayoutPlan.frames(
                    sizes: contentPresentation.linkedImages.map { $0.displaySize },
                    maximumWidth: inlineMediaMaximumWidth,
                    horizontalSpacing: InterfaceScale.metric(4),
                    verticalSpacing: InterfaceScale.metric(4)
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
            if !usesComponentsV2, (message.forwardedSnapshot?.flags ?? message.flags).contains(.voiceMessage) {
                let style: NativeTimelineVoiceMessageRegion.Style =
                    usesBubbles ? (isOutgoingBubble ? .outgoingBubble : .incomingBubble) : .plain
                let voiceY = verticalOffset + (hasRichContent ? InterfaceScale.metric(8) : 0)
                if let region = NativeTimelineVoiceMessageRegion.make(
                    message: message,
                    origin: CGPoint(x: contentX, y: voiceY),
                    maximumWidth: inlineMediaMaximumWidth,
                    style: style
                ) {
                    result.voiceMessageRegion = region
                    verticalOffset = region.frame.maxY
                    hasRichContent = true
                    return
                }
            }
            if !usesComponentsV2, !message.attachments.isEmpty {
                if hasRichContent {
                    verticalOffset += InterfaceScale.metric(8)
                }
                let galleryWidth = min(InterfaceScale.metric(500), max(InterfaceScale.metric(180), inlineMediaMaximumWidth))
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
                    spacing: InterfaceScale.metric(4)
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
                        origin: CGPoint(x: contentX, y: verticalOffset + (hasRichContent ? InterfaceScale.metric(8) : 0)),
                        maximumWidth: inlineMediaMaximumWidth, model: model,
                        isOwnMessage: message.author.id == model?.snapshot?.currentUser.id)
                    result.inviteRegions.append(region)
                    verticalOffset = region.frame.maxY
                    hasRichContent = true
                }
            }
            if !usesComponentsV2 {
                for (index, deepLink) in row.sakuraCordDeepLinks.enumerated() {
                    let deepLinkY = verticalOffset + (hasRichContent ? InterfaceScale.metric(8) : 0)
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
                    let embedY = verticalOffset + (hasRichContent ? InterfaceScale.metric(8) : 0)
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

            let componentY = verticalOffset + (hasRichContent ? InterfaceScale.metric(8) : 0)
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
                    verticalOffset += InterfaceScale.metric(8)
                }
                let size = min(contentWidth, InterfaceScale.metric(112))
                let gap = InterfaceScale.metric(8)
                var stickerX = contentX
                var rowHeight: CGFloat = 0
                for _ in message.stickers {
                    if stickerX + size > contentX + contentWidth,
                       stickerX > contentX
                    {
                        stickerX = contentX
                        verticalOffset += rowHeight + gap
                        rowHeight = 0
                    }
                    result.stickerFrames.append(
                        CGRect(x: stickerX, y: verticalOffset, width: size, height: size)
                    )
                    stickerX += size + gap
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
                if hasRichContent { verticalOffset += InterfaceScale.metric(7) }
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
                let sourceFont = NSFont.interfaceSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                    weight: .medium
                )
                let iconWidth: CGFloat = sameGuild ? 0 : InterfaceScale.metric(24)
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
                        height: InterfaceScale.metric(22)
                    ),
                    label: sourceLabel,
                    iconURL: sameGuild ? nil : sourceGuild?.iconURL,
                    channelID: sourceChannelID,
                    guildID: reference.guildID,
                    messageID: reference.messageID,
                    timestamp: snapshot.timestamp
                )
                verticalOffset += InterfaceScale.metric(22)
                hasRichContent = true
            }
            if let forwardedBarStartY {
                result.forwardedBarFrame = CGRect(
                    x: contentX - InterfaceScale.metric(11),
                    y: forwardedBarStartY,
                    width: InterfaceScale.metric(3),
                    height: max(InterfaceScale.metric(18), verticalOffset - forwardedBarStartY)
                )
            }

        }

        private mutating func appendThreadAndBubble() {
            if message.thread != nil {
                if hasRichContent {
                    verticalOffset += InterfaceScale.metric(8)
                }
                result.threadFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: min(contentWidth, InterfaceScale.metric(440)),
                    height: NativeTimelineThreadCard.height
                )
                verticalOffset += NativeTimelineThreadCard.height
                hasRichContent = true
            }

            if usesBubbles, hasRichContent {
                verticalOffset += InterfaceScale.metric(8)
                let region = NativeTimelineBubbleLayout.region(
                    contentX: contentX,
                    contentWidth: contentWidth,
                    minY: bubbleStartY,
                    maxY: verticalOffset,
                    isOutgoing: isOutgoingBubble,
                    showsTail: row.endsGroup,
                    isBare: showsBareContent
                )
                result.bubbleRegion = region
                result.avatarFrame = NativeTimelineBubbleLayout.bottomAlignedAvatarFrame(result.avatarFrame, to: region)
            }

        }

        /// Emoji-only text and stickers read as standalone content, as in
        /// Messages, so their bubble draws no fill.
        private var showsBareContent: Bool {
            let isEmojiOnlyText = result.attributedContent == nil
                || row.textPlan.preparedText?.isEmojiOnly == true
            return isEmojiOnlyText
                && (result.contentFrame != nil || !result.stickerFrames.isEmpty)
                && result.linkedImageRegions.isEmpty && result.attachmentRegions.isEmpty
                && result.voiceMessageRegion == nil
                && result.embedRegions.isEmpty && result.componentLayouts.isEmpty
                && result.inviteRegions.isEmpty && result.sakuraCordDeepLinkRegions.isEmpty
                && result.translationRegion == nil && result.pollLayout == nil
                && result.pollResultFrame == nil && result.threadFrame == nil
                && result.forwardedHeaderFrame == nil && translationPresentation == nil
                && !message.flags.contains(.loading)
        }

        private mutating func appendReactions() {
            if !presentedReactions.isEmpty {
                if hasRichContent {
                    verticalOffset += InterfaceScale.metric(4)
                }
                let sizes = presentedReactions.map(reactionSize)
                    + [CGSize(
                        width: ReactionActionMenuPresentation.inline.width,
                        height: MessageReactionMetrics.pillHeight
                    )]
                // Reactions sit below the bubble, so a short bubble must not
                // narrow them. They wrap against the bubble column instead.
                let rowWidth = usesBubbles
                    ? max(contentWidth, min(
                        NativeTimelineBubbleLayout.maximumContentWidth(availableWidth: width),
                        isOutgoingBubble ? contentX + contentWidth - horizontalInset : ordinaryContentWidth
                    ))
                    : contentWidth
                let rowX = isOutgoingBubble ? contentX + contentWidth - rowWidth : contentX
                let wrapping = InlineWrappingLayoutPlan.frames(
                    sizes: sizes,
                    maximumWidth: rowWidth,
                    horizontalSpacing: MessageReactionMetrics.horizontalSpacing,
                    verticalSpacing: MessageReactionMetrics.verticalSpacing
                )
                // Each line of reactions follows an outgoing bubble to the
                // trailing edge.
                let lineEnds = wrapping.frames.reduce(into: [CGFloat: CGFloat]()) { ends, frame in
                    ends[frame.minY] = max(ends[frame.minY] ?? 0, frame.maxX)
                }
                let frames = wrapping.frames.map { frame in
                    let lineShift = isOutgoingBubble
                        ? max(0, rowWidth - (lineEnds[frame.minY] ?? frame.maxX))
                        : 0
                    return frame.offsetBy(dx: rowX + lineShift, dy: verticalOffset)
                }
                result.reactionRegions = zip(
                    presentedReactions,
                    frames.prefix(presentedReactions.count)
                ).map { reaction, frame in
                    NativeTimelineRowLayout.reactionRegion(reaction, frame: frame)
                }
                result.addReactionFrame = frames.last
                verticalOffset += wrapping.size.height
            }

        }

        private mutating func appendDeliveryState() {
            if message.flags.contains(.ephemeral) {
                if hasRichContent || !presentedReactions.isEmpty {
                    verticalOffset += InterfaceScale.metric(4)
                }
                result.ephemeralRegion = NativeTimelineRowLayout.ephemeral(
                    origin: CGPoint(x: contentX, y: verticalOffset),
                    maximumWidth: contentWidth
                )
                verticalOffset += InterfaceScale.metric(15)
            }

            if message.outboxState == .failed {
                if hasRichContent
                    || !presentedReactions.isEmpty
                    || result.ephemeralRegion != nil
                {
                    verticalOffset += InterfaceScale.metric(4)
                }
                result.failedFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: contentWidth,
                    height: InterfaceScale.metric(14)
                )
                verticalOffset += InterfaceScale.metric(14)
            }

            if row.pinnedAt != nil {
                if hasRichContent || !presentedReactions.isEmpty || result.ephemeralRegion != nil {
                    verticalOffset += InterfaceScale.metric(6)
                }
                result.pinnedAtFrame = CGRect(
                    x: contentX,
                    y: verticalOffset,
                    width: contentWidth,
                    height: InterfaceScale.metric(16)
                )
                verticalOffset += InterfaceScale.metric(16)
            }

        }

        private mutating func finish() {
            let visibleContentMaxY = max(
                verticalOffset,
                result.avatarFrame?.maxY ?? 0,
                result.authorFrame?.maxY ?? 0
            )
            let searchBottomInset: CGFloat = searchContext == nil ? 0 : InterfaceScale.metric(8)
            let rowHeight = ceil(
                max(
                    visibleContentMaxY + highlightInsets.bottom,
                    highlightMinY
                        + highlightInsets.top
                        + (showsIncomingAvatar && !usesBubbles
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
