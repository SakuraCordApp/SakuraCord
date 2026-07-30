import AppKit
import SakuraCordModels
@testable import MessageRendering
import Testing

@Test func `markdown removes delimiters`() {
    let value = DiscordMarkdown.attributed("Hello **native** `client`")
    #expect(String(value.characters) == "Hello native client")
}

@Test func `message link policy permits web links and classifies Discord channels`() throws {
    let webURL = try #require(URL(string: "https://example.com/docs"))
    let channelURL = try #require(
        URL(string: "https://discord.com/channels/100/220")
    )

    #expect(MessageLinkPolicy.destination(for: webURL) == .web(webURL))
    #expect(
        MessageLinkPolicy.destination(for: channelURL)
            == .discordChannel(
                guildID: GuildID(rawValue: 100),
                channelID: ChannelID(rawValue: 220)
            )
    )
}

@Test func `message link policy rejects local and custom schemes`() throws {
    let rejectedURLs = try [
        #require(URL(string: "file:///Users/example/private.txt")),
        #require(URL(string: "x-apple.systempreferences:com.apple.settings")),
        #require(URL(string: "sakuracord-test://open")),
        #require(URL(string: "javascript:alert(1)")),
        #require(URL(string: "https:relative-path"))
    ]

    #expect(rejectedURLs.allSatisfy {
        MessageLinkPolicy.destination(for: $0) == nil
    })

    let rendered = DiscordMarkdown.appKitAttributed(
        "[safe-looking label](file:///Users/example/private.txt)"
    )
    #expect(
        rendered.attribute(.link, at: 0, effectiveRange: nil) == nil
    )
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

@Test func `message document recognizes discord channel and forum post links as structured mentions`() throws {
    let link = "https://discord.com/channels/1523442314092089394/1529700953366859816"
    let document = MessageDocument(source: "See \(link) now")
    let mention = try #require(document.segments.compactMap { segment -> RenderedMention? in
        guard case let .mention(value) = segment else { return nil }
        return value
    }.first)

    #expect(mention.kind == .channelLink)
    #expect(mention.messageGuildID == "1523442314092089394")
    #expect(mention.messageChannelID == "1529700953366859816")
    #expect(mention.id == "1529700953366859816")
    #expect(mention.rawToken == link)
}

@Test func `discord markdown preserves compact line breaks and styles headings`() {
    let value = DiscordMarkdown.attributed("*markdown*\n**bold**\n`code`\n# heading")
    #expect(String(value.characters) == "markdown\nbold\ncode\nheading")
    #expect(String(value.characters).filter { $0 == "\n" }.count == 3)
}

@Test func `discord inline code exposes rounded native paint metadata`() {
    let value = DiscordMarkdown.appKitAttributed("before `code` after")
    let range = (value.string as NSString).range(of: "code")

    #expect(
        value.attribute(
            .discordMarkdownInlineCode,
            at: range.location,
            effectiveRange: nil
        ) as? NSNumber == NSNumber(value: true)
    )
    #expect(
        value.attribute(
            .backgroundColor,
            at: range.location,
            effectiveRange: nil
        ) == nil
    )
}

@Test func `discord markdown reproduces discord nested traits and hides spoilers`() {
    let value = DiscordMarkdown.appKitAttributed(
        "**bold** _italic_ __underline__ ~~strike~~ ||secret|| ___triple___ __***all***__"
    )
    #expect(value.string == "bold italic underline strike secret triple all")
    let string = value.string as NSString

    let bold = string.range(of: "bold")
    let boldFont = value.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
    #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)

    let italic = string.range(of: "italic")
    let italicFont = value.attribute(.font, at: italic.location, effectiveRange: nil) as? NSFont
    #expect(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)

    let underline = string.range(of: "underline")
    #expect(
        value.attribute(
            .underlineStyle,
            at: underline.location,
            effectiveRange: nil
        ) as? Int == NSUnderlineStyle.single.rawValue
    )

    let strike = string.range(of: "strike")
    #expect(
        value.attribute(
            .strikethroughStyle,
            at: strike.location,
            effectiveRange: nil
        ) as? Int == NSUnderlineStyle.single.rawValue
    )

    let spoiler = string.range(of: "secret")
    #expect(
        value.attribute(
            .discordMarkdownSpoiler,
            at: spoiler.location,
            effectiveRange: nil
        ) as? NSNumber == NSNumber(value: true)
    )
    #expect(
        value.attribute(
            .foregroundColor,
            at: spoiler.location,
            effectiveRange: nil
        ) as? NSColor == NSColor.clear
    )

    let triple = string.range(of: "triple")
    let tripleFont = value.attribute(
        .font,
        at: triple.location,
        effectiveRange: nil
    ) as? NSFont
    #expect(tripleFont?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    #expect(tripleFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    #expect(
        value.attribute(
            .underlineStyle,
            at: triple.location,
            effectiveRange: nil
        ) as? Int == NSUnderlineStyle.single.rawValue
    )

    let all = string.range(of: "all")
    let allFont = value.attribute(.font, at: all.location, effectiveRange: nil) as? NSFont
    #expect(allFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(allFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    #expect(
        value.attribute(
            .underlineStyle,
            at: all.location,
            effectiveRange: nil
        ) as? Int == NSUnderlineStyle.single.rawValue
    )
}

@Test func `discord markdown renders discord blocks lists code json and ansi`() {
    let source = """
    # Large
    ## Medium
    ### Small
    -# Subtext
    > Quote
    Not quoted
    - Item
    1. Ordered
    ```json
    {"value": 42}
    ```
    ```
    \u{001B}[31mRed\u{001B}[0m
    ```
    """
    let value = DiscordMarkdown.appKitAttributed(source)
    #expect(!value.string.contains("```"))
    #expect(!value.string.contains("\u{001B}"))
    #expect(value.string.contains("[31mRed[0m"))
    #expect(value.string.contains("• Item"))
    #expect(value.string.contains("1. Ordered"))

    let string = value.string as NSString
    let quote = string.range(of: "Quote")
    #expect(
        value.attribute(
            .discordMarkdownBlock,
            at: quote.location,
            effectiveRange: nil
        ) as? String == "quote"
    )
    let notQuoted = string.range(of: "Not quoted")
    #expect(
        value.attribute(
            .discordMarkdownBlock,
            at: notQuoted.location,
            effectiveRange: nil
        ) == nil
    )
    let json = string.range(of: "{\"value\": 42}")
    #expect(
        value.attribute(
            .discordMarkdownBlock,
            at: json.location,
            effectiveRange: nil
        ) as? String == "code"
    )
    let codeFont = value.attribute(
        .font,
        at: json.location,
        effectiveRange: nil
    ) as? NSFont
    #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)

    let key = string.range(of: "\"value\"")
    #expect(
        value.attribute(
            .foregroundColor,
            at: key.location,
            effectiveRange: nil
        ) as? NSColor == NSColor(
            red: 0.31,
            green: 0.63,
            blue: 0.98,
            alpha: 1
        )
    )
    let number = string.range(of: "42")
    #expect(
        value.attribute(
            .foregroundColor,
            at: number.location,
            effectiveRange: nil
        ) as? NSColor == NSColor(
            red: 0.94,
            green: 0.56,
            blue: 0.31,
            alpha: 1
        )
    )
}

@Test func `discord fenced code reserves discord block padding`() {
    let value = DiscordMarkdown.appKitAttributed(
        """
        before
        ```
        first
        second
        ```
        after
        """
    )
    let string = value.string as NSString
    let firstRange = string.range(of: "first")
    let secondRange = string.range(of: "second")
    let firstStyle = value.attribute(
        .paragraphStyle,
        at: firstRange.location,
        effectiveRange: nil
    ) as? NSParagraphStyle
    let secondStyle = value.attribute(
        .paragraphStyle,
        at: secondRange.location,
        effectiveRange: nil
    ) as? NSParagraphStyle

    #expect(firstStyle?.paragraphSpacingBefore == 17)
    #expect(firstStyle?.paragraphSpacing == 0)
    #expect(secondStyle?.paragraphSpacingBefore == 0)
    #expect(secondStyle?.paragraphSpacing == 4)
    #expect(firstStyle?.minimumLineHeight == 18)
    #expect(secondStyle?.maximumLineHeight == 18)
}

@Test func `discord lists and blank paragraphs preserve discord vertical metrics`() {
    let source = """
    Unordered List:
    - Item 1
    - Item 2

    Ordered List:
    1. Item 1
    2. Item 2

    Inline Code:
    `Hello World`
    """
    let value = DiscordMarkdown.appKitAttributed(source)
    #expect(
        value.string
            == """
            Unordered List:
            • Item 1
            • Item 2

            Ordered List:
            1. Item 1
            2. Item 2

            Inline Code:
            Hello World
            """
    )

    let string = value.string as NSString
    for item in ["• Item 1", "1. Item 1"] {
        let range = string.range(of: item)
        let style = value.attribute(
            .paragraphStyle,
            at: range.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style?.minimumLineHeight == 26)
        #expect(style?.maximumLineHeight == 26)
        #expect(style?.paragraphSpacingBefore == 4)
    }

    let bulletRange = string.range(of: "•")
    #expect(
        value.attribute(
            .discordMarkdownListMarker,
            at: bulletRange.location,
            effectiveRange: nil
        ) as? NSNumber == NSNumber(value: true)
    )
    #expect(
        value.attribute(
            .foregroundColor,
            at: bulletRange.location,
            effectiveRange: nil
        ) as? NSColor == NSColor.clear
    )

    var searchRange = NSRange(location: 0, length: string.length)
    var blankParagraphCount = 0
    while searchRange.length > 0 {
        let range = string.range(of: "\n\n", options: [], range: searchRange)
        guard range.location != NSNotFound else { break }
        let blankTerminator = range.location + 1
        let style = value.attribute(
            .paragraphStyle,
            at: blankTerminator,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style?.minimumLineHeight == 26)
        #expect(style?.maximumLineHeight == 26)
        blankParagraphCount += 1

        let nextLocation = NSMaxRange(range)
        searchRange = NSRange(
            location: nextLocation,
            length: string.length - nextLocation
        )
    }
    #expect(blankParagraphCount == 2)

    let inlineCodeRange = string.range(of: "Hello World")
    let inlineCodeStyle = value.attribute(
        .paragraphStyle,
        at: inlineCodeRange.location,
        effectiveRange: nil
    ) as? NSParagraphStyle
    #expect(inlineCodeStyle?.paragraphSpacingBefore == 5)
}
