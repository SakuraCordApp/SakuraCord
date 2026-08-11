import Foundation
import Darwin
import DiscordProtocol
import SakuraCordModels
import Testing
@testable import SakuraCord

@Test func `forward destination search is local unified and bounded`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let dmUser = User(
        id: UserID(rawValue: 2),
        username: "maya_user",
        displayName: "Maya"
    )
    let channels = [
        Channel(
            id: ChannelID(rawValue: 10),
            guildID: guild.id,
            name: "general",
            kind: .text,
            position: 0
        ),
        Channel(
            id: ChannelID(rawValue: 11),
            guildID: nil,
            name: "Maya",
            kind: .directMessage,
            recipients: [dmUser],
            lastMessageID: MessageID(rawValue: 999)
        ),
        Channel(
            id: ChannelID(rawValue: 12),
            guildID: guild.id,
            name: "questions",
            kind: .forum
        ),
    ]

    let personResults = ForwardDestinationSearchPolicy.results(
        query: "maya_user",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: [:]
    )
    #expect(personResults.compactMap(\.resolvedChannelID) == [ChannelID(rawValue: 11)])

    let channelResults = ForwardDestinationSearchPolicy.results(
        query: "sakura gen",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: [:]
    )
    #expect(channelResults.compactMap(\.resolvedChannelID) == [ChannelID(rawValue: 10)])
    #expect(!channelResults.contains { $0.resolvedChannelID == ChannelID(rawValue: 12) })
}

@MainActor @Test
func `forward destination index warms before the menu is presented`() async throws {
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "current",
        displayName: "Current"
    )
    let guild = Guild(id: GuildID(rawValue: 2), name: "Warm Guild")
    let channel = Channel(
        id: ChannelID(rawValue: 10),
        guildID: guild.id,
        name: "warm-destination",
        kind: .text
    )
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [guild],
        channels: [channel],
        members: []
    )

    #expect(model.forwardingMessage == nil)
    let index = try #require(
        await ForwardDestinationSearchIndexCache.shared.prepare(
            for: model,
            priority: .utility
        )
    )

    #expect(index.results(query: "warm").map(\.id) == [.channel(channel.id)])
    #expect(ForwardDestinationSearchIndexCache.shared.value(
        for: model,
        userID: currentUser.id,
        revision: model.forwardSearchSourceRevision
    ) != nil)
}

@Test func `forward search includes account wide known users without a private channel`() {
    let knownUser = User(
        id: UserID(rawValue: 2),
        username: "supplemental_user",
        displayName: "Supplemental User"
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "supplemental",
        channels: [],
        users: [knownUser],
        guilds: [:],
        usageScores: [:]
    )

    #expect(results.map(\.id) == [.user(knownUser.id)])
}

@MainActor @Test
func `open forward search observes live user and guild nickname store updates`() {
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "current",
        displayName: "Current"
    )
    let observedUser = User(
        id: UserID(rawValue: 2),
        username: "observed",
        displayName: "Observed"
    )
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [],
        channels: [],
        members: []
    )

    let initialRevision = model.forwardSearchSourceRevision
    model.consumeImmediately(.knownUsersChanged([currentUser, observedUser]))
    #expect(model.forwardSearchSourceRevision == initialRevision + 1)
    #expect(model.snapshot?.knownUsers.contains(observedUser) == true)

    model.consumeImmediately(.userSearchAliasesChanged([
        observedUser.id: ["Guild nickname"],
    ]))
    #expect(model.forwardSearchSourceRevision == initialRevision + 2)
    #expect(model.snapshot?.userSearchAliasesByUserID[observedUser.id] == [
        "Guild nickname",
    ])
}

@Test func `empty forward search follows pinned history then frecency and omits origin`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let channels = (10 ... 14).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(value)),
            guildID: guild.id,
            name: "channel-\(value)",
            kind: .text,
            position: value
        )
    }

    let results = ForwardDestinationSearchPolicy.results(
        query: "",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: ["12": 20, "13": 40, "14": 10],
        recentChannelIDs: [ChannelID(rawValue: 11), ChannelID(rawValue: 10)],
        pinnedDestinationIDs: [.channel(ChannelID(rawValue: 14))],
        originChannelID: ChannelID(rawValue: 10)
    )

    #expect(results.compactMap(\.resolvedChannelID) == [
        ChannelID(rawValue: 14),
        ChannelID(rawValue: 11),
        ChannelID(rawValue: 13),
        ChannelID(rawValue: 12),
    ])
}

@Test func `empty forward search preserves frecency source order for equal scores`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let channels = (10 ... 13).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(value)),
            guildID: guild.id,
            name: "channel-\(value)",
            kind: .text
        )
    }

    let results = ForwardDestinationSearchPolicy.results(
        query: "",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: ["10": 100, "11": 100, "12": 100, "13": 100],
        usageOrder: ["12", "10", "13", "11"]
    )

    #expect(results.compactMap(\.resolvedChannelID) == [
        ChannelID(rawValue: 12),
        ChannelID(rawValue: 10),
        ChannelID(rawValue: 13),
        ChannelID(rawValue: 11),
    ])
}

@Test func `forward channel history is most recent unique and capped at eight`() {
    var history: [ChannelID] = []
    for value in 1 ... 10 {
        history = AppModel.updatedForwardDestinationHistory(
            history,
            visiting: ChannelID(rawValue: UInt64(value))
        )
    }
    #expect(history.map(\.rawValue) == [10, 9, 8, 7, 6, 5, 4, 3])

    history = AppModel.updatedForwardDestinationHistory(
        history,
        visiting: ChannelID(rawValue: 6)
    )
    #expect(history.map(\.rawValue) == [6, 10, 9, 8, 7, 5, 4, 3])
}

@MainActor @Test func `forward channel history persists per account like Discord quick switcher`() {
    let scope = "test-\(UUID().uuidString)"
    let historyKey = "dev.sakuracord.forward-destination-history.\(scope)"
    let frecencyKey = "dev.sakuracord.forward-frecency-deltas.\(scope)"
    defer {
        UserDefaults.standard.removeObject(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: frecencyKey)
    }

    let first = AppModel(
        launchMode: .normal,
        provider: MockChatProvider(),
        discordNetworkDisabledOverride: true,
        restoresStoredSession: false
    )
    first.configureForwardDestinationHistoryScope(scope)
    first.recordForwardDestinationVisit(ChannelID(rawValue: 10))
    first.recordForwardDestinationVisit(ChannelID(rawValue: 20))

    let second = AppModel(
        launchMode: .normal,
        provider: MockChatProvider(),
        discordNetworkDisabledOverride: true,
        restoresStoredSession: false
    )
    second.configureForwardDestinationHistoryScope(scope)
    #expect(second.forwardDestinationHistory == [
        ChannelID(rawValue: 20), ChannelID(rawValue: 10),
    ])
}

@MainActor @Test
func `passive initial channel selection does not contaminate forward history`() {
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "tester",
        displayName: "Tester"
    )
    let guild = Guild(id: GuildID(rawValue: 2), name: "Test Guild")
    let first = Channel(
        id: ChannelID(rawValue: 10), guildID: guild.id,
        name: "welcome", kind: .text
    )
    let second = Channel(
        id: ChannelID(rawValue: 11), guildID: guild.id,
        name: "general", kind: .text
    )
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [guild],
        channels: [first, second],
        members: []
    )
    model.visibleChannels = [first, second]

    model.selectedChannelID = first.id
    #expect(model.forwardDestinationHistory.isEmpty)

    model.selectedChannelID = second.id
    #expect(model.forwardDestinationHistory == [second.id])
}

@MainActor @Test func `failed frecency enrichment never leaves forwarding destinations loading`() async {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: ForwardSettingsFailureProvider()
    )

    await model.loadDiscordEmojiSettings()

    #expect(model.didAttemptDiscordEmojiSettings)
    #expect(model.hasLoadedDiscordEmojiSettings)
}

@Test func `forward frecency recomputes from retained uses like Discord`() {
    let day: UInt64 = 86_400_000
    let now: UInt64 = 1_800_000_000_000
    let usage = DiscordFrecencyUsage(
        totalUses: 5,
        recentUses: [now, now - day, now - 2 * day]
    )

    #expect(AppModel.discordFrecencyScore(usage, nowMilliseconds: now) == 367)
    #expect(AppModel.discordFrecencyScore(
        DiscordFrecencyUsage(totalUses: 9, recentUses: []),
        nowMilliseconds: now
    ) == nil)
}

@Test func `forward frecency uses Discords guild channel override boundaries`() {
    let day: UInt64 = 86_400_000
    let now: UInt64 = 1_800_000_000_000
    let usage = DiscordFrecencyUsage(
        totalUses: 9,
        recentUses: [0, 1, 2, 3, 4, 6, 7, 80, 81].map { now - UInt64($0) * day }
    )

    #expect(AppModel.discordFrecencyScore(usage, nowMilliseconds: now) == 360)
}

@Test func `persisted forward frecency replays total uses and the newest ten samples`() {
    let merged = AppModel.mergedDiscordFrecencyUsage(
        base: DiscordFrecencyUsage(
            totalUses: 20,
            recentUses: Array(1 ... 8).map(UInt64.init)
        ),
        delta: DiscordFrecencyUsage(
            totalUses: 4,
            recentUses: [12, 9, 11, 10]
        )
    )

    #expect(merged.totalUses == 24)
    #expect(merged.recentUses == Array(3 ... 12).map(UInt64.init))
}

@MainActor @Test
func `persisted forward frecency replay is idempotent for one account scope`() {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    model.discordFrecencyUsageDeltasDefaultsKey = "test.forward-frecency.scope"
    model.discordGuildAndChannelUsage = [
        "10": DiscordFrecencyUsage(totalUses: 10, recentUses: [100]),
    ]
    model.persistedDiscordFrecencyUsageDeltas = [
        "10": DiscordFrecencyUsage(totalUses: 2, recentUses: [200, 300]),
    ]

    model.applyPersistedDiscordFrecencyUsageDeltas()
    let once = model.discordGuildAndChannelUsage["10"]
    model.applyPersistedDiscordFrecencyUsageDeltas()
    let twice = model.discordGuildAndChannelUsage["10"]

    #expect(once?.totalUses == 12)
    #expect(twice?.totalUses == once?.totalUses)
    #expect(twice?.recentUses == once?.recentUses)
}

@Test func `typed forward search preserves source order after score`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let channels = [
        Channel(
            id: ChannelID(rawValue: 10), guildID: guild.id,
            name: "general", kind: .text
        ),
        Channel(
            id: ChannelID(rawValue: 11), guildID: guild.id,
            name: "generation", kind: .text
        ),
        Channel(
            id: ChannelID(rawValue: 12), guildID: guild.id,
            name: "gen-alpha", kind: .text
        ),
    ]

    let boosted = ForwardDestinationSearchPolicy.results(
        query: "gen",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: ["11": 100]
    )
    #expect(boosted.compactMap(\.resolvedChannelID).first == ChannelID(rawValue: 11))

    let sourceOrdered = ForwardDestinationSearchPolicy.results(
        query: "gen",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: [:]
    )
    #expect(sourceOrdered.compactMap(\.resolvedChannelID) == [
        ChannelID(rawValue: 10),
        ChannelID(rawValue: 11),
        ChannelID(rawValue: 12),
    ])

    var earlierPosition = channels[1]
    earlierPosition.position = -1
    let positioned = ForwardDestinationSearchPolicy.results(
        query: "gen",
        channels: [channels[0], earlierPosition, channels[2]],
        guilds: [guild.id: guild],
        usageScores: [:]
    )
    #expect(positioned.compactMap(\.resolvedChannelID) == [
        channels[0].id,
        earlierPosition.id,
        channels[2].id,
    ])
}

@Test func `forward channel search restores Discord store order independently of sidebar order`() {
    let guildID = GuildID(rawValue: 1)
    let sidebarOrdered = [
        Channel(
            id: ChannelID(rawValue: 10), guildID: guildID,
            name: "match-first-in-sidebar", kind: .text, position: 0
        ),
        Channel(
            id: ChannelID(rawValue: 11), guildID: guildID,
            name: "match-first-in-store", kind: .text, position: 1
        ),
        Channel(
            id: ChannelID(rawValue: 12), guildID: guildID,
            name: "match-new-after-ready", kind: .text, position: 2
        ),
    ]

    let ordered = ForwardDestinationSearchPolicy.channelsInStoreOrder(
        sidebarOrdered,
        storeOrder: [sidebarOrdered[1].id, sidebarOrdered[0].id]
    )

    #expect(ordered.map(\.id) == [
        sidebarOrdered[1].id,
        sidebarOrdered[0].id,
        sidebarOrdered[2].id,
    ])
}

@Test func `equal score group DMs preserve Ready source order not sidebar activity order`() {
    let user = User(
        id: UserID(rawValue: 2),
        username: "recipient",
        displayName: "Recipient"
    )
    let channels = [
        Channel(
            id: ChannelID(rawValue: 10), guildID: nil,
            name: "Group", kind: .groupDirectMessage, position: 2,
            recipients: [user], lastMessageID: MessageID(rawValue: 900)
        ),
        Channel(
            id: ChannelID(rawValue: 11), guildID: nil,
            name: "Group", kind: .groupDirectMessage, position: 0,
            recipients: [user], lastMessageID: MessageID(rawValue: 700)
        ),
        Channel(
            id: ChannelID(rawValue: 12), guildID: nil,
            name: "Group", kind: .groupDirectMessage, position: 1,
            recipients: [user], lastMessageID: MessageID(rawValue: 800)
        ),
    ]

    let results = ForwardDestinationSearchPolicy.results(
        query: "group",
        channels: channels,
        guilds: [:],
        usageScores: [:]
    )

    #expect(results.compactMap(\.resolvedChannelID) == [
        ChannelID(rawValue: 11),
        ChannelID(rawValue: 12),
        ChannelID(rawValue: 10),
    ])
}

@Test func `blank selection stays in place while search selection becomes a picker pin`() {
    let existing: [ForwardDestinationID] = [
        .channel(ChannelID(rawValue: 10)),
        .channel(ChannelID(rawValue: 11)),
    ]
    let selected = ForwardDestinationID.channel(ChannelID(rawValue: 12))

    #expect(ForwardDestinationSelectionPolicy.searchPins(
        afterSelecting: selected,
        query: "",
        selectedDestinationIDs: [.channel(ChannelID(rawValue: 13))],
        existing: existing
    ) == existing)
    let blankSelected = ForwardDestinationID.channel(ChannelID(rawValue: 13))
    #expect(ForwardDestinationSelectionPolicy.searchPins(
        afterSelecting: selected,
        query: "meow",
        selectedDestinationIDs: [blankSelected],
        existing: existing
    ) == [selected, blankSelected] + existing)
}

@Test func `search pin is retained at the visible top while blank results replace the query`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Server")
    let channels = (10 ... 30).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(value)),
            guildID: guild.id,
            name: "channel-\(value)",
            kind: .text
        )
    }
    let destinations = channels.prefix(15).map {
        ForwardDestination(kind: .channel($0), guild: guild)
    }
    let searchedDestination = ForwardDestination(
        kind: .channel(channels[20]),
        guild: guild
    )

    let merged = ForwardDestinationSelectionPolicy.mergingPinnedDestinations(
        [searchedDestination.id],
        into: destinations,
        fallbacks: [searchedDestination]
    )

    #expect(merged.first?.id == searchedDestination.id)
    #expect(merged.count == 15)
    #expect(Set(merged.map(\.id)).count == merged.count)
}

@Test func `forward people use relationship names while group subtitles use raw recipient names`() throws {
    let friend = User(
        id: UserID(rawValue: 2),
        username: "legacy-bot",
        discriminator: "8860",
        displayName: "Global Name",
        isBot: true
    )
    let clown = User(
        id: UserID(rawValue: 3), username: "clown", displayName: "*Clown*"
    )
    let namedGroup = Channel(
        id: ChannelID(rawValue: 20), guildID: nil, name: "group name",
        hasExplicitName: true, kind: .groupDirectMessage,
        recipients: [clown, friend]
    )
    let unnamedGroup = Channel(
        id: ChannelID(rawValue: 21), guildID: nil, name: "legacy-bot's Group",
        hasExplicitName: false, kind: .groupDirectMessage
    )
    let relationshipNames = [friend.id: "USERNAME THIEF!!!"]

    let person = try #require(ForwardDestinationSearchPolicy.results(
        query: "thief",
        channels: [namedGroup, unnamedGroup],
        users: [friend],
        friendUserIDs: [friend.id],
        relationshipNicknamesByUserID: relationshipNames,
        guilds: [:],
        usageScores: [:]
    ).first)
    #expect(person.title == "USERNAME THIEF!!!")
    #expect(person.detail == "legacy-bot#8860")

    let groups = ForwardDestinationSearchPolicy.results(
        query: "group",
        channels: [namedGroup, unnamedGroup],
        users: [friend, clown],
        relationshipNicknamesByUserID: relationshipNames,
        guilds: [:],
        usageScores: [:]
    )
    #expect(groups.first { $0.id == .channel(namedGroup.id) }?.detail
        == "*Clown*, Global Name")
    let unnamed = try #require(groups.first {
        $0.id == .channel(unnamedGroup.id)
    })
    #expect(unnamed.detailOverride == nil)
    #expect(unnamed.detail.isEmpty)

    let largeGroup = Channel(
        id: ChannelID(rawValue: 22), guildID: nil, name: "large group",
        hasExplicitName: true, kind: .groupDirectMessage,
        recipients: [clown, friend, clown, friend, clown]
    )
    let largeDetail = ForwardDestinationSearchPolicy.results(
        query: "large",
        channels: [largeGroup],
        relationshipNicknamesByUserID: relationshipNames,
        guilds: [:],
        usageScores: [:]
    ).first?.detail
    #expect(largeDetail == "*Clown*, Global Name, *Clown* and 2 others")
}

@Test func `forward people search matches account wide guild nickname without changing title`() throws {
    let samy = User(
        id: UserID(rawValue: 2),
        username: "samyy2025_",
        displayName: "Samy"
    )
    let directMessage = Channel(
        id: ChannelID(rawValue: 20), guildID: nil, name: "Samy",
        kind: .directMessage, recipients: [samy]
    )

    let person = try #require(ForwardDestinationSearchPolicy.results(
        query: "meow",
        channels: [directMessage],
        users: [samy],
        friendUserIDs: [samy.id],
        userSearchAliasesByUserID: [samy.id: ["Samy the meow car"]],
        guilds: [:],
        usageScores: [:]
    ).first)

    #expect(person.title == "Samy")
    #expect(person.detail == "samyy2025_")
}

@Test func `group DM search matches recipient relationship nicknames`() {
    let recipient = User(
        id: UserID(rawValue: 2), username: "recipient", displayName: "Recipient"
    )
    let group = Channel(
        id: ChannelID(rawValue: 20), guildID: nil, name: "Showcase",
        hasExplicitName: true, kind: .groupDirectMessage,
        recipients: [recipient]
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "meow",
        channels: [group],
        users: [recipient],
        relationshipNicknamesByUserID: [recipient.id: "Meow friend"],
        guilds: [:],
        usageScores: [:]
    )

    #expect(results.contains { $0.id == .channel(group.id) })
}

@Test func `typed channel search uses Discords live hundred point bonus scale`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let exact = Channel(
        id: ChannelID(rawValue: 10), guildID: guild.id,
        name: "gen", kind: .text
    )
    let boostedPrefix = Channel(
        id: ChannelID(rawValue: 11), guildID: guild.id,
        name: "general", kind: .text
    )
    let accountMaximum = Channel(
        id: ChannelID(rawValue: 12), guildID: guild.id,
        name: "unrelated", kind: .text
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "gen",
        channels: [exact, boostedPrefix, accountMaximum],
        guilds: [guild.id: guild],
        usageScores: ["11": 100, "12": 94_700]
    )

    #expect(results.compactMap(\.resolvedChannelID) == [boostedPrefix.id, exact.id])
}

@Test func `typed forward search includes missing DMs and caps each category separately`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let users = (1 ... 25).map { value in
        User(
            id: UserID(rawValue: UInt64(100 + value)),
            username: "match-user-\(value)",
            displayName: "Match User \(value)"
        )
    }
    let channels = (1 ... 25).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(200 + value)),
            guildID: guild.id,
            name: "match-channel-\(value)",
            kind: .text
        )
    }

    let results = ForwardDestinationSearchPolicy.results(
        query: "match",
        channels: channels,
        users: users,
        guilds: [guild.id: guild],
        usageScores: [:]
    )

    #expect(results.count == 40)
    #expect(results.filter { if case .user = $0.kind { true } else { false } }.count == 20)
    #expect(results.filter { if case .channel = $0.kind { true } else { false } }.count == 20)
    #expect(results.contains { $0.id == .user(users[0].id) })
}

@Test func `forward search truncates raw voice category before send permission filtering`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let channels = (1 ... 25).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(300 + value)),
            guildID: guild.id,
            name: "match-voice-\(value)",
            kind: .voice
        )
    }
    let eligible = Set(channels.dropFirst(4).map(\.id))

    let results = ForwardDestinationSearchPolicy.results(
        query: "match",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: [:],
        searchableChannelIDs: Set(channels.map(\.id)),
        eligibleChannelIDs: eligible
    )

    #expect(results.map(\.id) == channels[4 ..< 20].map {
        .channel($0.id)
    })
    #expect(!results.contains { $0.id == .channel(channels[20].id) })
}

@Test func `voice search overlaps selectable and vocal categories before deduplication`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let textChannels = (1 ... 20).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(600 + value)),
            guildID: guild.id,
            name: "match-text-\(value)",
            kind: .text
        )
    }
    let voice = Channel(
        id: ChannelID(rawValue: 700), guildID: guild.id,
        name: "match-voice", kind: .voice
    )
    let channels = textChannels + [voice]

    let results = ForwardDestinationSearchPolicy.results(
        query: "match",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: [:],
        searchableChannelIDs: Set(channels.map(\.id)),
        eligibleChannelIDs: Set(channels.map(\.id))
    )

    #expect(results.count == 21)
    #expect(results.filter { $0.id == .channel(voice.id) }.count == 1)
}

@Test func `selectable voice penalty does not admit an unmatched channel`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let matching = Channel(
        id: ChannelID(rawValue: 701), guildID: guild.id,
        name: "administration", kind: .text
    )
    let unmatchedVoice = Channel(
        id: ChannelID(rawValue: 702), guildID: guild.id,
        name: "music lounge", kind: .voice
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "admin",
        channels: [matching, unmatchedVoice],
        guilds: [guild.id: guild],
        usageScores: [:],
        searchableChannelIDs: [matching.id, unmatchedVoice.id],
        eligibleChannelIDs: [matching.id, unmatchedVoice.id]
    )

    #expect(results.map(\.id) == [.channel(matching.id)])
}

@Test func `forward search truncates raw text category before destination-type filtering`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let forums = (1 ... 4).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(400 + value)),
            guildID: guild.id,
            name: "match-forum-\(value)",
            kind: .forum
        )
    }
    let textChannels = (1 ... 21).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(500 + value)),
            guildID: guild.id,
            name: "match-text-\(value)",
            kind: .text
        )
    }
    let channels = forums + textChannels

    let results = ForwardDestinationSearchPolicy.results(
        query: "match",
        channels: channels,
        guilds: [guild.id: guild],
        usageScores: [:],
        searchableChannelIDs: Set(channels.map(\.id)),
        eligibleChannelIDs: Set(textChannels.map(\.id))
    )

    #expect(results.map(\.id) == textChannels.prefix(16).map {
        .channel($0.id)
    })
    #expect(!results.contains { $0.id == .channel(textChannels[16].id) })
}

@Test func `preindexed forward search benchmarks ten distinct inputs`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let channels = (1 ... 1_000).map { value in
        Channel(
            id: ChannelID(rawValue: UInt64(10_000 + value)),
            guildID: guild.id,
            name: "benchmark-channel-\(value)",
            kind: value.isMultiple(of: 4) ? .voice : .text,
            category: value.isMultiple(of: 3) ? "Community" : "General"
        )
    }
    let users = (1 ... 1_000).map { value in
        User(
            id: UserID(rawValue: UInt64(20_000 + value)),
            username: "benchmark-user-\(value)",
            displayName: "Benchmark Person \(value)"
        )
    }
    let index = ForwardDestinationSearchPolicy.makeIndex(
        channels: channels,
        users: users,
        guilds: [guild.id: guild],
        usageScores: [:]
    )
    let queries = [
        "b", "be", "bench", "channel", "person",
        "community", "general", "voice", "user-19", "channel-199",
    ]

    func currentThreadCPUSeconds() -> Double {
        var value = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    var resultCount = 0
    let wallStart = ContinuousClock.now
    let cpuStart = currentThreadCPUSeconds()
    for query in queries {
        resultCount += index.results(query: query).count
    }
    let cpuMilliseconds = (currentThreadCPUSeconds() - cpuStart) * 1_000
    let wallDuration = wallStart.duration(to: .now)
    let wallMilliseconds = Double(wallDuration.components.seconds) * 1_000
        + Double(wallDuration.components.attoseconds) / 1_000_000_000_000_000
    print(String(
        format: "Forward search benchmark: %.3f ms CPU (%.3f/input), %.3f ms wall",
        cpuMilliseconds,
        cpuMilliseconds / Double(queries.count),
        wallMilliseconds
    ))

    #expect(resultCount > 0)
    // A 25 ms per-input budget on a 2,000-destination synthetic account is
    // intentionally larger than the normal live picker population. Discord
    // retains only 20 raw rows per category, so this also catches regressions
    // that accidentally return to sorting every matching row per keystroke.
    #expect(cpuMilliseconds < 250)
}

@Test func `forward modal keyboard layout and animation contract stays immediate`() {
    #expect(WindowModalKeyPolicy.isEscape(keyCode: 53, characters: nil))
    #expect(WindowModalKeyPolicy.isEscape(keyCode: 0, characters: "\u{1B}"))
    #expect(!WindowModalKeyPolicy.isEscape(keyCode: 36, characters: "\r"))
    #expect(ForwardPickerLayoutMetrics.width == 480)
    #expect(ForwardPickerLayoutMetrics.height == 679)
    #expect(ForwardPickerLayoutMetrics.rowHeight == 48)
    #expect(ForwardPickerLayoutMetrics.selectionDiameter == 20)
    #expect(ForwardPickerLayoutMetrics.closeHitTarget >= 36)
    #expect(WindowModalAnimationTiming.openingSeconds <= 0.22)
    #expect(WindowModalAnimationTiming.closingSeconds <= 0.16)
    #expect(WindowModalAnimationTiming.removalDelayMilliseconds <= 170)
}

@Test func `forward preview follows Discord text emoji and attachment rules`() throws {
    let imageURL = try #require(URL(string: "https://cdn.discordapp.com/attachments/1/1/a.png"))
    let author = User(id: UserID(rawValue: 1), username: "tester", displayName: "Tester")

    func message(
        content: String = "",
        attachments: [SakuraCordModels.Attachment] = [],
        embeds: [MessageEmbed] = [],
        components: [MessageComponent] = []
    ) -> Message {
        Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            author: author,
            content: content,
            attachments: attachments,
            embeds: embeds,
            components: components
        )
    }

    let text = ForwardMessagePreviewPlan.make(message: message(
        content: "A deliberately long message with <:wave:123> that wraps onto another line."
    ))
    #expect(text.content?.contains("<:wave:123>") == true)
    #expect(text.contentLineLimit == 2)
    #expect(text.attachmentSummary == nil)
    #expect(text.media == nil)

    let heading = ForwardMessagePreviewPlan.make(message: message(
        content: "# Preview heading\n\nPreview body"
    ))
    #expect(heading.content == "**Preview heading** Preview body")

    let images = (1 ... 5).map { index in
        SakuraCordModels.Attachment(
            id: "\(index)",
            filename: "image-\(index).png",
            url: imageURL,
            mediaType: "image/png"
        )
    }
    let imagePlan = ForwardMessagePreviewPlan.make(message: message(attachments: images))
    #expect(imagePlan.content == nil)
    #expect(imagePlan.contentLineLimit == 1)
    #expect(imagePlan.attachmentSummary == "5 images")
    #expect(imagePlan.attachmentSystemImage == "photo.on.rectangle.angled")
    #expect(imagePlan.media == ForwardPreviewMedia(
        url: imageURL,
        kind: .image(animated: false)
    ))
    #expect(imagePlan.mediaOverflowCount == 4)

    let linked = ForwardMessagePreviewPlan.make(message: message(
        content: imageURL.absoluteString,
        embeds: [MessageEmbed(
            type: "image",
            url: imageURL,
            image: MessageEmbedMedia(url: imageURL)
        )]
    ))
    #expect(linked.content == imageURL.absoluteString)
    #expect(linked.attachmentSummary == nil)
    #expect(linked.media == ForwardPreviewMedia(
        url: imageURL,
        kind: .image(animated: false)
    ))

    let videoURL = try #require(URL(string: "https://cdn.discordapp.com/attachments/1/2/video.mp4"))
    let linkedVideo = ForwardMessagePreviewPlan.make(message: message(
        content: "https://example.com/video",
        embeds: [MessageEmbed(
            type: "video",
            url: URL(string: "https://example.com/video"),
            thumbnail: MessageEmbedMedia(url: imageURL),
            video: MessageEmbedMedia(url: videoURL)
        )]
    ))
    #expect(linkedVideo.attachmentSummary == nil)
    #expect(linkedVideo.media == ForwardPreviewMedia(
        url: imageURL,
        kind: .image(animated: false)
    ))

    let stickerOnly = ForwardMessagePreviewPlan.make(message: Message(
        id: MessageID(rawValue: 9),
        channelID: ChannelID(rawValue: 2),
        author: author,
        content: "",
        stickers: [MessageSticker(
            id: "sticker",
            name: "snacked",
            description: "Mr Snack staring at the camera"
        )]
    ))
    #expect(stickerOnly.content == nil)
    #expect(stickerOnly.attachmentSummary == nil)
    #expect(stickerOnly.media == nil)
}

@Test func `forward preview includes Components V2 text and media`() throws {
    let imageURL = try #require(URL(string: "https://cdn.discordapp.com/attachments/1/2/component.png"))
    let message = Message(
        id: MessageID(rawValue: 3),
        channelID: ChannelID(rawValue: 4),
        author: User(id: UserID(rawValue: 1), username: "tester", displayName: "Tester"),
        content: "## Stale fallback that must not win",
        flags: .isComponentsV2,
        components: [
            .container(
                id: "container",
                accentColor: nil,
                spoiler: false,
                children: [
                    .textDisplay(
                        id: "text",
                        content: "## Component preview heading\n\nComponent preview text"
                    ),
                    .mediaGallery(id: "gallery", items: [
                        ComponentGalleryItem(media: ComponentMedia(url: imageURL)),
                        ComponentGalleryItem(media: ComponentMedia(url: imageURL)),
                    ]),
                ]
            ),
        ]
    )

    let plan = ForwardMessagePreviewPlan.make(message: message)
    #expect(plan.content == "**Component preview heading** Component preview text")
    #expect(plan.attachmentSummary == nil)
    #expect(plan.mediaOverflowCount == 1)
    #expect(plan.contentLineLimit == 2)
}

@Test func `forward preview plan benchmark stays below presentation budget`() throws {
    let imageURL = try #require(URL(string: "https://cdn.discordapp.com/attachments/1/3/preview.gif"))
    let message = Message(
        id: MessageID(rawValue: 5),
        channelID: ChannelID(rawValue: 6),
        author: User(id: UserID(rawValue: 1), username: "tester", displayName: "Tester"),
        content: "Preview <:wave:123>",
        attachments: [SakuraCordModels.Attachment(
            id: "1",
            filename: "preview.gif",
            url: imageURL,
            mediaType: "image/gif"
        )]
    )
    let start = ContinuousClock.now
    var plans = 0
    for _ in 0 ..< 10_000 {
        plans += ForwardMessagePreviewPlan.make(message: message).media == nil ? 0 : 1
    }
    let duration = start.duration(to: .now)
    let milliseconds = Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    print(String(format: "Forward preview benchmark: %.3f ms / 10,000 plans", milliseconds))
    #expect(plans == 10_000)
    #expect(milliseconds < 250)
}

@Test func `equal score user search orders by the matched comparator`() {
    let first = User(
        id: UserID(rawValue: 30), username: "match-zed", displayName: "Match First"
    )
    let second = User(
        id: UserID(rawValue: 20), username: "match-alpha", displayName: "Match Second"
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "match",
        channels: [],
        users: [first, second],
        guilds: [:],
        usageScores: [:]
    )

    #expect(results.map(\.id) == [.user(second.id), .user(first.id)])
}

@Test func `user search comparator is the highest scoring matched identity`() {
    let usernameMatch = User(
        id: UserID(rawValue: 30), username: "azuronate", displayName: "Zulu"
    )
    let aliasMatch = User(
        id: UserID(rawValue: 20), username: "yuk1n0w", displayName: "Yotsuba"
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "a",
        channels: [],
        users: [usernameMatch, aliasMatch],
        userSearchAliasesByUserID: [aliasMatch.id: ["adeituto"]],
        guilds: [:],
        usageScores: [:]
    )

    #expect(results.map(\.id) == [.user(aliasMatch.id), .user(usernameMatch.id)])
}

@Test func `user search mirrors Discord confusable skeleton matching`() {
    let smartNickname = User(
        id: UserID(rawValue: 10), username: "plain-user", displayName: "Plain User"
    )
    let styledName = User(
        id: UserID(rawValue: 20), username: "another-user",
        displayName: "𝙶𝚎𝚗𝚎𝚛𝚊𝚕"
    )

    let samResults = ForwardDestinationSearchPolicy.results(
        query: "sam",
        channels: [],
        users: [smartNickname],
        userSearchAliasesByUserID: [smartNickname.id: ["cute (and smart) kitten"]],
        guilds: [:],
        usageScores: [:]
    )
    let genResults = ForwardDestinationSearchPolicy.results(
        query: "gen",
        channels: [],
        users: [styledName],
        guilds: [:],
        usageScores: [:]
    )

    #expect(samResults.map(\.id) == [.user(smartNickname.id)])
    #expect(genResults.map(\.id) == [.user(styledName.id)])
}

@Test func `typed user search applies friend then existing DM boosters`() {
    let existing = User(
        id: UserID(rawValue: 2), username: "match-existing", displayName: "Match Existing"
    )
    let friend = User(
        id: UserID(rawValue: 3), username: "match-friend", displayName: "Match Friend"
    )
    let channel = Channel(
        id: ChannelID(rawValue: 10), guildID: nil, name: existing.displayName,
        kind: .directMessage, recipients: [existing]
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "match",
        channels: [channel],
        users: [existing, friend],
        friendUserIDs: [friend.id],
        guilds: [:],
        usageScores: [:]
    )

    #expect(results.map(\.id) == [.user(friend.id), .user(existing.id)])
}

@Test func `forward destination search obeys the permission-filtered channel set`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "Sakura Server")
    let visible = Channel(
        id: ChannelID(rawValue: 10), guildID: guild.id, name: "match-visible", kind: .text
    )
    let hidden = Channel(
        id: ChannelID(rawValue: 11), guildID: guild.id, name: "match-hidden", kind: .text
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "match",
        channels: [visible, hidden],
        guilds: [guild.id: guild],
        usageScores: [:],
        eligibleChannelIDs: [visible.id]
    )

    #expect(results.map(\.id) == [.channel(visible.id)])
}

@MainActor @Test func `unresolved vocal access never becomes forward search connect access`() {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    let guildID = GuildID(rawValue: 1)
    let text = Channel(
        id: ChannelID(rawValue: 10), guildID: guildID,
        name: "text-match", kind: .text
    )
    let voice = Channel(
        id: ChannelID(rawValue: 11), guildID: guildID,
        name: "voice-match", kind: .voice
    )

    #expect(model.canSearchForwardDestination(text))
    #expect(!model.canSearchForwardDestination(voice))
}

@Test func `active forum thread remains a forward destination while its parent does not`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "SakuraCord")
    let forum = Channel(
        id: ChannelID(rawValue: 10), guildID: guild.id,
        name: "bug-reports", kind: .forum
    )
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 11), guildID: guild.id,
        parentID: forum.id, name: "forwarded messages need support",
        notificationSettings: ThreadNotificationSettings()
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "forwarded",
        channels: [forum],
        threads: [thread],
        guilds: [guild.id: guild],
        usageScores: [:],
        eligibleChannelIDs: [thread.id]
    )

    #expect(results.map(\.id) == [.channel(thread.id)])
    #expect(results.first?.detail == "bug-reports")
}

@Test func `forward search excludes inactive and unjoined cached threads`() {
    let guild = Guild(id: GuildID(rawValue: 1), name: "SakuraCord")
    let forum = Channel(
        id: ChannelID(rawValue: 10), guildID: guild.id,
        name: "bug-reports", kind: .forum
    )
    let unjoined = MessageThreadSummary(
        id: ChannelID(rawValue: 11), guildID: guild.id,
        parentID: forum.id, name: "matching unjoined"
    )
    let archived = MessageThreadSummary(
        id: ChannelID(rawValue: 12), guildID: guild.id,
        parentID: forum.id, name: "matching archived", isArchived: true,
        notificationSettings: ThreadNotificationSettings()
    )

    let results = ForwardDestinationSearchPolicy.results(
        query: "matching",
        channels: [forum],
        threads: [unjoined, archived],
        guilds: [guild.id: guild],
        usageScores: [:],
        eligibleChannelIDs: [unjoined.id, archived.id]
    )

    #expect(results.isEmpty)
}

@Test func `forward menu action is capability gated beside reply`() {
    let entries = NativeTimelineMessageMenuPolicy.entries(
        canEdit: false,
        canRetry: false,
        canReply: true,
        canForward: true
    )
    #expect(entries.contains(.action(
        .forward,
        title: "Forward",
        systemImage: "arrowshape.turn.up.right"
    )))
}

@Test func `forward eligibility matches first party message types and exclusions`() {
    func message(
        type: DiscordMessageType,
        flags: MessageFlags = [],
        outboxState: OutboxState = .confirmed,
        hasPoll: Bool = false,
        hasActivity: Bool = false,
        hasSharedClientTheme: Bool = false,
        hasCall: Bool = false,
        hasActivityInstance: Bool = false
    ) -> Message {
        Message(
            id: MessageID(rawValue: UInt64(type.rawValue + 100)),
            channelID: ChannelID(rawValue: 10),
            author: User(
                id: UserID(rawValue: 1),
                username: "tester",
                displayName: "Tester"
            ),
            content: "fixture",
            outboxState: outboxState,
            type: type,
            flags: flags,
            call: hasCall ? MessageCall() : nil,
            hasPoll: hasPoll,
            hasActivity: hasActivity,
            hasSharedClientTheme: hasSharedClientTheme,
            hasActivityInstance: hasActivityInstance
        )
    }

    #expect([0, 19, 20, 23, 35].allSatisfy {
        message(type: DiscordMessageType(rawValue: $0)).isForwardable
    })
    #expect([1, 2, 3, 7, 18, 21, 22, 24, 46, 68].allSatisfy {
        !message(type: DiscordMessageType(rawValue: $0)).isForwardable
    })
    #expect(!message(type: .default, outboxState: .failed).isForwardable)
    #expect(!message(type: .default, hasPoll: true).isForwardable)
    #expect(!message(type: .default, hasActivity: true).isForwardable)
    #expect(!message(type: .default, hasSharedClientTheme: true).isForwardable)
    #expect(!message(type: .default, hasCall: true).isForwardable)
    #expect(!message(type: .default, hasActivityInstance: true).isForwardable)

    let allowedFlags: [MessageFlags] = [
        .crossposted, .isCrosspost, .suppressEmbeds, .urgent, .hasThread,
        .failedToMentionRoles, .guildFeedHidden, .shouldShowNonDiscordLinkWarning,
        .suppressNotifications, .voiceMessage, .forwarded, .isComponentsV2,
        .isGuildOfficial,
    ]
    #expect(allowedFlags.allSatisfy {
        message(type: .default, flags: $0).isForwardable
    })
    #expect(!message(type: .default, flags: .sourceMessageDeleted).isForwardable)
    #expect(!message(type: .default, flags: .ephemeral).isForwardable)
    #expect(!message(type: .default, flags: .loading).isForwardable)
}

@MainActor @Test
func `forwarded snapshot reserves chrome while reusing rich message layout`() throws {
    let attachmentURL = try #require(URL(string: "https://cdn.discordapp.com/attachments/7/80/flower.png"))
    let snapshot = ForwardedMessageSnapshot(
        content: "forwarded text",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        attachments: [Attachment(
            id: "80",
            filename: "flower.png",
            url: attachmentURL,
            mediaType: "image/png",
            width: 64,
            height: 64
        )]
    )
    let message = Message(
        id: MessageID(rawValue: 50),
        channelID: ChannelID(rawValue: 41),
        author: User(
            id: UserID(rawValue: 1),
            username: "tester",
            displayName: "Tester"
        ),
        content: snapshot.content,
        attachments: snapshot.attachments,
        messageReference: DiscordMessageReference(
            type: .forward,
            messageID: MessageID(rawValue: 9),
            channelID: ChannelID(rawValue: 7),
            guildID: GuildID(rawValue: 5)
        ),
        forwardedSnapshot: snapshot
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )

    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: 560
    )
    #expect(layout.forwardedHeaderFrame != nil)
    #expect(layout.forwardedBarFrame != nil)
    #expect(layout.contentFrame != nil)
    #expect(layout.attachmentRegions.count == 1)
    #expect(layout.forwardedSourceRegion == nil)
}

@MainActor @Test
func `forward source footer distinguishes guild scope and disappears when inaccessible`() throws {
    let sourceGuildID = GuildID(rawValue: 5)
    let destinationGuildID = GuildID(rawValue: 6)
    let sourceChannelID = ChannelID(rawValue: 7)
    let sourceIcon = try #require(URL(string: "https://cdn.discordapp.com/icons/5/source.png"))
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "tester",
        displayName: "Tester"
    )
    let sourceGuild = Guild(
        id: sourceGuildID,
        name: "Source Guild",
        iconURL: sourceIcon
    )
    let sourceChannel = Channel(
        id: sourceChannelID,
        guildID: sourceGuildID,
        name: "actual-testing",
        kind: .text
    )
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [sourceGuild, Guild(id: destinationGuildID, name: "Destination Guild")],
        channels: [sourceChannel],
        members: []
    )
    let snapshot = ForwardedMessageSnapshot(
        content: "forwarded text",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )

    func layout(destinationGuildID: GuildID?) -> NativeTimelineRowLayout {
        let message = Message(
            id: MessageID(rawValue: 50),
            channelID: ChannelID(rawValue: 41),
            author: currentUser,
            content: snapshot.content,
            guildID: destinationGuildID,
            messageReference: DiscordMessageReference(
                type: .forward,
                messageID: MessageID(rawValue: 9),
                channelID: sourceChannelID,
                guildID: sourceGuildID
            ),
            forwardedSnapshot: snapshot
        )
        let row = MessageRowPresentation(
            message: message,
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        )
        return NativeTimelineRowLayout.make(
            item: .message(row, isUnreadBoundary: false, isHighlighted: false),
            width: 560,
            model: model
        )
    }

    let sameGuild = try #require(layout(destinationGuildID: sourceGuildID).forwardedSourceRegion)
    #expect(sameGuild.label == "#actual-testing")
    #expect(sameGuild.iconURL == nil)
    #expect(sameGuild.frame.width < 420)

    let crossGuild = try #require(layout(destinationGuildID: destinationGuildID).forwardedSourceRegion)
    #expect(crossGuild.label == "Source Guild")
    #expect(crossGuild.iconURL == sourceIcon)

    model.snapshot?.channels = []
    #expect(layout(destinationGuildID: destinationGuildID).forwardedSourceRegion == nil)
}

private actor ForwardSettingsFailureProvider: ChatProvider {
    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: User(id: UserID(rawValue: 1), username: "test", displayName: "Test"),
            guilds: [], channels: [], members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] { [] }
    func members(in guildID: GuildID?) async throws -> [Member] { [] }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("unused")
    }

    func emojiUserSettings() async throws -> EmojiUserSettings {
        throw ChatProviderError.transport(status: 503, requestID: nil)
    }

    func currentStatus() async -> PresenceStatus { .offline }
    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }
    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("unused")
    }
    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws
        -> Message
    {
        throw ChatProviderError.invalidRequest("unused")
    }
    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}
