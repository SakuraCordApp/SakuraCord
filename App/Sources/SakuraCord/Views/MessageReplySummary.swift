import Foundation
import MessageRendering

enum MessageReplySummary {
    nonisolated struct EmojiItem: Sendable {
        let range: NSRange
        let emoji: RenderedEmoji
    }

    nonisolated struct Prepared: Sendable {
        let source: String
        let text: String
        /// UTF-16 ranges of `text` inside spoilers. Reply bars never reveal
        /// them, so presentation conceals these ranges.
        let spoilerRanges: [NSRange]
        var emojis: [EmojiItem] = []
    }

    private final class CachedValue {
        let prepared: Prepared

        init(_ prepared: Prepared) {
            self.prepared = prepared
        }
    }

    private static let values: NSCache<NSString, CachedValue> = {
        let cache = NSCache<NSString, CachedValue>()
        cache.countLimit = 2_000
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    nonisolated private static let emojiExpression = RegularExpressionFactory.make(
        #"<a?:[A-Za-z0-9_]+:[0-9]+>"#
    )

    static let defaultMentionLabel: (RenderedMention) -> String = { mention in
        switch mention.kind {
        case .guildNavigation: GuildNavigationMention(rawValue: mention.id)?.title ?? mention.rawToken
        case .user: "@unknown-user"
        case .role: "@unknown-role"
        case .game, .broadcast, .command, .timestamp: MentionPresentation.fallback(for: mention).label
        case .channel: "#unknown-channel"
        case .channelLink: "Channel link"
        case .message: "Message link"
        }
    }

    /// Plain single-line text, including spoiler contents.
    static func text(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> String {
        summary(content: content, mentionLabel: mentionLabel).text
    }

    /// Single-line text with its spoiler ranges and inline custom emojis.
    static func summary(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> Prepared {
        let source = resolvedSource(content: content, mentionLabel: mentionLabel)
        if let cached = values.object(forKey: source as NSString) {
            return cached.prepared
        }
        let prepared = prepare(source)
        install(prepared)
        return prepared
    }

    /// Text for accessibility, which reads each spoiler as "Spoiler",
    /// and expands custom emojis to their :name: representation.
    static func accessibilityText(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> String {
        let prepared = summary(content: content, mentionLabel: mentionLabel)
        let text = NSMutableString(string: prepared.text)

        struct Replacement {
            let range: NSRange
            let value: String
        }
        var replacements: [Replacement] = []
        for range in prepared.spoilerRanges {
            replacements.append(Replacement(range: range, value: "Spoiler"))
        }
        for emoji in prepared.emojis {
            let isInsideSpoiler = prepared.spoilerRanges.contains { spoilerRange in
                NSLocationInRange(emoji.range.location, spoilerRange)
            }
            if !isInsideSpoiler {
                replacements.append(Replacement(range: emoji.range, value: ":\(emoji.emoji.name):"))
            }
        }
        replacements.sort { $0.range.location > $1.range.location }
        for replacement in replacements {
            text.replaceCharacters(in: replacement.range, with: replacement.value)
        }
        return text as String
    }

    static func preparation(
        content: String,
        mentionLabel: (RenderedMention) -> String
    ) -> String? {
        let source = resolvedSource(content: content, mentionLabel: mentionLabel)
        return values.object(forKey: source as NSString) == nil ? source : nil
    }

    private static func resolvedSource(
        content: String,
        mentionLabel: (RenderedMention) -> String
    ) -> String {
        let document = MessageDocumentCache.shared.document(for: content)
        return document.segments.reduce(into: "") { output, segment in
            switch segment {
            case let .markdown(value):
                output += value
            case let .customEmoji(emoji):
                output += emoji.rawToken
            case let .mention(mention):
                output += mentionLabel(mention)
            }
        }
    }

    private struct ProtectedEmojiTokens {
        let protectedSource: String
        let markerPrefix: String
        let emojisByIndex: [Int: RenderedEmoji]
    }

    nonisolated private static func protectEmojiTokens(
        in source: String
    ) -> ProtectedEmojiTokens {
        let matches = emojiExpression.matches(
            in: source,
            range: NSRange(source.startIndex ..< source.endIndex, in: source)
        )
        guard !matches.isEmpty else {
            return ProtectedEmojiTokens(protectedSource: source, markerPrefix: "", emojisByIndex: [:])
        }

        var markerPrefix = "SakuraEmojiMarker"
        while source.contains(markerPrefix) {
            markerPrefix += "X"
        }

        var emojisByIndex: [Int: RenderedEmoji] = [:]
        var protectedSource = ""
        var sourceCursor = source.startIndex
        var index = 0
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            let token = String(source[range])
            guard let emoji = RenderedEmoji(rawToken: token) else { continue }
            protectedSource += source[sourceCursor ..< range.lowerBound]
            protectedSource += "\(markerPrefix)I\(index)I"
            emojisByIndex[index] = emoji
            index += 1
            sourceCursor = range.upperBound
        }
        protectedSource += source[sourceCursor...]
        return ProtectedEmojiTokens(
            protectedSource: protectedSource,
            markerPrefix: markerPrefix,
            emojisByIndex: emojisByIndex
        )
    }

    /// Collapses the rendered text's whitespace to single spaces. A collapsed
    /// space is a spoiler only inside one spoiler, and adjacent spoilers stay
    /// separate ranges. Custom emojis are extracted into `Prepared.emojis` and
    /// represented as object replacement placeholders in `text`.
    nonisolated static func prepare(_ source: String) -> Prepared {
        var text = ""
        var spoilerRanges: [NSRange] = []
        var emojis: [EmojiItem] = []
        var length = 0
        var pendingSpace = false
        var previousSpoilerID: Int?
        var rangeSpoilerID: Int?

        func append(_ value: String, spoilerID: Int?) {
            let valueLength = value.utf16.count
            if let spoilerID {
                if let last = spoilerRanges.last,
                   NSMaxRange(last) == length,
                   rangeSpoilerID == spoilerID
                {
                    spoilerRanges[spoilerRanges.count - 1].length += valueLength
                } else {
                    spoilerRanges.append(NSRange(location: length, length: valueLength))
                    rangeSpoilerID = spoilerID
                }
            }
            text += value
            length += valueLength
        }

        func flushPendingSpace(spoilerID: Int?) {
            guard pendingSpace else { return }
            append(" ", spoilerID: previousSpoilerID == spoilerID ? spoilerID : nil)
            pendingSpace = false
        }

        func appendTextSlice(_ slice: String, spoilerID: Int?) {
            for character in slice {
                if character.isWhitespace {
                    pendingSpace = !text.isEmpty
                    continue
                }
                flushPendingSpace(spoilerID: spoilerID)
                append(String(character), spoilerID: spoilerID)
                previousSpoilerID = spoilerID
            }
        }

        let protection = protectEmojiTokens(in: source)
        let protectedSource = protection.protectedSource
        let markerPrefix = protection.markerPrefix
        let emojisByIndex = protection.emojisByIndex
        let markerExpression = markerPrefix.isEmpty
            ? nil
            : RegularExpressionFactory.make("\(markerPrefix)I([0-9]+)I")

        for run in DiscordMarkdown.plainTextRuns(protectedSource) {
            guard let markerExpression, run.text.contains(markerPrefix) else {
                appendTextSlice(run.text, spoilerID: run.spoilerID)
                continue
            }
            let runString = run.text as NSString
            let markerMatches = markerExpression.matches(
                in: run.text,
                range: NSRange(location: 0, length: runString.length)
            )
            var cursor = 0
            for match in markerMatches {
                if match.range.location > cursor {
                    let before = runString.substring(with: NSRange(
                        location: cursor,
                        length: match.range.location - cursor
                    ))
                    appendTextSlice(before, spoilerID: run.spoilerID)
                }
                if let indexRange = Range(match.range(at: 1), in: run.text),
                   let index = Int(run.text[indexRange]),
                   let emoji = emojisByIndex[index]
                {
                    flushPendingSpace(spoilerID: run.spoilerID)
                    let emojiRange = NSRange(location: length, length: 1)
                    append("\u{FFFC}", spoilerID: run.spoilerID)
                    emojis.append(EmojiItem(range: emojiRange, emoji: emoji))
                    previousSpoilerID = run.spoilerID
                }
                cursor = NSMaxRange(match.range)
            }
            if cursor < runString.length {
                let after = runString.substring(from: cursor)
                appendTextSlice(after, spoilerID: run.spoilerID)
            }
        }
        guard !text.isEmpty else {
            return Prepared(source: source, text: "Attachment", spoilerRanges: [])
        }
        return Prepared(source: source, text: text, spoilerRanges: spoilerRanges, emojis: emojis)
    }

    static func install(_ prepared: Prepared) {
        values.setObject(
            CachedValue(prepared),
            forKey: prepared.source as NSString,
            cost: prepared.source.utf8.count + prepared.text.utf8.count
        )
    }
}
