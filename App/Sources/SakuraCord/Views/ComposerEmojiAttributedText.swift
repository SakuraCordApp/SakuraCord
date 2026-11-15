import AppKit
import MessageRendering
import SakuraCordModels

extension NSAttributedString.Key {
    nonisolated static let discordEmojiToken = NSAttributedString.Key(
        "dev.sakuracord.discord-emoji-token"
    )
}

enum ComposerEmojiAttributedText {
    static let expression = RegularExpressionFactory.make(
        #"<a?:[A-Za-z0-9_]+:[0-9]+>|"# + RenderedMention.tokenPattern
    )

    static func make(
        _ source: String,
        style: ComposerTextStyle = .composer,
        mentionPresentations: [String: MentionPresentation] = [:],
        imageProvider: (String) -> NSImage? = { ComposerEmojiImageStore.shared.cachedImage(for: $0) }
    ) -> NSAttributedString {
        let font = style.font
        let result = NSMutableAttributedString()
        var cursor = 0
        for match in attachmentMatches(in: source) {
            if match.range.location > cursor {
                result.append(
                    NSAttributedString(
                        string: (source as NSString).substring(
                            with: NSRange(location: cursor, length: match.range.location - cursor)
                        ),
                        attributes: style.attributes
                    )
                )
            }
            let token = (source as NSString).substring(with: match.range)
            if let mention = RenderedMention(rawToken: token) {
                let presentation = mentionPresentations[token]
                    ?? MentionPresentation.fallback(for: mention)
                result.append(
                    MentionAttachmentRenderer.attributedString(
                        presentation: presentation,
                        font: font
                    )
                )
                cursor = NSMaxRange(match.range)
                continue
            }
            let attachment = NSTextAttachment()
            let name = token.split(separator: ":").dropFirst().first.map(String.init) ?? "emoji"
            attachment.image = imageProvider(token)
                ?? placeholderImage(name: name, size: font.pointSize * 1.15)
            attachment.bounds = CGRect(
                x: 0,
                y: attachmentOriginY(font: font, size: font.pointSize * 1.15),
                width: font.pointSize * 1.15,
                height: font.pointSize * 1.15
            )
            let attributedAttachment = NSMutableAttributedString(attachment: attachment)
            var attachmentAttributes = style.attributes
            attachmentAttributes[.discordEmojiToken] = token
            attributedAttachment.addAttributes(
                attachmentAttributes,
                range: NSRange(location: 0, length: attributedAttachment.length)
            )
            result.append(attributedAttachment)
            cursor = NSMaxRange(match.range)
        }
        if cursor < (source as NSString).length {
            result.append(
                NSAttributedString(
                    string: (source as NSString).substring(from: cursor), attributes: style.attributes
                )
            )
        }
        ComposerMarkdownPresentation.apply(to: result, style: style)
        return result
    }

    private static func attachmentMatches(in source: String) -> [NSTextCheckingResult] {
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
        guard !matches.isEmpty else { return [] }
        let mentionRanges = renderedMentionRanges(in: source)
        return matches.filter { match in
            let token = (source as NSString).substring(with: match.range)
            // Discord's composer keeps a command mention as typed text.
            guard !token.hasPrefix("</") else { return false }
            let isNewMention = token.hasPrefix("<t:") || token.hasPrefix("<@$") || token == "@everyone" || token == "@here"
            return !isNewMention || mentionRanges.contains(match.range)
        }
    }

    private static func renderedMentionRanges(in source: String) -> Set<NSRange> {
        var ranges: Set<NSRange> = []
        var location = 0
        for segment in MessageDocumentCache.shared.document(for: source).segments {
            let text: String
            switch segment {
            case let .markdown(value): text = value
            case let .customEmoji(emoji): text = emoji.rawToken
            case let .mention(mention):
                text = mention.rawToken
                ranges.insert(NSRange(location: location, length: text.utf16.count))
            }
            location += text.utf16.count
        }
        return ranges
    }

    static func serialize(_ value: NSAttributedString, range: NSRange? = nil) -> String {
        let target = range ?? NSRange(location: 0, length: value.length)
        let source = value.string as NSString
        var result = ""
        // Font and underline runs do not affect the outgoing Markdown. Inspect
        // token metadata only where an attachment can change the source text.
        value.enumerateAttribute(.attachment, in: target) { attachment, range, _ in
            guard attachment is NSTextAttachment else {
                result += source.substring(with: range)
                return
            }
            value.enumerateAttributes(in: range) { attributes, tokenRange, _ in
                guard let token = (attributes[.discordEmojiToken] ?? attributes[.discordMentionToken]) as? String else {
                    result += source.substring(with: tokenRange)
                    return
                }
                var cursor = tokenRange.location
                while cursor < NSMaxRange(tokenRange) {
                    let composedRange = NSIntersectionRange(
                        source.rangeOfComposedCharacterSequence(at: cursor), tokenRange
                    )
                    let substring = source.substring(with: composedRange)
                    result += composedRange.length == 1 && substring == "\u{FFFC}"
                        ? token
                        : substring
                    cursor = NSMaxRange(composedRange)
                }
            }
        }
        return result
    }

    static func usesCurrentMentionPresentations(
        _ value: NSAttributedString,
        mentionPresentations: [String: MentionPresentation]
    ) -> Bool {
        var isCurrent = true
        value.enumerateAttribute(.discordMentionToken, in: NSRange(location: 0, length: value.length)) { tokenValue, range, stop in
            guard let token = tokenValue as? String,
                  let mention = RenderedMention(rawToken: token)
            else { return }
            let expected = mentionPresentations[token]
                ?? MentionPresentation.fallback(for: mention)
            value.enumerateAttribute(.attachment, in: range) { attachment, _, attachmentStop in
                guard let attachment = attachment as? MentionTextAttachment,
                      attachment.presentation == expected
                else {
                    isCurrent = false
                    attachmentStop.pointee = true
                    stop.pointee = true
                    return
                }
            }
        }
        return isCurrent
    }

    static func displayRange(forRaw range: NSRange, source: String) -> NSRange {
        let start = displayOffset(forRawOffset: range.location, source: source)
        let end = displayOffset(forRawOffset: NSMaxRange(range), source: source)
        return NSRange(location: start, length: max(0, end - start))
    }

    static func rawRange(forDisplay range: NSRange, attributed: NSAttributedString) -> NSRange {
        let start = serialize(
            attributed, range: NSRange(location: 0, length: min(range.location, attributed.length))
        ).utf16.count
        let endLocation = min(NSMaxRange(range), attributed.length)
        let end = serialize(attributed, range: NSRange(location: 0, length: endLocation)).utf16.count
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func displayOffset(forRawOffset offset: Int, source: String) -> Int {
        var reduction = 0
        for match in attachmentMatches(in: source) {
            if offset >= NSMaxRange(match.range) {
                reduction += match.range.length - 1
            } else if offset > match.range.location {
                return match.range.location - reduction + 1
            }
        }
        return max(0, offset - reduction)
    }

}

/// How a draft's plain text looks: the composer's own style, or the style
/// of the text an inline edit replaces, so the editor matches it.
struct ComposerTextStyle {
    let font: NSFont
    let attributes: [NSAttributedString.Key: Any]
    /// Sets Markdown blocks in Discord's message line heights, as the
    /// timeline does, rather than in the text's natural lines.
    var usesMessageLineHeight = false

    static var composer: Self { composer(.interfaceSystemFont(ofSize: InterfaceTypographyMetrics.messageTextSize)) }

    static func composer(_ font: NSFont) -> Self {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return Self(font: font, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ])
    }

    /// The height of a line with no text.
    var emptyLineHeight: CGFloat {
        max(
            NSLayoutManager().defaultLineHeight(for: font),
            (attributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0
        )
    }
}

extension ComposerEmojiAttributedText {
    nonisolated static func attachmentOriginY(
        font: NSFont,
        size: CGFloat
    ) -> CGFloat {
        (font.ascender + font.descender - size) / 2
    }

    static func placeholderImage(name: String, size: CGFloat) -> NSImage {
        let image = SakuraCordSystemSymbol.image(
            named: SakuraCordSystemSymbol.emojiFaceGrinning,
            accessibilityDescription: name
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        ) ?? NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = true
        return image
    }
}

@MainActor
final class ComposerEmojiImageStore {
    static let shared = ComposerEmojiImageStore()
    private let images = NSCache<NSString, NSImage>()
    private var registeredImages: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        images.countLimit = 256
    }

    func cachedImage(for token: String) -> NSImage? {
        registeredImages[token] ?? images.object(forKey: token as NSString)
    }

    func register(_ emoji: DiscordEmoji) {
        guard let url = emoji.assetURL,
              url.isFileURL,
              let image = NSImage(contentsOf: url)
        else { return }
        let displayImage = Self.preparedForInlineDisplay(image)
        registeredImages[emoji.messageToken] = displayImage
        images.setObject(displayImage, forKey: emoji.messageToken as NSString)
    }

    func image(for token: String) async -> NSImage? {
        if let cached = cachedImage(for: token) {
            return cached
        }
        if let task = inFlight[token] {
            return await task.value
        }
        let task = Task<NSImage?, Never> {
            let reference = EmojiReference(rawToken: token)
            guard let url = reference.imageURL(size: 64),
                  let data = try? await SharedMediaDataLoader.shared.data(for: url),
                  let image = NSImage(data: data)
            else { return nil }
            return Self.preparedForInlineDisplay(image)
        }
        inFlight[token] = task
        let image = await task.value
        inFlight[token] = nil
        if let image {
            images.setObject(image, forKey: token as NSString)
        }
        return image
    }

    nonisolated static func aspectFitRect(
        imageSize: NSSize,
        in bounds: NSRect
    ) -> NSRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              bounds.width > 0,
              bounds.height > 0
        else { return bounds }

        return aspectRect(for: imageSize, in: bounds, fillsFrame: false)
    }

    static func preparedForInlineDisplay(_ source: NSImage) -> NSImage {
        let sourceSize = source.size
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              abs(sourceSize.width - sourceSize.height) > 0.5
        else { return source }

        let side = max(sourceSize.width, sourceSize.height)
        let canvasSize = NSSize(width: side, height: side)
        let image = NSImage(size: canvasSize, flipped: false) { bounds in
            source.draw(
                in: aspectFitRect(imageSize: sourceSize, in: bounds),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return true
        }
        image.accessibilityDescription = source.accessibilityDescription
        return image
    }
}
