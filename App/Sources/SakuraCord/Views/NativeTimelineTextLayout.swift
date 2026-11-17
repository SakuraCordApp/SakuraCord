import AppKit
import CoreText
import MessageRendering
import SakuraCordModels
import Synchronization

@MainActor
enum NativeTimelineTextPresentation {
    nonisolated struct Preparation: Sendable {
        /// Also carries the prepared text, emoji size and base font size.
        let key: NativeTimelineResolvedTextCache.Key
        let mentions: [String: MentionPresentation]
    }

    struct Value {
        let content: NativeTimelineAttributedTextBox?
        let linkedImages: [LinkedImageReference]
    }

    static func outgoingBubble(_ value: Value) -> Value {
        guard let content = value.content else {
            return value
        }
        let resolved = NSMutableAttributedString(
            attributedString: content.value
        )
        let range = NSRange(location: 0, length: resolved.length)
        let label = NSColor.sakuraCordLabelOnAccentColor
        resolved.addAttribute(.foregroundColor, value: label, range: range)
        resolved.addAttribute(.underlineColor, value: label, range: range)
        resolved.addAttribute(.strikethroughColor, value: label, range: range)
        resolved.enumerateAttribute(.link, in: range) { link, linkRange, _ in
            guard link != nil else { return }
            resolved.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: linkRange
            )
        }
        return Value(
            content: NativeTimelineAttributedTextBox(resolved),
            linkedImages: value.linkedImages
        )
    }

    /// Discord shows an unanswered interaction as red text behind an alert glyph.
    static func interactionFailure(_ value: Value) -> Value {
        guard let content = value.content, content.value.length > 0 else { return value }
        let resolved = NSMutableAttributedString(attributedString: content.value)
        let attributes = resolved.attributes(at: 0, effectiveRange: nil)
        resolved.insert(NSAttributedString(string: "⚠\u{FE0E} ", attributes: attributes), at: 0)
        resolved.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: resolved.length))
        return Value(
            content: NativeTimelineAttributedTextBox(resolved),
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
        return Value(content: NativeTimelineAttributedTextBox(resolved), linkedImages: [])
    }

    static var interactionLoadingTextIndent: CGFloat { InteractionLoadingDots.size.width + InterfaceScale.metric(4) }

    static func empty(linkedImages: [LinkedImageReference] = []) -> Value {
        Value(content: nil, linkedImages: linkedImages)
    }

    static func make(
        row: MessageRowPresentation,
        source: AppModel?,
        relativeTo date: Date = .now
    ) -> Value {
        let message = row.message
        guard !message.flags.contains(.isComponentsV2) else {
            return empty()
        }
        let systemActorColor = source?.roleColorDisplay == .inNames
            ? NSColor(discordColor: source?.authorPresentation(for: message).roleColorHex)
            : nil
        let plan = if message.type.hasGeneratedContent {
            NativeTimelineTextPlan.make(
                for: message,
                currentUserID: source?.currentUserID,
                systemRecipient: source?.systemMessageRecipient(for: message),
                systemActorColor: systemActorColor
            )
        } else {
            row.textPlan
        }
        return make(message: message, plan: plan, source: source, relativeTo: date)
    }

    static func make(
        message: Message,
        plan: NativeTimelineTextPlan,
        source: AppModel?,
        relativeTo date: Date = .now
    ) -> Value {
        guard plan.preparedText != nil else {
            return empty(linkedImages: plan.linkedImages)
        }

        let preservesCompactSystemStyle = message.type.hasGeneratedContent
            && source?.messageAppearance(for: message.channelID) != .bubbles
        let resolvedBaseFontSize = InterfaceScale.fontSize(
            preservesCompactSystemStyle
                ? plan.baseFontSize
                : InterfaceTypographyMetrics.messageTextSize
        )
        if let preparedBox = plan.attributedText,
           resolvedBaseFontSize == plan.baseFontSize
        {
            return Value(content: preparedBox, linkedImages: plan.linkedImages)
        }
        // Preserve system-message styling and actions at every size, including bubbles.
        if message.type.hasGeneratedContent, let preparedBox = plan.attributedText {
            let scaled = preparedBox.value.scalingTypography(
                by: resolvedBaseFontSize / plan.baseFontSize
            )
            return Value(content: NativeTimelineAttributedTextBox(scaled), linkedImages: plan.linkedImages)
        }

        guard let preparation = preparation(
            message: message,
            plan: plan,
            source: source,
            baseFontSize: resolvedBaseFontSize,
            relativeTo: date
        ) else {
            return empty(linkedImages: plan.linkedImages)
        }
        return Value(content: resolvedBox(for: preparation), linkedImages: plan.linkedImages)
    }

    static func preparation(
        message: Message,
        plan: NativeTimelineTextPlan,
        source: AppModel?,
        baseFontSize: CGFloat? = nil,
        relativeTo date: Date = .now
    ) -> Preparation? {
        let resolvedBaseFontSize = baseFontSize ?? plan.baseFontSize
        if plan.attributedText != nil,
           resolvedBaseFontSize == plan.baseFontSize
        {
            return nil
        }
        guard let prepared = plan.preparedText else { return nil }
        let mentions = TimestampMentionPresentation.refreshed(
            MessageMentionResolver.presentations(for: prepared, model: source, message: message),
            source: message.content,
            at: date
        )
        let emojiSize = InterfaceScale.metric(InterfaceTypographyMetrics.message(prepared.isEmojiOnly ? 48 : 22))
        let cacheKey = NativeTimelineResolvedTextCache.Key(
            messageID: message.id,
            scope: "message",
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: resolvedBaseFontSize,
            presentations: mentions
        )
        return Preparation(key: cacheKey, mentions: mentions)
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
                    prepared: preparation.key.prepared,
                    emojiSize: preparation.key.emojiSize,
                    baseFontSize: preparation.key.baseFontSize,
                    mentionPresentations: preparation.mentions,
                    usesMessageLineHeight: true
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

nonisolated extension NativeTimelineResolvedTextCache.Key {
    init(
        messageID: MessageID,
        scope: String,
        prepared: RichMessageAttributedText.Prepared,
        emojiSize: CGFloat,
        baseFontSize: CGFloat,
        presentations: [String: MentionPresentation]
    ) {
        self.init(
            messageID: messageID,
            scope: scope,
            prepared: prepared,
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            mentions: presentations.values.sorted { $0.rawToken < $1.rawToken }
        )
    }
}

private extension NSParagraphStyle {
    /// Message text floors its lines with a minimum and no maximum.
    nonisolated var isMessageLine: Bool { maximumLineHeight == 0 && minimumLineHeight > 0 }
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
        baseFontSize: CGFloat,
        usesMessageLineHeight: Bool = false,
        reservesCodeCopyButton: Bool = false
    ) -> NSAttributedString {
        let factor = InterfaceScale.factor
        guard factor != 1 else {
            return DiscordMarkdown.appKitAttributed(
                plan,
                baseFontSize: baseFontSize,
                usesMessageLineHeight: usesMessageLineHeight,
                reservesCodeCopyButton: reservesCodeCopyButton
            )
        }
        let unscaledBaseFontSize = baseFontSize / factor
        return DiscordMarkdown.appKitAttributed(
            plan,
            baseFontSize: unscaledBaseFontSize,
            usesMessageLineHeight: usesMessageLineHeight,
            reservesCodeCopyButton: reservesCodeCopyButton
        )
            .scalingTypography(by: baseFontSize / unscaledBaseFontSize)
    }

    /// `bodyScale` shrinks every line but headings, and the mentions and
    /// emoji in them; its source must use line feeds alone.
    static func make(
        prepared: RichMessageAttributedText.Prepared,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        bodyScale: CGFloat = 1,
        mentionPresentations: [String: MentionPresentation],
        usesMessageLineHeight: Bool = false,
        link: URL? = nil
    ) -> NSAttributedString {
        let resolvedBaseFontSize =
            prepared.isEmojiOnly
                ? emojiSize
                : baseFontSize ?? InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize)
        let bodyScale = prepared.isEmojiOnly ? 1 : bodyScale
        let baseFont = NSFont.systemFont(ofSize: resolvedBaseFontSize * bodyScale)
        let output = NSMutableAttributedString(
            attributedString: scaledMarkdown(
                prepared.markdownPlan,
                baseFontSize: resolvedBaseFontSize,
                usesMessageLineHeight: usesMessageLineHeight && !prepared.isEmojiOnly,
                // Every timeline text shows a code block's copy button.
                reservesCodeCopyButton: true
            )
        )
        if bodyScale != 1 {
            var location = 0
            // The markdown output joins its plan's lines with line feeds,
            // which pair up when the source has no carriage returns.
            let texts = output.string.split(separator: "\n", omittingEmptySubsequences: false)
            for (line, text) in zip(prepared.markdownPlan.lines, texts) {
                let range = NSRange(
                    location: location,
                    length: min(text.utf16.count + 1, output.length - location)
                )
                location = NSMaxRange(range)
                guard !line.isHeading else { continue }
                output.replaceCharacters(
                    in: range,
                    with: output.attributedSubstring(from: range).scalingTypography(by: bodyScale, keepingLegibility: true)
                )
            }
        }
        let fullRange = NSRange(location: 0, length: output.length)
        let placeholderRanges = RichMessageAttributedText.ranges(of: "\u{FFFC}", in: output.string)
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
                    NativeTimelineMentionBox(presentation, fontSize: baseFont.pointSize)
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
        if let link {
            output.addAttribute(.link, value: link, range: fullRange)
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
            let existing = output.attribute(
                .paragraphStyle,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            // A minimum without a maximum is a message's line height, which
            // floors the tallest font; code fixes both and keeps its own.
            // Normalizing drops markdown's line spacing, so the floor takes
            // it on and message lines keep their pitch.
            let messageLineHeight = if let existing, existing.isMessageLine {
                existing.minimumLineHeight + existing.lineSpacing
            } else {
                CGFloat(0)
            }
            var lineHeight = messageLineHeight
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
                    ceil(font.lineHeight)
                )
            }
            if let existing, existing.maximumLineHeight > 0, existing.minimumLineHeight == existing.maximumLineHeight {
                lineHeight = existing.maximumLineHeight
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
            let style = (existing?.mutableCopy()
                as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            // NSTextView's usedRect follows the typographic line bounds and
            // does not count the shared markdown style's trailing point.
            // CoreText otherwise rounds up the font bounding box and counts
            // that point once per line.
            style.lineSpacing = 0
            if containsSpoiler || containsInlineRun && messageLineHeight > 0 {
                // Natural line metrics agree between CoreText and TextKit.
                // A fixed ceil(font height) changes TextKit's baseline at some
                // sizes; the shared markdown line spacing adds another point.
                style.minimumLineHeight = messageLineHeight
                style.maximumLineHeight = 0
            } else if !containsInlineRun, lineHeight > 0 {
                style.minimumLineHeight = lineHeight
                // A message line stays a floor, which row measurement reads.
                style.maximumLineHeight = messageLineHeight > 0 ? 0 : lineHeight
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
            weight: presentation.labelWeight
        )
        let labelWidth = ceil(
            (presentation.label as NSString).size(
                withAttributes: [.font: labelFont]
            ).width
        )
        let height = max(InterfaceScale.metric(21), ceil(font.pointSize + InterfaceScale.metric(6)))
        let showsAvatar = presentation.showsAvatar
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
}

extension NSAttributedString.Key {
    nonisolated static let nativeTimelineMention = NSAttributedString.Key(
        "dev.sakuracord.native-timeline-mention"
    )
}

nonisolated final class NativeTimelineMentionBox: NSObject {
    let presentation: MentionPresentation
    /// The label's point size, which sized the pill.
    let fontSize: CGFloat

    init(_ presentation: MentionPresentation, fontSize: CGFloat) {
        self.presentation = presentation
        self.fontSize = fontSize
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
    /// A message's text height from CoreText's suggestion, without the
    /// trailing point the suggestion keeps. An inline editor's TextKit height
    /// rounded up is that same suggestion.
    static func messageTextHeight(suggested height: CGFloat) -> CGFloat {
        ceil(height - 1.01)
    }

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
        // One-line message text fits an 18-point compact row, but CoreText
        // reports that line just under 19 points because its suggested
        // bounds include fractional font leading. Multiline suggestions keep
        // one trailing point the row omits. A message's own line height (a
        // minimum without a maximum) replaces that compact row, and a
        // one-line code block still needs room for its bottom padding.
        let style = length > 0 ? value.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        let overflow = NativeTimelineMarkdownChromeMetrics.trailingVisualOverflow(in: value)
        if size.height < 20, overflow == 0, style?.isMessageLine != true {
            return MessageRowLayoutMetrics.compactContentHeight
        }
        return messageTextHeight(suggested: size.height) + overflow
    }

    /// A single layout pass shares its font resolution and timestamp gutter.
    /// Recreate this snapshot for each pass so preference changes stay live.
    struct Metrics {
        let authorFont: NSFont
        let timestampFont: NSFont
        let editedFont: NSFont
        let timestampGutterWidth: CGFloat

        init(source: AppModel?) {
            self.init(settings: source?.interfaceSettings ?? .defaults)
        }

        init(settings: InterfaceSettingsSnapshot) {
            authorFont = .messageSystemFont(ofSize: NSFont.authorNameSize, weight: .medium)
            timestampFont = .messageSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1)
            editedFont = .messageSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize + 1)
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

extension NativeTimelineAttributedTextBox {
    /// `frame` grown by the height the box's layout leaves out.
    nonisolated func drawingFrame(_ frame: CGRect) -> CGRect {
        var frame = frame
        frame.size.height += layoutHeightAdjustment
        return frame
    }

    /// Word-wrapped text in one font and colour, linking all of it when
    /// given a link.
    nonisolated static func plain(
        _ value: String,
        font: NSFont,
        color: NSColor,
        link: URL? = nil
    ) -> NativeTimelineAttributedTextBox {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let link { attributes[.link] = link }
        return NativeTimelineAttributedTextBox(NSAttributedString(string: value, attributes: attributes))
    }
}
