import AppKit
import MessageRendering
import OSLog
import SakuraCordModels
import SwiftUI
import Synchronization

nonisolated enum RichMessageTextMeasurement {
    static let maximumWidth: CGFloat = 10_000

    static func constrainedWidth(_ proposedWidth: CGFloat?) -> CGFloat? {
        guard let proposedWidth, proposedWidth.isFinite else { return nil }
        return min(max(1, proposedWidth), maximumWidth)
    }
}

nonisolated enum RichMessageAttributedText {
    private struct PreparedCacheState: Sendable {
        var values: [String: Prepared] = [:]
        var insertionOrder: [String] = []
        var evictionIndex = 0
    }

    private static let maximumPreparedCacheEntries = 2_048
    private static let preparedCache = Mutex(PreparedCacheState())
    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )

    enum InlineToken: Hashable, Sendable {
        case customEmoji(RenderedEmoji)
        case mention(RenderedMention)
    }

    struct Prepared: Hashable, Sendable {
        let markdownPlan: DiscordMarkdown.AppKitPlan
        let tokens: [InlineToken]
        let isEmojiOnly: Bool
    }

    nonisolated static func prepare(source: String) -> Prepared {
        if let cached = preparedCache.withLock({ $0.values[source] }) {
            return cached
        }
        let signpost = performanceSignposter.beginInterval(
            "RichTextParse",
            id: performanceSignposter.makeSignpostID()
        )
        defer {
            performanceSignposter.endInterval("RichTextParse", signpost)
        }
        let document = MessageDocument(source: source)
        var transformed = ""
        var tokens: [InlineToken] = []

        for segment in document.segments {
            switch segment {
            case let .markdown(value):
                transformed += value
            case let .customEmoji(emoji):
                transformed.append("\u{FFFC}")
                tokens.append(.customEmoji(emoji))
            case let .mention(mention):
                transformed.append("\u{FFFC}")
                tokens.append(.mention(mention))
            }
        }
        let prepared = Prepared(
            markdownPlan: DiscordMarkdown.appKitPlan(transformed),
            tokens: tokens,
            isEmojiOnly: document.isEmojiOnly
        )
        return preparedCache.withLock { state in
            if let existing = state.values[source] {
                return existing
            }
            state.values[source] = prepared
            state.insertionOrder.append(source)
            while state.values.count > maximumPreparedCacheEntries,
                  state.evictionIndex < state.insertionOrder.count
            {
                let evicted = state.insertionOrder[state.evictionIndex]
                state.evictionIndex += 1
                state.values[evicted] = nil
            }
            if state.evictionIndex > 1_024,
               state.evictionIndex * 2 > state.insertionOrder.count
            {
                state.insertionOrder.removeFirst(state.evictionIndex)
                state.evictionIndex = 0
            }
            return prepared
        }
    }

    @MainActor
    static func make(
        source: String,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        make(
            prepared: prepare(source: source),
            emojiSize: emojiSize,
            baseFontSize: baseFontSize,
            mentionPresentations: mentionPresentations
        )
    }

    @MainActor
    static func make(
        prepared: Prepared,
        emojiSize: CGFloat,
        baseFontSize: CGFloat? = nil,
        mentionPresentations: [String: MentionPresentation]
    ) -> NSAttributedString {
        let resolvedBaseFontSize = baseFontSize
            ?? (prepared.isEmojiOnly ? emojiSize : InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize))
        let baseFont = NSFont.systemFont(ofSize: resolvedBaseFontSize)
        let output = NSMutableAttributedString(
            attributedString: NativeTimelineCoreText.scaledMarkdown(
                prepared.markdownPlan,
                baseFontSize: resolvedBaseFontSize
            )
        )
        let placeholderRanges = ranges(of: "\u{FFFC}", in: output.string)

        for (range, token) in zip(
            placeholderRanges.reversed(),
            prepared.tokens.reversed()
        ) {
            let spoiler = output.attribute(
                .discordMarkdownSpoiler,
                at: range.location,
                effectiveRange: nil
            )
            let replacement = switch token {
            case let .customEmoji(emoji):
                customEmoji(emoji, size: emojiSize, font: baseFont)
            case let .mention(mention):
                mentionAttributedString(
                    mentionPresentations[mention.rawToken]
                        ?? MentionPresentation.fallback(for: mention),
                    font: baseFont
                )
            }
            output.replaceCharacters(in: range, with: replacement)
            if let spoiler {
                output.addAttribute(
                    .discordMarkdownSpoiler,
                    value: spoiler,
                    range: NSRange(location: range.location, length: replacement.length)
                )
            }
        }
        NativeTimelineCoreText.normalizeParagraphMetrics(in: output, spoilersOnly: true)
        return output
    }

    /// Spoilers are concealed behind a background cover unless revealed by the user.
    @MainActor
    static func concealSpoilers(
        in value: NSMutableAttributedString,
        revealedLocations: Set<Int> = []
    ) {
        value.enumerateAttribute(
            .discordMarkdownSpoiler,
            in: NSRange(location: 0, length: value.length)
        ) { rawValue, range, _ in
            guard rawValue != nil else { return }
            if revealedLocations.contains(range.location) {
                value.removeAttribute(.discordMarkdownSpoiler, range: range)
                return
            }
            SpoilerAppearance.concealText(in: value, range: range)
            value.removeAttribute(.link, range: range)
            value.enumerateAttribute(.attachment, in: range) { rawAttachment, attachmentRange, _ in
                guard let original = rawAttachment as? NSTextAttachment else { return }
                // Removing an attachment also removes its advance and baseline.
                // Retain layout with an empty image that cannot expose its payload.
                let concealed = NSTextAttachment()
                concealed.image = NSImage(size: original.bounds.size, flipped: false) { rect in
                    NSColor.clear.setFill()
                    rect.fill(using: .copy)
                    return true
                }
                concealed.bounds = original.bounds
                value.addAttribute(.attachment, value: concealed, range: attachmentRange)
            }
            value.removeAttribute(.backgroundColor, range: range)
        }
    }

    static func ranges(
        of value: String, in source: String, options: NSString.CompareOptions = []
    ) -> [NSRange] {
        let source = source as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let range = source.range(of: value, options: options, range: searchRange)
            guard range.location != NSNotFound else { break }
            ranges.append(range)
            let nextLocation = NSMaxRange(range)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return ranges
    }

    @MainActor
    private static func customEmoji(
        _ emoji: RenderedEmoji,
        size: CGFloat,
        font: NSFont
    ) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let image = ComposerEmojiImageStore.shared.cachedImage(for: emoji.rawToken)
            ?? SakuraCordSystemSymbol.image(
                named: SakuraCordSystemSymbol.emojiFaceGrinning,
                accessibilityDescription: emoji.name
            )
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: ComposerEmojiAttributedText.attachmentOriginY(font: font, size: size),
            width: size,
            height: size
        )
        let value = NSMutableAttributedString(attachment: attachment)
        value.addAttribute(
            .discordEmojiToken,
            value: emoji.rawToken,
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }

    @MainActor
    private static func mentionAttributedString(
        _ presentation: MentionPresentation,
        font: NSFont
    ) -> NSAttributedString {
        MentionAttachmentRenderer.attributedString(presentation: presentation, font: font)
    }

}

enum RichMessageCopySerializer {
    nonisolated static func string(from value: NSAttributedString, range: NSRange) -> String {
        var output = ""
        value.enumerateAttributes(in: range) { attributes, effectiveRange, _ in
            if let token = (attributes[.discordEmojiToken] ?? attributes[.discordMentionToken]) as? String {
                output += token
            } else {
                output += value.attributedSubstring(from: effectiveRange).string
            }
        }
        return output
    }
}
