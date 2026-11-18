import AppKit
import MessageRendering
import SakuraCordModels
import Synchronization
import UniformTypeIdentifiers

enum DiscordRichMessageMetrics {
    static var maximumWidth: CGFloat { InterfaceScale.metric(520) }
    /// Discord lays Components V2 out up to 600 pixels wide.
    static var componentsMaximumWidth: CGFloat { px(600) }
    static var cardCornerRadius: CGFloat { px(8) }
    static var embedCornerRadius: CGFloat { px(4) }
    /// The colour bar on an embed's or a container's leading edge.
    static var accentBarWidth: CGFloat { px(4) }
    /// A container's 16-pixel padding inside its 1-point border.
    static var cardPadding: CGFloat { px(16) + InterfaceScale.metric(1) }

    /// One of Discord's CSS pixels. Discord sizes components against its
    /// 16-pixel message text, which SakuraCord draws at `messageTextSize`,
    /// so every Discord length keeps its proportion to the text.
    nonisolated static func px(_ value: CGFloat) -> CGFloat {
        InterfaceScale.metric((value * InterfaceTypographyMetrics.messageTextSize / 16 * 2).rounded() / 2)
    }

    /// A Discord font size in pixels, as a message-content size at the
    /// default message text, so it scales with Message Font Size like `px`.
    nonisolated static func textSize(_ value: CGFloat) -> CGFloat {
        value * InterfaceTypographyMetrics.defaultMessageTextSize / 16
    }

    nonisolated static func font(_ value: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .messageSystemFont(ofSize: textSize(value), weight: weight)
    }
}

/// Discord's card colours, shared by embeds and component containers,
/// resolved from its design tokens for the midnight theme in dark mode, as
/// the spoiler cover assumes, and the light theme otherwise, then tinted the
/// way a gradient theme tints them.
enum DiscordEmbedPalette {
    /// The grey behind Discord's secondary buttons and its muted borders.
    static let grey = NSColor(srgbRed: 151 / 255, green: 151 / 255, blue: 159 / 255, alpha: 1)

    /// `--background-surface-high`.
    static var cardFill: NSColor {
        themed(NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 12 / 255, alpha: 1), light: .white)
    }

    /// `--border-subtle`.
    static var cardBorder: NSColor {
        themed(grey.withAlphaComponent(51 / 255), light: grey.withAlphaComponent(71 / 255))
    }

    /// `--border-normal`, the bar of an embed without a colour.
    static var defaultAccent: NSColor {
        themed(grey.withAlphaComponent(61 / 255), light: grey.withAlphaComponent(102 / 255))
    }

    private static func themed(_ midnight: NSColor, light: NSColor) -> NSColor {
        let theme = SakuraCordThemeStore.shared.committedTheme
        return NSColor(name: nil) { appearance in
            let isDark = appearance.isDark
            return theme.discordTinted(isDark ? midnight : light, isDark: isDark)
        }
    }
}

nonisolated enum MessageEmbedPresentationKind: Equatable {
    case hidden, bareMedia, card
}

nonisolated enum MessageEmbedPresentation {
    /// How Discord parses an embed's title and field names: only in rich
    /// embeds, and without bare links when the embed itself links.
    static func titleRules(for embed: MessageEmbed) -> RichMessageAttributedText.Rules? {
        guard embed.type?.lowercased() == "rich" else { return nil }
        return .embedTitle(allowsLinks: embed.url == nil)
    }

    static func visibleEmbeds(
        for message: Message
    ) -> [MessageEmbed] {
        // The content scans below only filter embeds: a row re-laid out for
        // every frame of a resize paid for them with none to filter.
        guard !message.embeds.isEmpty, !message.flags.contains(.suppressEmbeds), message.type != .pollResult,
              message.type != .autoModerationAction
        else { return [] }
        let (linkedEmojiURLs, sakuraCordDeepLinkActions) = contentLinks(in: message.content)
        return message.embeds.filter { embed in
            if let url = embed.url,
               let action = SakuraCordDeepLinkPresentation.action(for: url),
               sakuraCordDeepLinkActions.contains(action)
            {
                return false
            }
            return !(kind(for: embed) == .bareMedia
                && embed.url.map(linkedEmojiURLs.contains) == true)
        }
    }

    /// What the content links to, by content: a row laid out again at
    /// another width, as on every frame of a resize, scanned it each time.
    /// Keyed by the content's exact bytes: equal strings can differ in
    /// Unicode scalars, which the link parsers tell apart.
    private static let contentLinkCache = Mutex<[Data: ContentLinks]>([:])

    private typealias ContentLinks = (emojiURLs: Set<URL>, deepLinkActions: Set<SakuraCordDeepLinkAction>)

    private static func contentLinks(in content: String) -> ContentLinks {
        let key = Data(content.utf8)
        if let links = contentLinkCache.withLock({ $0[key] }) { return links }
        let links: ContentLinks = (
            LinkedImagePresentation(content: content).matchedEmojiURLs,
            Set(SakuraCordDeepLinkPresentation.all(in: content).map(\.action))
        )
        contentLinkCache.withLock { cache in
            if cache.count >= 2_048 { cache.removeAll(keepingCapacity: true) }
            cache[key] = links
        }
        return links
    }

    /// Discord represents a multi-image embed as a leading card followed by
    /// image-only entries with the same URL. Keep independent embeds separate.
    static func groupedEmbeds(_ embeds: [MessageEmbed]) -> [[MessageEmbed]] {
        var groups: [[MessageEmbed]] = []
        for embed in embeds {
            if let previous = groups.last,
               previous.count < 4,
               let first = previous.first,
               let url = first.url,
               first.image != nil, first.video == nil,
               embed.url == url, embed.image != nil, embed.video == nil,
               kind(for: embed) == .bareMedia,
               embed.author == nil, embed.title == nil, embed.description == nil,
               embed.fields.isEmpty, embed.footer == nil, embed.thumbnail == nil,
               embed.components == nil
            {
                groups[groups.count - 1].append(embed)
            } else {
                groups.append([embed])
            }
        }
        return groups
    }

    static func visibleMessageContent(
        for message: Message
    ) -> String {
        if let alert = message.autoModerationAlert {
            return AutoModAlertPresentation.headline(alert)
        }
        return visibleMessageContent(
            message.content,
            embeds: visibleEmbeds(
                for: message
            )
        )
    }

    static func kind(for embed: MessageEmbed) -> MessageEmbedPresentationKind {
        let type = embed.type?.lowercased()
        if type == "gifv" || type == "image" {
            return embed.image != nil || embed.video != nil ? .bareMedia : .hidden
        }
        let hasMedia = embed.image != nil || embed.video != nil
        let hasCardContent = embed.author != nil || embed.title != nil || embed.description != nil
            || !embed.fields.isEmpty || embed.footer != nil || embed.thumbnail != nil
        if !hasMedia, !hasCardContent {
            return .hidden
        }
        if hasMedia, !hasCardContent, embed.provider == nil {
            return .bareMedia
        }
        return .card
    }

    static func visibleMessageContent(_ content: String, embeds: [MessageEmbed]) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let rawURL = trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
            ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard let contentURL = URL(string: rawURL), contentURL.scheme != nil else { return content }
        // A multi-image post is a leading card followed by image-only embeds
        // with the same URL. Only the leading embed decides whether the link
        // is replaced: a card keeps its link, a direct media link does not.
        let replacesLink = embeds.first { $0.url == contentURL }
            .map { kind(for: $0) == .bareMedia } ?? false
        return replacesLink ? "" : content
    }
}

struct RichMediaItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case image(animated: Bool)
        case video, audio, file
        /// A text or code file, read and highlighted as its language.
        case text(language: String)
        case youtube(YouTubeEmbedPlayback)
    }

    var id: String
    var url: URL
    var previewURL: URL?
    var title: String
    var description: String?
    var width: Int?
    var height: Int?
    var size: Int
    var kind: Kind
    var isSpoiler: Bool
    var autoplaysInline: Bool
    var videoPreviewURL: URL?
    /// The type Discord declares for embed media, whose URL may have no
    /// extension, such as a tweet's image.
    var contentType: UTType?

    var canSave: Bool {
        if case .youtube = kind { return false }
        return true
    }

    func videoPosterURL(maximumPixelDimension: Int) -> URL? {
        if let videoPreviewURL { return videoPreviewURL }
        guard kind == .video else { return nil }
        return DiscordVideoPosterURL.url(
            proxyURL: previewURL,
            width: width,
            height: height,
            maximumPixelDimension: maximumPixelDimension
        )
    }

    init(_ attachment: Attachment) {
        id = attachment.id
        url = attachment.url
        previewURL = attachment.proxyURL
        title = attachment.title ?? attachment.filename
        description = attachment.description
        width = attachment.width
        height = attachment.height
        size = attachment.size
        isSpoiler = attachment.isSpoiler
        autoplaysInline = false
        kind =
            switch attachment.mediaKind {
            case .image: .image(animated: false)
            case .animatedImage: .image(animated: true)
            case .video: .video
            case .audio: .audio
            case .file: attachment.textPreviewLanguage.map { .text(language: $0) } ?? .file
            }
    }

    init(
        id: String, media: MessageEmbedMedia, fallbackTitle: String,
        autoplaysInline: Bool = false
    ) {
        self.id = id
        url = media.url ?? URL(string: "about:blank")!
        previewURL = media.proxyURL
        title = fallbackTitle
        description = media.description
        width = media.width
        height = media.height
        size = 0
        if media.contentType?.hasPrefix("video/") == true {
            kind = .video
        } else {
            kind = .image(
                animated: media.flags & 1 != 0 || media.url.map(Self.isAnimatedImageURL) == true
            )
        }
        isSpoiler = false
        self.autoplaysInline = autoplaysInline
        contentType = media.contentType.flatMap { UTType(mimeType: $0) }
    }

    init?(embed: MessageEmbed, attachments: [Attachment]) {
        guard var media = embed.video ?? embed.image else { return nil }
        if let raw = media.url?.absoluteString,
           raw.hasPrefix("attachment://"),
           let attachment = attachments.first(where: {
               $0.filename == String(raw.dropFirst("attachment://".count))
           })
        {
            self.init(attachment)
            return
        }
        guard media.url != nil else { return nil }
        if embed.video != nil {
            media.contentType = "video/unknown"
            if media.width == nil {
                media.width = embed.thumbnail?.width ?? embed.image?.width
            }
            if media.height == nil {
                media.height = embed.thumbnail?.height ?? embed.image?.height
            }
        }
        self.init(
            id: "\(embed.id)-media",
            media: media,
            fallbackTitle: embed.title ?? "Embed media",
            autoplaysInline: embed.isGIFV
        )
        if embed.video != nil {
            let preview = embed.thumbnail ?? embed.image
            videoPreviewURL = preview?.proxyURL ?? preview?.url
            if let playback = media.url.flatMap(YouTubeEmbedPlayback.init(url:)) {
                kind = .youtube(playback)
                url = playback.watchURL
            }
        }
    }

    init(id: String, media: ComponentMedia, fallbackTitle: String) {
        self.init(
            id: id,
            media: MessageEmbedMedia(
                url: media.url, proxyURL: media.proxyURL, width: media.width, height: media.height,
                description: media.description, contentType: media.contentType,
                placeholder: media.placeholder, placeholderVersion: media.placeholderVersion,
                flags: media.flags ?? 0
            ),
            fallbackTitle: fallbackTitle
        )
        isSpoiler = media.isSpoiler
    }

    init(
        imageID: String,
        url: URL,
        previewURL: URL? = nil,
        title: String,
        description: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        id = imageID
        self.url = url
        self.previewURL = previewURL
        self.title = title
        self.description = description
        self.width = width
        self.height = height
        size = 0
        kind = .image(animated: Self.isAnimatedImageURL(url))
        isSpoiler = false
        autoplaysInline = false
    }

    init(
        componentID: String,
        url: URL,
        previewURL: URL? = nil,
        title: String,
        description: String? = nil,
        isVideo: Bool
    ) {
        id = componentID
        self.url = url
        self.previewURL = previewURL
        self.title = title
        self.description = description
        width = nil
        height = nil
        size = 0
        kind = isVideo
            ? .video
            : .image(animated: Self.isAnimatedImageURL(url))
        isSpoiler = false
        autoplaysInline = false
    }

    static func isSupportedImageURL(_ url: URL) -> Bool {
        let extensions = Set([
            "apng", "avif", "gif", "heic", "heif", "jpeg", "jpg",
            "png", "tiff", "webp",
        ])
        return extensions.contains(url.pathExtension.lowercased())
    }

    static func isAnimatedImageURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "gif" || pathExtension == "apng"
    }

    var aspectRatio: CGFloat {
        Self.aspectRatio(width: width, height: height)
    }

    var intrinsicSize: CGSize? {
        Self.knownSize(width: width, height: height)
    }

    /// Width over height, or 16:9 when either is unknown.
    nonisolated static func aspectRatio(width: Int?, height: Int?) -> CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    /// The size, when both sides are known and positive.
    nonisolated static func knownSize(width: Int?, height: Int?) -> CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

/// Discord's media mosaic: one item at its own size, three as a hero beside
/// a stacked pair, and otherwise rows of two and square rows of three, led by
/// a full-width hero when the count leaves one over.
nonisolated enum MediaGalleryPlan {
    static func rowCounts(for count: Int) -> [Int] {
        switch count {
        case ...0: []
        case 1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 4: [2, 2]
        default:
            // Rows of three, after a lone hero or a pair for what is left.
            (count % 3 == 0 ? [] : [count % 3]) + Array(repeating: 3, count: count / 3)
        }
    }

    static func frames(
        count: Int, width: CGFloat, aspectRatios: [CGFloat], intrinsicSizes: [CGSize] = [],
        spacing: CGFloat, equalWidthColumns: Bool = false
    ) -> [CGRect]
    {
        guard count > 0 else { return [] }
        let maximumHeight = InterfaceScale.metric(350)
        if count == 1 {
            if let intrinsicSize = intrinsicSizes.first,
               intrinsicSize.width > 0, intrinsicSize.height > 0
            {
                let scale = min(1, width / intrinsicSize.width, maximumHeight / intrinsicSize.height)
                return [
                    CGRect(
                        x: 0, y: 0, width: intrinsicSize.width * scale,
                        height: intrinsicSize.height * scale
                    )
                ]
            }
            let ratio = max(0.2, min(12, aspectRatios.first ?? 16 / 9))
            let fittedWidth = min(width, maximumHeight * ratio)
            let fittedHeight = min(maximumHeight, fittedWidth / ratio)
            return [CGRect(x: 0, y: 0, width: fittedWidth, height: max(InterfaceScale.metric(80), fittedHeight))]
        }
        if count == 3 {
            let height = min(maximumHeight, width * 7 / 12)
            let heroWidth = (width - spacing) * (equalWidthColumns ? 1 / 2 : 2 / 3)
            let stackWidth = width - spacing - heroWidth
            let stackHeight = (height - spacing) / 2
            return [
                CGRect(x: 0, y: 0, width: heroWidth, height: height),
                CGRect(x: heroWidth + spacing, y: 0, width: stackWidth, height: stackHeight),
                CGRect(x: heroWidth + spacing, y: stackHeight + spacing, width: stackWidth, height: stackHeight)
            ]
        }
        // A row is as tall as its tallest item at the row's tile width, up
        // to 280 points, or half the 350-point grid for four items. Rows of
        // three are square.
        let rowCap = count == 4 ? (maximumHeight - spacing) / 2 : InterfaceScale.metric(280)
        var result: [CGRect] = []
        var verticalOffset: CGFloat = 0
        for columns in rowCounts(for: count) {
            let tileWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let ratios = aspectRatios.dropFirst(result.count).prefix(columns).map { max(0.2, $0) }
            let height = columns == 3
                ? tileWidth
                : min(rowCap, tileWidth / (ratios.min() ?? 1))
            for column in 0 ..< columns {
                result.append(
                    CGRect(
                        x: CGFloat(column) * (tileWidth + spacing),
                        y: verticalOffset,
                        width: tileWidth,
                        height: height
                    )
                )
            }
            verticalOffset += height + spacing
        }
        return result
    }
}

nonisolated enum MediaGalleryImagePresentation {
    static func fillsFrame(itemCount: Int) -> Bool {
        itemCount > 1
    }
}

extension MessageReplyPreview {
    /// A one-line preview of `message`. A system message is summarized,
    /// since its content is empty or only a parameter such as a new name.
    nonisolated static func presenting(_ message: Message) -> Self {
        var preview = Self(message: message)
        if message.type.hasGeneratedContent {
            preview.content = SystemMessagePresentation.previewText(for: message)
            preview.mediaKind = nil
        }
        return preview
    }
}
