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

@MainActor @Test
func `canonical previews hide when every link on their site is spoilered`() {
    let ids = concealedEmbedIDs(
        content: "||https://youtu.be/A https://youtu.be/B||",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=A")),
            MessageEmbed(id: "embed-1", type: "video", url: URL(string: "https://www.youtube.com/watch?v=B")),
        ]
    )
    #expect(ids == ["embed-0", "embed-1"])
}

@MainActor @Test
func `a link also written bare still owns its preview beside its <…> copy`() {
    let ids = concealedEmbedIDs(
        content: "||https://youtu.be/A <https://youtu.be/A>||",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=A")),
        ]
    )
    #expect(ids == ["embed-0"])
}

@MainActor @Test
func `a spoilered link keeps its preview hidden beside a <…> copy of it`() {
    let ids = concealedEmbedIDs(
        content: "||https://youtu.be/ID|| <https://youtu.be/ID>",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=ID")),
        ]
    )
    #expect(ids == ["embed-0"])
}

@MainActor @Test
func `a visible link's preview stays visible beside a spoilered <…> copy of it`() {
    let ids = concealedEmbedIDs(
        content: "||<https://youtu.be/ID>|| https://youtu.be/ID",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=ID")),
        ]
    )
    #expect(ids.isEmpty)
}

@MainActor @Test
func `previews of spoilered short links on other sites hide`() {
    let ids = concealedEmbedIDs(
        content: "||https://bit.ly/A|| ||https://bit.ly/B||",
        embeds: [
            MessageEmbed(id: "embed-0", type: "article", url: URL(string: "https://news.example.com/a")),
            MessageEmbed(id: "embed-1", type: "article", url: URL(string: "https://blog.example.org/b")),
        ]
    )
    #expect(ids == ["embed-0", "embed-1"])
}

@MainActor @Test
func `a link shown in code does not count as a copy of a spoilered one`() {
    let ids = concealedEmbedIDs(
        content: "`<https://youtu.be/ID>` ||https://youtu.be/ID||",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=ID")),
        ]
    )
    #expect(ids == ["embed-0"])
}

@MainActor @Test
func `escaped backticks around a <…> copy still leave the spoilered link's preview hidden`() {
    let ids = concealedEmbedIDs(
        content: #"\`<https://youtu.be/ID>\` ||https://youtu.be/ID||"#,
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=ID")),
        ]
    )
    #expect(ids == ["embed-0"])
}

@MainActor @Test
func `a masked <…> copy of a spoilered link leaves its preview hidden`() {
    let ids = concealedEmbedIDs(
        content: "||https://youtu.be/ID|| [watch](<https://youtu.be/ID>)",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=ID")),
        ]
    )
    #expect(ids == ["embed-0"])
}

@MainActor @Test
func `a <…> copy right against a spoilered link leaves its preview hidden`() {
    let ids = concealedEmbedIDs(
        content: "<https://youtu.be/ID>||https://youtu.be/ID||",
        embeds: [
            MessageEmbed(id: "embed-0", type: "video", url: URL(string: "https://www.youtube.com/watch?v=ID")),
        ]
    )
    #expect(ids == ["embed-0"])
}
