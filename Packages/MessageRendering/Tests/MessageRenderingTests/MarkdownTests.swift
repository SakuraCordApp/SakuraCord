@testable import MessageRendering
import Testing

@Test func `markdown removes delimiters`() {
    let value = DiscordMarkdown.attributed("Hello **native** `client`")
    #expect(String(value.characters) == "Hello native client")
}

@Test func `message document tokenizes mixed and animated custom emoji`() {
    let document = MessageDocument(source: "hello <a:wave:123> world <:still:456>")
    #expect(document.segments.count == 4)
    #expect(!document.isEmojiOnly)
    guard case let .customEmoji(animated) = document.segments[1] else {
        Issue.record("Missing animated emoji")
        return
    }
    #expect(animated.isAnimated)
    #expect(animated.rawToken == "<a:wave:123>")
}

@Test func `message document detects jumbo custom emoji`() {
    #expect(MessageDocument(source: "<:one:1> <:two:2>").isEmojiOnly)
    #expect(!MessageDocument(source: "text <:one:1>").isEmojiOnly)
}

@Test func `jumbo emoji follows discords twenty seven emoji limit across emoji types`() {
    let nativeTwentySeven = Array(repeating: "😀", count: 27).joined(separator: " ")
    let nativeTwentyEight = Array(repeating: "😀", count: 28).joined(separator: " ")
    let customTwentySeven = (1 ... 27).map { "<:emoji:\($0)>" }.joined(separator: " ")
    let customTwentyEight = (1 ... 28).map { "<:emoji:\($0)>" }.joined(separator: " ")
    let mixedTwentySeven = Array(repeating: "😀", count: 26).joined(separator: " ") + " <:emoji:27>"

    #expect(MessageDocument.maximumJumboEmojiCount == 27)
    #expect(MessageDocument(source: nativeTwentySeven).isEmojiOnly)
    #expect(!MessageDocument(source: nativeTwentyEight).isEmojiOnly)
    #expect(MessageDocument(source: customTwentySeven).isEmojiOnly)
    #expect(!MessageDocument(source: customTwentyEight).isEmojiOnly)
    #expect(MessageDocument(source: mixedTwentySeven).isEmojiOnly)
}

@Test func `message document does not enlarge plain keycap candidates`() {
    #expect(!MessageDocument(source: "123").isEmojiOnly)
    #expect(!MessageDocument(source: "#*").isEmojiOnly)
    #expect(MessageDocument(source: "😀 ✨").isEmojiOnly)
    #expect(MessageDocument(source: "1️⃣").isEmojiOnly)
}

@Test func `message document recognizes user role and channel mentions without treating them as emoji`() {
    let document = MessageDocument(source: "<@123> <@!456> <@&789> <#987>")
    let mentions = document.segments.compactMap { segment -> RenderedMention? in
        guard case let .mention(mention) = segment else { return nil }
        return mention
    }
    #expect(mentions.map(\.kind) == [.user, .user, .role, .channel])
    #expect(mentions.map(\.id) == ["123", "456", "789", "987"])
    #expect(!document.isEmojiOnly)
}

@Test func `message document recognizes discord message links as structured mentions`() throws {
    let link = "https://discord.com/channels/1523442314092089394/1523442315329405001/1529105171584389150"
    let document = MessageDocument(source: "See \(link) now")
    let mention = try #require(document.segments.compactMap { segment -> RenderedMention? in
        guard case let .mention(value) = segment else { return nil }
        return value
    }.first)

    #expect(mention.kind == .message)
    #expect(mention.messageGuildID == "1523442314092089394")
    #expect(mention.messageChannelID == "1523442315329405001")
    #expect(mention.id == "1529105171584389150")
    #expect(mention.rawToken == link)
    #expect(!document.isEmojiOnly)
}

@Test func `discord markdown preserves compact line breaks and styles headings`() {
    let value = DiscordMarkdown.attributed("*markdown*\n**bold**\n`code`\n# heading")
    #expect(String(value.characters) == "markdown\nbold\ncode\nheading")
    #expect(String(value.characters).filter { $0 == "\n" }.count == 3)
}
