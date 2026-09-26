import AppKit
import CoreGraphics
import Foundation
import SakuraCordModels
@testable import SakuraCord
import Testing

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
        !TimelineInlineVideoPolicy
            .canvasOwnsLoadingSurface(
                mediaIsVideo: true,
                autoplaysInline: true
            )
    )
    #expect(
        TimelineInlineVideoPolicy
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

@MainActor @Test
func `plain Discord attachment GIF plays inline without a server embed`() throws {
    let url = try #require(URL(
        string: "https://media.discordapp.net/attachments/1/2/example.gif?width=640"
    ))
    let message = Message(
        id: MessageID(rawValue: 101),
        channelID: ChannelID(rawValue: 102),
        author: User(
            id: UserID(rawValue: 103),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Look \(url.absoluteString)!"
    )

    let presentation = MessageEmbedPresentation.linkedImagePresentation(for: message)
    #expect(presentation.visibleText == "Look!")
    #expect(presentation.images.map(\.url) == [url])
    #expect(presentation.images[0].displayURL.pathExtension == "gif")

    let textPlan = NativeTimelineTextPlan.make(for: message)
    #expect(textPlan.linkedImages == presentation.images)
    let viewer = try #require(NativeTimelineMediaViewerPlan.linkedImages(
        in: message,
        selectedReferenceID: presentation.images[0].id
    ))
    #expect(viewer.items.map(\.url) == [url])
}

@MainActor @Test
func `plain attachment media respects suppressed and already rendered embeds`() throws {
    let url = try #require(URL(string: "https://cdn.discordapp.com/attachments/1/2/example.gif"))
    let author = User(
        id: UserID(rawValue: 103),
        username: "fixture",
        displayName: "Fixture"
    )
    let suppressed = Message(
        id: MessageID(rawValue: 104),
        channelID: ChannelID(rawValue: 102),
        author: author,
        content: url.absoluteString,
        flags: [.suppressEmbeds]
    )
    #expect(MessageEmbedPresentation.linkedImagePresentation(for: suppressed).images.isEmpty)
    #expect(
        MessageEmbedPresentation.linkedImagePresentation(for: suppressed).visibleText
            == url.absoluteString
    )

    let embedded = Message(
        id: MessageID(rawValue: 105),
        channelID: ChannelID(rawValue: 102),
        author: author,
        content: "Look \(url.absoluteString)",
        embeds: [MessageEmbed(
            type: "image",
            url: url,
            image: MessageEmbedMedia(url: url)
        )]
    )
    #expect(MessageEmbedPresentation.linkedImagePresentation(for: embedded).images.isEmpty)
    #expect(
        MessageEmbedPresentation.linkedImagePresentation(for: embedded).visibleText
            == embedded.content
    )
    #expect(LinkedImagePresentation(content: "<\(url.absoluteString)>").images.isEmpty)
}

@MainActor @Test
func `Discord attachment GIF still displays when its embed has no renderable media`() throws {
    let url = try #require(URL(string:
        "https://media.discordapp.net/attachments/708718994214879262/1142397887863590920/576D3811-DF63-4D10-8488-42BE96B7270F.gif"
    ))
    let message = Message(
        id: MessageID(rawValue: 106),
        channelID: ChannelID(rawValue: 102),
        author: User(
            id: UserID(rawValue: 103),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: url.absoluteString,
        embeds: [MessageEmbed(type: "image", url: url)]
    )

    let presentation = MessageEmbedPresentation.linkedImagePresentation(for: message)
    #expect(presentation.visibleText.isEmpty)
    #expect(presentation.images.map(\.url) == [url])
    #expect(NativeTimelineTextPlan.make(for: message).linkedImages == presentation.images)
}

@Test func `bare attachment links inside spoilers and code stay in the message text`() throws {
    let url = try #require(URL(string:
        "https://cdn.discordapp.com/attachments/1/2/private.gif"
    ))
    for content in [
        "||\(url.absoluteString)||",
        "`\(url.absoluteString)`",
        "```\n\(url.absoluteString)\n```",
    ] {
        let presentation = LinkedImagePresentation(content: content)
        #expect(presentation.images.isEmpty)
        #expect(presentation.visibleText == content)
    }
    let mixed = LinkedImagePresentation(
        content: "||\(url.absoluteString)|| \(url.absoluteString)"
    )
    #expect(mixed.images.map(\.url) == [url])
    #expect(mixed.visibleText == "||\(url.absoluteString)||")
}

@MainActor @Test
func `spoilered Discord attachment link keeps a clickable filename after reveal`() throws {
    let url = try #require(URL(string:
        "https://media.discordapp.net/attachments/1/2/example.gif"
    ))
    let author = User(
        id: UserID(rawValue: 103),
        username: "fixture",
        displayName: "Fixture"
    )
    let embedURL = try #require(URL(string: url.absoluteString + "?width=400"))
    let embed = MessageEmbed(
        type: "image",
        url: embedURL,
        image: MessageEmbedMedia(url: embedURL)
    )
    let angleBracketed = Message(
        id: MessageID(rawValue: 107),
        channelID: ChannelID(rawValue: 102),
        author: author,
        content: "<\(url.absoluteString)>",
        embeds: [embed]
    )
    #expect(
        MessageEmbedPresentation.visibleMessageContent(for: angleBracketed)
            == angleBracketed.content
    )
    #expect(MessageEmbedPresentation.visibleEmbeds(for: angleBracketed).isEmpty)

    for content in [
        "||<\(url.absoluteString)>||",
        "||\(url.absoluteString)||",
    ] {
        let spoilered = Message(
            id: MessageID(rawValue: 108),
            channelID: ChannelID(rawValue: 102),
            author: author,
            content: content,
            embeds: [embed]
        )
        let plan = NativeTimelineTextPlan.make(for: spoilered)
        #expect(MessageEmbedPresentation.visibleEmbeds(for: spoilered).isEmpty)
        let prepared = try #require(plan.preparedText)
        let value = NativeTimelineCoreText.make(
            prepared: prepared,
            emojiSize: 22,
            mentionPresentations: [:]
        )
        #expect(value.string == "📎 example.gif")
        #expect(value.attribute(.link, at: 0, effectiveRange: nil) as? URL == url)
        #expect(value.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .clear)
        #expect(value.attribute(.discordMarkdownAttachmentLink, at: 0, effectiveRange: nil) != nil)

        let framesetter = CTFramesetterCreateWithAttributedString(value)
        let hidden = NativeTimelineRowPainter.preparedDrawingText(
            value,
            framesetter: framesetter,
            hoveredLinkCharacterIndex: nil,
            underlinesLinks: false,
            revealedSpoilerLocations: []
        ).0
        let revealed = NativeTimelineRowPainter.preparedDrawingText(
            value,
            framesetter: framesetter,
            hoveredLinkCharacterIndex: nil,
            underlinesLinks: false,
            revealedSpoilerLocations: [0]
        ).0
        #expect(hidden.attribute(.discordMarkdownSpoiler, at: 0, effectiveRange: nil) != nil)
        #expect(revealed.attribute(.discordMarkdownSpoiler, at: 0, effectiveRange: nil) == nil)
        #expect(revealed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .linkColor)
    }
}
