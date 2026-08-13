import CoreGraphics
import SakuraCordModels
import Testing
@testable import SakuraCord

@Test func `quick switcher icon geometry aspect fills without stretching`() {
    #expect(QuickSwitcherIconGeometry.aspectFillRect(
        imageSize: CGSize(width: 200, height: 100),
        in: CGRect(x: 0, y: 0, width: 22, height: 22)
    ) == CGRect(x: -11, y: 0, width: 44, height: 22))
    #expect(QuickSwitcherIconGeometry.aspectFillRect(
        imageSize: CGSize(width: 100, height: 200),
        in: CGRect(x: 10, y: 20, width: 22, height: 22)
    ) == CGRect(x: 10, y: 9, width: 22, height: 44))
    #expect(QuickSwitcherIconGeometry.serverCornerRadius(iconSize: 22) == 7)
}

@Test func `unsupported prefix remains ordinary quick switcher search text`() {
    let query = QuickSwitcherParsedQuery("$anything")
    #expect(query.mode == nil)
    #expect(query.searchValue == "$anything")
}

private struct QuickSwitcherFixture {
    let currentGuild = Guild(id: GuildID(rawValue: 1), name: "SakuraCord")
    let swiftGuild = Guild(id: GuildID(rawValue: 2), name: "Swift Club")
    let teenGuild = Guild(id: GuildID(rawValue: 3), name: "Teen Lounge")
    let currentUser = User(
        id: UserID(rawValue: 10), username: "current", displayName: "Current"
    )
    let henry = User(
        id: UserID(rawValue: 11), username: "henry", displayName: "Henry"
    )
    let lena = User(
        id: UserID(rawValue: 12), username: "lena", displayName: "Lena"
    )
    let currentChannel = Channel(
        id: ChannelID(rawValue: 100), guildID: GuildID(rawValue: 1),
        name: "general", kind: .text, position: 0
    )
    let chatChannel = Channel(
        id: ChannelID(rawValue: 101), guildID: GuildID(rawValue: 1),
        name: "chat-lounge", kind: .text, position: 1
    )
    let musicChannel = Channel(
        id: ChannelID(rawValue: 102), guildID: GuildID(rawValue: 1),
        name: "music", kind: .voice, position: 2
    )
    let betaChannel = Channel(
        id: ChannelID(rawValue: 103), guildID: GuildID(rawValue: 1),
        name: "beta-forum", kind: .forum, position: 3
    )

    var guilds: [Guild] { [currentGuild, swiftGuild, teenGuild] }
    var channels: [Channel] { [currentChannel, chatChannel, musicChannel, betaChannel] }
    var users: [User] { [currentUser, henry, lena] }
    var usageScores: [String: Int] {
        [chatChannel.id.description: 80, musicChannel.id.description: 60,
         swiftGuild.id.description: 90, teenGuild.id.description: 20]
    }
    var usageOrder: [String] {
        [chatChannel.id.description, musicChannel.id.description,
         swiftGuild.id.description, teenGuild.id.description]
    }
    var index: ForwardDestinationSearchPolicy.Index {
        ForwardDestinationSearchPolicy.makeIndex(
            channels: channels,
            users: users,
            friendUserIDs: [henry.id, lena.id],
            currentUserID: currentUser.id,
            guilds: Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) }),
            usageScores: usageScores,
            usageOrder: usageOrder,
            searchableChannelIDs: Set(channels.map(\.id)),
            eligibleChannelIDs: []
        )
    }

    func results(
        _ query: String,
        history: [ChannelID]? = nil,
        unread: Set<ChannelID> = [],
        muted: Set<ChannelID> = [],
        mentions: [ChannelID] = [],
        drafts: [ChannelID] = [],
        recentlyTalked: [UserID] = []
    ) -> [QuickSwitcherResult] {
        QuickSwitcherSearchPolicy.results(
            query: query,
            context: QuickSwitcherSearchContext(
                index: index,
                guilds: guilds,
                usageScores: usageScores,
                history: history ?? [currentChannel.id, chatChannel.id, betaChannel.id],
                currentChannelID: currentChannel.id,
                currentGuildID: currentGuild.id,
                currentUserID: currentUser.id,
                searchableUserIDs: nil,
                friendUserIDs: [henry.id, lena.id],
                currentGuildMemberIDs: [currentUser.id, henry.id],
                unreadChannelIDs: unread,
                mutedChannelIDs: muted,
                mentionedChannelIDs: mentions,
                draftChannelIDs: drafts,
                recentlyTalkedUserIDs: recentlyTalked
            )
        )
    }
}

@Test func `quick switcher modifiers preserve Discord headings and candidate scopes`() {
    let fixture = QuickSwitcherFixture()

    #expect(
        fixture.results(
            "@",
            recentlyTalked: [fixture.lena.id, fixture.henry.id]
        ).map(\.id) == [
            .heading("mode-@"),
            .destination(.user(fixture.lena.id)),
            .destination(.user(fixture.henry.id)),
        ]
    )
    #expect(fixture.results("#gen").map(\.id) == [
        .heading("mode-#"), .destination(.channel(fixture.currentChannel.id)),
    ])
    #expect(fixture.results("#music").map(\.id) == [
        .heading("mode-#"), .destination(.channel(fixture.musicChannel.id)),
    ])
    #expect(fixture.results("!music").map(\.id) == [
        .heading("mode-!"), .destination(.channel(fixture.musicChannel.id)),
    ])
    #expect(fixture.results("*swift").map(\.id) == [
        .heading("mode-*"), .guild(fixture.swiftGuild.id),
    ])
    #expect(fixture.results("*sakura").map(\.id) == [.heading("mode-*")])
}

@Test func `quick switcher default sections deduplicate in Discord order`() {
    let fixture = QuickSwitcherFixture()
    let results = fixture.results(
        "",
        unread: [fixture.chatChannel.id, fixture.musicChannel.id],
        mentions: [fixture.musicChannel.id],
        drafts: [fixture.betaChannel.id]
    )

    #expect(results.map(\.id) == [
        .heading("previous"),
        .destination(.channel(fixture.chatChannel.id)),
        .destination(.channel(fixture.betaChannel.id)),
        .heading("mentions"),
        .destination(.channel(fixture.musicChannel.id)),
    ])

    let unread = fixture.results(
        "",
        history: [fixture.currentChannel.id],
        unread: [fixture.chatChannel.id, fixture.musicChannel.id],
        muted: [fixture.musicChannel.id]
    )
    #expect(unread.map(\.id) == [
        .heading("unread"), .destination(.channel(fixture.chatChannel.id)),
    ])
}

@Test func `quick switcher keeps the first persisted previous channel when it is not current`() {
    let fixture = QuickSwitcherFixture()

    #expect(fixture.results(
        "",
        history: [fixture.chatChannel.id, fixture.betaChannel.id]
    ).map(\.id) == [
        .heading("previous"),
        .destination(.channel(fixture.chatChannel.id)),
        .destination(.channel(fixture.betaChannel.id)),
    ])
}

@Test func `quick switcher exposes only implemented in-app navigation`() {
    #expect(QuickSwitcherNavigationDestination.discordDefaults.map(\.id) == ["SETTINGS"])
}

@Test func `quick switcher query matrix covers every implemented mode`() {
    let fixture = QuickSwitcherFixture()
    let checks: [(String, QuickSwitcherResultID)] = [
        ("gen", .destination(.channel(fixture.currentChannel.id))),
        ("chat", .destination(.channel(fixture.chatChannel.id))),
        ("music", .destination(.channel(fixture.musicChannel.id))),
        ("beta", .destination(.channel(fixture.betaChannel.id))),
        ("hen", .destination(.user(fixture.henry.id))),
        ("len", .destination(.user(fixture.lena.id))),
        ("settings", .navigation("SETTINGS")),
        ("@hen", .destination(.user(fixture.henry.id))),
        ("@len", .destination(.user(fixture.lena.id))),
        ("#gen", .destination(.channel(fixture.currentChannel.id))),
        ("#chat", .destination(.channel(fixture.chatChannel.id))),
        ("#music", .destination(.channel(fixture.musicChannel.id))),
        ("!music", .destination(.channel(fixture.musicChannel.id))),
        ("*swift", .guild(fixture.swiftGuild.id)),
        ("*teen", .guild(fixture.teenGuild.id)),
        ("club", .guild(fixture.swiftGuild.id)),
        ("lounge", .guild(fixture.teenGuild.id)),
    ]

    for (query, expectedID) in checks {
        #expect(
            fixture.results(query).contains { $0.id == expectedID },
            "Missing expected result for \(query)"
        )
    }
}

@Test func `quick switcher selection switches cleanly between keyboard and pointer`() {
    let ids: [QuickSwitcherResultID] = [
        .destination(.channel(ChannelID(rawValue: 1))),
        .destination(.channel(ChannelID(rawValue: 2))),
        .destination(.channel(ChannelID(rawValue: 3))),
    ]
    #expect(QuickSwitcherSelectionPolicy.synchronized(
        current: ids[2], selectableIDs: ids, preservesCurrent: false
    ) == ids[0])
    #expect(QuickSwitcherSelectionPolicy.synchronized(
        current: ids[2], selectableIDs: ids, preservesCurrent: true
    ) == ids[2])
    #expect(QuickSwitcherSelectionPolicy.moved(
        current: ids[1], selectableIDs: ids, delta: 1
    ) == ids[2])
    #expect(QuickSwitcherSelectionPolicy.moved(
        current: ids[0], selectableIDs: ids, delta: -1
    ) == ids[2])
}
