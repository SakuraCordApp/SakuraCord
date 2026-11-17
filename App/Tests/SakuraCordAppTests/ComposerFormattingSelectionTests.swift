@testable import SakuraCord
import AppKit
import SakuraCordModels
import Testing

@MainActor
@Test(arguments: [
    ("**hello world**", "hello", "**", "hello **world**"),
    ("**hello world**", "world", "**", "**hello** world"),
    ("**red green blue**", "green", "**", "**red** green **blue**"),
    ("***red green blue***", "green", "**", "***red*** *green* ***blue***"),
    ("**red __green blue__ tail**", "green", "**", "**red** __green__ **__blue__ tail**"),
    ("*__**red green blue**__*", "green", "*", "*__**red**__* __**green**__ *__**blue**__*"),
    ("__red green blue__", "green", "__", "__red__ green __blue__"),
    ("**ab🌸cd**", "🌸", "**", "**ab**🌸**cd**"),
    ("**hello <@123> world**", "hello", "**", "hello **<@123> world**"),
    ("**text [label*](https://example.com) end**", "text", "**", "text **[label*](https://example.com) end**"),
    ("**bold *literal** then *italic*", "bold", "**", "bold ***literal** then *italic*")
])
func `composer partial formatting preserves other text styles attachments and undo`(
    _ source: String, _ selected: String, _ marker: String, _ expected: String
) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = ComposerNSTextView(frame: window.contentView!.bounds)
    view.allowsUndo = true
    view.plainTextStyle = .composer(.systemFont(ofSize: 15))
    window.contentView = view
    window.makeFirstResponder(view)
    view.textStorage?.setAttributedString(ComposerEmojiAttributedText.make(source))
    view.setSelectedRange((view.string as NSString).range(of: selected))
    view.wrapSelectionInMarkdown(marker)
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == expected)
    #expect((view.string as NSString).substring(with: view.selectedRange()) == selected)
    let attributes = view.textStorage?.attributes(at: view.selectedRange().location, effectiveRange: nil)
    let traits = (attributes?[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
    if marker == "**" { #expect(!traits.contains(.bold)) }
    if marker == "*" { #expect(!traits.contains(.italic)) }
    if marker == "__" { #expect(attributes?[.underlineStyle] == nil) }
    view.undoManager?.undo()
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == source)
    view.undoManager?.redo()
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == expected)
}

@MainActor
@Test func `composer formatting applies to the selection even inside code and links`() {
    let view = ComposerNSTextView()
    for (source, selected, expected) in [
        ("**before [hello world](https://example.com) after**", "hello", "**before [**hello **world](https://example.com) after**"),
        ("`hello world`", "hello", "`**hello** world`"),
        ("```swift\nhello world\n```", "hello", "```swift\n**hello** world\n```"),
        ("[label](https://example.com)", "example", "[label](https://**example**.com)"),
        ("<https://example.com>", "example", "<https://**example**.com>"),
        ("https://example.com", "example", "https://**example**.com")
    ] {
        view.string = source
        view.setSelectedRange((source as NSString).range(of: selected))
        view.wrapSelectionInMarkdown("**")
        #expect(view.string == expected)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == selected)
    }
}

// Choosing a suggestion replaces `range` with the mention, so a wrong range
// would send leftover or deleted message text.
@MainActor
@Test(arguments: [
    ("check out #\"Release Notes\"", nil, "Release Notes", "#\"Release Notes\""),
    ("check out #\"Release Notes\" today", 19, "Release", "#\"Release Notes\""),
    ("see #\"Release Notes", nil, "Release Notes", "#\"Release Notes"),
    ("refer to #“Release Notes”", nil, "Release Notes", "#“Release Notes”"),
    (##"check #"Release \"Notes\" Updates""##, nil, #"Release "Notes" Updates"#, ##"#"Release \"Notes\" Updates""##),
    (##"check #"Release \"Notes\" Updates" now"##, 15, "Release", ##"#"Release \"Notes\" Updates""##),
    (##"check #"Release \\" and say "hello" today"##, 17, #"Release \"#, ##"#"Release \\""##),
    ("#\"C:\\\nnext \"line\"", 5, "C:\\", "#\"C:\\"),
    ("hello #release", nil, "release", "#release")
] as [(String, Int?, String, String)])
func `channel mention autocomplete covers the whole quoted token`(
    _ text: String, _ cursor: Int?, _ query: String, _ token: String
) throws {
    let context = try #require(MentionAutocompleteContext(
        text: text, selection: cursor.map { NSRange(location: $0, length: 0) }
    ))
    #expect(context.kind == .channel)
    #expect(context.query == query)
    #expect((text as NSString).substring(with: context.range) == token)
}

@MainActor
@Test func `channel mention autocomplete closes at a line break`() {
    let text = "check #\"Release\n Notes\" now"
    let caret = ("check #\"Release\n" as NSString).length
    #expect(MentionAutocompleteContext(text: text, selection: NSRange(location: caret, length: 0)) == nil)
}

@MainActor
@Test(arguments: [
    ("hello @Jane Doe", nil, "Jane Doe", "@Jane Doe"),
    ("hello @Jane ", nil, "Jane ", "@Jane "),
    ("hello @Jane", nil, "Jane", "@Jane"),
    ("hello @", nil, "", "@"),
    ("hello @Jane Doe today", 15, "Jane Doe", "@Jane Doe"),
    ("@Doctor Who", nil, "Doctor Who", "@Doctor Who"),
    ("ask @Alice In Wonderland", nil, "Alice In Wonderland", "@Alice In Wonderland"),
] as [(String, Int?, String, String)])
func `member mention autocomplete covers display names with spaces`(
    _ text: String, _ cursor: Int?, _ query: String, _ token: String
) throws {
    let context = try #require(MentionAutocompleteContext(
        text: text, selection: cursor.map { NSRange(location: $0, length: 0) }
    ))
    #expect(context.kind == .member)
    #expect(context.query == query)
    #expect((text as NSString).substring(with: context.range) == token)
}

@MainActor
@Test func `member mention autocomplete rejects space right after at and keywords with trailing space`() {
    #expect(MentionAutocompleteContext(text: "hello @ ", selection: nil) == nil)
    #expect(MentionAutocompleteContext(text: "email@example.com", selection: nil) == nil)
    #expect(MentionAutocompleteContext(text: "meet @time ", selection: nil) == nil)
    #expect(MentionAutocompleteContext(text: "play @game ", selection: nil) == nil)
}

@MainActor
@Test func `member mention suggestions match by profile name, nickname and word boundary`() {
    let member1 = Member(
        user: User(id: UserID(rawValue: 101), username: "janedoe99", displayName: "Jane Doe"),
        roleName: "Member",
        status: .online,
        globalDisplayName: "Jane Doe"
    )
    let member2 = Member(
        user: User(id: UserID(rawValue: 102), username: "superstar", displayName: "Johnny"),
        roleName: "Member",
        status: .online,
        globalDisplayName: "Johnathan Smith",
        guildNickname: "Guild Alias"
    )
    let members = [member1, member2]

    // Search by full profile name with space
    let fullProfileMatches = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "Jane Doe",
        recentMessages: [],
        localMembers: members,
        remoteMembers: [],
        roles: []
    )
    #expect(fullProfileMatches.first?.id == "user:101")

    // Search by word in profile name
    let wordMatches = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "Doe",
        recentMessages: [],
        localMembers: members,
        remoteMembers: [],
        roles: []
    )
    #expect(wordMatches.first?.id == "user:101")

    // Search by global profile name when nickname is set
    let globalNameMatches = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "Smith",
        recentMessages: [],
        localMembers: members,
        remoteMembers: [],
        roles: []
    )
    #expect(globalNameMatches.first?.id == "user:102")

    // Search by guild nickname
    let nicknameMatches = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "Guild Alias",
        recentMessages: [],
        localMembers: members,
        remoteMembers: [],
        roles: []
    )
    #expect(nicknameMatches.first?.id == "user:102")

    // Search by username
    let usernameMatches = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "superstar",
        recentMessages: [],
        localMembers: members,
        remoteMembers: [],
        roles: []
    )
    #expect(usernameMatches.first?.id == "user:102")
}

@MainActor
@Test func `keyword mention context matches queries and closes on newline`() {
    let gameContext = KeywordMentionContext(.game, text: "@game Civilization", selection: nil)
    #expect(gameContext != nil)
    #expect(gameContext?.query == "Civilization")

    let timeContext = KeywordMentionContext(.time, text: "@time November", selection: nil)
    #expect(timeContext != nil)
    #expect(timeContext?.query == "November")

    #expect(KeywordMentionContext(.game, text: "@game Civilization\n", selection: nil) == nil)
    #expect(KeywordMentionContext(.time, text: "@time November\n", selection: nil) == nil)
}

@MainActor
@Test func `member suggestions preserve local candidates matching query words when remote members are present`() {
    let local1 = Member(
        user: User(id: UserID(rawValue: 201), username: "local_user", displayName: "Local Alice"),
        roleName: "Member",
        status: .online,
        globalDisplayName: "Alice Wonder"
    )
    let local2 = Member(
        user: User(id: UserID(rawValue: 202), username: "unrelated", displayName: "Bob"),
        roleName: "Member",
        status: .online
    )
    let remote1 = Member(
        user: User(id: UserID(rawValue: 301), username: "alice_remote", displayName: "Alice Remote"),
        roleName: "Member",
        status: .online
    )

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "Alice",
        recentMessages: [],
        localMembers: [local1, local2],
        remoteMembers: [remote1],
        roles: []
    )

    let suggestedIDs = suggestions.map(\.id)
    #expect(suggestedIDs.contains("user:201"))
    #expect(suggestedIDs.contains("user:301"))
    #expect(!suggestedIDs.contains("user:202"))
    // Remote members must retain their supplied order and precedence ahead of local additions
    #expect(suggestedIDs.first == "user:301")
}
