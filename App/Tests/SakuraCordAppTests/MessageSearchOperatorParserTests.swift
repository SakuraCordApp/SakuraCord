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
    let before = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 14)))
    let after = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 11)))
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

@Test func `semantic message search tokens round trip canonical mixed syntax`() throws {
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

@Test func `message search user suggestions retain inline Discord identity presentation`() throws {
    let avatarURL = try #require(URL(string: "https://cdn.discordapp.com/avatars/4/avatar.webp"))
    let user = User(
        id: UserID(rawValue: 4),
        username: "maya_user",
        displayName: "Maya Chen",
        avatarURL: avatarURL
    )
    let suggestion = MessageSearchAutocompleteSuggestion.user(.from, user)

    #expect(suggestion.title == "Maya Chen")
    #expect(suggestion.userPresentation?.username == "maya_user")
    #expect(suggestion.userPresentation?.avatarURL == avatarURL)
    #expect(suggestion.accessibilityLabel == "Maya Chen, maya_user")
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

@Test func `message search toolbar is limited to normal timelines`() {
    #expect(MessageSearchSurfacePolicy.showsToolbar(channelKind: .text, hasOpenThread: false))
    #expect(MessageSearchSurfacePolicy.showsToolbar(
        channelKind: .directMessage,
        hasOpenThread: false
    ))
    #expect(!MessageSearchSurfacePolicy.showsToolbar(channelKind: .text, hasOpenThread: true))
    #expect(!MessageSearchSurfacePolicy.showsToolbar(channelKind: .forum, hasOpenThread: false))
    #expect(!MessageSearchSurfacePolicy.showsToolbar(channelKind: .voice, hasOpenThread: false))
}

@MainActor
@Test func `message search autocomplete matches Discord filter and content type ordering`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()

    model.messageSearch.queryText = ""
    let emptyResult = MessageSearchAutocompletePolicy.result(model: model)
    let empty = emptyResult.suggestions.filter(\.isSelectable).map(\.title)
    #expect(!emptyResult.selectsFirst)
    #expect(empty == [
        "From a specific user",
        "Sent in a specific channel",
        "Includes a specific type of data",
        "Mentions a specific user",
        "More filters",
    ])
    let overview = emptyResult.suggestions.compactMap(\.filterOverviewPresentation)
    #expect(overview.map(\.systemImage) == [
        "person.fill", "number", "link", "at", "slider.horizontal.3",
    ])
    #expect(overview.map(\.detail) == [
        "from: user",
        "in: channel",
        "has: link, embed or file",
        "mentions: user",
        "dates, author type and more",
    ])
    #expect(emptyResult.suggestions.dropFirst().allSatisfy {
        $0.autocompleteRowHeight == 48
    })

    model.messageSearch.queryText = "has:"
    let contentTypes = MessageSearchAutocompletePolicy.result(model: model)
        .suggestions.filter(\.isSelectable).map(\.title)
    #expect(contentTypes == [
        "image", "video", "link", "file", "embed", "sound", "poll", "sticker", "forward",
    ])

    model.messageSearch.queryText = "has:i"
    let fuzzyContentTypes = MessageSearchAutocompletePolicy.result(model: model)
        .suggestions.filter(\.isSelectable).map(\.title)
    #expect(fuzzyContentTypes == ["image", "video", "link", "file", "sticker"])

    model.messageSearch.tokens = [.init(kind: .contentType(.image))]
    model.messageSearch.queryText = ""
    #expect(!MessageSearchAutocompletePolicy.result(model: model).selectsFirst)

    model.messageSearch.queryText = "author_type:"
    let authorTypeFallback = MessageSearchAutocompletePolicy.result(model: model)
    #expect(authorTypeFallback.suggestions.filter(\.isSelectable).map(\.title) == [
        "Search for author_type:",
    ] + empty)
    #expect(!authorTypeFallback.selectsFirst)

    model.messageSearch.queryText = "before:"
    #expect(MessageSearchAutocompletePolicy.result(model: model).suggestions.isEmpty)

    model.messageSearch.queryText = "during:"
    #expect(MessageSearchAutocompletePolicy.result(model: model).suggestions.isEmpty)

    if let guildID = model.selectedGuildID {
        model.messageSearch.queryText = "from:"
        let joined = Set(
            model.snapshot?.quickSwitcherJoinedGuildMemberUserIDs[guildID] ?? []
        )
        let suggestedUserIDs = MessageSearchAutocompletePolicy.result(model: model)
            .suggestions.compactMap { suggestion -> UserID? in
                guard case .user(_, let user) = suggestion else { return nil }
                return user.id
            }
        #expect(suggestedUserIDs.allSatisfy(joined.contains))
    }
}

@MainActor
@Test func `direct message autocomplete uses current conversation and clean Discord ordering`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.selectedGuildID = nil
    let directMessages = model.messageSearchChannels.filter {
        $0.kind == .directMessage || $0.kind == .groupDirectMessage
    }
    let current = try #require(directMessages.first)
    model.selectedChannelID = current.id
    model.messageSearch.tokens = []
    model.messageSearch.queryText = ""

    let blank = MessageSearchAutocompletePolicy.result(model: model)
    let scope = try #require(blank.suggestions.first?.directMessageScopePresentation)
    #expect(scope.action == "Find in")
    #expect(scope.username == model.messageSearchPresentedName(for: current))
    #expect(blank.suggestions.first?.autocompleteRowHeight == 34)
    #expect(!blank.selectsFirst)

    model.messageSearch.queryText = "in:"
    let channels = MessageSearchAutocompletePolicy.result(model: model)
        .suggestions.compactMap(\.channelPresentation)
    #expect(channels.first?.id == current.id)
    #expect(channels.count <= 10)

    model.messageSearch.queryText = ""
    model.messageSearch.tokens = [MessageSearchToken(kind: .contentType(.link))]
    let completedFilter = MessageSearchAutocompletePolicy.result(model: model)
    #expect(completedFilter.suggestions.first?.title == "Search for has: link")
    #expect(completedFilter.suggestions.first?.directMessageScopePresentation == nil)

    let addFilters = MessageSearchAutocompleteSuggestion.addSearchFilters
    #expect(addFilters.isSelectable)
    #expect(addFilters.autocompleteRowHeight == 34)
    #expect(addFilters.valueSystemImage(rulesChannelID: nil) == "slider.horizontal.3")
}

@Test func `message search value rows cover every Discord icon family`() {
    let guildID = GuildID(rawValue: 100)
    let text = Channel(id: ChannelID(rawValue: 1), guildID: guildID, name: "general")
    let forum = Channel(
        id: ChannelID(rawValue: 2), guildID: guildID, name: "bugs", kind: .forum
    )
    #expect(ChannelIconPresentation.systemImage(
        for: text,
        access: .readable(canSend: true),
        rulesChannelID: nil
    ) == "number")
    #expect(ChannelIconPresentation.systemImage(
        for: forum,
        access: .readable(canSend: true),
        rulesChannelID: nil
    ) == "bubble.left.and.bubble.right.fill")
    #expect(ChannelIconPresentation.systemImage(
        for: text,
        access: .readable(canSend: true),
        rulesChannelID: text.id
    ) == "newspaper.fill")
    #expect(ChannelIconPresentation.systemImage(
        for: text,
        access: .hidden,
        rulesChannelID: nil
    ) == "lock.fill")

    let contentIcons = MessageSearchContentType.allCases.map {
        MessageSearchAutocompleteSuggestion.contentType($0)
            .valueSystemImage(rulesChannelID: nil)
    }
    #expect(contentIcons == [
        "photo.fill", "video.fill", "link", "doc.fill", "play.rectangle.fill",
        "speaker.wave.2.fill", "chart.bar.fill", "face.smiling.fill",
        "arrowshape.turn.up.right.fill",
    ])
}

@MainActor
@Test func `twenty query autocomplete matrix has stable ordering and complete visuals`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let queries = [
        "", "f", "fr", "from:", "from:a",
        "mentions:", "mentions:e", "in:", "in:g", "has:",
        "has:i", "has:vid", "has:link", "pinned:", "before:",
        "after:", "author_type:", "during:", "plain", "test",
    ]
    #expect(queries.count == 20)

    for query in queries {
        model.messageSearch.queryText = query
        let first = MessageSearchAutocompletePolicy.result(model: model).suggestions
        let second = MessageSearchAutocompletePolicy.result(model: model).suggestions
        #expect(first.map(\.id) == second.map(\.id), "Unstable order for \(query)")
        #expect(first.filter(\.isSelectable).allSatisfy { suggestion in
            suggestion.filterOverviewPresentation != nil
                || suggestion.avatarPresentation != nil
                || suggestion.directMessageScopePresentation != nil
                || suggestion.channelPresentation != nil
                || suggestion.valueSystemImage(rulesChannelID: nil) != nil
        }, "Missing visual presentation for \(query)")
    }
}

@MainActor
@Test func `twenty query direct message autocomplete matrix matches static Discord families`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.selectedGuildID = nil
    let current = try #require(model.messageSearchChannels.first)
    model.selectedChannelID = current.id
    let queries = [
        "", "f", "fr", "from:", "from:a",
        "mentions:", "mentions:e", "in:", "in:e", "in:a",
        "has:", "has:i", "has:vid", "has:link", "pinned:",
        "author_type:", "before:", "during:", "plain", "test",
    ]
    #expect(queries.count == 20)

    for query in queries {
        model.messageSearch.tokens = []
        model.messageSearch.queryText = query
        let first = MessageSearchAutocompletePolicy.result(model: model).suggestions
        let second = MessageSearchAutocompletePolicy.result(model: model).suggestions
        #expect(first.map(\.id) == second.map(\.id), "Unstable DM order for \(query)")
        #expect(!MessageSearchAutocompletePolicy.result(model: model).selectsFirst)
    }

    model.messageSearch.queryText = "has:"
    #expect(MessageSearchAutocompletePolicy.result(model: model).suggestions
        .filter(\.isSelectable).map(\.title) == [
            "image", "video", "link", "file", "embed", "sound", "poll", "sticker", "forward",
        ])
    model.messageSearch.queryText = "pinned:"
    #expect(MessageSearchAutocompletePolicy.result(model: model).suggestions
        .filter(\.isSelectable).map(\.title) == ["true", "false"])
}
