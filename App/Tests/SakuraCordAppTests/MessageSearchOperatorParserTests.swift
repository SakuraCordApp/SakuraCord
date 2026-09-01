import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@Test func `message search operators resolve names ids multi value filters and content`() throws {
    let maya = User(
        id: UserID(rawValue: 4),
        username: "maya_user",
        displayName: "Maya Chen"
    )
    let releaseChannel = Channel(
        id: ChannelID(rawValue: 200),
        guildID: GuildID(rawValue: 100),
        name: "release-notes"
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let parsed = MessageSearchOperatorParser.parse(
        #"roadmap from:"Maya Chen" in:release-notes mentions:4 has:image,video author_type:bot pinned:true before:2026-08-14 after:2026-08-10"#,
        filters: .init(contentTypes: [.link]),
        users: [maya],
        channels: [releaseChannel],
        calendar: calendar
    )

    #expect(parsed.content == "roadmap")
    #expect(parsed.filters.authorIDs == [maya.id])
    #expect(parsed.filters.channelIDs == [releaseChannel.id])
    #expect(parsed.filters.mentionedUserIDs == [maya.id])
    #expect(parsed.filters.contentTypes == [.link, .image, .video])
    #expect(parsed.filters.authorTypes == [.bot])
    #expect(parsed.filters.pinned == true)
    let before = try #require(calendar.date(
        from: DateComponents(year: 2026, month: 8, day: 14)
    ))
    let after = try #require(calendar.date(
        from: DateComponents(year: 2026, month: 8, day: 11)
    ))
    #expect(parsed.filters.maximumMessageID == .messageSearchBoundary(at: before))
    #expect(parsed.filters.minimumMessageID == .messageSearchBoundary(at: after))
}

@Test func `unresolved and unknown message search operators stay searchable text`() {
    let parsed = MessageSearchOperatorParser.parse(
        "hello from:unknown future:value before:2026-02-31",
        filters: .init(),
        users: [],
        channels: []
    )

    #expect(parsed.content == "hello from:unknown future:value before:2026-02-31")
    #expect(parsed.filters.isEmpty)
}

@Test func `semantic message search tokens round trip canonical mixed syntax`() {
    let maya = User(
        id: UserID(rawValue: 4),
        username: "maya_user",
        displayName: "Maya Chen"
    )
    let general = Channel(
        id: ChannelID(rawValue: 200),
        guildID: GuildID(rawValue: 100),
        name: "general"
    )
    let parsed = MessageSearchTokenParser.parse(
        "from:maya_user in:general road has:image",
        users: [maya],
        channels: [general]
    )

    #expect(parsed.text == "road")
    #expect(parsed.tokens.map(\.canonicalSyntax) == [
        "from:maya_user", "in:general", "has:image",
    ])
    #expect(
        MessageSearchTokenParser.serialize(tokens: parsed.tokens, text: parsed.text)
            == "from:maya_user in:general has:image road"
    )
    let filters = parsed.tokens.reduce(MessageSearchFilters()) {
        $0.merging($1.filters)
    }
    #expect(filters.authorIDs == [maya.id])
    #expect(filters.channelIDs == [general.id])
    #expect(filters.contentTypes == [.image])
}

@Test func `message search clipboard serializes a mixed native token selection`() {
    let maya = User(
        id: UserID(rawValue: 4),
        username: "maya_user",
        displayName: "Maya Chen"
    )
    let token = MessageSearchToken(kind: .from(
        userID: maya.id,
        username: maya.username,
        displayName: maya.displayName
    ))
    let editorText = "\u{FFFC}road"

    #expect(MessageSearchClipboardSerialization.canonicalSelection(
        editorString: editorText,
        selectedRange: NSRange(location: 0, length: (editorText as NSString).length),
        tokens: [token]
    ) == "from:maya_user road")
}

@MainActor
@Test func `native token attachment characters never become search content`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.messageSearchInputText = "\u{FFFC}road\u{FFFC}"
    #expect(model.messageSearch.queryText == "road")
}

@MainActor
@Test func `typing resolvable people stays text while static syntax becomes native tokens`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let user = try #require(model.messageSearchUsers.first)

    model.messageSearchInputText = "mentions:\(user.username)"
    #expect(model.messageSearch.queryText == "mentions:\(user.username)")
    #expect(model.messageSearch.tokens.isEmpty)

    model.messageSearchInputText = "has:link"
    #expect(model.messageSearch.queryText.isEmpty)
    #expect(model.messageSearch.tokens.map(\.canonicalSyntax) == ["has:link"])
}
