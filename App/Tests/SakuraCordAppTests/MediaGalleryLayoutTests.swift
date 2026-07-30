import CoreGraphics
import Foundation
import SakuraCordModels
@testable import SakuraCord
import Testing

@Test func `media gallery keeps every item visible for counts one through ten`() {
    for count in 1 ... 10 {
        let frames = MediaGalleryPlan.frames(
            count: count, width: 500, aspectRatios: Array(repeating: 16 / 9, count: count), spacing: 4
        )
        #expect(frames.count == count)
        #expect(
            frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 500.001 && $0.width > 0 && $0.height > 0 }
        )
    }
}

@Test func `media gallery uses hero arrangements and adapts to narrow panes`() {
    #expect(MediaGalleryPlan.rowCounts(for: 3) == [1, 2])
    #expect(MediaGalleryPlan.rowCounts(for: 7) == [1, 3, 3])
    #expect(MediaGalleryPlan.rowCounts(for: 10) == [1, 3, 3, 3])

    let narrow = MediaGalleryPlan.frames(count: 10, width: 220, aspectRatios: [], spacing: 4)
    let wide = MediaGalleryPlan.frames(count: 10, width: 500, aspectRatios: [], spacing: 4)
    #expect(narrow.count == wide.count)
    #expect((narrow.map(\.maxY).max() ?? 0) < (wide.map(\.maxY).max() ?? 0))
}

@Test func `media gallery continues beyond documented limits`() {
    #expect(MediaGalleryPlan.frames(count: 14, width: 500, aspectRatios: [], spacing: 4).count == 14)
}

@Test func `multi image galleries crop edge to edge while single images preserve aspect`() {
    #expect(!MediaGalleryImagePresentation.fillsFrame(itemCount: 1))
    #expect(MediaGalleryImagePresentation.fillsFrame(itemCount: 2))
    #expect(MediaGalleryImagePresentation.fillsFrame(itemCount: 4))
}

@MainActor @Test func `gifv embed media autoplays while ordinary video attachments remain click to play`() throws {
    let videoURL = try #require(URL(string: "https://cdn.example/animation.mp4"))
    let embed = RichMediaItem(
        id: "gifv", media: MessageEmbedMedia(url: videoURL, contentType: "video/mp4"),
        fallbackTitle: "GIF", autoplaysInline: true
    )
    let attachment = RichMediaItem(
        Attachment(id: "video", filename: "clip.mp4", url: videoURL, mediaType: "video/mp4")
    )
    #expect(embed.autoplaysInline)
    #expect(!attachment.autoplaysInline)
    #expect(
        !NativeTimelineInlineVideoPresentationPolicy
            .canvasOwnsLoadingSurface(
                mediaIsVideo: true,
                autoplaysInline: true
            )
    )
    #expect(
        NativeTimelineInlineVideoPresentationPolicy
            .canvasOwnsLoadingSurface(
                mediaIsVideo: true,
                autoplaysInline: false
            )
    )
}

@MainActor @Test func `linked Discord emoji and image markdown is extracted into inline media`() {
    let content = "before [wave](https://cdn.discordapp.com/emojis/123.webp?size=48) after"
    let presentation = LinkedImagePresentation(content: content)
    #expect(presentation.visibleText == content)
    #expect(presentation.images.count == 1)
    #expect(presentation.images[0].isEmoji)
    #expect(presentation.images[0].displaySize == CGSize(width: 48, height: 48))
    #expect(presentation.images[0].displayURL.path == "/emojis/123.png")

    let mediaOnly = LinkedImagePresentation(
        content: "[wave](https://cdn.discordapp.com/emojis/123.webp?size=48)"
    )
    #expect(mediaOnly.visibleText == "<:wave:123>")
    #expect(mediaOnly.images.isEmpty)
}

@MainActor @Test
func `animated linked Discord emoji use the normal animated emoji presentation`() throws {
    let sourceURL = try #require(URL(
        string:
            "https://cdn.discordapp.com/emojis/456.gif?size=48&animated=true&name=party&lossless=true"
    ))
    let presentation = LinkedImagePresentation(
        content: "[party](\(sourceURL.absoluteString))"
    )

    #expect(presentation.visibleText == "<a:party:456>")
    #expect(presentation.images.isEmpty)
    #expect(presentation.matchedEmojiURLs == Set([sourceURL]))
}

@MainActor @Test
func `linked emoji previews replace duplicate Discord bare media embeds`() throws {
    let sourceURL = try #require(URL(
        string:
            "https://cdn.discordapp.com/emojis/456.gif?size=48&animated=true&name=party&lossless=true"
    ))
    let message = Message(
        id: MessageID(rawValue: 1),
        channelID: ChannelID(rawValue: 2),
        author: User(
            id: UserID(rawValue: 3),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "hello [party](\(sourceURL.absoluteString))",
        embeds: [
            MessageEmbed(
                type: "image",
                url: sourceURL,
                image: MessageEmbedMedia(url: sourceURL)
            )
        ]
    )

    #expect(MessageEmbedPresentation.visibleEmbeds(for: message).isEmpty)
    let presentation = LinkedImagePresentation(content: message.content)
    #expect(presentation.visibleText == message.content)
    #expect(presentation.images.count == 1)
    #expect(presentation.images[0].displayURL.path == "/emojis/456.gif")
}

@MainActor @Test func `media only embeds are bare and replace solitary source links`() throws {
    let sourceURL = try #require(URL(string: "https://example.com/cat"))
    let videoURL = try #require(URL(string: "https://cdn.example/cat.mp4"))
    let gifv = MessageEmbed(
        title: "Cat", type: "gifv", url: sourceURL,
        video: MessageEmbedMedia(url: videoURL, width: 320, height: 480),
        provider: MessageEmbedProvider(name: "Example")
    )
    #expect(MessageEmbedPresentation.kind(for: gifv) == .bareMedia)
    #expect(MessageEmbedPresentation.visibleMessageContent(sourceURL.absoluteString, embeds: [gifv]).isEmpty)
    #expect(
        MessageEmbedPresentation.visibleMessageContent("Look: \(sourceURL.absoluteString)", embeds: [gifv])
            == "Look: \(sourceURL.absoluteString)"
    )

    #expect(MessageEmbedPresentation.kind(for: MessageEmbed(type: "rich")) == .hidden)
    #expect(MessageEmbedPresentation.kind(for: MessageEmbed(title: "Preview", type: "rich")) == .card)
}

@MainActor @Test
func `suppressed embeds retain their source link and expose no preview`() throws {
    let sourceURL = try #require(URL(string: "https://example.com/cat"))
    let videoURL = try #require(URL(string: "https://cdn.example/cat.mp4"))
    let embed = MessageEmbed(
        id: "suppressed-gifv",
        type: "gifv",
        url: sourceURL,
        video: MessageEmbedMedia(
            url: videoURL,
            width: 320,
            height: 480
        )
    )
    let message = Message(
        id: MessageID(rawValue: 90),
        channelID: ChannelID(rawValue: 91),
        author: User(
            id: UserID(rawValue: 92),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: sourceURL.absoluteString,
        flags: [.suppressEmbeds],
        embeds: [embed]
    )

    #expect(MessageEmbedPresentation.visibleEmbeds(for: message).isEmpty)
    #expect(
        MessageEmbedPresentation.visibleMessageContent(for: message)
            == sourceURL.absoluteString
    )
}

@Test func `single portrait media keeps its aspect ratio without letterbox space`() {
    let frame = MediaGalleryPlan.frames(count: 1, width: 500, aspectRatios: [2 / 3], spacing: 4)[0]
    #expect(frame.height == 350)
    #expect(abs(frame.width / frame.height - 2 / 3) < 0.001)
    #expect(frame.width < 500)
}

@MainActor @Test func `single small attachment keeps its intrinsic size instead of being enlarged`() throws {
    let url = try #require(URL(string: "https://cdn.example/small.png"))
    let item = RichMediaItem(
        Attachment(
            id: "small", filename: "small.png", url: url, mediaType: "image/png", width: 128,
            height: 128
        )
    )
    let frame = MediaGalleryPlan.frames(
        count: 1, width: 500, aspectRatios: [item.aspectRatio],
        intrinsicSizes: [try #require(item.intrinsicSize)],
        spacing: 4
    )[0]
    #expect(frame.size == CGSize(width: 128, height: 128))
}

@Test func `single oversized attachment is downscaled within the media cap`() {
    let frame = MediaGalleryPlan.frames(
        count: 1, width: 500, aspectRatios: [1], intrinsicSizes: [CGSize(width: 1024, height: 1024)],
        spacing: 4
    )[0]
    #expect(frame.size == CGSize(width: 350, height: 350))
}

@MainActor @Test func `component button styles use Discord semantic colors`() {
    #expect(DiscordComponentButtonAppearance.backgroundHex(for: .primary) == 0x5865F2)
    #expect(DiscordComponentButtonAppearance.backgroundHex(for: .secondary) == 0x4E5058)
    #expect(DiscordComponentButtonAppearance.backgroundHex(for: .success) == 0x248046)
    #expect(DiscordComponentButtonAppearance.backgroundHex(for: .destructive) == 0xDA373C)
}

@Test func `component emoji use one discord sized optical target`() {
    #expect(DiscordComponentEmojiMetrics.buttonSize == 16)
    #expect(DiscordComponentEmojiMetrics.selectSize == 16)
    #expect(DiscordComponentEmojiMetrics.opticalSize(for: 16) == 14)
}

@Test func `inline emoji and linked media stay on one row until the available width is exhausted`() {
    let sizes = Array(repeating: CGSize(width: 48, height: 48), count: 3)
    let wide = InlineWrappingLayoutPlan.frames(
        sizes: sizes, maximumWidth: 160, horizontalSpacing: 4, verticalSpacing: 4
    )
    #expect(wide.frames.map(\.minY) == [0, 0, 0])
    #expect(wide.frames.map(\.minX) == [0, 52, 104])
    #expect(wide.size == CGSize(width: 152, height: 48))

    let narrow = InlineWrappingLayoutPlan.frames(
        sizes: sizes, maximumWidth: 100, horizontalSpacing: 4, verticalSpacing: 4
    )
    #expect(narrow.frames.map(\.minY) == [0, 0, 52])
    #expect(narrow.frames[2].minX == 0)
}

@Test func `discord cards hug content and clamp only to the available maximum`() {
    #expect(DiscordFittingWidthPlan.width(ideal: 284, available: 900, maximum: 520) == 284)
    #expect(DiscordFittingWidthPlan.width(ideal: 760, available: 900, maximum: 520) == 520)
    #expect(DiscordFittingWidthPlan.width(ideal: 420, available: 360, maximum: 520) == 360)
    #expect(DiscordFittingWidthPlan.width(ideal: 284, available: nil, maximum: 520) == 284)
}

@MainActor @Test func `component media preserves dimensions and avoids fallback letterboxing`() throws {
    let mediaURL = try #require(URL(string: "https://cdn.example/banner.png"))
    let proxyURL = try #require(URL(string: "https://proxy.example/banner.png"))
    let item = RichMediaItem(
        id: "banner",
        media: ComponentMedia(
            url: mediaURL, proxyURL: proxyURL, width: 1200, height: 200,
            contentType: "image/png", flags: 1
        ),
        fallbackTitle: "Banner"
    )
    #expect(item.previewURL == proxyURL)
    #expect(item.aspectRatio == 6)
    guard case let .image(animated) = item.kind else {
        Issue.record("Expected component image")
        return
    }
    #expect(animated)

    let frame = MediaGalleryPlan.frames(
        count: 1, width: 500, aspectRatios: [item.aspectRatio], spacing: 4
    )[0]
    #expect(abs(frame.width / frame.height - 6) < 0.001)
}

@Test func `component container width accounts for an optional accent`() {
    #expect(
        DiscordComponentContainerLayoutPlan.width(
            idealContent: 100, available: 600, maximum: 520, padding: 12, hasAccent: false
        ) == 124
    )
    #expect(
        DiscordComponentContainerLayoutPlan.width(
            idealContent: 100, available: 600, maximum: 520, padding: 12, hasAccent: true
        ) == 128
    )
}
