import DiscordProtocol
import AppKit
import Foundation
import MessageRendering
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `typing state supports multiple users independent refresh and self suppression`() {
    let state = TypingStateModel(expiry: .milliseconds(40))
    let channel = ChannelID(rawValue: 10)
    let current = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let amy = User(id: UserID(rawValue: 2), username: "amy", displayName: "Amy")
    let ben = User(id: UserID(rawValue: 3), username: "ben", displayName: "Ben")
    let cy = User(id: UserID(rawValue: 4), username: "cy", displayName: "Cy")

    state.receive(channelID: channel, user: current, currentUserID: current.id)
    #expect(state.presentation(in: channel) == nil)
    state.receive(channelID: channel, user: amy, currentUserID: current.id)
    #expect(state.presentation(in: channel) == "Amy is typing…")
    state.receive(channelID: channel, user: ben, currentUserID: current.id)
    #expect(state.presentation(in: channel) == "Amy and Ben are typing…")
    state.receive(channelID: channel, user: cy, currentUserID: current.id)
    #expect(state.presentation(in: channel) == "Amy, Ben, and 1 other are typing…")

    state.clear(userID: ben.id, in: channel)
    #expect(state.presentation(in: channel) == "Amy and Cy are typing…")
    let amyGeneration = state.expiryGenerationForTesting(channelID: channel, userID: amy.id)
    let oldCyGeneration = state.expiryGenerationForTesting(channelID: channel, userID: cy.id)
    state.receive(channelID: channel, user: cy, currentUserID: current.id)
    let refreshedCyGeneration = state.expiryGenerationForTesting(channelID: channel, userID: cy.id)
    state.applyExpiryForTesting(channelID: channel, userID: amy.id, generation: amyGeneration ?? 0)
    #expect(state.presentation(in: channel) == "Cy is typing…")
    state.applyExpiryForTesting(channelID: channel, userID: cy.id, generation: oldCyGeneration ?? 0)
    #expect(state.presentation(in: channel) == "Cy is typing…")
    state.applyExpiryForTesting(channelID: channel, userID: cy.id, generation: refreshedCyGeneration ?? 0)
    #expect(state.presentation(in: channel) == nil)
}

@MainActor
@Test func `typing state expires automatically`() async {
    let state = TypingStateModel(expiry: .milliseconds(10))
    let channel = ChannelID(rawValue: 20)
    let user = User(id: UserID(rawValue: 21), username: "timer", displayName: "Timer")
    state.receive(channelID: channel, user: user, currentUserID: nil)
    #expect(state.presentation(in: channel) != nil)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await eventuallyOnMain { state.presentation(in: channel) == nil })
}

@MainActor
@Test func `remote typing is channel scoped cleared by message and disconnect`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider, typingExpiry: .seconds(1))
    await model.start()
    let text = try #require(model.selectedChannel)
    let other = provider.otherUser
    let third = User(id: UserID(rawValue: 3), username: "third", displayName: "Third")

    await provider.emit(.typing(channelID: text.id, user: other))
    await provider.emit(.typing(channelID: ChannelID(rawValue: 12), user: third))
    #expect(await eventuallyOnMain { model.typingState.presentation(in: text.id) == "Other is typing…" })
    #expect(await eventuallyOnMain {
        model.typingState.presentation(in: ChannelID(rawValue: 12)) == "Third is typing…"
    })

    await provider.emit(.messageCreated(Message(
        id: MessageID(rawValue: 99),
        channelID: text.id,
        author: other,
        content: "sent"
    )))
    #expect(await eventuallyOnMain { model.typingState.presentation(in: text.id) == nil })

    await provider.emit(.connectionChanged(.disconnected))
    #expect(await eventuallyOnMain { model.typingState.presentation(in: ChannelID(rawValue: 12)) == nil })
}

@MainActor
@Test func `local typing debounces throttles and cancels for draft send and channel changes`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        localTypingTiming: .init(debounce: .milliseconds(10), throttle: .milliseconds(50))
    )
    await model.start()
    let textID = try #require(model.selectedChannelID)

    // Loading/restoring a draft is not a user edit and must not emit typing.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await provider.typingCount == 0)

    model.updateDraft("h")
    model.updateDraft("he")
    model.updateDraft("hello")
    try? await Task.sleep(for: .milliseconds(25))
    #expect(await provider.typingCount == 1)
    #expect(await provider.typingChannels == [textID])

    model.updateDraft("hello!")
    model.updateDraft("hello!!")
    try? await Task.sleep(for: .milliseconds(15))
    #expect(await provider.typingCount == 1)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await provider.typingCount == 2)

    model.updateDraft("pending")
    model.updateDraft("")
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await provider.typingCount == 2)

    model.updateDraft("send now")
    await model.send()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await provider.typingCount == 2)

    model.selectedChannelID = ChannelID(rawValue: 11)
    model.updateDraft("voice draft")
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await provider.typingCount == 2)

    model.selectedChannelID = ChannelID(rawValue: 12)
    model.updateDraft("other channel")
    model.selectedChannelID = textID
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await provider.typingCount == 2)
}

@MainActor
@Test func `mock typing is deterministic and rejects voice channels`() async throws {
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    try await provider.sendTyping(in: ChannelID(rawValue: 210))
    try await provider.sendTyping(in: ChannelID(rawValue: 210))
    #expect(await provider.typingRequests == [ChannelID(rawValue: 210), ChannelID(rawValue: 210)])
    await #expect(throws: ChatProviderError.self) {
        try await provider.sendTyping(in: ChannelID(rawValue: 230))
    }
}

@MainActor
@Test func `composer return decision covers setting shift command and IME`() {
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: false, command: false, hasMarkedText: false
    ) == .send)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: true, command: false, hasMarkedText: false
    ) == .newline)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: false, command: false, hasMarkedText: false
    ) == .newline)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: false, command: true, hasMarkedText: false
    ) == .send)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: false, command: false, hasMarkedText: true
    ) == .inputMethod)
}

@Test func `message edit submission trims edges and rejects empty input`() {
    #expect(MessageEditInputPolicy.submission(from: "") == nil)
    #expect(MessageEditInputPolicy.submission(from: " \n\t ") == nil)
    #expect(MessageEditInputPolicy.submission(from: "  edited message  \n") == "edited message")
    #expect(MessageEditInputPolicy.submission(from: "first line\nsecond line") == "first line\nsecond line")
}

@MainActor
@Test func `message edit return policy saves return preserves multiline and respects IME`() {
    #expect(MessageEditInputPolicy.returnAction(
        shift: false, command: false, hasMarkedText: false
    ) == .send)
    #expect(MessageEditInputPolicy.returnAction(
        shift: true, command: false, hasMarkedText: false
    ) == .newline)
    #expect(MessageEditInputPolicy.returnAction(
        shift: false, command: false, hasMarkedText: true
    ) == .inputMethod)
}

@Test func `message edit footer stays compact and vertically balanced`() {
    #expect(MessageEditLayoutMetrics.editorFooterSpacing == 2)
    #expect(MessageEditLayoutMetrics.footerVerticalPadding == 0)
    #expect(MessageEditLayoutMetrics.actionHeight == 22)
    #expect(MessageEditLayoutMetrics.actionHeight >= 20)
    #expect(MessageEditLayoutMetrics.keycapVerticalPadding == 1)
    #expect(MessageEditLayoutMetrics.footerIntrinsicHeight == 22)
    #expect(MessageEditLayoutMetrics.verticalContributionBelowEditor == 24)
}

@MainActor
@Test func `attachment only send works and whitespace only does not send`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let before = await provider.sendCount
    model.updateDraft("  \n")
    await model.send()
    #expect(await provider.sendCount == before)

    let attachment = URL(fileURLWithPath: "/tmp/sakuracord-test-attachment")
    await model.send(attachments: [attachment])
    #expect(await provider.sendCount == before + 1)
}

@Test func `composer insertion repairs stale selections and inserts emoji without spaces`() {
    let inserted = ComposerDraftEditing.insert(
        "✨", into: "hello", replacing: NSRange(location: 99, length: 4)
    )
    #expect(inserted == ComposerDraftEdit(
        text: "hello✨",
        selection: NSRange(location: 6, length: 0)
    ))

    let emoji = ComposerDraftEditing.insertCustomEmoji(
        "<:wave:123>", into: "hello world", replacing: NSRange(location: 5, length: 0)
    )
    #expect(emoji.text == "hello<:wave:123> world")
    #expect(emoji.selection.location == "hello<:wave:123>".utf16.count)
}

@MainActor
@Test func `colon emoji completion waits for two characters and recognizes a closing colon`() throws {
    #expect(ColonAutocompleteContext(text: ":w", selection: nil) == nil)
    let open = try #require(ColonAutocompleteContext(text: "hello :wa", selection: nil))
    #expect(open.query == "wa")
    #expect(open.range == NSRange(location: 6, length: 3))

    let closed = try #require(ClosedColonAutocompleteContext(text: "hello :wave:", selection: nil))
    #expect(closed.query == "wave")
    #expect(closed.range == NSRange(location: 6, length: 6))
}

@MainActor
@Test func `emoji completion includes other guilds and preserves linked image fallback`() throws {
    let currentGuild = GuildID(rawValue: 10)
    let otherGuild = GuildID(rawValue: 20)
    let current = DiscordEmoji(id: "100", name: "wave", guildID: currentGuild)
    let other = DiscordEmoji(id: "200", name: "wave", guildID: otherGuild)
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "wave",
        customEmojis: [current, other],
        customValue: { emoji in
            emoji.guildID == currentGuild ? emoji.messageToken : emoji.linkedImageMarkdown
        },
        customSource: { emoji in emoji.guildID == currentGuild ? "Current Server" : "Other Server" }
    )
    let custom = suggestions.filter { $0.customEmoji != nil }

    #expect(custom.map(\.customEmoji?.id) == ["100", "200"])
    #expect(custom[0].value == current.messageToken)
    #expect(custom[1].value == other.linkedImageMarkdown)
    #expect(custom.map(\.detail) == [":wave:", ":wave~1:"])
    #expect(custom.map(\.source) == ["Current Server", "Other Server"])
    #expect(custom[0].matchesCompletionName("WAVE"))
}

@Test func `message emoji permissions use Nitro tokens and non Nitro linked image fallbacks`() {
    let currentGuild = GuildID(rawValue: 10)
    let otherGuild = GuildID(rawValue: 20)
    let localStatic = DiscordEmoji(id: "100", name: "local", guildID: currentGuild)
    let remoteStatic = DiscordEmoji(id: "200", name: "remote", guildID: otherGuild)
    let localAnimated = DiscordEmoji(
        id: "300",
        name: "local_dance",
        isAnimated: true,
        guildID: currentGuild
    )
    let remoteAnimated = DiscordEmoji(
        id: "400",
        name: "remote_dance",
        isAnimated: true,
        guildID: otherGuild
    )

    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: localStatic, currentGuildID: currentGuild, premiumType: 0
    ) == localStatic.messageToken)
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: remoteStatic, currentGuildID: currentGuild, premiumType: 0
    ) == remoteStatic.linkedImageMarkdown)
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: localAnimated, currentGuildID: currentGuild, premiumType: 0
    ) == localAnimated.linkedImageMarkdown)
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: remoteAnimated, currentGuildID: currentGuild, premiumType: 0
    ) == remoteAnimated.linkedImageMarkdown)
    #expect(localAnimated.linkedImageMarkdown.contains(".gif?"))

    for premiumType in 1 ... 3 {
        #expect(DiscordEmojiPermissionPolicy.composerText(
            for: remoteStatic, currentGuildID: currentGuild, premiumType: premiumType
        ) == remoteStatic.messageToken)
        #expect(DiscordEmojiPermissionPolicy.composerText(
            for: localAnimated, currentGuildID: currentGuild, premiumType: premiumType
        ) == localAnimated.messageToken)
    }
}

@Test func `reaction emoji permissions filter new choices and allow existing reactions`() {
    let currentGuild = GuildID(rawValue: 10)
    let otherGuild = GuildID(rawValue: 20)
    let localStatic = DiscordEmoji(id: "100", name: "local", guildID: currentGuild)
    let remoteStatic = DiscordEmoji(id: "200", name: "remote", guildID: otherGuild)
    let localAnimated = DiscordEmoji(
        id: "300", name: "dance", isAnimated: true, guildID: currentGuild
    )

    #expect(DiscordEmojiPermissionPolicy.canShow(
        localStatic, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canShow(
        remoteStatic, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canShow(
        localAnimated, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canShow(
        localAnimated, for: .reaction(guildID: currentGuild), premiumType: 2
    ))
    #expect(!DiscordEmojiPermissionPolicy.canShowGuild(
        otherGuild, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canShowGuild(
        otherGuild, for: .reaction(guildID: currentGuild), premiumType: 2
    ))

    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        "👍", existingReactions: [], currentGuildEmojis: [localStatic, localAnimated], premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        localStatic.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canToggleReaction(
        remoteStatic.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canToggleReaction(
        localAnimated.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        localAnimated.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 2
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        remoteStatic.messageToken,
        existingReactions: [
            Reaction(emoji: remoteStatic.messageToken, count: 1)
        ],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        localAnimated.messageToken,
        existingReactions: [Reaction(emoji: localAnimated.messageToken, count: 1)],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
}

@MainActor
@Test func `custom emoji catalog follows server order and disambiguates duplicate names`() throws {
    let firstGuild = GuildID(rawValue: 10)
    let secondGuild = GuildID(rawValue: 20)
    let first = DiscordEmoji(id: "100", name: "catscared", guildID: firstGuild)
    let second = DiscordEmoji(id: "200", name: "catscared", guildID: secondGuild)
    let other = DiscordEmoji(id: "201", name: "scales", guildID: secondGuild)
    let ordered = DiscordCustomEmojiCatalog.ordered(
        emojisByGuild: [firstGuild: [first], secondGuild: [second, other]],
        guildOrder: [secondGuild, firstGuild]
    )

    #expect(ordered.map(\.id) == ["200", "201", "100"])
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "catscared",
        customEmojis: ordered,
        customValue: (\.messageToken)
    ).filter { $0.customEmoji != nil }
    #expect(suggestions.map(\.detail) == [":catscared:", ":catscared~1:"])
    #expect(suggestions.last?.value == first.messageToken)
    #expect(suggestions.last?.matchesCompletionName("catscared~1") == true)

    let localURL = URL(fileURLWithPath: "/tmp/catscared.webp")
    let local = DiscordEmoji(
        id: "300",
        name: "local",
        guildID: firstGuild,
        assetURL: localURL
    )
    let imageURLs = DiscordCustomEmojiCatalog.imageURLsByID(from: [first, local])
    #expect(imageURLs["100"] == first.imageURL)
    #expect(imageURLs["300"] == localURL)
}

@MainActor
@Test func `native emoji autocomplete searches aliases but displays the primary shortcode`() {
    #expect(DiscordEmojiSearchAliases.english["100"]?.contains("score") == true)
    let suggestions = NativeEmojiAutocompleteCatalog.search("fa")

    #expect(!suggestions.isEmpty)
    #expect(suggestions.contains { $0.shortcode == "alien" })
    #expect(NativeEmojiAutocompleteCatalog.search("sc").contains { $0.shortcode == "100" })
    #expect(suggestions.allSatisfy { suggestion in
        suggestion.completionNames.contains {
            EmojiSearchMatcher.autocompleteNormalized($0).contains("fa")
        }
    })
}

@MainActor
@Test func `emoji completion matches authenticated Discord visible composer order`() {
    let guildID = GuildID(rawValue: 30)
    let customNames = [
        "catscared", "SClongcat1", "SClongcat2", "SClongcat3",
        "DiscordKit", "EVIL_scared",
    ]
    let customEmojis = customNames.enumerated().map { offset, name in
        DiscordEmoji(id: String(900 + offset), name: name, guildID: guildID)
    }
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "sc",
        customEmojis: customEmojis,
        customValue: (\.messageToken),
        customSource: { _ in "Test Server" },
        discordFavoriteKeys: ["900"],
        discordSettingsAreLoaded: true
    )

    #expect(Array(suggestions.prefix(21).map(\.detail)) == [
        ":catscared:", ":SClongcat1:", ":SClongcat2:", ":SClongcat3:",
        ":scales:", ":scarf:", ":school:", ":school_satchel:", ":scientist:",
        ":scissors:", ":scooter:", ":scorpion:", ":scorpius:", ":scotland:",
        ":scream:", ":scream_cat:", ":screwdriver:", ":scroll:", ":100:",
        ":DiscordKit:", ":EVIL_scared:",
    ])
    let native = suggestions.filter { $0.customEmoji == nil }
    #expect(Array(native.prefix(15).map(\.detail)) == [
        ":scales:", ":scarf:", ":school:", ":school_satchel:", ":scientist:",
        ":scissors:", ":scooter:", ":scorpion:", ":scorpius:", ":scotland:",
        ":scream:", ":scream_cat:", ":screwdriver:", ":scroll:", ":100:",
    ])
    #expect(!native.contains { $0.detail == ":sc:" })
    #expect(NativeEmojiAutocompleteCatalog.search("sey").contains {
        $0.value == "🇸🇨" && $0.rankingName == "seychelles"
    })
}

@MainActor
@Test func `emoji completion hoists account favorites but ignores local usage order`() {
    let guildID = GuildID(rawValue: 30)
    let custom = DiscordEmoji(id: "900", name: "catscared", guildID: guildID)
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "sc",
        customEmojis: [custom],
        customValue: (\.messageToken),
        favoriteKeys: ["custom:catscared:900"],
        usageCounts: ["unicode:🙀": 10_000]
    )

    #expect(suggestions.first?.detail == ":catscared:")
    let native = suggestions.filter { $0.customEmoji == nil }
    #expect(native.first?.detail == ":scales:")
}

@MainActor
@Test func `mention tokens are atomic attachments and serialize exact raw text`() throws {
    let userID = UserID(rawValue: 123)
    let roleID = RoleID(rawValue: 456)
    let channelID = ChannelID(rawValue: 789)
    let source = "hi <@123> <@&456> <#789>"
    let values: [String: MentionPresentation] = [
        "<@123>": MentionPresentation(
            rawToken: "<@123>", label: "@Ari", target: .user(userID)
        ),
        "<@&456>": MentionPresentation(
            rawToken: "<@&456>", label: "@Design", target: .role(roleID), colorHex: 0xff5599
        ),
        "<#789>": MentionPresentation(
            rawToken: "<#789>", label: "#general", target: .channel(channelID)
        ),
    ]
    let attributed = ComposerEmojiAttributedText.make(source, mentionPresentations: values)
    var attachmentCount = 0
    attributed.enumerateAttribute(
        .discordMentionToken,
        in: NSRange(location: 0, length: attributed.length)
    ) { token, _, _ in
        if token != nil { attachmentCount += 1 }
    }

    #expect(attachmentCount == 3)
    #expect(ComposerEmojiAttributedText.serialize(attributed) == source)
}

@MainActor
@Test func `ordinary text typed around a mention serializes one exact mention token`() throws {
    let token = "<@123>"
    let presentation = MentionPresentation(
        rawToken: token,
        label: "@Ari",
        target: .user(UserID(rawValue: 123))
    )
    let textView = ComposerNSTextView()
    textView.plainTypingAttributes = ComposerEmojiAttributedText.textAttributes(
        .systemFont(ofSize: 15)
    )
    textView.textStorage?.setAttributedString(
        ComposerEmojiAttributedText.make(token, mentionPresentations: [token: presentation])
    )

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.insertText("before ", replacementRange: textView.selectedRange())
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    textView.insertText(" after", replacementRange: textView.selectedRange())

    let serialized = ComposerEmojiAttributedText.serialize(textView.attributedString())
    #expect(serialized == "before <@123> after")
    #expect(serialized.unicodeScalars.allSatisfy { $0.value != 0xFFFC })
    #expect(serialized.components(separatedBy: token).count == 2)
}

@MainActor
@Test func `pasted discord message link becomes an atomic mention and serializes unchanged`() throws {
    let link = "https://discord.com/channels/100/200/300"
    let presentation = MentionPresentation(
        rawToken: link,
        label: "# general ›",
        target: .message(
            guildID: GuildID(rawValue: 100),
            channelID: ChannelID(rawValue: 200),
            messageID: MessageID(rawValue: 300)
        )
    )

    let attributed = ComposerEmojiAttributedText.make(
        "Open \(link)",
        mentionPresentations: [link: presentation]
    )
    let attachment = try #require(attributed.attribute(
        .attachment,
        at: attributed.length - 1,
        effectiveRange: nil
    ) as? MentionTextAttachment)

    #expect(attachment.presentation.target == presentation.target)
    #expect(ComposerEmojiAttributedText.serialize(attributed) == "Open \(link)")
}

@MainActor
@Test func `pasted discord forum post link becomes an atomic post mention`() throws {
    let link = "https://discord.com/channels/100/200"
    let mention = try #require(RenderedMention(rawToken: link))
    let presentation = MentionPresentation(
        rawToken: link,
        label: "A forum post",
        target: .linkedChannel(
            guildID: GuildID(rawValue: 100),
            channelID: ChannelID(rawValue: 200)
        ),
        systemImage: ChannelIconPresentation.forumPostSystemImage
    )
    let attributed = ComposerEmojiAttributedText.make(
        "Open \(link)",
        mentionPresentations: [link: presentation]
    )
    let attachment = try #require(attributed.attribute(
        .attachment,
        at: attributed.length - 1,
        effectiveRange: nil
    ) as? MentionTextAttachment)

    #expect(mention.kind == .channelLink)
    #expect(attachment.presentation.systemImage == "bubble.left.fill")
    #expect(ComposerEmojiAttributedText.serialize(attributed) == "Open \(link)")
}

@MainActor
@Test func `pasted message link refreshes its fallback attachment when channel data resolves`() {
    let link = "https://discord.com/channels/100/200/300"
    let fallback = ComposerEmojiAttributedText.make(link)
    let resolved = MentionPresentation(
        rawToken: link,
        label: "# general ›",
        target: .message(
            guildID: GuildID(rawValue: 100),
            channelID: ChannelID(rawValue: 200),
            messageID: MessageID(rawValue: 300)
        )
    )

    #expect(!ComposerEmojiAttributedText.usesCurrentMentionPresentations(
        fallback,
        mentionPresentations: [link: resolved]
    ))
    let refreshed = ComposerEmojiAttributedText.make(
        link,
        mentionPresentations: [link: resolved]
    )
    #expect(ComposerEmojiAttributedText.usesCurrentMentionPresentations(
        refreshed,
        mentionPresentations: [link: resolved]
    ))
}

@MainActor
@Test func `channel mention only includes server for a proven cross server target`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let sourceChannel = try #require(model.selectedChannel)
    let sameGuildChannel = try #require(model.snapshot?.channels.first {
        $0.guildID == sourceChannel.guildID && $0.id != sourceChannel.id
    })
    let crossGuildChannel = try #require(model.snapshot?.channels.first {
        $0.guildID != nil && $0.guildID != sourceChannel.guildID
    })
    let message = Message(
        id: MessageID(rawValue: 999),
        channelID: sourceChannel.id,
        author: try #require(model.snapshot?.currentUser),
        content: "",
        guildID: nil
    )
    let resolver = MessageMentionResolver(model: model, message: message)
    let sameMention = try #require(RenderedMention(rawToken: "<#\(sameGuildChannel.id)>"))
    let crossMention = try #require(RenderedMention(rawToken: "<#\(crossGuildChannel.id)>"))
    let crossGuildID = try #require(crossGuildChannel.guildID)
    let crossGuildName = try #require(model.serverRailGuildsByID[crossGuildID]).name

    #expect(resolver.presentation(sameMention).label == sameGuildChannel.name)
    #expect(
        resolver.presentation(sameMention).systemImage
            == ChannelIconPresentation.systemImage(for: sameGuildChannel.kind, isHidden: false)
    )
    #expect(
        resolver.presentation(crossMention).label
            == "\(crossGuildName) / \(crossGuildChannel.name)"
    )
}

@MainActor
@Test func `message link navigation selects and publishes the exact message target`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let channel = try #require(model.snapshot?.channels.first { $0.id == ChannelID(rawValue: 200) })
    let target = MessageID(rawValue: 1001)
    model.navigate(to: channel.guildID, channelID: channel.id, messageID: target)

    #expect(await eventuallyOnMain {
        model.messageNavigationRequest?.channelID == channel.id
            && model.messageNavigationRequest?.messageID == target
    })
}

@MainActor
@Test func `notification deep link navigates within its exact account channel and message`() async
    throws
{
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let channel = try #require(model.snapshot?.channels.first { $0.id == ChannelID(rawValue: 200) })
    let target = MessageID(rawValue: 1001)
    await model.navigate(
        from: NotificationDeepLink(
            accountID: "offline",
            guildID: channel.guildID,
            channelID: channel.id,
            messageID: target
        )
    )

    #expect(await eventuallyOnMain {
        model.readState.accountID == "offline"
            && model.selectedGuildID == channel.guildID
            && model.selectedChannelID == channel.id
            && model.messageNavigationRequest?.channelID == channel.id
            && model.messageNavigationRequest?.messageID == target
    })
}

@MainActor
@Test func `notification deep link switches accounts before navigating`() async throws {
    let targetAccount = CredentialHandle(accountID: "target-account")
    let credentials = NotificationCredentialStore(handles: [targetAccount])
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: credentials,
        authenticatedProviderFactory: { _, _ in MockChatProvider() }
    )
    await model.start()
    #expect(
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "other-account")
        )
    )
    #expect(model.readState.accountID == "other-account")

    let channel = try #require(
        model.snapshot?.channels.first { $0.id == ChannelID(rawValue: 200) }
    )
    let expectedGuildID = channel.guildID
    let expectedChannelID = channel.id
    let target = MessageID(rawValue: 1001)
    await model.navigate(
        from: NotificationDeepLink(
            accountID: targetAccount.accountID,
            guildID: expectedGuildID,
            channelID: expectedChannelID,
            messageID: target
        )
    )

    let didNavigate = await eventuallyOnMain {
        model.readState.accountID == "target-account"
            && model.selectedGuildID == expectedGuildID
            && model.selectedChannelID == expectedChannelID
            && model.messageNavigationRequest?.channelID == expectedChannelID
            && model.messageNavigationRequest?.messageID == target
    }
    #expect(didNavigate)
}

@MainActor
@Test func `mention autocomplete opens immediately and scopes the replacement`() throws {
    let members = try #require(MentionAutocompleteContext(text: "hello @", selection: nil))
    #expect(members.kind == .member)
    #expect(members.query.isEmpty)
    #expect(members.range == NSRange(location: 6, length: 1))

    let channels = try #require(MentionAutocompleteContext(text: "go #gen", selection: nil))
    #expect(channels.kind == .channel)
    #expect(channels.query == "gen")
    #expect(channels.range == NSRange(location: 3, length: 4))
}

@MainActor
@Test func `member autocomplete ranks prefixes before fuzzy store order then reserves roles`() {
    func member(_ id: UInt64, _ displayName: String, _ username: String) -> Member {
        Member(
            user: User(id: UserID(rawValue: id), username: username, displayName: displayName),
            roleName: "Member",
            status: .offline
        )
    }

    let fluffy = member(1, "fluffy wizkers", "f1uffi3r_wizk3rrz")
    let kitten = member(2, "cute (and smart) kitten", "theunfunny_clown")
    let yawortsa = member(3, "yawortsa", "yawortsa")
    let giveaway = member(4, "GiveawayBot", "GiveawayBot")
    let teenarazzi = member(5, "Teenarazzi Awards", "Teenarazzi Awards")
    let idk = member(6, "Idk what my username should be", "furby2010")
    let raph = member(7, "Raphawouel", "raph9367_89144")
    let recentMessages = [
        Message(id: MessageID(rawValue: 10), channelID: ChannelID(rawValue: 20), author: idk.user, content: "oldest"),
        Message(id: MessageID(rawValue: 11), channelID: ChannelID(rawValue: 20), author: teenarazzi.user, content: "older"),
        Message(id: MessageID(rawValue: 12), channelID: ChannelID(rawValue: 20), author: giveaway.user, content: "older"),
        Message(id: MessageID(rawValue: 13), channelID: ChannelID(rawValue: 20), author: raph.user, content: "older"),
        Message(id: MessageID(rawValue: 14), channelID: ChannelID(rawValue: 20), author: yawortsa.user, content: "older"),
        Message(id: MessageID(rawValue: 15), channelID: ChannelID(rawValue: 20), author: kitten.user, content: "older"),
        Message(id: MessageID(rawValue: 16), channelID: ChannelID(rawValue: 20), author: fluffy.user, content: "newest"),
    ]
    let roles = [
        GuildRole(
            id: RoleID(rawValue: 30), name: "Yellow", position: 1, isMentionable: false
        ),
        GuildRole(id: RoleID(rawValue: 31), name: "White", position: 3),
        GuildRole(id: RoleID(rawValue: 32), name: "Giveaway Ping", position: 2),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "w",
        recentMessages: recentMessages,
        localMembers: [yawortsa, giveaway, teenarazzi, kitten, fluffy, idk, raph],
        remoteMembers: [fluffy, kitten, yawortsa, raph, giveaway, teenarazzi, idk],
        roles: roles,
        canMentionNonMentionableRoles: true
    )

    #expect(suggestions.map(\.title) == [
        "fluffy wizkers", "cute (and smart) kitten", "yawortsa", "Raphawouel",
        "GiveawayBot", "Teenarazzi Awards", "Idk what my username should be",
        "@White", "@Giveaway Ping", "@Yellow",
    ])
    #expect(suggestions.prefix(7).allSatisfy {
        if case .user = $0.target { true } else { false }
    })
    #expect(suggestions.suffix(3).allSatisfy {
        if case .role = $0.target { true } else { false }
    })
    #expect(MentionAutocompleteSuggestionFactory.memberHeading(query: "w") == "MEMBERS MATCHING @W")
}

@MainActor
@Test func `nonempty remote member search narrows stale local candidates`() {
    func member(_ id: UInt64, _ name: String) -> Member {
        Member(
            user: User(id: UserID(rawValue: id), username: name, displayName: name),
            roleName: "Member",
            status: .offline
        )
    }
    let yawortsa = member(1, "yawortsa")
    let evil = Member(
        user: User(
            id: UserID(rawValue: 2),
            username: "theunfunny_clown",
            displayName: "evil stupid cat"
        ),
        roleName: "Member",
        status: .offline
    )
    let staleFluffy = member(3, "fluffy wizkers")

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "w",
        recentMessages: [],
        localMembers: [yawortsa, evil, staleFluffy],
        remoteMembers: [yawortsa, evil],
        roles: []
    )

    #expect(suggestions.map(\.title) == ["yawortsa", "evil stupid cat"])
}

@MainActor
@Test func `empty member autocomplete uses recent authors up to the shared result limit before roles`() {
    let members = (1 ... 6).map { id in
        Member(
            user: User(
                id: UserID(rawValue: UInt64(id)),
                username: "user\(id)",
                displayName: "Member \(id)"
            ),
            roleName: "Member",
            status: .offline
        )
    }
    let messages = members.enumerated().map { index, member in
        Message(
            id: MessageID(rawValue: UInt64(index + 1)),
            channelID: ChannelID(rawValue: 20),
            author: member.user,
            content: "message"
        )
    }
    let role = GuildRole(id: RoleID(rawValue: 40), name: "Access", position: 1)

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "",
        recentMessages: messages,
        localMembers: members,
        remoteMembers: [],
        roles: [role]
    )

    #expect(suggestions.map(\.title) == [
        "Member 6", "Member 5", "Member 4", "Member 3", "Member 2", "Member 1", "@Access",
    ])
    #expect(MentionAutocompleteSuggestionFactory.memberHeading(query: "") == "MEMBERS")
}

@MainActor
@Test func `role autocomplete uses match sorter ranks and alphabetical ties`() {
    let roles = [
        GuildRole(id: RoleID(rawValue: 1), name: "Yellow", position: 100),
        GuildRole(id: RoleID(rawValue: 2), name: "Giveaway Ping", position: 200),
        GuildRole(id: RoleID(rawValue: 3), name: "White", position: 1),
        GuildRole(id: RoleID(rawValue: 4), name: "@everyone", position: 999),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "w",
        recentMessages: [],
        localMembers: [],
        remoteMembers: [],
        roles: roles
    )

    #expect(suggestions.map(\.title) == ["@White", "@Giveaway Ping", "@Yellow"])
}

@MainActor
@Test func `member autocomplete matches a global name behind a guild nickname and only exact snowflakes`() {
    let member = Member(
        user: User(
            id: UserID(rawValue: 123),
            username: "account_name",
            displayName: "Guild Nickname"
        ),
        roleName: "Member",
        status: .offline,
        globalDisplayName: "World Traveler"
    )

    let globalName = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "world",
        recentMessages: [],
        localMembers: [member],
        remoteMembers: [],
        roles: []
    )
    #expect(globalName.map(\.title) == ["Guild Nickname"])

    let partialSnowflake = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "12",
        recentMessages: [],
        localMembers: [member],
        remoteMembers: [],
        roles: []
    )
    #expect(partialSnowflake.isEmpty)

    let exactSnowflake = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "123",
        recentMessages: [],
        localMembers: [member],
        remoteMembers: [],
        roles: []
    )
    #expect(exactSnowflake.map(\.title) == ["Guild Nickname"])
}

@MainActor
@Test func `message mention labels prefer guild member display names`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let member = try #require(model.members.first)
    let channelID = try #require(model.selectedChannelID)
    let globalUser = User(
        id: member.id,
        username: member.user.username,
        displayName: "Global Display Name"
    )
    let rawToken = "<@\(member.id.rawValue)>"
    let mention = try #require(RenderedMention(rawToken: rawToken))
    let message = Message(
        id: MessageID(rawValue: 987_654),
        channelID: channelID,
        author: model.snapshot?.currentUser ?? globalUser,
        content: rawToken,
        guildID: model.selectedGuildID,
        mentionedUsers: [globalUser]
    )

    let presentation = MessageMentionResolver(model: model, message: message).presentation(mention)
    #expect(presentation.label == "@\(member.user.displayName)")
    #expect(presentation.label != "@Global Display Name")
}

@MainActor
@Test func `channel autocomplete follows guild positions and shows category metadata without duplicate hashes`() {
    let guildID = GuildID(rawValue: 50)
    let currentUser = User(id: UserID(rawValue: 60), username: "current", displayName: "Current")
    let memberRole = GuildRole(
        id: RoleID(rawValue: 51),
        name: "Member",
        permissions: 1 << 17
    )
    let currentMember = Member(
        user: currentUser,
        roleName: "Member",
        status: .online,
        roles: [memberRole]
    )
    let everyone = GuildRole(
        id: RoleID(rawValue: guildID.rawValue),
        name: "@everyone",
        permissions: 1 << 10
    )
    let channels = [
        Channel(
            id: ChannelID(rawValue: 3), guildID: guildID, name: "voice", kind: .voice,
            category: "VOICE", position: 0, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 2), guildID: guildID, name: "rules", kind: .text,
            category: "INFO", position: 2, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 1), guildID: guildID, name: "welcome", kind: .text,
            category: "INFO", position: 1, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 4), guildID: guildID, name: "general", kind: .text,
            category: "MAIN", position: 0, categoryPosition: 1
        ),
        Channel(
            id: ChannelID(rawValue: 5), guildID: guildID, name: "bot-updates", kind: .text,
            category: "INFO", position: 3, categoryPosition: 0,
            permissionOverwrites: [
                ChannelPermissionOverwrite(
                    id: guildID.description,
                    type: 0,
                    deny: 1 << 10
                ),
            ]
        ),
        Channel(
            id: ChannelID(rawValue: 6), guildID: guildID, name: "member-lounge", kind: .text,
            category: "INFO", position: 4, categoryPosition: 0,
            permissionOverwrites: [
                ChannelPermissionOverwrite(
                    id: guildID.description,
                    type: 0,
                    deny: 1 << 10
                ),
                ChannelPermissionOverwrite(
                    id: memberRole.id.description,
                    type: 0,
                    allow: 1 << 10
                ),
            ]
        ),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "",
        channels: channels,
        guilds: [:],
        currentUserID: currentUser.id,
        currentMember: currentMember,
        roles: [everyone, memberRole]
    )

    #expect(suggestions.map(\.title) == [
        "welcome", "rules", "bot-updates", "member-lounge", "general",
    ])
    #expect(suggestions.map(\.detail) == ["INFO", "INFO", "INFO", "INFO", "MAIN"])
    #expect(suggestions.allSatisfy { !$0.title.hasPrefix("#") })
    #expect(
        suggestions.map(\.systemImage)
            == Array(
                repeating: ChannelIconPresentation.systemImage(for: .text, isHidden: false),
                count: 5
            )
    )
    #expect(MentionAutocompleteSuggestionFactory.canMentionNonMentionableRoles(
        in: channels.first { $0.name == "general" },
        currentUserID: currentUser.id,
        currentMember: currentMember,
        roles: [everyone, memberRole]
    ))
    #expect(MentionAutocompleteSuggestionFactory.canMentionNonMentionableRoles(
        in: channels.first { $0.name == "general" },
        guild: Guild(
            id: guildID,
            name: "Guild",
            currentUserPermissions: (1 << 10) | (1 << 17)
        ),
        currentUserID: currentUser.id,
        currentMember: nil,
        roles: [everyone, memberRole]
    ))
}

@MainActor
@Test func `channel autocomplete ranks exact prefix contains and fuzzy before sidebar position`() {
    let guildID = GuildID(rawValue: 50)
    let channels = [
        Channel(
            id: ChannelID(rawValue: 1), guildID: guildID, name: "misc-ann", kind: .text,
            category: "INFO", position: 0, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 2), guildID: guildID, name: "announcements", kind: .text,
            category: "INFO", position: 4, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 3), guildID: guildID, name: "planning", kind: .text,
            category: "INFO", position: 1, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 4), guildID: guildID, name: "photography", kind: .text,
            category: "MEDIA", position: 0, categoryPosition: 1
        ),
    ]

    let contains = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "ann", channels: channels, guilds: [:]
    )
    #expect(contains.map(\.title) == ["announcements", "misc-ann", "planning"])

    let exact = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "planning", channels: channels, guilds: [:]
    )
    #expect(exact.map(\.title) == ["planning"])

    let fuzzy = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "ptg", channels: channels, guilds: [:]
    )
    #expect(fuzzy.map(\.title) == ["photography"])
}

@MainActor
@Test func `empty channel autocomplete hoists every positive frecency equally then keeps sidebar order`() {
    let guildID = GuildID(rawValue: 50)
    let channels = [
        Channel(
            id: ChannelID(rawValue: 1), guildID: guildID, name: "welcome", kind: .text,
            category: "INFO", position: 0, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 2), guildID: guildID, name: "rules", kind: .text,
            category: "INFO", position: 1, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 3), guildID: guildID, name: "current-channel", kind: .text,
            category: "MAIN", position: 0, categoryPosition: 1
        ),
        Channel(
            id: ChannelID(rawValue: 4), guildID: guildID, name: "logs", kind: .text,
            category: "LOGS", position: 0, categoryPosition: 9
        ),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "",
        channels: channels,
        guilds: [:],
        guildAndChannelUsageScores: ["1": 1, "3": 250, "4": 9_999]
    )

    // The current client gives any positive frecency the same full boost. It
    // then preserves the channel store/sidebar order among equally boosted
    // entries rather than sorting by the numeric frecency value.
    #expect(suggestions.map(\.title) == ["welcome", "current-channel", "logs", "rules"])
}

@MainActor
@Test func `mention attachment geometry stays atomic while using compact padding`() throws {
    let presentation = MentionPresentation(
        rawToken: "<@123>",
        label: "@Ari",
        target: .user(UserID(rawValue: 123))
    )
    let attributed = MentionAttachmentRenderer.attributedString(presentation: presentation)
    let attachment = try #require(attributed.attribute(
        .attachment,
        at: 0,
        effectiveRange: nil
    ) as? MentionTextAttachment)

    #expect(attributed.length == 1)
    #expect(attachment.normalImage.size.height == 21)
    #expect(ComposerEmojiAttributedText.serialize(attributed) == "<@123>")
}

@MainActor
@Test func `emoji completion returns every matching custom emoji`() {
    let guildID = GuildID(rawValue: 30)
    let emojis = (0 ..< 24).map {
        DiscordEmoji(id: String($0), name: "match_\($0)", guildID: guildID)
    }
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "match_",
        customEmojis: emojis,
        customValue: (\.messageToken),
        customSource: { _ in "Complete Catalog" }
    )

    #expect(suggestions.filter { $0.customEmoji != nil }.count == emojis.count)
}

@Test func `unfocused typing redirect accepts text but preserves shortcuts and control keys`() {
    #expect(ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "s",
        modifierFlags: []
    ))
    #expect(ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "S",
        modifierFlags: [.shift]
    ))
    #expect(!ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "s",
        modifierFlags: [.command]
    ))
    #expect(!ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "\t",
        modifierFlags: []
    ))
}

@MainActor
@Test func `definite send failure removes the optimistic message`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await provider.failNextSend()

    model.updateDraft("remove me")
    let didSend = await model.send()
    #expect(!didSend)
    #expect(!model.messages.contains { $0.content == "remove me" })
    #expect(await provider.sendCount == 1)
}

@MainActor
@Test func `optimistic message is pending until send confirmation`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    await provider.suspendNextSend()
    model.updateDraft("pending message")
    let send = Task { await model.send() }
    await provider.waitUntilSendStarts()

    let pending = model.messages.last { $0.content == "pending message" }
    #expect(pending?.outboxState == .sending)
    #expect(
        pending.map {
            MessageOutboxPresentation.textOpacity(for: $0.outboxState)
        } == 0.55
    )

    await provider.releaseSend()
    #expect(await send.value)
    let confirmed = model.messages.last { $0.content == "pending message" }
    #expect(confirmed?.outboxState == .confirmed)
    #expect(
        confirmed.map {
            MessageOutboxPresentation.textOpacity(for: $0.outboxState)
        } == 1
    )
}

@MainActor
@Test func `optimistic image attachment renders as dimmed local media`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-pending-image-\(UUID().uuidString).png"
    )
    let representation = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 48,
        pixelsHigh: 30,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    let pngData = try #require(representation.representation(using: .png, properties: [:]))
    try pngData.write(to: imageURL)
    defer { try? FileManager.default.removeItem(at: imageURL) }

    await provider.suspendNextSend()
    let send = Task { await model.send(attachments: [imageURL]) }
    await provider.waitUntilSendStarts()

    let pending = try #require(model.messages.last { $0.attachments.first?.url == imageURL })
    let attachment = try #require(pending.attachments.first)
    #expect(attachment.mediaType == "image/png")
    #expect(attachment.width == 48)
    #expect(attachment.height == 30)
    #expect(attachment.size == pngData.count)
    #expect(RichMediaItem(attachment).kind == .image(animated: false))
    #expect(MessageOutboxPresentation.mediaOpacity(for: pending.outboxState) == 0.55)

    await provider.releaseSend()
    #expect(await send.value)
}

@MainActor
@Test func `ambiguous timeout keeps the optimistic message pending`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await provider.timeOutNextSend()

    model.updateDraft("await reconciliation")
    let didSend = await model.send()
    #expect(!didSend)

    let pending = model.messages.last { $0.content == "await reconciliation" }
    #expect(pending?.outboxState == .awaitingReconciliation)
    #expect(
        pending.map {
            MessageOutboxPresentation.textOpacity(for: $0.outboxState)
        } == 0.55
    )
    #expect(await provider.sendCount == 1)
}

@MainActor
@Test func `send confirmation stays with its original channel after navigation`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let originalChannel = try! #require(model.selectedChannelID)

    await provider.suspendNextSend()
    model.updateDraft("channel scoped")
    let send = Task { await model.send() }
    await provider.waitUntilSendStarts()
    model.selectedChannelID = ChannelID(rawValue: 12)
    await provider.releaseSend()
    #expect(await send.value)
    #expect(model.messages.allSatisfy { $0.channelID == model.selectedChannelID })

    model.selectedChannelID = originalChannel
    #expect(await eventuallyOnMain {
        model.messages.count { $0.content == "channel scoped" } == 1
            && model.messages.last(where: { $0.content == "channel scoped" })?.outboxState == .confirmed
    })
}

@MainActor
private func eventuallyOnMain(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private actor TypingTestProvider: ChatProvider {
    private enum SendFailure {
        case definite
        case timedOut
    }

    let currentUser = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let otherUser = User(id: UserID(rawValue: 2), username: "other", displayName: "Other")
    private let channels = [
        Channel(id: ChannelID(rawValue: 10), guildID: nil, name: "text", kind: .directMessage),
        Channel(id: ChannelID(rawValue: 11), guildID: nil, name: "voice", kind: .voice),
        Channel(id: ChannelID(rawValue: 12), guildID: nil, name: "group", kind: .groupDirectMessage)
    ]
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private(set) var typingChannels: [ChannelID] = []
    private(set) var sendCount = 0
    private(set) var sentNonces: [String] = []
    private var nextMessageID: UInt64 = 100
    private var nextSendFailure: SendFailure?
    private var suspendsNextSend = false
    private var sendStartedWaiter: CheckedContinuation<Void, Never>?
    private var sendReleaseWaiter: CheckedContinuation<Void, Never>?
    private var didStartSuspendedSend = false

    var typingCount: Int {
        typingChannels.count
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.ready))
        return BootstrapSnapshot(currentUser: currentUser, guilds: [], channels: channels, members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        channels
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("not used")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func sendTyping(in channelID: ChannelID) async throws {
        typingChannels.append(channelID)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        sendCount += 1
        sentNonces.append(draft.nonce)
        if let failure = nextSendFailure {
            nextSendFailure = nil
            switch failure {
            case .definite:
                throw ChatProviderError.invalidRequest("Synthetic send failure")
            case .timedOut:
                throw URLError(.timedOut)
            }
        }
        if suspendsNextSend {
            suspendsNextSend = false
            didStartSuspendedSend = true
            sendStartedWaiter?.resume()
            sendStartedWaiter = nil
            await withCheckedContinuation { continuation in
                sendReleaseWaiter = continuation
            }
        }
        nextMessageID += 1
        let message = Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: draft.channelID,
            author: currentUser,
            content: draft.content,
            attachments: draft.attachmentURLs.enumerated().map {
                Attachment(id: "\(nextMessageID)-\($0.offset)", filename: $0.element.lastPathComponent, url: $0.element)
            },
            nonce: draft.nonce
        )
        continuation?.yield(.messageCreated(message))
        return message
    }

    func suspendNextSend() {
        suspendsNextSend = true
        didStartSuspendedSend = false
    }

    func failNextSend() {
        nextSendFailure = .definite
    }

    func timeOutNextSend() {
        nextSendFailure = .timedOut
    }

    func waitUntilSendStarts() async {
        if didStartSuspendedSend { return }
        await withCheckedContinuation { continuation in
            sendStartedWaiter = continuation
        }
    }

    func releaseSend() {
        sendReleaseWaiter?.resume()
        sendReleaseWaiter = nil
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("not used")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> {
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(50))
        continuation = stream.continuation
        return stream.stream
    }

    func disconnect() async {
        continuation?.yield(.connectionChanged(.disconnected))
    }

    func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }
}

private actor NotificationCredentialStore: CredentialStore {
    let storedHandles: [CredentialHandle]

    init(handles: [CredentialHandle]) {
        storedHandles = handles
    }

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data()
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        storedHandles
    }
}
