import AppKit
import CoreText
import MessageRendering
import SakuraCordModels

enum NativeTimelineEmbedLayout {
    private struct PreparedField {
        let field: MessageEmbedField
        let name: NativeTimelineAttributedTextBox
        let value: NativeTimelineAttributedTextBox
    }

    private struct Builder {
        let embed: MessageEmbed
        let mediaCount: Int
        let message: Message
        let source: AppModel?
        let attachments: [Attachment]
        let origin: CGPoint
        let maximumWidth: CGFloat
        let integratesWithBubble: Bool
        let drawsTopSeparator: Bool

        private var mainMedia: MessageEmbedMedia? {
            guard var media = embed.video ?? embed.image else { return nil }
            if embed.video != nil {
                media.width = media.width ?? embed.thumbnail?.width ?? embed.image?.width
                media.height = media.height ?? embed.thumbnail?.height ?? embed.image?.height
            }
            return media
        }

        /// The frame follows the video's shape only when its size is known.
        /// A differently shaped poster (YouTube Shorts ship a padded 16:9
        /// thumbnail) is then cropped; a fallback 16:9 frame fits it instead.
        private var mediaPosterFillsFrame: Bool {
            guard embed.video != nil, let media = mainMedia else { return false }
            return NativeTimelineEmbedLayout.knownSize(of: media) != nil
        }

        private var mediaPreviewURL: URL? {
            guard embed.video != nil else { return nil }
            if let preview = embed.thumbnail ?? embed.image,
               let url = NativeTimelineEmbedLayout.resolvedURL(preview, attachments: attachments) { return url }
            return DiscordVideoPosterURL.url(
                proxyURL: embed.video?.proxyURL, width: mainMedia?.width, height: mainMedia?.height,
                maximumPixelDimension: 1_024
            )
        }

        /// A video previews the poster it loads, falling back to its own hash.
        private var mediaPlaceholder: NativeTimelineMediaPlaceholder? {
            let poster = embed.video == nil ? nil : embed.thumbnail ?? embed.image
            return NativeTimelineMediaPlaceholder(poster) ?? NativeTimelineMediaPlaceholder(mainMedia)
        }

        var region: NativeTimelineRowLayout.EmbedRegion? {
            let isYouTube = embed.video?.url.flatMap(YouTubeEmbedPlayback.init(url:)) != nil
            let maximumWidth = min(self.maximumWidth, isYouTube ? InterfaceScale.metric(432) : self.maximumWidth)
            switch MessageEmbedPresentation.kind(for: embed) {
            case .hidden:
                return nil
            case .bareMedia:
                guard let media = mainMedia,
                      let url = NativeTimelineEmbedLayout.resolvedURL(media, attachments: attachments)
                else { return nil }
                let size = mediaSize(media, maximumWidth: min(maximumWidth, InterfaceScale.metric(500)))
                let frame = CGRect(origin: origin, size: size)
                return .init(
                    embedID: embed.id,
                    kind: .bareMedia,
                    frame: frame,
                    textRegions: [],
                    imageRegions: [],
                    mediaFrame: frame,
                    mediaURL: url,
                    mediaPreviewURL: mediaPreviewURL,
                    mediaPlaceholder: mediaPlaceholder,
                    mediaIsVideo: embed.video != nil,
                    mediaAutoplaysInline: embed.isGIFV,
                    mediaPosterFillsFrame: mediaPosterFillsFrame,
                    accentColor: nil,
                    drawsTopSeparator: false
                )
            case .card:
                let cardPadding: CGFloat = integratesWithBubble ? 0 : 12
                let stripeWidth: CGFloat = integratesWithBubble ? 0 : InterfaceScale.metric(4)
                let innerChrome = stripeWidth + cardPadding * 2
                let maximumContentWidth = max(InterfaceScale.metric(80), maximumWidth - innerChrome)
                let author = embed.author.map {
                    NativeTimelineAttributedTextBox.plain(
                        $0.name,
                        font: .messageSystemFont(ofSize: 14, weight: .medium),
                        color: .labelColor,
                        link: $0.url
                    )
                }
                let title = embed.title.map {
                    NativeTimelineAttributedTextBox.plain(
                        $0,
                        font: .messageSystemFont(ofSize: 14, weight: .semibold),
                        color: embed.url == nil ? .labelColor : .linkColor,
                        link: embed.url
                    )
                }
                let description = (["image", "video", "gifv"].contains(embed.type?.lowercased() ?? "") ? nil : embed.description).map {
                    NativeTimelineEmbedLayout.resolvedTextBox(
                        prepared: RichMessageAttributedText.prepare(source: $0),
                        scope: "description",
                        emojiSize: InterfaceTypographyMetrics.message(18),
                        fontSizeAdjustment: -1,
                        embed: embed,
                        message: message,
                        source: source
                    )
                }
                let fields = embed.fields.enumerated().map { index, field in
                    PreparedField(
                        field: field,
                        name: NativeTimelineAttributedTextBox.plain(
                            field.name,
                            font: .messageSystemFont(ofSize: 11, weight: .bold),
                            color: .labelColor
                        ),
                        value: NativeTimelineEmbedLayout.resolvedTextBox(
                            prepared: RichMessageAttributedText.prepare(
                                source: field.value
                            ),
                            scope: "field:\(index)",
                            emojiSize: InterfaceTypographyMetrics.message(16),
                            embed: embed,
                            message: message,
                            source: source
                        )
                    )
                }
                let provider = embed.provider?.name.map {
                    NativeTimelineAttributedTextBox.plain(
                        $0,
                        font: .messageSystemFont(ofSize: 11),
                        color: .secondaryLabelColor,
                        link: embed.provider?.url
                    )
                }
                let footerText = NativeTimelineEmbedLayout.footerText(
                    footer: embed.footer,
                    timestamp: embed.timestamp,
                    settings: source?.interfaceSettings ?? .defaults
                )
                let footer = footerText.map {
                    NativeTimelineAttributedTextBox.plain(
                        $0,
                        font: .messageSystemFont(ofSize: 11),
                        color: .secondaryLabelColor
                    )
                }

                let showsSideThumbnail = embed.video == nil && (embed.image == nil || embed.type?.lowercased() == "rich")
                let thumbnailURL = showsSideThumbnail ? embed.thumbnail.flatMap {
                    NativeTimelineEmbedLayout.resolvedURL($0, attachments: attachments)
                } : nil
                let thumbnailSize: CGFloat = thumbnailURL == nil ? 0 : InterfaceScale.metric(80)
                // Text and thumbnail keep 12 points of spacing on each side of the
                // collapsed gap between them; inside a bubble only one applies.
                let thumbnailAllowance: CGFloat =
                    thumbnailSize > 0
                        ? thumbnailSize + (integratesWithBubble ? 12 : 24)
                        : 0

                let naturalTextWidth = NativeTimelineEmbedLayout.textColumnIdealWidth(
                    author: author,
                    authorHasIcon:
                        (embed.author?.proxyIconURL ?? embed.author?.iconURL) != nil,
                    title: title,
                    description: description,
                    fields: fields,
                    provider: provider
                )
                let naturalTopWidth = naturalTextWidth + thumbnailAllowance
                let mainMedia = self.mainMedia
                let naturalMediaSize = mainMedia.map {
                    mediaSize($0, maximumWidth: maximumContentWidth)
                }
                let naturalFooterWidth = footer.map {
                    NativeTimelineEmbedLayout.idealWidth($0)
                        + ((embed.footer?.proxyIconURL ?? embed.footer?.iconURL) == nil
                            ? 0 : 23)
                } ?? 0
                let naturalContentWidth = max(
                    naturalTopWidth,
                    naturalMediaSize?.width ?? 0,
                    naturalFooterWidth,
                    92
                )
                let width = integratesWithBubble
                    ? maximumWidth
                    : min(
                        maximumWidth,
                        max(InterfaceScale.metric(120), ceil(naturalContentWidth + innerChrome))
                    )
                let contentX = origin.x + stripeWidth + cardPadding
                let contentWidth = max(InterfaceScale.metric(80), width - innerChrome)
                let textWidth = max(InterfaceScale.metric(40), contentWidth - thumbnailAllowance)
                var textRegions: [NativeTimelineRowLayout.EmbedRegion.TextRegion] = []
                var imageRegions: [NativeTimelineRowLayout.EmbedRegion.ImageRegion] = []

                var textY = origin.y + cardPadding
                var hasTextSection = false
                func appendText(
                    _ box: NativeTimelineAttributedTextBox?,
                    x horizontalPosition: CGFloat = contentX,
                    width: CGFloat = textWidth,
                    spacing: CGFloat = 7,
                    isSelectable: Bool = false
                ) {
                    guard let box else { return }
                    if hasTextSection {
                        textY += spacing
                    }
                    textY += NativeTimelineMarkdownChromeMetrics.leadingVisualInset(in: box.value)
                    let height = NativeTimelineEmbedLayout.measuredHeight(box, width: width)
                    textRegions.append(
                        .init(
                            frame: CGRect(
                                x: horizontalPosition,
                                y: textY,
                                width: width,
                                height: height
                            ),
                            text: box,
                            isSelectable: isSelectable
                        )
                    )
                    textY += height
                    hasTextSection = true
                }

                appendText(provider)
                if let author {
                    if let iconURL = embed.author?.proxyIconURL
                        ?? embed.author?.iconURL
                    {
                        if hasTextSection {
                            textY += InterfaceScale.metric(7)
                        }
                        let authorWidth = max(InterfaceScale.metric(20), textWidth - InterfaceScale.metric(28))
                        let authorHeight = NativeTimelineEmbedLayout.measuredHeight(author, width: authorWidth)
                        let lineHeight = max(InterfaceScale.metric(22), authorHeight)
                        imageRegions.append(
                            .init(
                                frame: CGRect(
                                    x: contentX,
                                    y: textY + (lineHeight - InterfaceScale.metric(22)) / 2,
                                    width: InterfaceScale.metric(22),
                                    height: InterfaceScale.metric(22)
                                ),
                                url: iconURL,
                                cornerRadius: InterfaceScale.metric(11),
                                fallbackSystemImage: "person.crop.circle",
                                maximumPixelDimension: 64,
                                placeholder: nil
                            )
                        )
                        textRegions.append(
                            .init(
                                frame: CGRect(
                                    x: contentX + InterfaceScale.metric(28),
                                    y: textY + (lineHeight - authorHeight) / 2,
                                    width: authorWidth,
                                    height: authorHeight
                                ),
                                text: author,
                                isSelectable: false
                            )
                        )
                        textY += lineHeight
                        hasTextSection = true
                    } else {
                        appendText(author)
                    }
                }
                appendText(title)
                appendText(description, isSelectable: true)

                if !fields.isEmpty {
                    if hasTextSection {
                        textY += InterfaceScale.metric(7)
                    }
                    NativeTimelineEmbedLayout.layoutFields(
                        fields,
                        x: contentX,
                        y: &textY,
                        width: textWidth,
                        into: &textRegions
                    )
                    hasTextSection = true
                }

                let textHeight = hasTextSection
                    ? textY - (origin.y + cardPadding)
                    : 0
                let topHeight = max(textHeight, thumbnailSize)

                if let thumbnailURL {
                    imageRegions.append(
                        .init(
                            frame: CGRect(
                                x: origin.x + width - cardPadding - thumbnailSize,
                                y: origin.y + cardPadding,
                                width: thumbnailSize,
                                height: thumbnailSize
                            ),
                            url: thumbnailURL,
                            cornerRadius: InterfaceScale.metric(4),
                            fallbackSystemImage: "photo",
                            maximumPixelDimension: 256,
                            placeholder: .init(embed.thumbnail)
                        )
                    )
                }

                let mediaURL = mainMedia.flatMap {
                    NativeTimelineEmbedLayout.resolvedURL($0, attachments: attachments)
                }
                let mediaSize = mainMedia.flatMap { media -> CGSize? in
                    guard mediaURL != nil else { return nil }
                    return self.mediaSize(media, maximumWidth: min(contentWidth, InterfaceScale.metric(500)))
                }
                let mediaGap: CGFloat =
                    mediaSize == nil ? 0 : (topHeight > 0 ? InterfaceScale.metric(9) : 0)
                let mediaFrame = mediaSize.map {
                    CGRect(
                        x: contentX,
                        y: origin.y + cardPadding + topHeight + mediaGap,
                        width: $0.width,
                        height: $0.height
                    )
                }

                var bottomY =
                    origin.y + cardPadding + topHeight + mediaGap
                    + (mediaSize?.height ?? 0)
                if let footer {
                    if topHeight > 0 || mediaSize != nil {
                        bottomY += InterfaceScale.metric(9)
                    }
                    let footerIconURL =
                        embed.footer?.proxyIconURL ?? embed.footer?.iconURL
                    let footerTextX = contentX + (footerIconURL == nil ? 0 : InterfaceScale.metric(23))
                    let footerTextWidth = max(
                        30,
                        contentWidth - (footerIconURL == nil ? 0 : InterfaceScale.metric(23))
                    )
                    let footerTextHeight = NativeTimelineEmbedLayout.measuredHeight(
                        footer,
                        width: footerTextWidth
                    )
                    let footerHeight = max(
                        footerTextHeight,
                        footerIconURL == nil ? 0 : 18
                    )
                    if let footerIconURL {
                        imageRegions.append(
                            .init(
                                frame: CGRect(
                                    x: contentX,
                                    y: bottomY + (footerHeight - InterfaceScale.metric(18)) / 2,
                                    width: InterfaceScale.metric(18),
                                    height: InterfaceScale.metric(18)
                                ),
                                url: footerIconURL,
                                cornerRadius: InterfaceScale.metric(9),
                                fallbackSystemImage: "photo.circle",
                                maximumPixelDimension: 64,
                                placeholder: nil
                            )
                        )
                    }
                    textRegions.append(
                        .init(
                            frame: CGRect(
                                x: footerTextX,
                                y: bottomY + (footerHeight - footerTextHeight) / 2,
                                width: footerTextWidth,
                                height: footerTextHeight
                            ),
                            text: footer,
                            isSelectable: false
                        )
                    )
                    bottomY += footerHeight
                }
                let cardHeight = bottomY - origin.y + cardPadding
                let frame = CGRect(
                    x: origin.x,
                    y: origin.y,
                    width: width,
                    height: max(integratesWithBubble ? InterfaceScale.metric(18) : InterfaceScale.metric(58), cardHeight)
                )
                return .init(
                    embedID: embed.id,
                    kind: integratesWithBubble
                        ? .bubbleIntegratedCard
                        : .card,
                    frame: frame,
                    textRegions: textRegions,
                    imageRegions: imageRegions,
                    mediaFrame: mediaFrame,
                    mediaURL: mediaURL,
                    mediaPreviewURL: mediaPreviewURL,
                    mediaPlaceholder: mediaPlaceholder,
                    mediaIsVideo: embed.video != nil,
                    mediaAutoplaysInline: false,
                    mediaPosterFillsFrame: mediaPosterFillsFrame,
                    accentColor: embed.color,
                    drawsTopSeparator:
                        integratesWithBubble && drawsTopSeparator
                )
            }
        }

        private func mediaSize(_ media: MessageEmbedMedia, maximumWidth: CGFloat) -> CGSize {
            if mediaCount > 1 {
                return NativeTimelineEmbedLayout.groupFrames(count: mediaCount, width: maximumWidth)
                    .reduce(CGRect.null) { $0.union($1) }.size
            }
            return NativeTimelineEmbedLayout.mediaSize(media, maximumWidth: maximumWidth)
        }
    }

    static func make(
        embed: MessageEmbed,
        message: Message,
        source: AppModel?,
        attachments: [Attachment],
        origin: CGPoint,
        maximumWidth: CGFloat,
        integratesWithBubble: Bool = false,
        drawsTopSeparator: Bool = false,
        mediaCount: Int = 1
    ) -> NativeTimelineRowLayout.EmbedRegion? {
        Builder(
            embed: embed,
            mediaCount: mediaCount,
            message: message,
            source: source,
            attachments: attachments,
            origin: origin,
            maximumWidth: maximumWidth,
            integratesWithBubble: integratesWithBubble,
            drawsTopSeparator: drawsTopSeparator
        ).region
    }

    static func makeGroup(
        embeds: [MessageEmbed],
        message: Message,
        source: AppModel?,
        origin: CGPoint,
        maximumWidth: CGFloat,
        integratesWithBubble: Bool,
        drawsTopSeparator: Bool
    ) -> [NativeTimelineRowLayout.EmbedRegion] {
        // Resolve before laying out so an unavailable image leaves no empty tile.
        let tiles = embeds.dropFirst().compactMap { embed in
            embed.image.flatMap { image in
                resolvedURL(image, attachments: message.attachments).map { (embed, image, $0) }
            }
        }
        guard var region = make(
            embed: embeds[0], message: message, source: source,
            attachments: message.attachments, origin: origin,
            maximumWidth: maximumWidth, integratesWithBubble: integratesWithBubble,
            drawsTopSeparator: drawsTopSeparator, mediaCount: tiles.count + 1
        )
        else { return [] }
        guard !tiles.isEmpty, let mediaFrame = region.mediaFrame else { return [region] }
        let frames = groupFrames(count: tiles.count + 1, width: mediaFrame.width)
            .map { $0.offsetBy(dx: mediaFrame.minX, dy: mediaFrame.minY) }
        // The leading region owns the full card and footer. Each image keeps
        // its embed identity for loading, animation, hit testing and accessibility.
        region.mediaFrame = frames[0]
        region.mediaFillsFrame = true
        return [region] + zip(tiles, frames.dropFirst()).map { tile, frame in
            let (embed, image, url) = tile
            return NativeTimelineRowLayout.EmbedRegion(
                embedID: embed.id, kind: .bareMedia, frame: frame,
                textRegions: [], imageRegions: [], mediaFrame: frame,
                mediaURL: url, mediaPreviewURL: nil, mediaPlaceholder: .init(image),
                mediaFillsFrame: true,
                mediaIsVideo: false, mediaAutoplaysInline: false,
                mediaPosterFillsFrame: false,
                accentColor: nil, drawsTopSeparator: false
            )
        }
    }

    /// A multi-image post's tiles: equal columns, so no image dominates.
    private static func groupFrames(count: Int, width: CGFloat) -> [CGRect] {
        MediaGalleryPlan.frames(
            count: count, width: width, aspectRatios: [],
            spacing: InterfaceScale.metric(4), equalWidthColumns: true
        )
    }

    static func resolvedTextBox(
        prepared: RichMessageAttributedText.Prepared,
        scope: String,
        emojiSize: CGFloat,
        fontSizeAdjustment: CGFloat = 0,
        embed: MessageEmbed,
        message: Message,
        source: AppModel?
    ) -> NativeTimelineAttributedTextBox {
        let mentions = MessageMentionResolver.presentations(for: prepared, model: source, message: message)
        let baseFontSize = InterfaceScale.fontSize(
            InterfaceTypographyMetrics.messageTextSize + fontSizeAdjustment
        )
        let emojiSize = InterfaceScale.metric(emojiSize)
        let key = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "embed:\(embed.id):\(scope)",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            presentations: mentions
        )
        return NativeTimelineResolvedTextCache.shared.box(for: key) {
            NativeTimelineAttributedTextBox(
                NativeTimelineCoreText.make(
                    prepared: prepared,
                    emojiSize: emojiSize,
                    baseFontSize: baseFontSize,
                    mentionPresentations: mentions
                ),
                layoutHeightAdjustment: 1
            )
        }
    }

    private static func textColumnIdealWidth(
        author: NativeTimelineAttributedTextBox?,
        authorHasIcon: Bool,
        title: NativeTimelineAttributedTextBox?,
        description: NativeTimelineAttributedTextBox?,
        fields: [PreparedField],
        provider: NativeTimelineAttributedTextBox?
    ) -> CGFloat {
        var width = max(
            author.map(idealWidth) ?? 0,
            title.map(idealWidth) ?? 0,
            description.map(idealWidth) ?? 0,
            provider.map(idealWidth) ?? 0
        )
        if author != nil, authorHasIcon {
            width = max(width, (author.map(idealWidth) ?? 0) + InterfaceScale.metric(28))
        }
        for row in fieldRows(fields) {
            if row.count == 1, row[0].field.isInline == false {
                width = max(
                    width,
                    max(idealWidth(row[0].name), idealWidth(row[0].value))
                )
            } else {
                let fieldsWidth = row.reduce(CGFloat.zero) {
                    $0 + max(idealWidth($1.name), idealWidth($1.value))
                }
                width = max(
                    width,
                    fieldsWidth + CGFloat(max(0, row.count - 1)) * 14
                )
            }
        }
        return width
    }

    private static func layoutFields(
        _ fields: [PreparedField],
        x horizontalPosition: CGFloat,
        y verticalOffset: inout CGFloat,
        width: CGFloat,
        into regions: inout [
            NativeTimelineRowLayout.EmbedRegion.TextRegion
        ]
    ) {
        let columnGap: CGFloat = InterfaceScale.metric(14)
        let rowGap: CGFloat = InterfaceScale.metric(8)
        let rows = fieldRows(fields)
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 {
                verticalOffset += rowGap
            }
            let inlineColumnCount = max(1, min(3, row.count))
            let columnWidth = max(
                20,
                (
                    width
                        - columnGap * CGFloat(inlineColumnCount - 1)
                ) / CGFloat(inlineColumnCount)
            )
            var rowHeight: CGFloat = 0
            for (columnIndex, field) in row.enumerated() {
                let spansAllColumns =
                    row.count == 1 && field.field.isInline == false
                let fieldWidth = spansAllColumns ? width : columnWidth
                let fieldX = spansAllColumns
                    ? horizontalPosition
                    : horizontalPosition + CGFloat(columnIndex) * (columnWidth + columnGap)
                let nameHeight = measuredHeight(
                    field.name,
                    width: fieldWidth
                )
                let valueInset = NativeTimelineMarkdownChromeMetrics.leadingVisualInset(in: field.value.value)
                let valueHeight = measuredHeight(
                    field.value,
                    width: fieldWidth
                )
                regions.append(
                    .init(
                        frame: CGRect(
                            x: fieldX,
                            y: verticalOffset,
                            width: fieldWidth,
                            height: nameHeight
                        ),
                        text: field.name,
                        isSelectable: false
                    )
                )
                regions.append(
                    .init(
                        frame: CGRect(
                            x: fieldX,
                            y: verticalOffset + nameHeight + InterfaceScale.metric(2) + valueInset,
                            width: fieldWidth,
                            height: valueHeight
                        ),
                        text: field.value,
                        isSelectable: true
                    )
                )
                rowHeight = max(rowHeight, nameHeight + 2 + valueInset + valueHeight)
            }
            verticalOffset += rowHeight
        }
    }

    private static func fieldRows(
        _ fields: [PreparedField]
    ) -> [[PreparedField]] {
        var rows: [[PreparedField]] = []
        var inline: [PreparedField] = []
        func flushInline() {
            while !inline.isEmpty {
                let count = min(3, inline.count)
                rows.append(Array(inline.prefix(count)))
                inline.removeFirst(count)
            }
        }
        for field in fields {
            if field.field.isInline {
                inline.append(field)
                if inline.count == 3 {
                    flushInline()
                }
            } else {
                flushInline()
                rows.append([field])
            }
        }
        flushInline()
        return rows
    }

    private static func footerText(
        footer: MessageEmbedFooter?,
        timestamp: Date?,
        settings: InterfaceSettingsSnapshot
    ) -> String? {
        var values: [String] = []
        if let footer {
            values.append(footer.text)
        }
        if let timestamp {
            // Today's time alone, "Yesterday at" the time, or the full date
            // and time when older, as Discord shows an embed timestamp.
            values.append(NativeTimelineTimestamp.headerText(for: timestamp, settings: settings))
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " • ")
    }

    static func idealWidth(
        _ box: NativeTimelineAttributedTextBox
    ) -> CGFloat {
        let width = NativeTimelineMarkdownChromeMetrics.fittedWidth(
            box.framesetter,
            value: box.value,
            maximumWidth: 10_000
        )
        return max(1, ceil(width))
    }

    private static func measuredHeight(
        _ box: NativeTimelineAttributedTextBox,
        width: CGFloat
    ) -> CGFloat {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            box.framesetter,
            CFRange(location: 0, length: box.value.length),
            nil,
            CGSize(width: max(1, width), height: 10_000),
            nil
        )
        // Rounding every CoreText leaf upward would make a rich embed
        // progressively taller across its title, description, field grid,
        // and footer, so each leaf rounds down.
        return max(
            1,
            floor(size.height) - box.layoutHeightAdjustment
                + NativeTimelineMarkdownChromeMetrics
                    .trailingVisualOverflow(in: box.value)
        )
    }

    /// The media's reported size, when both dimensions are positive. Without
    /// it, embed media is laid out in a fallback 16:9 frame.
    private static func knownSize(of media: MessageEmbedMedia) -> CGSize? {
        RichMediaItem.knownSize(width: media.width, height: media.height)
    }

    /// One media item framed as a single-item gallery; a side the media
    /// doesn't report falls back to 16:9's.
    private static func mediaSize(_ media: MessageEmbedMedia, maximumWidth: CGFloat) -> CGSize {
        MediaGalleryPlan.frames(
            count: 1,
            width: min(InterfaceScale.metric(500), max(InterfaceScale.metric(180), maximumWidth)),
            aspectRatios: [CGFloat(media.width ?? 16) / CGFloat(media.height ?? 9)],
            intrinsicSizes: knownSize(of: media).map { [$0] } ?? [],
            spacing: 0
        )[0].size
    }

    private static func resolvedURL(
        _ media: MessageEmbedMedia,
        attachments: [Attachment]
    ) -> URL? {
        let candidate = media.proxyURL ?? media.url
        guard let candidate else { return nil }
        guard candidate.scheme?.lowercased() == "attachment" else {
            return candidate
        }
        let filename = candidate.host ?? candidate.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return attachments.first { $0.filename == filename }
            .map { $0.proxyURL ?? $0.url }
    }

}
