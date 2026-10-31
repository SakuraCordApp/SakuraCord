import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
private func concealedEmbedIDs(content: String, embeds: [MessageEmbed]) -> Set<String> {
    let message = Message(
        id: MessageID(rawValue: 9_001),
        channelID: ChannelID(rawValue: 9_002),
        author: User(id: UserID(rawValue: 9_003), username: "spoiler.fixture", displayName: "Spoiler Fixture"),
        content: content,
        embeds: embeds
    )
    return Set(
        NativeTimelineSpoilerConcealmentPolicy.concealedEmbeds(
            in: message,
            store: NativeTimelineSpoilerRevealStore()
        ).keys
    )
}

@MainActor @Test
func `a spoilered short link hides its preview even beside a visible link`() {
    let ids = concealedEmbedIDs(
        content: "||https://youtu.be/VIDEO_ID|| https://example.com",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=VIDEO_ID")),
            MessageEmbed(id: "embed-1", type: "link", url: URL(string: "https://example.com")),
        ]
    )
    #expect(ids == ["embed-0"])
}

@MainActor @Test
func `a visible link's canonical preview stays visible beside a spoilered link`() {
    let ids = concealedEmbedIDs(
        content: "https://github.com/apple/swift and ||https://example.com/secret||",
        embeds: [
            MessageEmbed(id: "embed-0", type: "article", url: URL(string: "https://github.com/swiftlang/swift")),
        ]
    )
    #expect(ids.isEmpty)
}

@MainActor @Test
func `every card of a spoilered link hides`() {
    let url = URL(string: "https://example.com/post")
    let ids = concealedEmbedIDs(
        content: "||https://example.com/post||",
        embeds: [
            MessageEmbed(id: "embed-0", type: "rich", url: url),
            MessageEmbed(id: "embed-1", type: "rich", url: url),
        ]
    )
    #expect(ids == ["embed-0", "embed-1"])
}

@MainActor @Test
func `a visible short link's preview stays visible after a suppressed spoilered link`() {
    let ids = concealedEmbedIDs(
        content: "||<https://example.com>|| https://youtu.be/VIDEO_ID",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=VIDEO_ID")),
        ]
    )
    #expect(ids.isEmpty)
}
