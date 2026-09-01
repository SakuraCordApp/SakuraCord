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
