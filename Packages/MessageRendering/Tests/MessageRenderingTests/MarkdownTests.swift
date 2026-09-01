import AppKit
import SakuraCordModels
@testable import MessageRendering
import Testing

@Test func `markdown removes delimiters`() {
    let value = DiscordMarkdown.attributed("Hello **native** `client`")
    #expect(String(value.characters) == "Hello native client")
}

@Test func `angle bracket masked links match discord rendering`() throws {
    let source =
        "[portfolio](<https://exyron.dev>) and [docs](<https://example.com/docs>)"
    let expectedText = "portfolio and docs"
    let expectedURLs = try [
        #require(URL(string: "https://exyron.dev")),
        #require(URL(string: "https://example.com/docs"))
    ]

    let swiftUIValue = DiscordMarkdown.attributed(source)
    #expect(String(swiftUIValue.characters) == expectedText)

    let appKitValue = DiscordMarkdown.appKitAttributed(source)
    #expect(appKitValue.string == expectedText)
    let string = appKitValue.string as NSString
    #expect(
        appKitValue.attribute(
            .link,
            at: string.range(of: "portfolio").location,
            effectiveRange: nil
        ) as? URL == expectedURLs[0]
    )
    #expect(
        appKitValue.attribute(
            .link,
            at: string.range(of: "docs").location,
            effectiveRange: nil
        ) as? URL == expectedURLs[1]
    )
}

@Test func `bare angle bracket autolinks match discord rendering`() throws {
    let source = "what if i do just <https://exyron.dev/>"
    let expectedURL = try #require(URL(string: "https://exyron.dev/"))
    let expectedText = "what if i do just https://exyron.dev/"

    let swiftUIValue = DiscordMarkdown.attributed(source)
    #expect(String(swiftUIValue.characters) == expectedText)

    let appKitValue = DiscordMarkdown.appKitAttributed(source)
    #expect(appKitValue.string == expectedText)
    let linkRange = (appKitValue.string as NSString).range(
        of: "https://exyron.dev/"
    )
    #expect(
        appKitValue.attribute(
            .link,
            at: linkRange.location,
            effectiveRange: nil
        ) as? URL == expectedURL
    )
}

@Test func `bare URLs keep markdown delimiters inside one intact link`() throws {
    let urlText =
        "https://docs.google.com/document/d/abc_def__ghi/edit?tab=t.0#heading=h.foo_bar"
    let source = "Open \(urlText) to review it"
    let expectedURL = try #require(URL(string: urlText))

    let swiftUIValue = DiscordMarkdown.attributed(source)
    #expect(String(swiftUIValue.characters) == source)

    let appKitValue = DiscordMarkdown.appKitAttributed(source)
    #expect(appKitValue.string == source)
    let linkRange = (appKitValue.string as NSString).range(of: urlText)
    #expect(linkRange.length == (urlText as NSString).length)
    var effectiveLinkRange = NSRange(location: 0, length: 0)
    #expect(
        appKitValue.attribute(
            .link,
            at: linkRange.location,
            longestEffectiveRange: &effectiveLinkRange,
            in: linkRange
        ) as? URL == expectedURL
    )
    #expect(NSEqualRanges(effectiveLinkRange, linkRange))
    #expect(
        appKitValue.attribute(
            .link,
            at: NSMaxRange(linkRange) - 1,
            effectiveRange: nil
        ) as? URL == expectedURL
    )

    let firstUnderscore = (appKitValue.string as NSString).range(of: "_")
    let font = try #require(
        appKitValue.attribute(
            .font,
            at: firstUnderscore.location,
            effectiveRange: nil
        ) as? NSFont
    )
    #expect(!font.fontDescriptor.symbolicTraits.contains(.italic))
    #expect(
        appKitValue.attribute(
            .underlineStyle,
            at: linkRange.location,
            effectiveRange: nil
        ) == nil
    )
}

@Test func `bare URLs exclude sentence punctuation and keep balanced parentheses`() throws {
    let first = "https://example.com/docs"
    let second = "https://en.wikipedia.org/wiki/Function_(mathematics)"
    let source = "Read \(first), then \(second)."
    let value = DiscordMarkdown.appKitAttributed(source)

    #expect(value.string == source)
    let string = value.string as NSString
    for expected in [first, second] {
        let range = string.range(of: expected)
        #expect(range.location != NSNotFound)
        #expect(
            value.attribute(.link, at: range.location, effectiveRange: nil)
                as? URL == URL(string: expected)
        )
        #expect(
            value.attribute(
                .link,
                at: NSMaxRange(range) - 1,
                effectiveRange: nil
            ) as? URL == URL(string: expected)
        )
    }
    let comma = string.range(of: ",").location
    let period = string.range(of: ".", options: .backwards).location
    #expect(value.attribute(.link, at: comma, effectiveRange: nil) == nil)
    #expect(value.attribute(.link, at: period, effectiveRange: nil) == nil)
}

@Test func `bare URL rendering rejects a scheme without a host`() {
    let value = DiscordMarkdown.appKitAttributed("broken https:// remains plain")

    #expect(value.string == "broken https:// remains plain")
    #expect(value.attribute(.link, at: 7, effectiveRange: nil) == nil)
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

    let angleBracketRendered = DiscordMarkdown.appKitAttributed(
        "[safe-looking label](<file:///Users/example/private.txt>)"
    )
    #expect(
        angleBracketRendered.attribute(.link, at: 0, effectiveRange: nil) == nil
    )

    let unsafeAutolink = DiscordMarkdown.appKitAttributed(
        "<file:///Users/example/private.txt>"
    )
    #expect(unsafeAutolink.string == "<file:///Users/example/private.txt>")
    #expect(
        unsafeAutolink.attribute(.link, at: 0, effectiveRange: nil) == nil
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
