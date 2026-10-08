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

    static func outgoingBubble(_ value: Value) -> Value {
        guard let attributedContent = value.attributedContent else {
            return value
        }
        let resolved = NSMutableAttributedString(
            attributedString: attributedContent
        )
        let range = NSRange(location: 0, length: resolved.length)
        resolved.addAttribute(.foregroundColor, value: NSColor.white, range: range)
        resolved.addAttribute(.underlineColor, value: NSColor.white, range: range)
        resolved.addAttribute(.strikethroughColor, value: NSColor.white, range: range)
        resolved.enumerateAttribute(.link, in: range) { link, linkRange, _ in
            guard link != nil else { return }
            resolved.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: linkRange
            )
        }
        return Value(
            attributedContent: resolved,
            framesetter: CTFramesetterCreateWithAttributedString(resolved),
            linkedImages: value.linkedImages
        )
    }

    /// Discord shows an unanswered interaction as red text behind an alert glyph.
    static func interactionFailure(_ value: Value) -> Value {
        guard let attributedContent = value.attributedContent, attributedContent.length > 0 else { return value }
        let resolved = NSMutableAttributedString(attributedString: attributedContent)
        let attributes = resolved.attributes(at: 0, effectiveRange: nil)
        resolved.insert(NSAttributedString(string: "⚠\u{FE0E} ", attributes: attributes), at: 0)
        resolved.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: resolved.length))
        return Value(
            attributedContent: resolved,
            framesetter: CTFramesetterCreateWithAttributedString(resolved),
            linkedImages: value.linkedImages
        )
    }

    /// Discord replaces a pending interaction's body with muted status text
    /// whose first line leaves room for the loading dots.
    static func interactionLoading(_ status: String) -> Value {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.firstLineHeadIndent = interactionLoadingTextIndent
        let resolved = NSAttributedString(string: status, attributes: [
            .font: NSFont.interfaceSystemFont(ofSize: InterfaceTypographyMetrics.messageTextSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        return Value(
            attributedContent: resolved,
            framesetter: CTFramesetterCreateWithAttributedString(resolved),
            linkedImages: []
        )
    }

    static var interactionLoadingTextIndent: CGFloat { InteractionLoadingDots.size.width + InterfaceScale.metric(4) }

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
        row: MessageRowPresentation,
        model: AppModel?
    ) -> Value {
        let message = row.message
        guard !message.flags.contains(.isComponentsV2) else {
            return empty
        }
        let systemActorColor = model?.accessibilitySettings.roleColorDisplay == .inNames ? model?.authorPresentation(for: message)
            .roleColorHex.flatMap { value -> NSColor? in
                guard value != 0 else { return nil }
                return NSColor(
                    red: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            } : nil
        let plan = if message.type.hasGeneratedContent {
            NativeTimelineTextPlan.make(
                for: message,
                currentUserID: model?.snapshot?.currentUser.id,
                systemRecipient: model?.systemMessageRecipient(for: message),
                systemActorColor: systemActorColor
            )
        } else {
            row.textPlan
        }
        return make(message: message, plan: plan, model: model)
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

        let preservesCompactSystemStyle = message.type.hasGeneratedContent
            && model?.appearanceSettings.messageAppearance != .bubbles
        let resolvedBaseFontSize = InterfaceScale.fontSize(
            preservesCompactSystemStyle
                ? plan.baseFontSize
                : InterfaceTypographyMetrics.messageTextSize
        )
        if let preparedBox = plan.attributedText,
           resolvedBaseFontSize == plan.baseFontSize
        {
            return Value(
                attributedContent: preparedBox.value,
                framesetter: preparedBox.framesetter,
                linkedImages: plan.linkedImages
            )
        }
        // System messages keep their actor styling at other interface sizes.
        if preservesCompactSystemStyle, let preparedBox = plan.attributedText {
            let scaled = preparedBox.value.scalingTypography(
                by: resolvedBaseFontSize / plan.baseFontSize
            )
            return Value(
                attributedContent: scaled,
                framesetter: CTFramesetterCreateWithAttributedString(scaled),
                linkedImages: plan.linkedImages
            )
        }

        guard let preparation = preparation(
            message: message,
            plan: plan,
            model: model,
            baseFontSize: resolvedBaseFontSize
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
        model: AppModel?,
        baseFontSize: CGFloat? = nil
    ) -> Preparation? {
        let resolvedBaseFontSize = baseFontSize ?? plan.baseFontSize
        if plan.attributedText != nil,
           resolvedBaseFontSize == plan.baseFontSize
        {
            return nil
        }
        guard let prepared = plan.preparedText else { return nil }
        let resolver = model.map { MessageMentionResolver(model: $0, message: message) }
        let mentions = prepared.tokens.reduce(into: [String: MentionPresentation]()) { values, token in
            guard case let .mention(mention) = token else { return }
            values[mention.rawToken] =
                resolver?.presentation(mention)
                ?? MentionPresentation.fallback(for: mention)
        }
        let emojiSize = InterfaceScale.metric(prepared.isEmojiOnly ? 48 : 22)
        let cacheKey = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "message",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: resolvedBaseFontSize,
            mentions: mentions.values.sorted {
                $0.rawToken < $1.rawToken
            }
        )
        return Preparation(
            key: cacheKey,
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: resolvedBaseFontSize,
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
        /// The interface size when the key was prepared.
        var interfaceScale = InterfaceScale.factor
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
        // A render that raced an interface size change is used once but not
        // cached; the presentation revision bump prepares it again.
        guard InterfaceScale.factor == key.interfaceScale else { return box }
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

    /// Renders Markdown at its unscaled base size, so heading, code and
    /// subtext sizes keep their relationship to body text, then applies the
    /// interface size to every resolved font once.
    static func scaledMarkdown(
        _ plan: DiscordMarkdown.AppKitPlan,
        baseFontSize: CGFloat
    ) -> NSAttributedString {
        let factor = InterfaceScale.factor
        guard factor != 1 else {
            return DiscordMarkdown.appKitAttributed(plan, baseFontSize: baseFontSize)
        }
        let unscaledBaseFontSize = baseFontSize / factor
        return DiscordMarkdown.appKitAttributed(plan, baseFontSize: unscaledBaseFontSize)
            .scalingTypography(by: baseFontSize / unscaledBaseFontSize)
    }

    static func make(
        prepared: RichMessageAttributedText.Prepared,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        let resolvedBaseFontSize =
            prepared.isEmojiOnly
                ? emojiSize
                : baseFontSize ?? InterfaceScale.fontSize(15)
        let baseFont = NSFont.systemFont(ofSize: resolvedBaseFontSize)
        let output = NSMutableAttributedString(
            attributedString: scaledMarkdown(
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

    static func normalizeParagraphMetrics(
        in output: NSMutableAttributedString,
        spoilersOnly: Bool = false
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
            var containsSpoiler = false
            var paragraphFont: NSFont?
            output.enumerateAttributes(
                in: paragraphRange,
                options: []
            ) { attributes, _, _ in
                if attributes[runDelegateKey] != nil || attributes[.attachment] != nil {
                    containsInlineRun = true
                }
                if attributes[.discordMarkdownSpoiler] != nil {
                    containsSpoiler = true
                }
                guard let font = attributes[.font] as? NSFont else {
                    return
                }
                paragraphFont = paragraphFont ?? font
                lineHeight = max(
                    lineHeight,
                    ceil(font.ascender - font.descender + font.leading)
                )
            }
            let lastLocation = NSMaxRange(paragraphRange) - 1
            if containsSpoiler, source.character(at: lastLocation) == 10,
               output.attribute(.font, at: lastLocation, effectiveRange: nil) == nil,
               let font = (output.attribute(.font, at: max(paragraphRange.location, lastLocation - 1),
                                            effectiveRange: nil) as? NSFont) ?? paragraphFont
            {
                // Markdown separators have no font. CoreText otherwise uses
                // its default font for them, enlarging small-text line metrics.
                output.addAttribute(.font, value: font, range: NSRange(location: lastLocation, length: 1))
            }
            if spoilersOnly, !containsSpoiler {
                location = NSMaxRange(paragraphRange)
                continue
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
            if containsSpoiler {
                // Natural line metrics agree between CoreText and TextKit.
                // A fixed ceil(font height) changes TextKit's baseline at some
                // sizes; the shared markdown line spacing adds another point.
                style.minimumLineHeight = 0
                style.maximumLineHeight = 0
            } else if !containsInlineRun, lineHeight > 0 {
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
        let height = max(InterfaceScale.metric(21), ceil(font.pointSize + InterfaceScale.metric(6)))
        let showsAvatar = if case .user = presentation.target { true } else { false }
        let showsLeadingIcon = presentation.systemImage != nil
        let metrics = NativeTimelineMentionMetrics.self
        let avatarSize = height - metrics.avatarInset
        let iconSize = height - metrics.iconInset
        let width = ceil(
            metrics.horizontalPadding * 2 + labelWidth
                + (showsAvatar ? avatarSize + metrics.leadingGap : 0)
                + (showsLeadingIcon ? iconSize + metrics.leadingGap : 0)
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
        let integratesWithBubble: Bool
        let drawsTopSeparator: Bool

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
                maximumWidth: min(maximumWidth, InterfaceScale.metric(500)),
                maximumHeight: InterfaceScale.metric(350)
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
                accentColor: nil,
                drawsTopSeparator: false
            )
        case .card:
            let cardPadding: CGFloat = integratesWithBubble ? 0 : 12
            let stripeWidth: CGFloat = integratesWithBubble ? 0 : InterfaceScale.metric(4)
            let innerChrome = stripeWidth + cardPadding * 2
            let maximumContentWidth = max(InterfaceScale.metric(80), maximumWidth - innerChrome)

            let author = embed.author.map {
                plainTextBox(
                    $0.name,
                    font: .interfaceSystemFont(ofSize: 11, weight: .semibold),
                    color: $0.url == nil ? .labelColor : .linkColor,
                    link: $0.url
                )
            }
            let title = embed.title.map {
                plainTextBox(
                    $0,
                    font: .interfaceSystemFont(ofSize: 13, weight: .semibold),
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
                        font: .interfaceSystemFont(ofSize: 11, weight: .bold),
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
                    font: .interfaceSystemFont(ofSize: 11),
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
                    font: .interfaceSystemFont(ofSize: 11),
                    color: .secondaryLabelColor
                )
            }

            let thumbnailURL = embed.thumbnail.flatMap {
                resolvedURL($0, attachments: attachments)
            }
            let thumbnailSize: CGFloat = thumbnailURL == nil ? 0 : InterfaceScale.metric(80)
            // The legacy HStack contains text, a zero-minimum Spacer, and the
            // thumbnail. SwiftUI applies its 12-point spacing on both sides
            // of that spacer even when the spacer collapses to zero.
            let thumbnailAllowance: CGFloat =
                thumbnailSize > 0
                    ? thumbnailSize + (integratesWithBubble ? 12 : 24)
                    : 0

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
                    maximumHeight: InterfaceScale.metric(350)
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
                        textY += InterfaceScale.metric(7)
                    }
                    let lineHeight = max(InterfaceScale.metric(20), measuredHeight(
                        author,
                        width: max(InterfaceScale.metric(20), textWidth - InterfaceScale.metric(26))
                    ))
                    imageRegions.append(
                        .init(
                            frame: CGRect(
                                x: contentX,
                                y: textY + (lineHeight - InterfaceScale.metric(20)) / 2,
                                width: InterfaceScale.metric(20),
                                height: InterfaceScale.metric(20)
                            ),
                            url: iconURL,
                            cornerRadius: InterfaceScale.metric(10),
                            fallbackSystemImage: "person.crop.circle",
                            maximumPixelDimension: 64
                        )
                    )
                    let authorHeight = measuredHeight(
                        author,
                        width: max(InterfaceScale.metric(20), textWidth - InterfaceScale.metric(26))
                    )
                    textRegions.append(
                        .init(
                            frame: CGRect(
                                x: contentX + InterfaceScale.metric(26),
                                y: textY + (lineHeight - authorHeight) / 2,
                                width: max(InterfaceScale.metric(20), textWidth - InterfaceScale.metric(26)),
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
                        cornerRadius: InterfaceScale.metric(6),
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
                    maximumWidth: min(contentWidth, InterfaceScale.metric(500)),
                    maximumHeight: InterfaceScale.metric(350)
                )
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
                                y: bottomY + (footerHeight - InterfaceScale.metric(18)) / 2,
                                width: InterfaceScale.metric(18),
                                height: InterfaceScale.metric(18)
                            ),
                            url: footerIconURL,
                            cornerRadius: InterfaceScale.metric(9),
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
                mediaIsVideo: embed.video != nil,
                mediaAutoplaysInline: false,
                accentColor: embed.color,
                drawsTopSeparator:
                    integratesWithBubble && drawsTopSeparator
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
        maximumWidth: CGFloat,
        integratesWithBubble: Bool = false,
        drawsTopSeparator: Bool = false
    ) -> NativeTimelineRowLayout.EmbedRegion? {
        Builder(
            embed: embed,
            message: message,
            model: model,
            attachments: attachments,
            origin: origin,
            maximumWidth: maximumWidth,
            integratesWithBubble: integratesWithBubble,
            drawsTopSeparator: drawsTopSeparator
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
        let baseFontSize = InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize)
        let emojiSize = InterfaceScale.metric(emojiSize)
        let key = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "embed:\(embed.id):\(scope)",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            mentions: mentions.values.sorted {
                $0.rawToken < $1.rawToken
            }
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
            width = max(width, (author.map(idealWidth) ?? 0) + InterfaceScale.metric(26))
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
                            y: verticalOffset + nameHeight + InterfaceScale.metric(2),
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
        let width = min(InterfaceScale.metric(500), max(InterfaceScale.metric(180), maximumWidth))
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
            height: max(InterfaceScale.metric(80), fittedHeight)
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

nonisolated enum NativeTimelineMarkdownChromeMetrics {
    static var codeBlockInset: CGFloat { InterfaceScale.metric(8) }
    static var codeBlockParagraphBottomSpacing: CGFloat { InterfaceScale.metric(4) }
    // The painter gives CoreText one point of extra layout headroom and its
    // selection-derived block rect has fractional vertical bounds. Preserve
    // the established three-point message-highlight inset after that painted
    // geometry instead of merely making the block fit the row.
    static var codeBlockTerminalPaintAndHighlightInset: CGFloat { InterfaceScale.metric(5.5) }

    static func trailingVisualOverflow(
        in value: NSAttributedString
    ) -> CGFloat {
        guard value.length > 0 else { return 0 }
        let source = value.string as NSString
        var index = value.length - 1
        while index >= 0 {
            let scalar = source.character(at: index)
            if let unicodeScalar = UnicodeScalar(scalar),
               CharacterSet.whitespacesAndNewlines
                .contains(unicodeScalar)
            {
                index -= 1
                continue
            }
            break
        }
        guard index >= 0,
              value.attribute(
                  .discordMarkdownBlock,
                  at: index,
                  effectiveRange: nil
              ) as? String == "code"
        else { return 0 }
        return max(
            0,
            codeBlockInset
                - codeBlockParagraphBottomSpacing
                + codeBlockTerminalPaintAndHighlightInset
        )
    }
}

enum NativeTimelineTimestamp {
    static func headerText(
        for date: Date,
        settings: InterfaceSettingsSnapshot = .defaults
    ) -> String {
        InterfaceTimestampFormatter.messageText(
            for: date,
            format: settings.timestampFormat,
            includesSeconds: settings.includesTimestampSeconds
        )
    }

    static func text(
        for date: Date,
        settings: InterfaceSettingsSnapshot = .defaults,
        includesSeconds: Bool? = nil
    ) -> String {
        InterfaceTimestampFormatter.text(
            for: date,
            format: settings.timestampFormat,
            includesSeconds: includesSeconds
                ?? settings.includesTimestampSeconds
        )
    }
}

extension NSAttributedString.Key {
    nonisolated static let nativeTimelineMention = NSAttributedString.Key(
        "dev.sakuracord.native-timeline-mention"
    )
}

nonisolated final class NativeTimelineMentionBox: NSObject {
    let presentation: MentionPresentation

    init(_ presentation: MentionPresentation) {
        self.presentation = presentation
    }
}

nonisolated private final class NativeTimelineRunMetrics: @unchecked Sendable {
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat

    init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
        self.ascent = ascent
        self.descent = descent
        self.width = width
    }
}

nonisolated enum NativeTimelineRunDelegate {
    static func make(
        width: CGFloat,
        height: CGFloat,
        baselineOffset: CGFloat
    ) -> CTRunDelegate {
        let descent = max(0, -baselineOffset)
        let metrics = NativeTimelineRunMetrics(
            ascent: max(0, height - descent),
            descent: descent,
            width: width
        )
        let retained = Unmanaged.passRetained(metrics)
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .release()
            },
            getAscent: { pointer in
                return Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .ascent
            },
            getDescent: { pointer in
                return Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .descent
            },
            getWidth: { pointer in
                return Unmanaged<NativeTimelineRunMetrics>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .width
            }
        )
        guard let delegate = CTRunDelegateCreate(
            &callbacks,
            retained.toOpaque()
        ) else {
            retained.release()
            preconditionFailure("Unable to create CoreText inline run delegate")
        }
        return delegate
    }
}

extension NativeTimelineRowLayout {
    static func measuredTextHeight(
        _ framesetter: CTFramesetter,
        value: NSAttributedString,
        length: Int,
        width: CGFloat
    ) -> CGFloat {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: length),
            nil,
            CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            nil
        )
        // SwiftUI's one-line message text fits exactly in the established
        // 18-point compact row. CoreText reports that same line just under
        // 19 points because its suggested bounds include fractional font
        // leading. Multiline suggestions retain one trailing point that the
        // preserved NSTextView usedRect omitted.
        if size.height < 20 {
            return MessageRowLayoutMetrics.compactContentHeight
        }
        return ceil(size.height - 1.01)
            + NativeTimelineMarkdownChromeMetrics
                .trailingVisualOverflow(in: value)
    }

    /// A single layout pass shares its font resolution and timestamp gutter.
    /// Recreate this snapshot for each pass so preference changes stay live.
    struct Metrics {
        let authorFont: NSFont
        let timestampFont: NSFont
        let editedFont: NSFont
        let timestampGutterWidth: CGFloat

        init(settings: InterfaceSettingsSnapshot) {
            authorFont = .interfaceSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
            timestampFont = .interfacePreferredFont(forTextStyle: .caption1)
            editedFont = .interfacePreferredFont(forTextStyle: .caption2)
            timestampGutterWidth = NativeTimelineCompactTimestampMetrics.width(settings: settings)
        }
    }

    private struct TextWidthKey: Hashable {
        let text: String
        let font: NSFont
    }
    private static var measuredTextWidths: [TextWidthKey: CGFloat] = [:]

    static func measuredTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let key = TextWidthKey(text: text, font: font)
        if let width = measuredTextWidths[key] { return width }
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        if measuredTextWidths.count >= 4_096 { measuredTextWidths.removeAll(keepingCapacity: true) }
        measuredTextWidths[key] = width
        return width
    }

}

/// Mention pill geometry shared by text measurement and the row painter.
nonisolated enum NativeTimelineMentionMetrics {
    static var horizontalPadding: CGFloat { InterfaceScale.metric(6) }
    static var leadingGap: CGFloat { InterfaceScale.metric(4) }
    static var avatarInset: CGFloat { InterfaceScale.metric(6) }
    static var iconInset: CGFloat { InterfaceScale.metric(7) }
}
