import AppKit
import SakuraCordModels
@testable import MessageRendering
import Testing

@Test func `server invite recognition excludes code and lookalike hosts while deduplicating bare URLs`() {
    let source = """
    discord.gg/Valid https://discord.com/invite/Valid discordapp.com/invite/Other
    ||https://discord.gg/Third|| ||discord.gg/BareSpoiler|| ||[hidden](https://discord.gg/Masked)||
    <https://discord.gg/Third> https://notdiscord.gg/Hidden
    `discord.gg/Inline`
    ```
    discord.gg/Fenced
    ```
    discord.gg/ie3urhej
    ||https://discord.gg/HiddenInvite||
    """
    #expect(DiscordMarkdown.serverInviteReferences(in: source).map(\.code) == ["Valid", "Other", "Third", "ie3urhej"])
    #expect(ServerInviteReference("https://discord.gg@evil.example/test") == nil)
    #expect(ServerInviteReference("https://discord.gg/a/b") == nil)
    #expect(ServerInviteReference("../users/@me") == nil)
}

@Test func `markdown removes delimiters`() {
    let value = DiscordMarkdown.attributed("Hello **native** `client`")
    #expect(String(value.characters) == "Hello native client")
    let widgetSource = "# **Bold** __underlined__ *italic* `code` ~~strike~~ ||spoiler||\n[label](https://example.com) <a:emoji:123>"
    let widget = DiscordMarkdown.profileWidgetAttributed(widgetSource)
    #expect(String(widget.characters) == "# Bold underlined italic `code` ~~strike~~ ||spoiler||\nlabel <a:emoji:123>")
    #expect(widget.runs.contains { $0.link?.absoluteString == "https://example.com" })
    let preview = DiscordMarkdown.profileWidgetAttributed(widgetSource, links: false)
    #expect(preview.runs.allSatisfy { $0.link == nil })

    // Composer nesting must not change the established message renderer.
    let message = "**bold *literal** then *italic*"
    _ = DiscordMarkdown.sourceFormats(message)
    let rendered = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(message))
    #expect(rendered.string == "bold *literal then italic")
    let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("**text [label*](https://example.com) end**")).string == "text label* end")
}

// Leaderboard bots name fields `1. Alice`; Discord shows these and other
// block syntax as text in embed titles and field names.
@Test func `embed titles parse inline markdown without lists headings or subtext`() throws {
    for source in ["1. Alice", "- Daily", "# Weekly", "-# beta"] {
        let plan = DiscordMarkdown.appKitPlan(source, rules: .embedTitle(allowsLinks: true))
        let rendered = DiscordMarkdown.appKitAttributed(plan)
        #expect(rendered.string == source)
        #expect(rendered.attribute(.discordMarkdownListMarker, at: 0, effectiveRange: nil) == nil)
        let font = try #require(rendered.attribute(.font, at: rendered.length - 1, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == 15)
    }
    let linked = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("[x](https://a.example) *Level*", rules: .embedTitle(allowsLinks: false)))
    #expect(linked.string == "[x](https://a.example) Level")
    #expect(linked.attribute(.link, at: 5, effectiveRange: nil) == nil)
    // Titles never parse masked links; their URLs still link, with Discord's
    // link text, when the embed doesn't.
    let unlinked = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("[x](https://a.example)", rules: .embedTitle(allowsLinks: true)))
    #expect(unlinked.string == "[x](https://a.example/)")
    #expect(unlinked.attribute(.link, at: 0, effectiveRange: nil) == nil)
    #expect(unlinked.attribute(.link, at: 5, effectiveRange: nil) != nil)
    // Italic keeps the title's semibold weight.
    let italic = try #require(linked.attribute(.font, at: linked.length - 1, effectiveRange: nil) as? NSFont)
    #expect(italic.fontName.contains("SemiboldItalic"))
}

// Discord's code rules: inline code closes at a backtick run of its own
// length, and a block opens at any three backticks and closes at the next
// three, even mid-line.
@Test func `code closes at matching backtick runs and the next fence`() {
    func code(_ source: String) -> [String] {
        let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))
        var kinds: [(kind: String, text: String)] = []
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            let kind = attributes[.discordMarkdownInlineCode] != nil ? "inline" : (attributes[.discordMarkdownBlock] as? String ?? "text")
            let text = (value.string as NSString).substring(with: range)
            if kinds.last?.kind == kind { kinds[kinds.count - 1].text += text } else { kinds.append((kind, text)) }
        }
        return kinds.map { "\($0.kind):\($0.text)" }
    }
    #expect(code("``a`b`` c") == ["inline:a`b", "text: c"])
    #expect(code("``a` c") == ["inline:`a", "text: c"])
    #expect(code("```code```\nhello") == ["code:code", "text:\nhello"])
    #expect(code("```\ncode```after") == ["code:code", "text:\nafter"])
    let title = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("```x``` ``y``", rules: .embedTitle(allowsLinks: true)))
    #expect(title.string == "x y")
    // A fence that nothing closes is text, after an earlier one-line block.
    #expect(code("a\n```x```\n```\nunclosed") == ["text:a\n", "code:x", "text:\n```\nunclosed"])
    // A block opens at any three backticks, splitting the sentence around it.
    #expect(code("One ```x``` fence") == ["text:One \n", "code:x", "text:\n fence"])
    #expect(code("Mid-line: ```\nlet a = 1```after") == ["text:Mid-line: \n", "code:let a = 1", "text:\nafter"])
    #expect(code("```swift\n\nlet a = 1\n\n```") == ["code:let a = 1"])
    // Discord reads a spoiler before the code in it, which stays hidden.
    #expect(code("||```secret```||") == ["inline:secret"])
    // A spoiler that doesn't close on its line, or a masked link, doesn't hide a block.
    #expect(code("a || b\n```\nif (a || b) {}\n```") == ["text:a || b\n", "code:if (a || b) {}"])
    #expect(!code("[```x```](https://example.com)").contains { $0.hasPrefix("code:") })
    // The composer reads bold after a one-line block, and text after a
    // mid-line close, as message rendering does.
    let draft = "```code```\n**bold**\n```\nx\n```"
    #expect(DiscordMarkdown.sourceFormats(draft).map(\.range) == [(draft as NSString).range(of: "bold")])
    let closed = "```\nc\n```**hi**"
    let styled = DiscordMarkdown.appKitSourceAttributed(closed, attributes: [:], baseFontSize: 14, usesMessageLineHeight: false)
    let font = styled.attribute(.font, at: (closed as NSString).range(of: "hi").location, effectiveRange: nil) as? NSFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)
    #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    let oneLine = DiscordMarkdown.appKitSourceAttributed("```x```", attributes: [:], baseFontSize: 14, usesMessageLineHeight: false)
    #expect(oneLine.attribute(.discordMarkdownBlock, at: 3, effectiveRange: nil) as? String == "code")
    // Code on a block's closing line keeps its syntax colours.
    let swift = "```swift\nlet a = 1\nlet b = 2```"
    let coloured = DiscordMarkdown.appKitSourceAttributed(swift, attributes: [:], baseFontSize: 14, usesMessageLineHeight: false)
    let keyword = { (location: Int) in coloured.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor }
    #expect(keyword((swift as NSString).range(of: "let b").location) == keyword((swift as NSString).range(of: "let a").location))
    #expect(keyword((swift as NSString).range(of: "let b").location) != keyword((swift as NSString).range(of: "b = 2").location))
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

    let appKitValue = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))
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

    let appKitValue = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))
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

    let appKitValue = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))
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
    let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))

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
    let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("broken https:// remains plain"))

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
        DiscordMarkdown.appKitPlan("[safe-looking label](file:///Users/example/private.txt)")
    )
    #expect(
        rendered.attribute(.link, at: 0, effectiveRange: nil) == nil
    )

    let angleBracketRendered = DiscordMarkdown.appKitAttributed(
        DiscordMarkdown.appKitPlan("[safe-looking label](<file:///Users/example/private.txt>)")
    )
    #expect(
        angleBracketRendered.attribute(.link, at: 0, effectiveRange: nil) == nil
    )

    let unsafeAutolink = DiscordMarkdown.appKitAttributed(
        DiscordMarkdown.appKitPlan("<file:///Users/example/private.txt>")
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

@Test func `masked discord message links stay links while bare ones become pills`() {
    let link = "https://discord.com/channels/1/2/3"
    #expect(MessageDocument(source: "[Jump to original message](\(link))").segments
        == [.markdown("[Jump to original message](\(link))")])
    guard case .mention? = MessageDocument(source: "see \(link)").segments.last else {
        Issue.record("Bare message link should remain a pill")
        return
    }
}

@Test func `profile bios use Discord's bio rules for code and mentions`() {
    let source = "```swift\nlet **x** = 1 <#9>\n``` <@1> <@&2> <#3> @here <t:0:R> <:wave:4>\nhttps://discord.com/channels/1/2 ``` <t:1:R>"
    let bio = MessageDocument(source: source, rules: .profileBio)
    let mentionKinds = bio.segments.compactMap { segment -> RenderedMention.Kind? in
        guard case let .mention(mention) = segment else { return nil }
        return mention.kind
    }
    // Code holds no mentions; an unclosed fence is plain text, so the last
    // timestamp renders.
    #expect(mentionKinds == [.channel, .timestamp, .channelLink, .timestamp])
    #expect(bio.segments.contains { if case .customEmoji = $0 { true } else { false } })
    // Code keeps a custom emoji token as text, as Discord's inline code does.
    for rules in [DiscordMarkdown.Rules.message, .profileBio] {
        #expect(MessageDocument(source: "`<:x:1>`", rules: rules).segments == [.markdown("`<:x:1>`")])
        #expect(MessageDocument(source: #"\<:x:1>"#, rules: rules).segments == [.markdown(#"\<:x:1>"#)])
    }

    // A fence is inline code across lines, its Markdown kept literal.
    let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source, rules: .profileBio))
    let string = value.string as NSString
    let code = string.range(of: "swift\nlet **x** = 1 <#9>\n")
    #expect(code.location != NSNotFound)
    #expect(value.attribute(.discordMarkdownInlineCode, at: code.location, effectiveRange: nil) != nil)
    #expect(value.attribute(.discordMarkdownInlineCode, at: NSMaxRange(code) - 2, effectiveRange: nil) != nil)
    #expect(value.attribute(.discordMarkdownBlock, at: code.location, effectiveRange: nil) == nil)
    // Only the unclosed fence stays as literal backticks.
    #expect(value.string.components(separatedBy: "```").count == 2)

    // Discord retries a shorter opening run, so the extra backtick is code.
    let shorter = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("``x`", rules: .profileBio))
    #expect(shorter.string == "`x")
    #expect(shorter.attribute(.discordMarkdownInlineCode, at: 0, effectiveRange: nil) != nil)
}

@Test func `bio inline code matches Discord's rule in linear time and spans a quote's lines`() {
    // A regex scan of this bio backtracked for over half a second per pass,
    // freezing the profile popover.
    let backticks = String(repeating: "`", count: 190)
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = DiscordMarkdown.appKitPlan(backticks, rules: .profileBio) }
    #expect(elapsed < .milliseconds(250))
    // The longest opening run with a close of its length wins.
    for rules in [DiscordMarkdown.Rules.message, .profileBio] {
        #expect(DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("``a`b``", rules: rules)).string == "a`b")
        // Discord drops a space of padding beside a backtick.
        #expect(DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("`` `x` ``", rules: rules)).string == "`x`")
    }

    // Discord merges consecutive `> ` lines and parses code across them.
    let quote = "> a `b https://discord.com/channels/1/2\n> c` d"
    #expect(!MessageDocument(source: quote, rules: .profileBio).segments.contains {
        if case .mention = $0 { true } else { false }
    })
    let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(quote, rules: .profileBio))
    let code = (value.string as NSString).range(of: "b https://discord.com/channels/1/2\nc")
    #expect(code.location != NSNotFound)
    #expect(value.attribute(.discordMarkdownInlineCode, at: code.location, effectiveRange: nil) != nil)
    #expect(value.attribute(.discordMarkdownBlock, at: code.location, effectiveRange: nil) as? String == "quote")
    #expect(!value.string.contains("`"))

    // Within a `>>>` quote, `>` lines are text; a quote marker may be indented.
    for (source, expected) in [
        (">>> x\n> a `b\n> c`", "b\n> c"), (">>> x\n> a `b\nc`", "b\nc"), ("  > a `b\n  > c`", "b\nc"),
    ] {
        let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source, rules: .profileBio))
        let code = (value.string as NSString).range(of: expected)
        #expect(code.location != NSNotFound, "\(source)")
        #expect(value.attribute(.discordMarkdownInlineCode, at: code.location, effectiveRange: nil) != nil, "\(source)")
        #expect(value.attribute(.discordMarkdownBlock, at: code.location, effectiveRange: nil) as? String == "quote", "\(source)")
    }

    // A `>>>` inside code opens no quote, so the later `> ` lines stay their
    // own quote and `d`'s backtick finds no close in it.
    let inCode = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("x `a\n>>> b`\n> c `d\n> e\nf `g`", rules: .profileBio))
    let string = inCode.string as NSString
    #expect(inCode.attribute(.discordMarkdownInlineCode, at: string.range(of: "a\n>>> b").location, effectiveRange: nil) != nil)
    #expect(inCode.attribute(.discordMarkdownInlineCode, at: string.range(of: "`d").location, effectiveRange: nil) == nil)
    #expect(inCode.attribute(.discordMarkdownInlineCode, at: string.range(of: "g", options: .backwards).location, effectiveRange: nil) != nil)

    // Each line loses its own marker once; a second `>` is text.
    let nested = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("> > a `b\n> c`", rules: .profileBio))
    #expect(nested.string.hasPrefix("> a "))
    #expect(nested.attribute(.discordMarkdownInlineCode, at: (nested.string as NSString).range(of: "b\nc").location, effectiveRange: nil) != nil)
}

@Test func `bios keep headings, lists and masked links literal as Discord's bio parser does`() {
    // parseBioReact never sets allowHeading, allowList or allowLinks.
    let source = "# h\n- item\n[label](https://x.y)"
    let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source, rules: .profileBio))
    // The bare URL shows the text Discord normalizes it to.
    #expect(value.string == "# h\n- item\n[label](https://x.y/)")
    #expect(value.attribute(.discordMarkdownBlock, at: 0, effectiveRange: nil) == nil)
    #expect(value.attribute(.discordMarkdownListMarker, at: (value.string as NSString).range(of: "- item").location, effectiveRange: nil) == nil)
    #expect(value.attribute(.link, at: (value.string as NSString).range(of: "label").location, effectiveRange: nil) == nil)
    let url = (value.string as NSString).range(of: "https://x.y/")
    #expect(value.attribute(.link, at: url.location, effectiveRange: nil) as? URL == URL(string: "https://x.y"))
    #expect(value.attribute(.link, at: NSMaxRange(url), effectiveRange: nil) == nil)
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

@Test func `message document recognizes broadcast mentions at word boundaries`() {
    let document = MessageDocument(
        source: #"@everyone and @here, but not name@everyone or @hereabouts or \@everyone"#
    )
    let mentions = document.segments.compactMap { segment -> RenderedMention? in
        guard case let .mention(mention) = segment else { return nil }
        return mention
    }
    #expect(mentions.map(\.kind) == [.broadcast, .broadcast])
    #expect(mentions.map(\.rawToken) == ["@everyone", "@here"])
    #expect(!document.isEmojiOnly)
}

@Test func `message document recognizes Discord timestamps and localizes their display`() throws {
    let source = "<t:1790247407:S> <t:1790247407:f> <t:1790247407:R> <t:1790247407>"
    let document = MessageDocument(source: source)
    let mentions = document.segments.compactMap { segment -> RenderedMention? in
        guard case let .mention(mention) = segment else { return nil }
        return mention
    }
    #expect(mentions.map(\.kind) == [.timestamp, .timestamp, .timestamp, .timestamp])
    #expect(mentions.map(\.rawToken) == source.split(separator: " ").map(String.init))

    let timestamp = try #require(DiscordTimestampToken(rawToken: mentions[0].rawToken))
    #expect(timestamp.seconds == 1_790_247_407)
    #expect(timestamp.style == .shortDateMediumTime)
    #expect(timestamp.rawToken == mentions[0].rawToken)
    let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3_600))
    let localTime = timestamp.formatted(locale: Locale(identifier: "en_GB"), timeZone: timeZone)
    #expect(localTime.contains("24/09/2026"))
    #expect(localTime.contains("18:56:47"))
    #expect(DiscordTimestampToken(rawToken: "<t:1790247407:Q>") == nil)
}

@Test func `message document recognizes game profile mentions`() {
    let token = "<@$356875221078245376>"
    let document = MessageDocument(source: "Playing \(token) now")
    let mentions = document.segments.compactMap { segment -> RenderedMention? in
        guard case let .mention(mention) = segment else { return nil }
        return mention
    }
    #expect(mentions.map(\.kind) == [.game])
    #expect(mentions.first?.id == "356875221078245376")
    #expect(mentions.first?.rawToken == token)
}

@Test func `custom emoji and mentions stay literal in code and escaped text`() {
    let tokens = ["@everyone", "<t:1000000:R>", "<@$356875221078245376>", "</role add:1234>", "<@1234>", "<#1234>"]
    let raw = tokens.joined(separator: " ") + " <:x:1> <a:y:2>"
    for source in [
        "🌸 `\(raw)`", "``\(raw)``", "``a`\(raw)``", "**`\(raw)`**", "```swift\n\(raw)\n```", "```\(raw)```",
        "* `**\(raw)**`", ">>> quote\n\n* `**\(raw)**`",
        #"\@everyone \<t:1000000:R> \<@$356875221078245376> \</role add:1234> \<@1234> \<#1234> \<:x:1> \<a:y:2>"#,
        "[open](https://example.com/@here) https://example.com/@everyone",
    ] {
        #expect(MessageDocument(source: source).segments == [.markdown(source)])
    }
    // Discord shows a masked link whose label holds a mention, other than a
    // timestamp, as typed: no pill, and no link on the label.
    for label in ["</role add:1234>", "<@356875221078245376>", "@everyone", "<@$356875221078245376>"] {
        let source = "[\(label)](https://example.com)"
        #expect(MessageDocument(source: source).segments == [.markdown(source)])
        let rendered = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))
        #expect(rendered.string == source)
        #expect(rendered.attribute(.link, at: 1, effectiveRange: nil) == nil)
        #expect(rendered.attribute(.link, at: source.utf16.count - 2, effectiveRange: nil) == nil)
    }
    let timestampLink = MessageDocument(source: "[<t:1000000:R>](https://example.com)").segments
    #expect(timestampLink.contains(.mention(RenderedMention(rawToken: "<t:1000000:R>")!)))
    let mixed = MessageDocument(source: "`\(raw)` \(raw)")
    let mentions = mixed.segments.compactMap { segment -> RenderedMention? in
        guard case let .mention(mention) = segment else { return nil }
        return mention
    }
    #expect(mentions.map(\.rawToken) == tokens)
    #expect(mentions.map(\.kind) == [.broadcast, .timestamp, .game, .command, .user, .channel])
    #expect(mixed.segments.filter { if case .customEmoji = $0 { true } else { false } }.count == 2)
    // A block that closes on its own line, or mid-line, leaves the text after it.
    for source in ["```code``` <:x:1>", "```code```\n<:x:1>", "```\ncode```\n<:x:1>", "``a`` <:x:1>"] {
        #expect(MessageDocument(source: source).segments.last == .customEmoji(RenderedEmoji(rawToken: "<:x:1>")!))
    }
    #expect(mentions[3].commandName == "role add")
    let afterLink = MessageDocument(source: "[read](https://example.com)@here").segments
    #expect(afterLink.last == .mention(RenderedMention(rawToken: "@here")!))
}

@Test func `a backslash escapes punctuation only, as Discord's escape rule does`() {
    // A letter after a backslash keeps it, and a link after one still links in full.
    let rendered = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(#"C:\Users \https://example.com/foo_bar_baz \*x\*"#))
    #expect(rendered.string == #"C:\Users \https://example.com/foo_bar_baz *x*"#)
    let link = MessageDocument(source: #"\https://discord.com/channels/1/2/3"#).segments.last
    #expect(link == .mention(RenderedMention(rawToken: "https://discord.com/channels/1/2/3")!))
}

@Test func `links show the text Discord normalizes them to`() {
    // Hidden and bidirectional characters stay escaped, so a link's text
    // can't disguise where it goes.
    let cases = [
        "https://example.com": "https://example.com/",
        "<https://user:pw@EXAMPLE.com:443?#>": "https://example.com/",
        "https://bücher.de:8080/a/../Caf%C3%A9?q=it's#`x`": "https://xn--bcher-kva.de:8080/Café?q=it's#%60x%60",
        "https://example.com/%41%2F%E2%80%AEgpj.exe": "https://example.com/A%2F%E2%80%AEgpj.exe",
        "<https://example.com/\u{FE0F}secret>": "https://example.com/%EF%B8%8Fsecret",
        "https://example.com/100%25%2E": "https://example.com/100%25.",
        "https://example.com/100%": "https://example.com/100%",
    ]
    for (source, text) in cases {
        #expect(DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source)).string == text)
    }
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

@Test func `discord markdown reproduces discord nested traits and marks spoilers`() {
    let value = DiscordMarkdown.appKitAttributed(
        DiscordMarkdown.appKitPlan("**bold** _italic_ __underline__ ~~strike~~ ||secret|| ___triple___ __***all***__ ||[hidden](https://example.com)||")
    )
    #expect(value.string == "bold italic underline strike secret triple all hidden")
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
        ) != nil
    )
    // Spoilers keep their real colors; presentation conceals hidden ones.
    let spoilerLink = string.range(of: "hidden")
    #expect(
        value.attribute(
            .foregroundColor,
            at: spoiler.location,
            effectiveRange: nil
        ) as? NSColor == NSColor.labelColor
    )
    #expect(
        value.attribute(
            .foregroundColor,
            at: spoilerLink.location,
            effectiveRange: nil
        ) as? NSColor == NSColor.linkColor
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

@Test func `a draft quote with an invisible spacer line styles without crashing`() {
    let source = "> first\n>\u{FE0F}\n> last"
    let value = DiscordMarkdown.appKitSourceAttributed(
        source, attributes: [:], baseFontSize: 14, usesMessageLineHeight: false
    )
    #expect(value.string == source)
    let spacer = (source as NSString).range(of: ">\u{FE0F}")
    #expect(value.attribute(.discordMarkdownBlock, at: spacer.location, effectiveRange: nil) as? String == "quote")
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
    let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))
    #expect(!value.string.contains("```"))
    #expect(!value.string.contains("\u{001B}"))
    #expect(value.string.contains("[31mRed[0m"))
    // Discord continues a list with its first item's kind.
    #expect(value.string.contains("•\tItem\n•\tOrdered"))

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

    // JSON keys and numbers get their own appearance-aware colours.
    let key = value.attribute(.foregroundColor, at: string.range(of: "\"value\"").location, effectiveRange: nil) as? NSColor
    let number = value.attribute(.foregroundColor, at: string.range(of: "42").location, effectiveRange: nil) as? NSColor
    #expect(key != nil && number != nil && key != number)
    #expect(key != NSColor.labelColor && number != NSColor.labelColor)
}

@Test func `composer source formatting preserves UTF16 ranges and nested styles`() throws {
    let source = "🌸 **bold *italic*** and __underlined__"
    let formats = DiscordMarkdown.sourceFormats(source)
    let italic = try #require(formats.first { $0.isItalic })
    #expect((source as NSString).substring(with: italic.range) == "italic")
    #expect(italic.isBold)
    let underline = try #require(formats.first { $0.isUnderlined })
    #expect((source as NSString).substring(with: underline.range) == "underlined")
    for nested in ["***__test__***", "**__*test*__**", "*__**test**__*", "__***test***__", "*italic **bold***"] {
        let content = (nested as NSString).range(of: nested.contains("italic") ? "bold" : "test")
        let covering = DiscordMarkdown.sourceFormats(nested).filter {
            $0.range.location <= content.location && NSMaxRange($0.range) >= NSMaxRange(content)
        }
        #expect(covering.contains { $0.isBold && $0.isItalic })
        if nested.contains("__") { #expect(covering.contains { $0.isUnderlined }) }
    }

}

@Test func `source formatting excludes code escaped delimiters and URL syntax`() {
    let literal = "`**code**` \\*escaped\\* https://example.com/__path__\n```\n**fenced**\n```"
    #expect(DiscordMarkdown.sourceFormats(literal).isEmpty)
    let escapedClose = #"**one \** two**"#
    let formats = DiscordMarkdown.sourceFormats(escapedClose)
    #expect(formats.count == 1)
    #expect(formats.first.map { (escapedClose as NSString).substring(with: $0.range) } == #"one \** two"#)
    #expect(DiscordMarkdown.sourceFormats("**first\nsecond**").first?.range == NSRange(location: 2, length: 12))
    for source in ["**text [label*](https://example.com) end**", "**bold *literal** then *italic*"] {
        let bold = DiscordMarkdown.sourceFormats(source).first
        #expect(bold?.delimiter == "**")
        #expect(bold?.isBold == true)
        #expect(bold?.isItalic == false)
    }
}

@Test func `bare attachment links preserve the full URL and destination`() throws {
    for source in [
        "https://cdn.discordapp.com/attachments/1/2/funny_Giff.gif?ex=6a000000&is=69f00000&hm=ab12&",
        "https://media-eu.discordapp.net/ephemeral-attachments/3/4/clip.mp4%20tail",
        "https://cdn.discordapp.com.example.com/attachments/1/2/file.pdf",
    ] {
        let value = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source))
        #expect(value.string == source)
        var range = NSRange()
        #expect(value.attribute(.link, at: 0, effectiveRange: &range) as? URL == URL(string: source))
        #expect(range == NSRange(location: 0, length: value.length))
    }
}

@Test func `attachment links refresh when unsigned or expiring within the hour`() throws {
    let now = Date(timeIntervalSince1970: 0x6A00_0000)
    func url(_ query: String) throws -> URL {
        try #require(URL(string: "https://cdn.discordapp.com/attachments/1/2/a.png\(query)"))
    }
    #expect(DiscordAttachmentLink.needsRefresh(try url(""), now: now))
    #expect(DiscordAttachmentLink.needsRefresh(try url("?ex=zz"), now: now))
    #expect(DiscordAttachmentLink.needsRefresh(try url("?ex=6a000e10&is=1&hm=2&"), now: now))
    #expect(!DiscordAttachmentLink.needsRefresh(try url("?ex=6a000e11&is=1&hm=2&"), now: now))
    #expect(DiscordAttachmentLink.matches(try url("?ex=6a000e11&is=1&hm=2&")))
    let encodedName = "https://cdn.discordapp.com/attachments/1/2/my%20notes%E2%9C%93.txt?ex=1"
    #expect(DiscordAttachmentLink.matches(try #require(URL(string: encodedName))))
    #expect(!DiscordAttachmentLink.matches(try #require(URL(string: "https://cdn.discordapp.com/attachments/1/2/a.png#x"))))
}

/// Renders plain text with each spoiler in brackets, like `a [b] c`.
private func spoilerOutline(_ source: String) -> String {
    var output = ""
    var openSpoiler: Int?
    for run in DiscordMarkdown.plainTextRuns(source) {
        if run.spoilerID != openSpoiler {
            if openSpoiler != nil { output += "]" }
            if run.spoilerID != nil { output += "[" }
            openSpoiler = run.spoilerID
        }
        output += run.text
    }
    return output + (openSpoiler == nil ? "" : "]")
}

@Test func `spoilers follow discord's nearest non-empty delimiter rule and stay separate`() {
    let cases: [(source: String, outline: String)] = [
        ("||one||||two||", "[one][two]"),
        ("||a||b||c||", "[a]b[c]"),
        ("||||", "||||"),
        ("||", "||"),
        ("||a", "||a"),
        ("|| ||", "[ ]"),
        ("||||x||", "[||x]"),
        ("`||x||`", "||x||"),
        ("||`x`||", "[x]"),
        ("**a ||b** c||", "a ||b c||"),
        ("||a **b|| c**", "[a **b] c**"),
        (#"\|\|x\|\|"#, "||x||"),
        (#"\||x||"#, "||x||"),
    ]
    for (source, outline) in cases {
        #expect(spoilerOutline(source) == outline, "\(source)")
    }
    // Spoilers on different lines have different identifiers too.
    #expect(Set(DiscordMarkdown.plainTextRuns("||a||\n||b||").compactMap(\.spoilerID)).count == 2)

    // Adjacent spoilers are separate attribute runs, and inline code keeps
    // its own styling inside a spoiler.
    let adjacent = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("||one||||two||"))
    var ranges: [NSRange] = []
    adjacent.enumerateAttribute(
        .discordMarkdownSpoiler,
        in: NSRange(location: 0, length: adjacent.length)
    ) { value, range, _ in
        if value != nil { ranges.append(range) }
    }
    #expect(ranges == [NSRange(location: 0, length: 3), NSRange(location: 3, length: 3)])
    let code = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan("||`x`||"))
    #expect(code.attribute(.discordMarkdownInlineCode, at: 0, effectiveRange: nil) != nil)
    #expect(code.attribute(.discordMarkdownSpoiler, at: 0, effectiveRange: nil) != nil)
}

@Test func `known emoji names show as emoji, as Discord's emoji rule reads them`() {
    // Code, escapes and links keep the name; an unknown name stays text.
    let source = #"hi:wave: :+1::skin-tone-2: :nope: `:wave:` \:wave: https://x.y/:wave:"#
    for rules in [DiscordMarkdown.Rules.message, .profileBio] {
        let rendered = DiscordMarkdown.appKitAttributed(DiscordMarkdown.appKitPlan(source, rules: rules)).string
        #expect(rendered == "hi👋 👍🏼 :nope: :wave: :wave: https://x.y/:wave:")
    }
    #expect(MessageDocument(source: ":sparkles: :thumbsup::skin-tone-1:").isEmojiOnly)
    // Underscores in a name close no emphasis; a token keeps its `:name:`;
    // a symbol shows as emoji.
    let plan = DiscordMarkdown.appKitPlan("snake_case :heart_eyes: x_y <:fire:1> <t:1234:R> :tm:")
    #expect(DiscordMarkdown.appKitAttributed(plan).string == "snake_case 😍 x_y <:fire:1> <t:1234:R> ™\u{FE0F}")
    // Profile widgets parse no emoji.
    #expect(String(DiscordMarkdown.profileWidgetAttributed(":sparkles:").characters) == ":sparkles:")
}
