import AppKit
import CoreText
import MessageRendering
import SakuraCordModels
import Synchronization

@MainActor
enum NativeTimelineTextPresentation {
    nonisolated struct Preparation: Sendable {
        let key: NativeTimelineResolvedTextCache.Key
        let prepared: RichMessageAttributedText.Prepared
        let emojiSize: CGFloat
        let baseFontSize: CGFloat
        let mentions: [String: MentionPresentation]
    }

    struct Value {
        let attributedContent: NSAttributedString?
        let framesetter: CTFramesetter
        let linkedImages: [LinkedImageReference]
    }

    static var empty: Value {
        Value(
            attributedContent: nil,
            framesetter: CTFramesetterCreateWithAttributedString(
                NSAttributedString()
            ),
            linkedImages: []
        )
    }

    static func make(
        message: Message,
        plan: NativeTimelineTextPlan,
        model: AppModel?
    ) -> Value {
        guard plan.preparedText != nil else {
            return Value(
                attributedContent: nil,
                framesetter: CTFramesetterCreateWithAttributedString(
                    NSAttributedString()
                ),
                linkedImages: plan.linkedImages
            )
        }

        if let preparedBox = plan.attributedText {
            return Value(
                attributedContent: preparedBox.value,
                framesetter: preparedBox.framesetter,
                linkedImages: plan.linkedImages
            )
        }

        guard let preparation = preparation(
            message: message,
            plan: plan,
            model: model
        ) else {
            return Value(
                attributedContent: nil,
                framesetter: CTFramesetterCreateWithAttributedString(
                    NSAttributedString()
                ),
                linkedImages: plan.linkedImages
            )
        }
        let box = resolvedBox(for: preparation)
        return Value(
            attributedContent: box.value,
            framesetter: box.framesetter,
            linkedImages: plan.linkedImages
        )
    }

    static func preparation(
        message: Message,
        plan: NativeTimelineTextPlan,
        model: AppModel?
    ) -> Preparation? {
        guard plan.attributedText == nil,
              let prepared = plan.preparedText
        else { return nil }
        let resolver = model.map { MessageMentionResolver(model: $0, message: message) }
        let mentions = prepared.tokens.reduce(into: [String: MentionPresentation]()) { values, token in
            guard case let .mention(mention) = token else { return }
            values[mention.rawToken] =
                resolver?.presentation(mention)
                ?? MentionPresentation.fallback(for: mention)
        }
        let emojiSize: CGFloat = prepared.isEmojiOnly ? 48 : 22
        let cacheKey = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "message",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: plan.baseFontSize,
            mentions: mentions.values.sorted {
                $0.rawToken < $1.rawToken
            }
        )
        return Preparation(
            key: cacheKey,
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: plan.baseFontSize,
            mentions: mentions
        )
    }

    @discardableResult
    nonisolated static func prewarm(
        _ preparation: Preparation
    ) -> NativeTimelineAttributedTextBox {
        resolvedBox(for: preparation)
    }

    private nonisolated static func resolvedBox(
        for preparation: Preparation
    ) -> NativeTimelineAttributedTextBox {
        NativeTimelineResolvedTextCache.shared.box(
            for: preparation.key
        ) {
            NativeTimelineAttributedTextBox(
                NativeTimelineCoreText.make(
                    prepared: preparation.prepared,
                    emojiSize: preparation.emojiSize,
                    baseFontSize: preparation.baseFontSize,
                    mentionPresentations: preparation.mentions
                )
            )
        }
    }
}

nonisolated final class NativeTimelineResolvedTextCache: Sendable {
    struct Key: Hashable, Sendable {
        let messageID: MessageID
        let scope: String
        let prepared: RichMessageAttributedText.Prepared
        let emojiSize: CGFloat
        let baseFontSize: CGFloat
        let mentions: [MentionPresentation]
    }

    static let shared = NativeTimelineResolvedTextCache()

    private struct State: Sendable {
        var entries: [Key: NativeTimelineAttributedTextBox] = [:]
        var insertionOrder: [Key] = []
        var evictionIndex = 0
    }

    private let entryLimit = 2_000
    private let state: Mutex<State>

    private init() {
        var initial = State()
        initial.entries.reserveCapacity(entryLimit)
        initial.insertionOrder.reserveCapacity(entryLimit + 512)
        state = Mutex(initial)
    }

    func box(
        for key: Key,
        make: () -> NativeTimelineAttributedTextBox
    ) -> NativeTimelineAttributedTextBox {
        if let cached = state.withLock({ $0.entries[key] }) {
            return cached
        }
        let box = make()
        return state.withLock { state in
            if let existing = state.entries[key] {
                return existing
            }
            state.entries[key] = box
            state.insertionOrder.append(key)
            while state.entries.count > entryLimit,
                  state.evictionIndex < state.insertionOrder.count
            {
                let oldest = state.insertionOrder[state.evictionIndex]
                state.evictionIndex += 1
                state.entries.removeValue(forKey: oldest)
            }
            if state.evictionIndex > 1_024,
               state.evictionIndex * 2 > state.insertionOrder.count
            {
                state.insertionOrder.removeFirst(state.evictionIndex)
                state.evictionIndex = 0
            }
            return box
        }
    }
}

nonisolated enum NativeTimelineCoreText {
    private static let runDelegateKey = NSAttributedString.Key(
        rawValue: kCTRunDelegateAttributeName as String
    )

    static func make(
        prepared: RichMessageAttributedText.Prepared,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        let resolvedBaseFontSize =
            prepared.isEmojiOnly
                ? emojiSize
                : baseFontSize ?? 15
        let baseFont = NSFont.systemFont(ofSize: resolvedBaseFontSize)
        let output = NSMutableAttributedString(
            attributedString: DiscordMarkdown.appKitAttributed(
                prepared.markdownPlan,
                baseFontSize: resolvedBaseFontSize
            )
        )
        let fullRange = NSRange(location: 0, length: output.length)
        let placeholderRanges = ranges(of: "\u{FFFC}", in: output.string)
        for (range, token) in zip(
            placeholderRanges.reversed(),
            prepared.tokens.reversed()
        ) {
            var inlineAttributes = output.attributes(
                at: range.location,
                effectiveRange: nil
            )
            let replacement: NSAttributedString
            switch token {
            case let .customEmoji(emoji):
                inlineAttributes[.discordEmojiToken] = emoji.rawToken
                replacement = inlineRun(
                    width: emojiSize,
                    height: emojiSize,
                    baselineOffset: ComposerEmojiAttributedText
                        .attachmentOriginY(font: baseFont, size: emojiSize),
                    attributes: inlineAttributes
                )
            case let .mention(mention):
                let presentation =
                    mentionPresentations[mention.rawToken]
                    ?? MentionPresentation.fallback(for: mention)
                let metrics = mentionMetrics(
                    presentation: presentation,
                    font: baseFont
                )
                inlineAttributes[.discordMentionToken] =
                    presentation.rawToken
                inlineAttributes[.nativeTimelineMention] =
                    NativeTimelineMentionBox(presentation)
                replacement = inlineRun(
                    width: metrics.width,
                    height: metrics.height,
                    baselineOffset: ComposerEmojiAttributedText
                        .attachmentOriginY(
                            font: baseFont,
                            size: metrics.height
                        ),
                    attributes: inlineAttributes
                )
            }
            output.replaceCharacters(in: range, with: replacement)
        }
        output.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            output.addAttributes(
                [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: 0,
                ],
                range: range
            )
        }
        normalizeParagraphMetrics(in: output)
        return output
    }

    private static func normalizeParagraphMetrics(
        in output: NSMutableAttributedString
    ) {
        guard output.length > 0 else { return }
        let source = output.string as NSString
        var location = 0
        while location < output.length {
            let paragraphRange = source.paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            var lineHeight: CGFloat = 0
            var containsInlineRun = false
            output.enumerateAttributes(
                in: paragraphRange,
                options: []
            ) { attributes, _, _ in
                if attributes[runDelegateKey] != nil {
                    containsInlineRun = true
                }
                guard let font = attributes[.font] as? NSFont else {
                    return
                }
                lineHeight = max(
                    lineHeight,
                    ceil(font.ascender - font.descender + font.leading)
                )
            }
            let existing = output.attribute(
                .paragraphStyle,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let style = (existing?.mutableCopy()
                as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            // NSTextView's usedRect follows the typographic line bounds and
            // does not count the shared markdown style's trailing point.
            // CoreText otherwise rounds up the font bounding box and counts
            // that point once per line.
            style.lineSpacing = 0
            if !containsInlineRun, lineHeight > 0 {
                style.minimumLineHeight = lineHeight
                style.maximumLineHeight = lineHeight
            }
            output.addAttribute(
                .paragraphStyle,
                value: style,
                range: paragraphRange
            )
            location = NSMaxRange(paragraphRange)
        }
    }

    private static func inlineRun(
        width: CGFloat,
        height: CGFloat,
        baselineOffset: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var attributes = attributes
        attributes[runDelegateKey] = NativeTimelineRunDelegate.make(
            width: width,
            height: height,
            baselineOffset: baselineOffset
        )
        return NSAttributedString(
            string: "\u{FFFC}",
            attributes: attributes
        )
    }

    private static func mentionMetrics(
        presentation: MentionPresentation,
        font: NSFont
    ) -> (width: CGFloat, height: CGFloat) {
        let labelFont = NSFont.systemFont(
            ofSize: font.pointSize,
            weight: .semibold
        )
        let labelWidth = ceil(
            (presentation.label as NSString).size(
                withAttributes: [.font: labelFont]
            ).width
        )
        let height = max(21, ceil(font.pointSize + 6))
        let showsAvatar = if case .user = presentation.target { true } else { false }
        let showsLeadingIcon = presentation.systemImage != nil
        let avatarSize = height - 6
        let iconSize = height - 7
        let width = ceil(
            12 + labelWidth
                + (showsAvatar ? avatarSize + 4 : 0)
                + (showsLeadingIcon ? iconSize + 4 : 0)
        )
        return (width, height)
    }

    private static func ranges(
        of value: String,
        in source: String
    ) -> [NSRange] {
        let source = source as NSString
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let range = source.range(
                of: value,
                options: [],
                range: searchRange
            )
            guard range.location != NSNotFound else { break }
            result.append(range)
            let nextLocation = NSMaxRange(range)
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }
        return result
    }
}

enum NativeTimelineEmbedLayout {
    private struct PreparedField {
        let field: MessageEmbedField
        let name: NativeTimelineAttributedTextBox
        let value: NativeTimelineAttributedTextBox
    }

    private struct Builder {
        let embed: MessageEmbed
        let message: Message
        let model: AppModel?
        let attachments: [Attachment]
        let origin: CGPoint
        let maximumWidth: CGFloat

        var region: NativeTimelineRowLayout.EmbedRegion? {
        switch MessageEmbedPresentation.kind(for: embed) {
        case .hidden:
            return nil
        case .bareMedia:
            guard let media = embed.image ?? embed.video,
                  let url = resolvedURL(media, attachments: attachments)
            else { return nil }
            let size = mediaSize(
                media,
                maximumWidth: min(maximumWidth, 500),
                maximumHeight: 350
            )
            let frame = CGRect(origin: origin, size: size)
            return .init(
                embedID: embed.id,
                kind: .bareMedia,
                frame: frame,
                textRegions: [],
                imageRegions: [],
                mediaFrame: frame,
                mediaURL: url,
                mediaIsVideo: embed.video != nil,
                mediaAutoplaysInline: embed.type?.lowercased() == "gifv",
                accentColor: nil
            )
        case .card:
            let cardPadding: CGFloat = 12
            let stripeWidth: CGFloat = 4
            let innerChrome = stripeWidth + cardPadding * 2
            let maximumContentWidth = max(80, maximumWidth - innerChrome)

            let author = embed.author.map {
                plainTextBox(
                    $0.name,
                    font: .systemFont(ofSize: 11, weight: .semibold),
                    color: $0.url == nil ? .labelColor : .linkColor,
                    link: $0.url
                )
            }
            let title = embed.title.map {
                plainTextBox(
                    $0,
                    font: .systemFont(ofSize: 13, weight: .semibold),
                    color: embed.url == nil ? .labelColor : .linkColor,
                    link: embed.url
                )
            }
            let description = embed.description.map {
                resolvedTextBox(
                    prepared: RichMessageAttributedText.prepare(source: $0),
                    scope: "description",
                    emojiSize: 18,
                    embed: embed,
                    message: message,
                    model: model
                )
            }
            let fields = embed.fields.enumerated().map { index, field in
                PreparedField(
                    field: field,
                    name: plainTextBox(
                        field.name,
                        font: .systemFont(ofSize: 11, weight: .bold),
                        color: .labelColor
                    ),
                    value: resolvedTextBox(
                        prepared: RichMessageAttributedText.prepare(
                            source: field.value
                        ),
                        scope: "field:\(index)",
                        emojiSize: 16,
                        embed: embed,
                        message: message,
                        model: model
                    )
                )
            }
            let provider = embed.provider?.name.map {
                plainTextBox(
                    $0,
                    font: .systemFont(ofSize: 11),
                    color: .secondaryLabelColor
                )
            }
            let footerText = footerText(
                footer: embed.footer,
                timestamp: embed.timestamp
            )
            let footer = footerText.map {
                plainTextBox(
                    $0,
                    font: .systemFont(ofSize: 11),
                    color: .secondaryLabelColor
                )
            }

            let thumbnailURL = embed.thumbnail.flatMap {
                resolvedURL($0, attachments: attachments)
            }
            let thumbnailSize: CGFloat = thumbnailURL == nil ? 0 : 80
            // The legacy HStack contains text, a zero-minimum Spacer, and the
            // thumbnail. SwiftUI applies its 12-point spacing on both sides
            // of that spacer even when the spacer collapses to zero.
            let thumbnailAllowance: CGFloat =
                thumbnailSize > 0 ? thumbnailSize + 24 : 0

            let naturalTextWidth = textColumnIdealWidth(
                author: author,
                authorHasIcon:
                    (embed.author?.proxyIconURL ?? embed.author?.iconURL) != nil,
                title: title,
                description: description,
                fields: fields,
                provider: provider
            )
            let naturalTopWidth = naturalTextWidth + thumbnailAllowance
            let mainMedia = embed.image ?? embed.video
            let naturalMediaSize = mainMedia.map {
                mediaSize(
                    $0,
                    maximumWidth: maximumContentWidth,
                    maximumHeight: 350
                )
            }
            let naturalFooterWidth = footer.map {
                idealWidth($0)
                    + ((embed.footer?.proxyIconURL ?? embed.footer?.iconURL) == nil
                        ? 0 : 23)
            } ?? 0
            let naturalContentWidth = max(
                naturalTopWidth,
                naturalMediaSize?.width ?? 0,
                naturalFooterWidth,
                92
            )
            let width = min(
                maximumWidth,
                max(120, ceil(naturalContentWidth + innerChrome))
            )
            let contentX = origin.x + stripeWidth + cardPadding
            let contentWidth = max(80, width - innerChrome)
            let textWidth = max(40, contentWidth - thumbnailAllowance)
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
                let height = measuredHeight(box, width: width)
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

            if let author {
                if let iconURL = embed.author?.proxyIconURL
                    ?? embed.author?.iconURL
                {
                    if hasTextSection {
                        textY += 7
                    }
                    let lineHeight = max(20, measuredHeight(
                        author,
                        width: max(20, textWidth - 26)
                    ))
                    imageRegions.append(
                        .init(
                            frame: CGRect(
                                x: contentX,
                                y: textY + (lineHeight - 20) / 2,
                                width: 20,
                                height: 20
                            ),
                            url: iconURL,
                            cornerRadius: 10,
                            fallbackSystemImage: "person.crop.circle",
                            maximumPixelDimension: 64
                        )
                    )
                    let authorHeight = measuredHeight(
                        author,
                        width: max(20, textWidth - 26)
                    )
                    textRegions.append(
                        .init(
                            frame: CGRect(
                                x: contentX + 26,
                                y: textY + (lineHeight - authorHeight) / 2,
                                width: max(20, textWidth - 26),
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
                    textY += 7
                }
                layoutFields(
                    fields,
                    x: contentX,
                    y: &textY,
                    width: textWidth,
                    into: &textRegions
                )
                hasTextSection = true
            }
            appendText(provider)

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
                        cornerRadius: 6,
                        fallbackSystemImage: "photo",
                        maximumPixelDimension: 256
                    )
                )
            }

            let mediaURL = mainMedia.flatMap {
                resolvedURL($0, attachments: attachments)
            }
            let mediaSize = mainMedia.flatMap { media -> CGSize? in
                guard mediaURL != nil else { return nil }
                return self.mediaSize(
                    media,
                    maximumWidth: min(contentWidth, 500),
                    maximumHeight: 350
                )
            }
            let mediaGap: CGFloat =
                mediaSize == nil ? 0 : (topHeight > 0 ? 9 : 0)
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
                    bottomY += 9
                }
                let footerIconURL =
                    embed.footer?.proxyIconURL ?? embed.footer?.iconURL
                let footerTextX = contentX + (footerIconURL == nil ? 0 : 23)
                let footerTextWidth = max(
                    30,
                    contentWidth - (footerIconURL == nil ? 0 : 23)
                )
                let footerTextHeight = measuredHeight(
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
                                y: bottomY + (footerHeight - 18) / 2,
                                width: 18,
                                height: 18
                            ),
                            url: footerIconURL,
                            cornerRadius: 9,
                            fallbackSystemImage: "photo.circle",
                            maximumPixelDimension: 64
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
                height: max(58, cardHeight)
            )
            return .init(
                embedID: embed.id,
                kind: .card,
                frame: frame,
                textRegions: textRegions,
                imageRegions: imageRegions,
                mediaFrame: mediaFrame,
                mediaURL: mediaURL,
                mediaIsVideo: embed.video != nil,
                mediaAutoplaysInline: false,
                accentColor: embed.color
            )
        }
        }

        private func resolvedTextBox(
            prepared: RichMessageAttributedText.Prepared,
            scope: String,
            emojiSize: CGFloat,
            embed: MessageEmbed,
            message: Message,
            model: AppModel?
        ) -> NativeTimelineAttributedTextBox {
            NativeTimelineEmbedLayout.resolvedTextBox(
                prepared: prepared,
                scope: scope,
                emojiSize: emojiSize,
                embed: embed,
                message: message,
                model: model
            )
        }

        private func plainTextBox(
            _ value: String,
            font: NSFont,
            color: NSColor,
            link: URL? = nil
        ) -> NativeTimelineAttributedTextBox {
            NativeTimelineEmbedLayout.plainTextBox(
                value,
                font: font,
                color: color,
                link: link
            )
        }

        private func textColumnIdealWidth(
            author: NativeTimelineAttributedTextBox?,
            authorHasIcon: Bool,
            title: NativeTimelineAttributedTextBox?,
            description: NativeTimelineAttributedTextBox?,
            fields: [PreparedField],
            provider: NativeTimelineAttributedTextBox?
        ) -> CGFloat {
            NativeTimelineEmbedLayout.textColumnIdealWidth(
                author: author,
                authorHasIcon: authorHasIcon,
                title: title,
                description: description,
                fields: fields,
                provider: provider
            )
        }

        private func layoutFields(
            _ fields: [PreparedField],
            x horizontalPosition: CGFloat,
            y verticalOffset: inout CGFloat,
            width: CGFloat,
            into regions: inout [NativeTimelineRowLayout.EmbedRegion.TextRegion]
        ) {
            NativeTimelineEmbedLayout.layoutFields(
                fields,
                x: horizontalPosition,
                y: &verticalOffset,
                width: width,
                into: &regions
            )
        }

        private func footerText(
            footer: MessageEmbedFooter?,
            timestamp: Date?
        ) -> String? {
            NativeTimelineEmbedLayout.footerText(
                footer: footer,
                timestamp: timestamp
            )
        }

        private func idealWidth(_ box: NativeTimelineAttributedTextBox) -> CGFloat {
            NativeTimelineEmbedLayout.idealWidth(box)
        }

        private func measuredHeight(
            _ box: NativeTimelineAttributedTextBox,
            width: CGFloat
        ) -> CGFloat {
            NativeTimelineEmbedLayout.measuredHeight(box, width: width)
        }

        private func mediaSize(
            _ media: MessageEmbedMedia,
            maximumWidth: CGFloat,
            maximumHeight: CGFloat
        ) -> CGSize {
            NativeTimelineEmbedLayout.mediaSize(
                media,
                maximumWidth: maximumWidth,
                maximumHeight: maximumHeight
            )
        }

        private func resolvedURL(
            _ media: MessageEmbedMedia,
            attachments: [Attachment]
        ) -> URL? {
            NativeTimelineEmbedLayout.resolvedURL(
                media,
                attachments: attachments
            )
        }
    }

    static func make(
        embed: MessageEmbed,
        message: Message,
        model: AppModel?,
        attachments: [Attachment],
        origin: CGPoint,
        maximumWidth: CGFloat
    ) -> NativeTimelineRowLayout.EmbedRegion? {
        Builder(
            embed: embed,
            message: message,
            model: model,
            attachments: attachments,
            origin: origin,
            maximumWidth: maximumWidth
        ).region
    }

    private static func resolvedTextBox(
        prepared: RichMessageAttributedText.Prepared,
        scope: String,
        emojiSize: CGFloat,
        embed: MessageEmbed,
        message: Message,
        model: AppModel?
    ) -> NativeTimelineAttributedTextBox {
        let resolver = model.map {
            MessageMentionResolver(model: $0, message: message)
        }
        let mentions = prepared.tokens.reduce(
            into: [String: MentionPresentation]()
        ) { result, token in
            guard case let .mention(mention) = token else { return }
            result[mention.rawToken] =
                resolver?.presentation(mention)
                ?? MentionPresentation.fallback(for: mention)
        }
        let key = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "embed:\(embed.id):\(scope)",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: 15,
            mentions: mentions.values.sorted {
                $0.rawToken < $1.rawToken
            }
        )
        return NativeTimelineResolvedTextCache.shared.box(for: key) {
            NativeTimelineAttributedTextBox(
                NativeTimelineCoreText.make(
                    prepared: prepared,
                    emojiSize: emojiSize,
                    mentionPresentations: mentions
                ),
                layoutHeightAdjustment: 1
            )
        }
    }

    private static func plainTextBox(
        _ value: String,
        font: NSFont,
        color: NSColor,
        link: URL? = nil
    ) -> NativeTimelineAttributedTextBox {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let output = NSMutableAttributedString(
            string: value,
            attributes: attributes
        )
        if let link {
            output.addAttribute(
                .link,
                value: link,
                range: NSRange(location: 0, length: output.length)
            )
        }
        return NativeTimelineAttributedTextBox(output)
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
            width = max(width, (author.map(idealWidth) ?? 0) + 26)
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
        let columnGap: CGFloat = 14
        let rowGap: CGFloat = 8
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
                            y: verticalOffset + nameHeight + 2,
                            width: fieldWidth,
                            height: valueHeight
                        ),
                        text: field.value,
                        isSelectable: true
                    )
                )
                rowHeight = max(rowHeight, nameHeight + 2 + valueHeight)
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
        timestamp: Date?
    ) -> String? {
        var values: [String] = []
        if let footer {
            values.append(footer.text)
        }
        if let timestamp {
            values.append(
                timestamp.formatted(date: .omitted, time: .shortened)
            )
        }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " • ")
    }

    private static func idealWidth(
        _ box: NativeTimelineAttributedTextBox
    ) -> CGFloat {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            box.framesetter,
            CFRange(location: 0, length: box.value.length),
            nil,
            CGSize(width: 10_000, height: 10_000),
            nil
        )
        return max(1, ceil(size.width))
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
        // TextKit reports the used fragment height before SwiftUI rounds the
        // composed stack. Rounding every CoreText leaf upward makes a rich
        // embed progressively taller than the previous renderer, especially
        // across its title, description, field grid, and footer.
        return max(
            1,
            floor(size.height) - box.layoutHeightAdjustment
                + NativeTimelineMarkdownChromeMetrics
                    .trailingVisualOverflow(in: box.value)
        )
    }

    private static func mediaSize(
        _ media: MessageEmbedMedia,
        maximumWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> CGSize {
        let width = min(500, max(180, maximumWidth))
        if let rawWidth = media.width,
           let rawHeight = media.height,
           rawWidth > 0,
           rawHeight > 0
        {
            let source = CGSize(
                width: CGFloat(rawWidth),
                height: CGFloat(rawHeight)
            )
            let scale = min(
                1,
                width / source.width,
                maximumHeight / source.height
            )
            return CGSize(
                width: source.width * scale,
                height: source.height * scale
            )
        }
        let ratio = max(
            0.2,
            min(
                12,
                CGFloat(media.width ?? 16) / CGFloat(media.height ?? 9)
            )
        )
        let fittedWidth = min(width, maximumHeight * ratio)
        let fittedHeight = min(maximumHeight, fittedWidth / ratio)
        return CGSize(
            width: fittedWidth,
            height: max(80, fittedHeight)
        )
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
