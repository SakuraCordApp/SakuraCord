import AppKit
@testable import DiscordProtocol
import Foundation
import MessageRendering
import SakuraCordModels
import SakuraCordPersistence
import Testing
import UserNotifications
@testable import SakuraCord

@MainActor
@Test func `server rail projection isolates unrelated guild row updates`() {
    var first = Guild(id: GuildID(rawValue: 1), name: "First")
    let second = Guild(id: GuildID(rawValue: 2), name: "Second")
    let missingID = GuildID(rawValue: 3)
    let items: [GuildRailItem] = [
        .guild(first.id),
        .guild(second.id),
        .guild(missingID),
        .folder(
            GuildFolder(
                id: 4,
                name: "Folder",
                guildIDs: [first.id, missingID, second.id]
            )
        ),
    ]
    let settings: (Guild) -> GuildNotificationSettings = {
        GuildNotificationSettings(guildID: $0.id)
    }
    let store = ServerRailPresentationStore()
    store.updateLayout(items)
    store.updateGuilds(
        [first.id: first, second.id: second],
        notificationSettings: settings,
        isMutationPending: { _ in false }
    )
    let baseline = store.items
    guard case .guild(let firstEntry) = baseline[0],
          case .guild(let secondEntry) = baseline[1],
          case .guild(let missingEntry) = baseline[2],
          case .folder(let folderEntry) = baseline[3]
    else {
        Issue.record("Expected the projected server rail layout")
        return
    }
    let secondPresentation = secondEntry.presentation

    first.mentionCount = 1
    store.updateGuilds(
        [first.id: first, second.id: second],
        notificationSettings: settings,
        isMutationPending: { _ in false }
    )
    let updated = store.items

    #expect(baseline.map(\.id) == items.map(\.id))
    guard case .guild(let updatedFirstEntry) = updated[0],
          case .guild(let updatedSecondEntry) = updated[1],
          case .guild(let updatedMissingEntry) = updated[2],
          case .folder(let updatedFolderEntry) = updated[3]
    else {
        Issue.record("Expected the stable projected server rail layout")
        return
    }
    #expect(firstEntry === updatedFirstEntry)
    #expect(secondEntry === updatedSecondEntry)
    #expect(missingEntry === updatedMissingEntry)
    #expect(folderEntry === updatedFolderEntry)
    #expect(firstEntry.presentation?.guild.mentionCount == 1)
    #expect(secondEntry.presentation == secondPresentation)
    #expect(missingEntry.presentation == nil)
    #expect(folderEntry.mentionCount == 1)
}

@MainActor
@Test func `voice sidebar projection isolates unrelated channel updates`() {
    let firstChannelID = ChannelID(rawValue: 10)
    let secondChannelID = ChannelID(rawValue: 20)
    let firstUserID = UserID(rawValue: 11)
    let secondUserID = UserID(rawValue: 21)
    let firstEntry: VoiceSidebarChannelEntry
    let secondEntry: VoiceSidebarChannelEntry
    let store = VoiceSidebarPresentationStore()

    firstEntry = store.entry(for: firstChannelID)
    secondEntry = store.entry(for: secondChannelID)
    let firstState = VoiceParticipantState(
        userID: firstUserID,
        channelID: firstChannelID,
        guildID: GuildID(rawValue: 1),
        sessionID: "first"
    )
    let secondState = VoiceParticipantState(
        userID: secondUserID,
        channelID: secondChannelID,
        guildID: GuildID(rawValue: 1),
        sessionID: "second"
    )
    let states = [firstUserID: firstState, secondUserID: secondState]
    var firstMember = Member(
        user: User(
            id: firstUserID,
            username: "first",
            displayName: "First"
        ),
        roleName: "Member",
        status: .online
    )
    let secondMember = Member(
        user: User(
            id: secondUserID,
            username: "second",
            displayName: "Second"
        ),
        roleName: "Member",
        status: .online
    )
    store.update(
        voiceStates: states,
        membersByID: [firstUserID: firstMember, secondUserID: secondMember],
        currentUser: nil,
        activeVoiceChannel: nil,
        isVoiceMuted: false,
        isVoiceDeafened: false,
        isCameraEnabled: false
    )
    let unchangedParticipants = secondEntry.participants

    firstMember = Member(
        user: User(
            id: firstUserID,
            username: "first",
            displayName: "Renamed First"
        ),
        roleName: "Member",
        status: .online
    )
    store.update(
        voiceStates: states,
        membersByID: [firstUserID: firstMember, secondUserID: secondMember],
        currentUser: nil,
        activeVoiceChannel: nil,
        isVoiceMuted: false,
        isVoiceDeafened: false,
        isCameraEnabled: false
    )

    #expect(store.entry(for: firstChannelID) === firstEntry)
    #expect(store.entry(for: secondChannelID) === secondEntry)
    #expect(firstEntry.participants.map(\.name) == ["Renamed First"])
    #expect(secondEntry.participants == unchangedParticipants)

    store.update(
        voiceStates: [secondUserID: secondState],
        membersByID: [secondUserID: secondMember],
        currentUser: nil,
        activeVoiceChannel: nil,
        isVoiceMuted: false,
        isVoiceDeafened: false,
        isCameraEnabled: false
    )

    #expect(firstEntry.participants.isEmpty)
    #expect(secondEntry.participants == unchangedParticipants)
}

@Test func `loading overlap bootstrap keeps measured guild cold`() {
    let google = Guild(id: GuildID(rawValue: 10), name: "Google Labs")
    let control = Guild(id: GuildID(rawValue: 20), name: "Control")

    #expect(
        PerformanceBenchmarkInitialGuildPolicy.resolve(
            guilds: [google, control],
            retainedGuildID: google.id,
            avoidingGuildNamed: "google labs"
        ) == control.id
    )
    #expect(
        PerformanceBenchmarkInitialGuildPolicy.resolve(
            guilds: [google, control],
            retainedGuildID: google.id,
            avoidingGuildNamed: nil
        ) == google.id
    )
}

@MainActor
@Test func `numbered navigation maps and selects direct messages and eight servers in rail order`() async {
    let model = AppModel(launchMode: .offlineTesting)
    let guilds = (1 ... 10).map {
        Guild(id: GuildID(rawValue: UInt64($0)), name: "Server \($0)")
    }
    model.serverRailGuildsByID = Dictionary(
        uniqueKeysWithValues: guilds.map { ($0.id, $0) }
    )
    model.serverRailItems = [
        .guild(guilds[0].id),
        .folder(GuildFolder(id: 1, guildIDs: guilds[1 ... 3].map(\.id))),
        .guild(GuildID(rawValue: 999)),
        .folder(GuildFolder(id: 2, guildIDs: guilds[4 ... 7].map(\.id))),
        .guild(guilds[8].id),
        .guild(guilds[9].id),
    ]

    #expect(model.navigationDestination(for: 1) == .directMessages)
    for shortcutNumber in 2 ... 9 {
        #expect(
            model.navigationDestination(for: shortcutNumber)
                == .guild(guilds[shortcutNumber - 2].id)
        )
    }
    #expect(model.navigationDestination(for: 0) == nil)
    #expect(model.navigationDestination(for: 10) == nil)

    model.navigateUsingShortcut(9)
    await model.guildActivationTask?.value
    #expect(model.selectedGuildID == guilds[7].id)

    model.navigateUsingShortcut(1)
    await model.guildActivationTask?.value
    #expect(model.selectedGuildID == nil)
}

@MainActor
@Test func `switching servers restores each server's last opened channel`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let auroraID = GuildID(rawValue: 100)
    let nativeLabID = GuildID(rawValue: 101)
    let rememberedAuroraChannel = try #require(
        model.snapshot?.channels.first(where: {
            $0.guildID == auroraID && $0.id == ChannelID(rawValue: 211)
        })
    )
    let rememberedNativeChannel = try #require(
        model.snapshot?.channels.first(where: {
            $0.guildID == nativeLabID && $0.id == ChannelID(rawValue: 301)
        })
    )

    model.selectedChannelID = rememberedAuroraChannel.id
    #expect(model.lastOpenedChannelIDsByGuild[auroraID] == rememberedAuroraChannel.id)
    model.selectGuild(nativeLabID)
    await model.guildActivationTask?.value
    model.selectedChannelID = rememberedNativeChannel.id
    #expect(model.lastOpenedChannelIDsByGuild[nativeLabID] == rememberedNativeChannel.id)

    model.selectGuild(auroraID)
    await model.guildActivationTask?.value
    #expect(model.selectedChannelID == rememberedAuroraChannel.id)

    model.selectGuild(nativeLabID)
    await model.guildActivationTask?.value
    #expect(model.selectedChannelID == rememberedNativeChannel.id)
}

@MainActor
@Test func `message search Escape respects focused and unfocused behavior`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.presentMessageSearch()
    model.messageSearch.queryText = "road"
    model.messageSearch.isPresented = true

    #expect(!model.consumeEscapeForUnfocusedMessageSearch())
    #expect(model.messageSearch.queryText == "road")

    model.handleMessageSearchEscape()
    #expect(model.messageSearch.queryText.isEmpty)
    #expect(model.messageSearch.isPresented)
    #expect(model.messageSearch.isInputFocused)

    model.handleMessageSearchEscape()
    #expect(!model.messageSearch.isPresented)
    #expect(!model.messageSearch.isInputFocused)

    model.presentMessageSearch()
    model.messageSearch.queryText = "priority"
    model.messageSearch.isPresented = true
    model.messageSearch.isInputFocused = false

    #expect(model.consumeEscapeForUnfocusedMessageSearch())
    #expect(model.messageSearch.queryText.isEmpty)
    #expect(model.messageSearch.tokens.isEmpty)
    #expect(!model.messageSearch.isPresented)
    #expect(!model.consumeEscapeForUnfocusedMessageSearch())
}

@Test func `forum navigation keeps the toolbar search surface installed`() {
    #expect(MessageSearchSurfacePolicy.showsToolbar(
        channelKind: .forum,
        hasOpenThread: false
    ))
    #expect(!MessageSearchSurfacePolicy.showsToolbar(
        channelKind: .forum,
        hasOpenThread: true
    ))
}

@Test func `message search keeps guild thread metadata out of canonical channels`() {
    let guildID = GuildID(rawValue: 100)
    let thread = Channel(
        id: ChannelID(rawValue: 300),
        guildID: guildID,
        name: "Search result thread",
        categoryID: ChannelID(rawValue: 200)
    )
    let directMessage = Channel(
        id: ChannelID(rawValue: 400),
        guildID: nil,
        name: "Maya",
        kind: .directMessage
    )
    let groupDirectMessage = Channel(
        id: ChannelID(rawValue: 500),
        guildID: nil,
        name: "Release group",
        kind: .groupDirectMessage
    )

    let canonicalChannels = MessageSearchChannelMergePolicy
        .canonicalPrivateChannels(
            in: [thread, directMessage, groupDirectMessage]
        )

    #expect(canonicalChannels.map(\.id) == [
        directMessage.id,
        groupDirectMessage.id,
    ])
}

@MainActor
@Test func `command f scopes message search to the current conversation`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let channel = try #require(model.selectedChannel)

    model.presentMessageSearchFromCommand()

    let token = try #require(model.messageSearch.tokens.first)
    guard case .channel(let channelID, let name) = token.kind else {
        Issue.record("Command-F did not create an in: token")
        return
    }
    #expect(channelID == channel.id)
    #expect(name == model.messageSearchPresentedName(for: channel))
    #expect(model.messageSearch.isInputFocused)
}

@MainActor
@Test func `channel message cache keeps only the newest bounded history`() {
    let channelID = ChannelID(rawValue: 9)
    let author = User(
        id: UserID(rawValue: 7),
        username: "cache",
        displayName: "Cache"
    )
    let messages = (0 ..< ChannelMessageCachePolicy.maximumMessageCountPerChannel + 25)
        .map { index in
            Message(
                id: MessageID(rawValue: UInt64(index + 1)),
                channelID: channelID,
                author: author,
                content: "Message \(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    let retained = ChannelMessageCachePolicy.retainedMessages(from: messages)

    #expect(
        retained.count
            == ChannelMessageCachePolicy.maximumMessageCountPerChannel
    )
    #expect(retained.first?.id == messages[messages.count - retained.count].id)
    #expect(retained.last?.id == messages.last?.id)
}

@MainActor
@Test func `app model loads demo and sends message`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    #expect(model.snapshot != nil)
    #expect(model.selectedChannel != nil)
    #expect(model.supportsCapability(.components))
    let before = model.messages.count
    model.updateDraft("hello from test")
    await model.send()
    #expect(model.messages.count == before + 1)
    #expect(model.messages.last?.content == "hello from test")
}

@MainActor
@Test func `newest page reconciliation removes covered deletions and preserves live rows`() {
    let channelID = ChannelID(rawValue: 9_100)
    let author = User(
        id: UserID(rawValue: 9_101),
        username: "reconcile",
        displayName: "Reconcile"
    )
    func message(
        _ value: UInt64,
        outboxState: OutboxState = .confirmed
    ) -> Message {
        Message(
            id: MessageID(rawValue: value),
            channelID: channelID,
            author: author,
            content: "message \(value)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(value)),
            outboxState: outboxState
        )
    }
    let current = [
        message(1),
        message(2),
        message(3),
        message(5),
        message(6, outboxState: .sending),
        message(7),
    ]
    let fresh = [message(2), message(4)]
    let mutations: [MessageID: ConversationRefreshMutation] = [
        message(7).id: .upsert(message(7))
    ]
    let refreshed = AppModel.applyingConversationRefreshMutations(
        mutations,
        to: fresh
    )

    let partialPageIDs = AppModel.reconcilingNewestPage(
        current: current,
        fresh: refreshed,
        hasMoreBefore: true,
        authoritativeOldestMessageID: fresh.map(\.id).min()
    ).map(\.id.rawValue)
    let completePageIDs = AppModel.reconcilingNewestPage(
        current: current,
        fresh: refreshed,
        hasMoreBefore: false,
        authoritativeOldestMessageID: fresh.map(\.id).min()
    ).map(\.id.rawValue)

    #expect(partialPageIDs == [1, 2, 4, 6, 7])
    #expect(completePageIDs == [2, 4, 6, 7])
}

@MainActor
@Test func `inaccessible private channels remain visible but are excluded from unread state`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let privateChannelID = ChannelID(rawValue: 215)

    #expect(await eventuallyOnMain {
        model.readState.entries[privateChannelID]?.isAccessible == false
    })
    let privateChannel = model.visibleChannels.first { $0.id == privateChannelID }
    #expect(privateChannel != nil)
    #expect(privateChannel.map(model.conversationAccess(for:)) == .hidden)
    #expect(model.hiddenChannelIDs.contains(privateChannelID))
    #expect(!model.isChannelUnread(privateChannelID))
    #expect(model.channelMentionCount(privateChannelID) == 0)

    model.selectedChannelID = privateChannelID
    #expect(await eventuallyOnMain {
        model.selectedChannel?.id == privateChannelID
            && model.selectedChannel.map(model.conversationAccess(for:)) == .hidden
    })
}

@MainActor
@Test func `selecting an inaccessible text channel performs no message read`() async throws {
    let provider = InaccessibleChannelRequestCountingProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try hiddenMockChannel(kind: .text, in: model)

    model.selectedChannelID = channel.id
    try await Task.sleep(for: .milliseconds(40))

    #expect(model.selectedConversationAccess == .hidden)
    #expect(await provider.messageRequestCount(for: channel.id) == 0)
    #expect(!model.isLoadingMessages)
    #expect(model.messages.isEmpty)
}

@MainActor
@Test func `unresolved channel waits for readable access before loading`() async throws {
    let provider = InaccessibleChannelRequestCountingProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    var snapshot = try #require(model.snapshot)
    var guild = try #require(snapshot.guilds.first)
    guild.currentUserPermissions = nil
    let guildIndex = try #require(snapshot.guilds.firstIndex { $0.id == guild.id })
    snapshot.guilds[guildIndex] = guild
    let channel = Channel(
        id: ChannelID(rawValue: 77_150),
        guildID: guild.id,
        name: "permission-loading",
        kind: .text,
        lastMessageID: MessageID(rawValue: 77_151)
    )
    snapshot.channels.append(channel)
    model.snapshot = snapshot
    model.serverRailGuildsByID[guild.id] = guild
    model.selectedGuildID = guild.id
    model.currentUserRoleIDsByGuild[guild.id] = nil
    model.membersByGuildID[guild.id] = nil
    model.guildRolesByGuildID[guild.id] = nil
    model.membersByID = [:]
    model.guildRoles = []
    model.refreshUnreadPresentation(appliesAccessImmediately: true)

    #expect(model.conversationAccess(for: channel) == .checking)
    #expect(model.checkingChannelIDs.contains(channel.id))
    #expect(model.readState.entries[channel.id]?.isAccessible == false)
    let checkingVoice = Channel(
        id: ChannelID(rawValue: 77_152),
        guildID: guild.id,
        name: "permission-loading-voice",
        kind: .voice
    )
    #expect(!model.canJoinVoice(checkingVoice))

    model.selectedChannelID = channel.id
    try await Task.sleep(for: .milliseconds(40))
    #expect(await provider.messageRequestCount(for: channel.id) == 0)

    guild.currentUserPermissions = .max
    var resolvedSnapshot = try #require(model.snapshot)
    let resolvedGuildIndex = try #require(
        resolvedSnapshot.guilds.firstIndex { $0.id == guild.id }
    )
    resolvedSnapshot.guilds[resolvedGuildIndex] = guild
    model.snapshot = resolvedSnapshot
    model.serverRailGuildsByID[guild.id] = guild
    model.currentUserRoleIDsByGuild[guild.id] = []
    model.refreshUnreadPresentation(appliesAccessImmediately: true)

    #expect(await eventuallyOnMain {
        model.selectedConversationAccess.isReadable
            && !model.checkingChannelIDs.contains(channel.id)
    })
    #expect(await eventuallyOnMain {
        !model.isLoadingMessages
    })
    #expect(await provider.messageRequestCount(for: channel.id) == 1)
}

@MainActor
@Test func `selecting an inaccessible forum performs no forum read`() async throws {
    let provider = InaccessibleChannelRequestCountingProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try hiddenMockChannel(kind: .forum, in: model)

    model.selectedChannelID = channel.id
    try await Task.sleep(for: .milliseconds(40))

    #expect(model.selectedConversationAccess == .hidden)
    #expect(await provider.forumRequestCount(for: channel.id) == 0)
    #expect(model.forumLoadTask == nil)
}

@MainActor
@Test func `inaccessible voice performs no history read or join`() async throws {
    let provider = InaccessibleChannelRequestCountingProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try hiddenMockChannel(kind: .voice, in: model)

    model.selectedChannelID = channel.id
    try await Task.sleep(for: .milliseconds(40))
    #expect(await provider.messageRequestCount(for: channel.id) == 0)
    #expect(!model.isLoadingMessages)
    #expect(model.selectedConversationAccess == .hidden)
    #expect(!model.canJoinVoice(channel))

    await model.joinVoice(channel)

    #expect(await provider.voiceJoinRequestCount() == 0)
    #expect(model.activeVoiceChannel == nil)
}

@MainActor
@Test func `startup snapshot presents channel guild and folder unread without a later event`() async
    throws
{
    let provider = StartupUnreadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()

    let channel = try #require(model.visibleChannels.first)
    let guild = try #require(model.serverRailGuildsByID[GuildID(rawValue: 77_000)])
    #expect(channel.unreadCount == 1)
    #expect(channel.mentionCount == 2)
    #expect(guild.unreadCount == 1)
    #expect(guild.mentionCount == 2)
    #expect(
        model.serverRailItems
            == [
                .folder(
                    GuildFolder(
                        id: 77,
                        name: "Startup",
                        guildIDs: [GuildID(rawValue: 77_000)]
                    )
                )
            ]
    )
}

@MainActor
@Test func `gateway guild metadata update preserves projected server unread`() async throws {
    let provider = StartupUnreadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let guildID = GuildID(rawValue: 77_000)
    var gatewayGuild = try #require(model.snapshot?.guilds.first { $0.id == guildID })
    gatewayGuild.unreadCount = 0
    gatewayGuild.mentionCount = 0

    model.consumeGuildChanged(gatewayGuild)

    #expect(model.serverRailGuildsByID[guildID]?.unreadCount == 1)
    #expect(model.serverRailGuildsByID[guildID]?.mentionCount == 2)
    #expect(model.snapshot?.guilds.first { $0.id == guildID }?.unreadCount == 1)
}

@MainActor
@Test func `gateway guild layout update preserves projected server unread`() async throws {
    let provider = StartupUnreadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let guildID = GuildID(rawValue: 77_000)
    var gatewayGuild = try #require(model.snapshot?.guilds.first { $0.id == guildID })
    gatewayGuild.unreadCount = 0
    gatewayGuild.mentionCount = 0
    let railItems = model.serverRailItems

    model.consumeGuildLayoutChanged(guilds: [gatewayGuild], railItems: railItems)

    #expect(model.serverRailGuildsByID[guildID]?.unreadCount == 1)
    #expect(model.serverRailGuildsByID[guildID]?.mentionCount == 2)
    #expect(model.snapshot?.guilds.first { $0.id == guildID }?.unreadCount == 1)
}

@MainActor
@Test func `untouched server keeps authoritative unread while permissions are checking`() async
    throws
{
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let guildID = GuildID(rawValue: 77_100)
    let unreadChannelID = ChannelID(rawValue: 77_101)
    let unknownChannelID = ChannelID(rawValue: 77_102)
    var refreshed = try #require(model.snapshot)
    refreshed.guilds.append(
        Guild(
            id: guildID,
            name: "Untouched server",
            defaultMessageNotifications: .allMessages
        )
    )
    refreshed.guildRailItems.append(.guild(guildID))
    refreshed.channels.append(contentsOf: [
        Channel(
            id: unreadChannelID,
            guildID: guildID,
            name: "authoritative-unread",
            lastMessageID: MessageID(rawValue: 12)
        ),
        Channel(
            id: unknownChannelID,
            guildID: guildID,
            name: "no-read-state",
            lastMessageID: MessageID(rawValue: 22)
        ),
    ])
    refreshed.readStates.append(
        ChannelReadState(
            channelID: unreadChannelID,
            lastAcknowledgedMessageID: MessageID(rawValue: 10),
            mentionCount: 2
        )
    )

    model.consumeSnapshotChanged(refreshed)

    #expect(model.checkingChannelIDs.contains(unreadChannelID))
    #expect(model.checkingChannelIDs.contains(unknownChannelID))
    #expect(model.readState.entries[unreadChannelID]?.isAccessible == true)
    #expect(model.readState.entries[unknownChannelID]?.isAccessible == false)
    #expect(model.serverRailGuildsByID[guildID]?.unreadCount == 1)
    #expect(model.serverRailGuildsByID[guildID]?.mentionCount == 2)
}

@MainActor
@Test func `reopening a channel reuses session memory without another history request`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let first = try #require(model.visibleChannels.first)
    let second = try #require(model.visibleChannels.dropFirst().first)

    model.selectedChannelID = first.id
    await model.channelLoadTask?.value
    #expect(await provider.requestCount(for: first.id) == 1)
    let firstMessages = model.messages

    model.selectedChannelID = second.id
    await model.channelLoadTask?.value
    model.selectedChannelID = first.id
    await model.channelLoadTask?.value

    #expect(model.messages == firstMessages)
    #expect(await provider.requestCount(for: first.id) == 1)
}

@Test func `local history member resolution prioritizes newest unknown authors and stays bounded`() {
    let channelID = ChannelID(rawValue: 76_000)
    let messages = (1 ... 120).map { rawID in
        let id = UInt64(rawID)
        return Message(
            id: MessageID(rawValue: id),
            channelID: channelID,
            author: User(
                id: UserID(rawValue: id),
                username: "user-\(id)",
                displayName: "User \(id)"
            ),
            content: ""
        )
    }

    let requested = LocalHistoryMemberResolution.userIDs(
        in: messages,
        known: [UserID(rawValue: 120)]
    )

    #expect(requested.count == LocalHistoryMemberResolution.maximumUserCount)
    #expect(requested.first == UserID(rawValue: 119))
    #expect(requested.last == UserID(rawValue: 20))
    #expect(!requested.contains(UserID(rawValue: 120)))
    #expect(!requested.contains(UserID(rawValue: 19)))
}

@MainActor
@Test func `guild history resolves missing authors into the timeline member store`() async throws {
    let provider = LocalHistoryMemberTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()

    #expect(await eventuallyOnMain {
        guard let message = model.messages.first else { return false }
        return model.authorPresentation(for: message).roleColorHex == 0xFF7900
    })
    #expect(await provider.resolutionRequests() == [[UserID(rawValue: 76_101)]])
}

@MainActor
@Test func `history member hydration refreshes only affected message rows`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 76_400)
    let affectedAuthor = User(
        id: UserID(rawValue: 76_401),
        username: "affected",
        displayName: "Affected"
    )
    let unaffectedAuthor = User(
        id: UserID(rawValue: 76_402),
        username: "unaffected",
        displayName: "Unaffected"
    )
    let sourceMessages = [
        Message(
            id: MessageID(rawValue: 76_403),
            channelID: channelID,
            author: affectedAuthor,
            content: "Affected row"
        ),
        Message(
            id: MessageID(rawValue: 76_404),
            channelID: channelID,
            author: unaffectedAuthor,
            content: "Unaffected row"
        ),
    ]
    model.replaceSelectedMessages(with: sourceMessages)
    let affectedRow = try #require(model.messageRows.first)
    let unaffectedRow = try #require(model.messageRows.last)
    let previousRowsRevision = model.messageRowsRevision
    let previousPresentationRevision = model.timelinePresentationRevision
    let resolvedMember = Member(
        user: User(
            id: affectedAuthor.id,
            username: affectedAuthor.username,
            displayName: "Resolved nickname"
        ),
        roleName: "Resolved",
        status: .offline,
        roleID: RoleID(rawValue: 76_405),
        rolePosition: 1,
        isRoleCategory: true,
        roleIDs: [RoleID(rawValue: 76_405)]
    )
    let hydrated = LocalHistoryMemberResolution.hydrating(
        sourceMessages,
        with: [resolvedMember.id: resolvedMember]
    )

    model.applySelectedHistoryMemberHydration(
        hydrated,
        presentationMessageIDs: [sourceMessages[0].id]
    )

    #expect(model.messages[0].guildMember != nil)
    #expect(model.messageRows[0] !== affectedRow)
    #expect(model.messageRows[0].textPlan == affectedRow.textPlan)
    #expect(model.messageRows[1] === unaffectedRow)
    #expect(model.messageRowsRevision == previousRowsRevision &+ 1)
    #expect(model.timelinePresentationRevision == previousPresentationRevision)
    let records = try #require(
        model.messageRowsUpdateJournal.records(
            after: previousRowsRevision,
            through: model.messageRowsRevision
        )
    )
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.changedMessageIDs == [sourceMessages[0].id])
    #expect(!record.invalidatesAllRows)
}

@MainActor
@Test func `snapshot refresh preserves the account unread notification mode`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let guildID = GuildID(rawValue: 78_000)
    let channelID = ChannelID(rawValue: 78_001)
    let refreshed = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [
            Guild(
                id: guildID,
                name: "Legacy unread policy",
                currentUserPermissions: .max,
                defaultMessageNotifications: .onlyMentions
            )
        ],
        channels: [
            Channel(
                id: channelID,
                guildID: guildID,
                name: "general",
                lastMessageID: MessageID(rawValue: 11)
            )
        ],
        members: [],
        readStates: [
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10)
            )
        ],
        usesNewNotifications: false
    )

    await provider.emit(.snapshotChanged(refreshed))

    #expect(await eventuallyOnMain {
        model.snapshot?.usesNewNotifications == false
            && model.snapshot?.channels.contains(where: { $0.id == channelID }) == true
    })
    #expect(model.isChannelUnread(channelID))
    #expect(model.serverRailGuildsByID[guildID]?.unreadCount == 1)
}

@MainActor
@Test func `gateway ready refreshes the account unread notification mode`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guildID = GuildID(rawValue: 79_000)
    let channelID = ChannelID(rawValue: 79_001)
    let currentUser = try #require(model.snapshot?.currentUser)
    let refreshed = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [
            Guild(
                id: guildID,
                name: "Reconnect policy",
                currentUserPermissions: .max,
                defaultMessageNotifications: .onlyMentions
            )
        ],
        channels: [
            Channel(
                id: channelID,
                guildID: guildID,
                name: "general",
                lastMessageID: MessageID(rawValue: 11)
            )
        ],
        members: [],
        readStates: [
            ChannelReadState(
                channelID: channelID,
                lastAcknowledgedMessageID: MessageID(rawValue: 10)
            )
        ],
        usesNewNotifications: true
    )
    await provider.emit(.snapshotChanged(refreshed))
    #expect(await eventuallyOnMain {
        model.snapshot?.usesNewNotifications == true
            && model.snapshot?.channels.contains(where: { $0.id == channelID }) == true
    })
    #expect(!model.isChannelUnread(channelID))

    await provider.emit(
        .notificationModeChanged(usesNewNotifications: false)
    )

    #expect(await eventuallyOnMain {
        model.snapshot?.usesNewNotifications == false
    })
    #expect(model.isChannelUnread(channelID))
    #expect(await eventuallyOnMain {
        model.serverRailGuildsByID[guildID]?.unreadCount == 1
    })
}

@MainActor
@Test func `reaction gateway updates reconcile forum previews and open threads without reload`() async
    throws
{
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(model.forumPosts.first)
    let starter = try #require(post.firstMessage)
    model.open(post)
    #expect(await eventuallyOnMain { !model.isLoadingThread && !model.threadMessages.isEmpty })

    await provider.emit(
        .messageReactionUpdated(
            .add(
                channelID: post.id,
                messageID: starter.id,
                userID: UserID(rawValue: 55_555),
                emoji: "<:gateway_blob:999>",
                kind: .normal
            )
        )
    )

    #expect(
        await eventuallyOnMain {
            model.threadMessages.first(where: { $0.id == starter.id })?
                .reactions.contains(where: { $0.id == "custom:999" }) == true
                && model.forumPosts.first(where: { $0.id == post.id })?
                    .firstMessage?.reactions.contains(where: { $0.id == "custom:999" }) == true
        }
    )

    await provider.emit(
        .messageReactionUpdated(
            .removeEmoji(
                channelID: post.id,
                messageID: starter.id,
                emoji: "<a:renamed_gateway_blob:999>"
            )
        )
    )
    #expect(
        await eventuallyOnMain {
            model.threadMessages.first(where: { $0.id == starter.id })?
                .reactions.contains(where: { $0.id == "custom:999" }) == false
                && model.forumPosts.first(where: { $0.id == post.id })?
                    .firstMessage?.reactions.contains(where: { $0.id == "custom:999" }) == false
        }
    )
}

@MainActor
@Test func `forum preview hydration preserves loaded reactor avatars`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let initialPost = try #require(
        model.forumPosts.first(where: { $0.firstMessage?.reactions.isEmpty == false })
    )
    let initialMessage = try #require(initialPost.firstMessage)
    let initialReaction = try #require(initialMessage.reactions.first)
    await model.loadReactionReactors(initialReaction, on: initialMessage)
    #expect(
        await eventuallyOnMain {
            model.forumPosts.first(where: { $0.id == initialPost.id })?
                .firstMessage?.reactions.first(where: { $0.id == initialReaction.id })?
                .reactors.isEmpty == false
        }
    )
    let loadedReactors = try #require(
        model.forumPosts.first(where: { $0.id == initialPost.id })?
            .firstMessage?.reactions.first(where: { $0.id == initialReaction.id })?
            .reactors
    )

    var replacement = try #require(
        model.forumPosts.first(where: { $0.id == initialPost.id })
    )
    var replacementMessage = try #require(replacement.firstMessage)
    let reactionIndex = try #require(
        replacementMessage.reactions.firstIndex(where: {
            $0.id == initialReaction.id
        })
    )
    replacementMessage.reactions[reactionIndex].count += 1
    replacementMessage.reactions[reactionIndex].reactors = []
    replacement.firstMessage = replacementMessage
    await provider.emit(
        .forumPostPreviewsChanged(channelID: forum.id, posts: [replacement])
    )

    #expect(
        await eventuallyOnMain {
            guard
                let reaction = model.forumPosts.first(where: { $0.id == initialPost.id })?
                    .firstMessage?.reactions.first(where: { $0.id == initialReaction.id })
            else {
                return false
            }
            return reaction.count == initialReaction.count + 1
                && reaction.reactors == loadedReactors
        }
    )
}

@MainActor
@Test func `rapid reaction clicks publish only the latest state per message and emoji`() async throws {
    let provider = ReactionMutationTestProvider()
    let model = reactionMutationTestModel(provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    let initialRowsRevision = model.messageRowsRevision
    await model.toggleReaction("🔥", on: message)
    #expect(model.messages.first?.reactions.first?.didCurrentUserReact == true)
    #expect(model.messageRows.first?.message.reactions.first?.didCurrentUserReact == true)
    #expect(model.messageRowsRevision > initialRowsRevision)
    await model.toggleReaction("🔥", on: message)
    #expect(model.messages.first?.reactions.isEmpty == true)
    #expect(model.messageRows.first?.message.reactions.isEmpty == true)
    await model.toggleReaction("🔥", on: message)
    #expect(model.messages.first?.reactions.first?.didCurrentUserReact == true)

    #expect(await drainReactionMutations(in: model))
    #expect(await provider.requests() == [.init(messageID: message.id, emoji: "🔥", reacted: true)])
}

@MainActor
@Test func `reaction clicks that return to confirmed state issue no request`() async throws {
    let provider = ReactionMutationTestProvider()
    let model = reactionMutationTestModel(provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    for _ in 0 ..< 20 {
        await model.toggleReaction("🔥", on: message)
    }

    #expect(await drainReactionMutations(in: model))
    #expect(await provider.requests().isEmpty)
    #expect(model.messages.first?.reactions.isEmpty == true)
}

@MainActor
@Test func `reaction mutations stay independent across message and emoji keys`() async throws {
    let provider = ReactionMutationTestProvider()
    let model = reactionMutationTestModel(provider: provider)
    await model.start()
    let first = try #require(model.messages.first)
    let second = try #require(model.messages.dropFirst().first)

    await model.toggleReaction("🔥", on: first)
    await model.toggleReaction("✅", on: first)
    await model.toggleReaction("🔥", on: second)

    #expect(await drainReactionMutations(in: model))
    let requests = await provider.requests()
    #expect(requests.count == 3)
    #expect(Set(requests.map(\.messageID)) == Set([first.id, second.id]))
    #expect(Set(requests.map(\.emoji)) == Set(["🔥", "✅"]))
}

@MainActor
@Test func `reaction failure reverts only the failed optimistic key`() async throws {
    let provider = ReactionMutationTestProvider(failingEmoji: "🔥")
    let model = reactionMutationTestModel(provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    await model.toggleReaction("🔥", on: message)
    await model.toggleReaction("✅", on: message)
    #expect(model.messages.first?.reactions.count == 2)

    #expect(await drainReactionMutations(in: model))
    let reactions = try #require(model.messages.first?.reactions)
    #expect(reactions.contains(where: { $0.id == "unicode:🔥" }) == false)
    #expect(reactions.first(where: { $0.id == "unicode:✅" })?.didCurrentUserReact == true)
}

@MainActor
@Test func `message updates preserve already loaded reactor avatars`() async throws {
    let reactor = ReactionReactor(
        id: UserID(rawValue: 98_200),
        displayName: "Loaded Reactor",
        avatarURL: URL(string: "https://cdn.example/reactor.png")
    )
    let provider = ReactionMutationTestProvider(
        initialReaction: Reaction(emoji: "🔥", count: 2, reactors: [reactor])
    )
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let original = try #require(model.messages.first(where: { !$0.reactions.isEmpty }))

    await provider.emit(
        .messageUpdated(
            Message(
                id: original.id,
                channelID: original.channelID,
                author: original.author,
                content: original.content,
                reactions: [Reaction(emoji: "🔥", count: 3)]
            )
        )
    )

    #expect(
        await eventuallyOnMain {
            let updated = model.messages.first(where: { $0.id == original.id })
            return updated?.reactions.first?.count == 3
                && updated?.reactions.first?.reactors == [reactor]
        }
    )
}

@MainActor
@Test func `clicks during an in flight reaction collapse to one latest follow up`() async throws {
    let provider = ReactionMutationTestProvider(blocksFirstRequest: true)
    let model = reactionMutationTestModel(provider: provider)
    await model.start()
    let message = try #require(model.messages.first)

    await model.toggleReaction("🔥", on: message)
    #expect(await waitForReactionRequestCount(1, from: provider))
    for _ in 0 ..< 9 {
        await model.toggleReaction("🔥", on: message)
    }
    await provider.resumeFirstRequest()

    let expectedRequests = [
        ReactionMutationRequest(messageID: message.id, emoji: "🔥", reacted: true),
        ReactionMutationRequest(messageID: message.id, emoji: "🔥", reacted: false),
    ]
    #expect(await drainReactionMutations(in: model))
    #expect(await provider.requests() == expectedRequests)
    #expect(model.messages.first?.reactions.isEmpty == true)
}

@MainActor
@Test func `forum pagination failures preserve posts and can be retried`() async throws {
    let provider = ForumPaginationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts
                && model.forumPosts.count == 1
                && model.hasMoreForumPosts
        }
    )
    let initialPostIDs = model.forumPosts.map(\.id)

    model.updateForumSearch("Recent")
    #expect(!model.hasMoreForumPosts)
    await model.loadMoreForumPosts()
    #expect(await provider.paginationRequestCount() == 0)
    model.updateForumSearch("")
    #expect(model.hasMoreForumPosts)

    await model.loadMoreForumPosts()

    #expect(model.forumPosts.map(\.id) == initialPostIDs)
    #expect(model.forumPostError == nil)
    #expect(model.forumPaginationError != nil)
    #expect(model.hasMoreForumPosts)

    await model.loadMoreForumPosts()

    #expect(model.forumPosts.count == 2)
    #expect(model.forumPaginationError == nil)
    #expect(!model.hasMoreForumPosts)
    #expect(await provider.paginationRequestCount() == 2)
}

@MainActor
@Test func `opening a forum acknowledges only the parent new post boundary`() async throws {
    let provider = ForumVisitAcknowledgementTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts && model.forumPosts.count == 2
        }
    )
    for _ in 0 ..< 40 where await provider.acknowledgements().isEmpty {
        try await Task.sleep(for: .milliseconds(25))
    }
    let acknowledgement = try #require(await provider.acknowledgements().first)
    #expect(acknowledgement.channelID == provider.forumID)
    #expect(acknowledgement.messageID.rawValue > provider.newPostID.rawValue)
    #expect(await provider.acknowledgements().count == 1)

    let newPost = try #require(model.forumPosts.first(where: { $0.id == provider.newPostID }))
    let unreadPost = try #require(
        model.forumPosts.first(where: { $0.id == provider.unreadPostID })
    )
    #expect(model.isForumPostNew(newPost))
    #expect(!model.isForumPostUnread(newPost))
    #expect(model.shouldEmphasizeForumPost(newPost))
    #expect(model.isForumPostUnread(unreadPost))
    #expect(model.shouldEmphasizeForumPost(unreadPost))
    #expect(!model.isChannelUnread(provider.forumID))

    model.open(newPost)
    #expect(!model.isForumPostNew(newPost))
    #expect(!model.shouldEmphasizeForumPost(newPost))
}

@MainActor
@Test func `forum thread links select their parent and open the post`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(model.forumPosts.first)
    let otherChannel = try #require(
        model.snapshot?.channels.first(where: { $0.guildID == forum.guildID && $0.id != forum.id })
    )

    model.selectedChannelID = otherChannel.id
    model.navigate(to: post.thread.guildID, linkedChannelID: post.id)

    #expect(
        await eventuallyOnMain {
            model.selectedChannelID == forum.id && model.openThread?.id == post.id
        }
    )
}

@MainActor
@Test func `returning to a forum clears the previous forum query state`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    let otherChannel = try #require(
        model.snapshot?.channels.first {
            $0.guildID == forum.guildID && $0.id != forum.id && $0.kind != .forum
        }
    )
    let tagID = try #require(forum.availableTags.first?.id)

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts })
    model.forumSelectedTagIDs = [tagID]
    model.updateForumSearch("visual")
    #expect(model.forumSearchText == "visual")
    #expect(model.forumSelectedTagIDs == [tagID])

    model.selectedChannelID = otherChannel.id
    model.selectedChannelID = forum.id

    #expect(model.forumSearchText.isEmpty)
    #expect(model.forumSelectedTagIDs.isEmpty)
    #expect(!model.hasMoreForumPosts)
    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts
                && model.forumSearchText.isEmpty
                && model.forumSelectedTagIDs.isEmpty
        }
    )
}

@MainActor
@Test func `ordinary linked channels load their guild before forum resolution`() async {
    let provider = LinkedChannelNavigationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let target = provider.targetChannel

    model.navigate(to: target.guildID, linkedChannelID: target.id)

    #expect(
        await eventuallyOnMain {
            model.selectedGuildID == target.guildID
                && model.selectedChannelID == target.id
        }
    )
    #expect(await provider.forumPostRequestCount() == 0)
}

@MainActor
@Test func `remote forum deletion closes the open post`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(model.forumPosts.first)
    model.open(post)
    #expect(model.openThread?.id == post.id)

    await provider.emit(
        .forumPostsChanged(
            channelID: forum.id,
            posts: model.forumPosts.filter { $0.id != post.id }
        )
    )

    #expect(await eventuallyOnMain { model.openThread == nil })
}

@MainActor
@Test func `gateway forum catalogues keep forwarding thread destinations current`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 999_002),
        guildID: forum.guildID,
        parentID: forum.id,
        name: "Forward meow thread"
    )

    await provider.emit(
        .forumPostsChanged(
            channelID: forum.id,
            posts: [ForumPost(thread: thread)]
        )
    )
    #expect(await eventuallyOnMain {
        model.snapshot?.threads.filter { $0.parentID == forum.id } == [thread]
    })

    await provider.emit(.forumPostsChanged(channelID: forum.id, posts: []))
    #expect(await eventuallyOnMain {
        model.snapshot?.threads.contains { $0.parentID == forum.id } == false
    })
}

@MainActor
@Test func `forum cache events cannot close an ordinary text thread`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try #require(model.snapshot?.channels.first(where: { $0.kind == .text }))
    model.selectedChannelID = channel.id
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 999_001),
        guildID: channel.guildID,
        parentID: channel.id,
        name: "Ordinary thread"
    )
    model.open(thread)

    await provider.emit(.forumPostsChanged(channelID: channel.id, posts: []))
    await Task.yield()

    #expect(model.openThread?.id == thread.id)
}

@MainActor
@Test func `thread send commits optimistic insertion and confirmation revisions`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(
        model.snapshot?.channels.first(where: { $0.kind == .forum })
    )
    model.selectedChannelID = forum.id
    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts
                && model.forumPosts.contains(where: { !$0.thread.isLocked })
        }
    )
    let post = try #require(
        model.forumPosts.first(where: { !$0.thread.isLocked })
    )
    model.open(post)
    #expect(
        await eventuallyOnMain {
            model.hasCompletedInitialThreadLoad
                && model.openThreadAccess.canSend
        }
    )
    let previousCount = model.threadMessages.count
    let previousRevision = model.threadMessageRowsRevision
    model.threadDraft = "one thread timeline mutation"

    #expect(await model.sendThreadComposerMessage(attachments: []))
    #expect(
        await eventuallyOnMain {
            model.threadMessages.count == previousCount + 1
        }
    )
    await Task.yield()

    #expect(model.threadMessageRowsRevision == previousRevision + 2)
    #expect(
        model.threadMessageRowsUpdateHint?.change
            == .replace(IndexSet(integer: previousCount))
    )
    let records = try #require(
        model.threadMessageRowsUpdateJournal.records(
            after: previousRevision,
            through: model.threadMessageRowsRevision
        )
    )
    #expect(records.count == 2)
    let insertion = try #require(records.first)
    guard case let .insert(insertedIndexes) = insertion.change else {
        Issue.record("Expected a bounded optimistic thread insertion hint")
        return
    }
    #expect(insertedIndexes == IndexSet(integer: previousCount))
    #expect(insertion.insertedMessageIDs.count == 1)
    #expect(!insertion.invalidatesAllRows)
    let confirmation = try #require(records.last)
    #expect(confirmation.revision == model.threadMessageRowsRevision)
    #expect(confirmation.insertedMessageIDs.isEmpty)
    let confirmed = try #require(
        model.threadMessages.first {
            $0.content == "one thread timeline mutation"
        }
    )
    #expect(confirmation.changedMessageIDs == [confirmed.id])
    #expect(
        confirmation.change
            == .replace(IndexSet(integer: previousCount))
    )
    #expect(!confirmation.invalidatesAllRows)
}

@MainActor
@Test func `Discord channel links accept forum thread URLs without accepting lookalike hosts`() throws {
    let forumURL = try #require(URL(string: "https://discord.com/channels/100/220"))
    let lookalikeURL = try #require(URL(string: "https://discord.example/channels/100/220"))
    guard case let .discordChannel(guildID, channelID) =
        MessageLinkPolicy.destination(for: forumURL)
    else {
        Issue.record("Expected an internal Discord channel destination.")
        return
    }
    #expect(guildID == GuildID(rawValue: 100))
    #expect(channelID == ChannelID(rawValue: 220))
    #expect(
        MessageLinkPolicy.destination(for: lookalikeURL)
            == .web(lookalikeURL)
    )
}

@Test func `cancelled forum searches never become user visible errors`() {
    #expect(AppModel.isForumLoadCancellation(CancellationError()))
    #expect(AppModel.isForumLoadCancellation(URLError(.cancelled)))
    #expect(!AppModel.isForumLoadCancellation(URLError(.timedOut)))
}

@Test func `forum post deletion is limited to its owner or a thread moderator`() {
    let ownerID = UserID(rawValue: 10)
    let otherID = UserID(rawValue: 11)

    #expect(
        AppModel.canDeleteForumPost(
            ownerID: ownerID,
            currentUserID: ownerID,
            canManage: false
        )
    )
    #expect(
        !AppModel.canDeleteForumPost(
            ownerID: ownerID,
            currentUserID: otherID,
            canManage: false
        )
    )
    #expect(
        AppModel.canDeleteForumPost(
            ownerID: ownerID,
            currentUserID: otherID,
            canManage: true
        )
    )
}

@MainActor
@Test func `forum creation clears queued upload progress after completion`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    let tag = try #require(forum.availableTags.first(where: { !$0.isModerated }))
    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts })

    let didCreate = await model.createForumPost(
        CreateForumPostDraft(
            channelID: forum.id,
            title: "Progress lifecycle",
            content: "The completion state must not be overwritten by a queued callback.",
            appliedTagIDs: [tag.id]
        )
    )
    await Task.yield()

    #expect(didCreate)
    #expect(model.forumCreateProgress == nil)
}

@MainActor
@Test func `deleting an offline forum post removes its card and closes its thread`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let forum = try #require(model.snapshot?.channels.first(where: { $0.kind == .forum }))
    let currentUserID = try #require(model.snapshot?.currentUser.id)

    model.selectedChannelID = forum.id
    #expect(await eventuallyOnMain { model.hasLoadedForumPosts && !model.forumPosts.isEmpty })
    let post = try #require(
        model.forumPosts.first {
            ($0.thread.ownerID ?? $0.owner?.id) == currentUserID
        }
    )
    model.open(post)
    #expect(model.openThread?.id == post.id)

    await model.deleteForumPost(post)

    #expect(!model.forumPosts.contains { $0.id == post.id })
    #expect(model.openThread == nil)
    #expect(model.forumActionError == nil)
}

@Test func `rich message selection copies custom emoji as its discord token`() {
    let value = NSMutableAttributedString(string: "hello ")
    let attachment = NSMutableAttributedString(attachment: NSTextAttachment())
    attachment.addAttribute(
        .discordEmojiToken,
        value: "<:wave:123>",
        range: NSRange(location: 0, length: attachment.length)
    )
    value.append(attachment)
    value.append(NSAttributedString(string: " @Design"))

    #expect(
        RichMessageCopySerializer.string(
            from: value,
            range: NSRange(location: 0, length: value.length)
        ) == "hello <:wave:123> @Design"
    )
}

@MainActor
@Test func `only supported offline flags select testing mode`() {
    #expect(AppLaunchConfiguration(arguments: ["SakuraCord"]).mode == .normal)
    #expect(AppLaunchConfiguration(arguments: ["SakuraCord", "--offline"]).mode == .offlineTesting)
    let longList = AppLaunchConfiguration(arguments: ["SakuraCord", "--offline-long-server-list"])
    #expect(longList.mode == .offlineTesting)
    #expect(longList.includesLongServerList)
    let forumPerformance = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-forum-performance"]
    )
    #expect(forumPerformance.mode == .offlineTesting)
    #expect(forumPerformance.includesForumPerformanceFixture)
    let chatPerformance = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-performance"]
    )
    #expect(chatPerformance.mode == .offlineTesting)
    #expect(chatPerformance.includesChatPerformanceFixture)
    #expect(!chatPerformance.runsChatPerformanceAutoScroll)
    let chatAutoScroll = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-performance-autoscroll"]
    )
    #expect(chatAutoScroll.mode == .offlineTesting)
    #expect(chatAutoScroll.includesChatPerformanceFixture)
    #expect(chatAutoScroll.runsChatPerformanceAutoScroll)
    #expect(!chatAutoScroll.runsChatLiveArrivalStress)
    let chatLiveAutoScroll = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-performance-live-autoscroll"]
    )
    #expect(chatLiveAutoScroll.mode == .offlineTesting)
    #expect(chatLiveAutoScroll.includesChatPerformanceFixture)
    #expect(chatLiveAutoScroll.runsChatPerformanceAutoScroll)
    #expect(chatLiveAutoScroll.runsChatLiveArrivalStress)
    let chatMediaAutoScroll = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-chat-media-performance-autoscroll"]
    )
    #expect(chatMediaAutoScroll.mode == .offlineTesting)
    #expect(chatMediaAutoScroll.includesChatPerformanceFixture)
    #expect(chatMediaAutoScroll.includesChatMediaPerformanceFixture)
    #expect(chatMediaAutoScroll.runsChatPerformanceAutoScroll)
    #expect(!chatMediaAutoScroll.runsChatLiveArrivalStress)
    let pinsAutoScroll = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-pins-performance-autoscroll"]
    )
    #expect(pinsAutoScroll.mode == .offlineTesting)
    #expect(pinsAutoScroll.includesPinsPerformanceFixture)
    #expect(pinsAutoScroll.includesChatPerformanceFixture)
    #expect(pinsAutoScroll.runsPinsPerformanceAutoScroll)
    let authenticatedAutoScroll = AppLaunchConfiguration(
        arguments: [
            "SakuraCord",
            "--debug-authenticated-chat-performance-autoscroll",
        ]
    )
    #expect(authenticatedAutoScroll.mode == .normal)
    #expect(!authenticatedAutoScroll.includesChatPerformanceFixture)
    #expect(authenticatedAutoScroll.runsChatPerformanceAutoScroll)
    #expect(!authenticatedAutoScroll.runsMemberListPerformanceAutoScroll)
    #expect(!authenticatedAutoScroll.runsChatLiveArrivalStress)
    let authenticatedMemberListAutoScroll = AppLaunchConfiguration(
        arguments: [
            "SakuraCord",
            "--debug-authenticated-member-list-performance-autoscroll",
        ]
    )
    #expect(authenticatedMemberListAutoScroll.mode == .normal)
    #expect(authenticatedMemberListAutoScroll.runsMemberListPerformanceAutoScroll)
    #expect(!authenticatedMemberListAutoScroll.runsChatPerformanceAutoScroll)
    let authenticatedGestureScroll = AppLaunchConfiguration(
        arguments: [
            "SakuraCord",
            "--debug-authenticated-gesture-scroll-performance",
        ]
    )
    #expect(authenticatedGestureScroll.mode == .normal)
    #expect(authenticatedGestureScroll.runsAuthenticatedGestureScrollBenchmark)
    #expect(authenticatedGestureScroll.runsAnyReadOnlyPerformanceBenchmark)
    let authenticatedLoadingOverlap = AppLaunchConfiguration(
        arguments: [
            "SakuraCord",
            "--debug-authenticated-loading-scroll-overlap-performance",
        ]
    )
    #expect(authenticatedLoadingOverlap.mode == .normal)
    #expect(
        authenticatedLoadingOverlap
            .runsLoadingScrollOverlapBenchmark
    )
    #expect(authenticatedLoadingOverlap.runsAnyReadOnlyPerformanceBenchmark)
    let incomingPrivateCall = AppLaunchConfiguration(
        arguments: ["SakuraCord", "--offline-incoming-private-call"]
    )
    #expect(incomingPrivateCall.mode == .offlineTesting)
    #expect(incomingPrivateCall.includesIncomingPrivateCallFixture)
}

@MainActor
@Test func `network disabled normal launch stops signed out without mock data`() async {
    let model = AppModel(launchMode: .normal, discordNetworkDisabledOverride: true)
    #expect(model.sessionState == .restoring)
    await model.start()

    #expect(model.sessionState == .signedOut)
    #expect(model.snapshot == nil)
    #expect(model.visibleChannels.isEmpty)
    #expect(!model.isOfflineTesting)
}

@MainActor
@Test func `offline launch never consults its credential store`() async {
    let credentials = CredentialAccessProbeStore()
    let model = AppModel(launchMode: .offlineTesting, credentialStore: credentials)

    await model.start()

    #expect(model.sessionState == .workspace)
    #expect(await credentials.accessCount == 0)
}

@Test func `performance restore selects its requested stored account`() {
    let first = CredentialHandle(accountID: "100")
    let requested = CredentialHandle(accountID: "200")
    let handles = [first, requested]

    #expect(
        RestoredCredentialSelectionPolicy.handle(
            from: handles,
            preferredAccountID: requested.accountID
        ) == requested
    )
    #expect(
        RestoredCredentialSelectionPolicy.handle(
            from: handles,
            preferredAccountID: "missing"
        ) == first
    )
    #expect(
        RestoredCredentialSelectionPolicy.handle(
            from: handles,
            preferredAccountID: nil
        ) == first
    )
}

@Test func `saved account registry filters removed credentials and remembers the newest account`()
    async throws
{
    let store = UserDefaultsSavedAccountStore(defaults: InMemoryPreferences())
    let older = SavedAccount(
        accountID: "100",
        username: "older",
        displayName: "Older",
        lastUsedAt: Date(timeIntervalSince1970: 100)
    )
    let newer = SavedAccount(
        accountID: "200",
        username: "newer",
        displayName: "Newer",
        lastUsedAt: Date(timeIntervalSince1970: 200)
    )

    await store.record(older)
    await store.record(newer)
    let accounts = await store.accounts(matching: [
        CredentialHandle(accountID: "100"),
        CredentialHandle(accountID: "200"),
        CredentialHandle(accountID: "300"),
    ])

    #expect(accounts.map(\.accountID) == ["200", "100", "300"])
    #expect(accounts.last?.resolvedSubtitle == "Saved account ••••300")
    #expect(await store.preferredAccountID() == "200")

    await store.remove(accountID: "200")
    #expect(await store.preferredAccountID() == nil)
    #expect(
        await store.accounts(matching: [CredentialHandle(accountID: "100")])
            == [older]
    )
}

@MainActor
@Test func `saved account switch reuses credentials and account management logs out selected sessions`()
    async
{
    let firstUser = User(
        id: UserID(rawValue: 93_000),
        username: "first",
        displayName: "First Account"
    )
    let secondUser = User(
        id: UserID(rawValue: 94_000),
        username: "second",
        displayName: "Second Account"
    )
    let firstProvider = SuspendedBootstrapTestProvider(user: firstUser)
    let secondProvider = SuspendedBootstrapTestProvider(user: secondUser)
    let credentials = MultiAccountCredentialStore(accountIDs: ["93000", "94000"])
    let savedAccounts = SavedAccountStoreSpy()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: credentials,
        savedAccountStore: savedAccounts,
        authenticatedProviderFactory: { handle, _ in
            handle.accountID == "93000" ? firstProvider : secondProvider
        },
        accountDatabaseFactory: { _ in nil }
    )
    await model.start()
    await model.refreshSavedAccounts()
    #expect(model.savedAccounts.map(\.accountID) == ["93000", "94000"])

    let firstConnection = Task {
        await model.switchAccount(to: "93000")
    }
    await firstProvider.waitUntilBootstrapStarts()
    #expect(model.sessionState == .connecting)
    #expect(model.isSwitchingAccounts)
    await firstProvider.releaseBootstrap()
    #expect(await firstConnection.value)
    #expect(!model.isSwitchingAccounts)
    #expect(model.activeAccountID == "93000")
    #expect(model.savedAccounts.first?.displayName == "First Account")

    let secondConnection = Task {
        await model.switchAccount(to: "94000")
    }
    await secondProvider.waitUntilBootstrapStarts()
    #expect(model.sessionState == .workspace)
    #expect(model.isSwitchingAccounts)
    await secondProvider.releaseBootstrap()
    #expect(await secondConnection.value)
    #expect(!model.isSwitchingAccounts)
    #expect(model.activeAccountID == "94000")
    #expect(await credentials.accountIDs == ["93000", "94000"])
    #expect(await credentials.removedAccountIDs.isEmpty)
    #expect(await savedAccounts.preferredAccountID() == "94000")

    await model.logout(accountID: "93000")
    #expect(model.sessionState == .workspace)
    #expect(model.activeAccountID == "94000")
    #expect(model.savedAccounts.map(\.accountID) == ["94000"])
    #expect(await credentials.accountIDs == ["94000"])
    #expect(await credentials.removedAccountIDs == ["93000"])
    #expect(await savedAccounts.preferredAccountID() == "94000")

    await model.logout()
    #expect(model.sessionState == .signedOut)
    #expect(model.activeAccountID == nil)
    #expect(model.savedAccounts.isEmpty)
    #expect(await credentials.accountIDs.isEmpty)
    #expect(await credentials.removedAccountIDs == ["93000", "94000"])
    #expect(await savedAccounts.preferredAccountID() == nil)
}

@MainActor
@Test func `stale bootstrap persistence cannot replace the current account`() async {
    let savedAccounts = SuspendedSavedAccountStore()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        savedAccountStore: savedAccounts,
        accountDatabaseFactory: { _ in nil }
    )
    model.activeAccountID = "current-account"
    let staleSession = model.accountSession()
    let persistence = Task { @MainActor in
        await model.persistBootstrapAccount(
            SavedAccount(accountID: "stale-account"),
            session: staleSession
        )
    }
    await savedAccounts.waitUntilRecordStarts()

    model.invalidateAccountSession()
    await savedAccounts.releaseRecord()
    await persistence.value

    #expect(model.activeAccountID == "current-account")
    #expect(model.savedAccounts.isEmpty)
    #expect(await savedAccounts.preferredAccountID() == "current-account")
}

@MainActor
@Test func `workspace presentation does not wait for initial history`() async {
    let provider = SuspendedBootstrapTestProvider(suspendsMessages: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    let start = Task { await model.start() }
    await provider.waitUntilBootstrapStarts()
    await provider.releaseBootstrap()
    await provider.waitUntilMessageLoadStarts()

    #expect(model.sessionState == .workspace)
    #expect(model.isLoadingMessages)
    #expect(model.messages.isEmpty)

    await provider.releaseMessageLoad()
    await start.value
    #expect(!model.isLoadingMessages)
    #expect(model.hasCompletedInitialMessageLoad)
}

@MainActor
@Test func `network disabled insecure debug launch prepares its credential store`() async {
    let credentials = CredentialAccessProbeStore()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: true,
        usesInsecureDebugCredentialsOverride: true,
        credentialStore: credentials
    )

    await model.start()

    #expect(model.sessionState == .signedOut)
    #expect(await credentials.accessCount == 1)
}

@MainActor
@Test func `interactive sign in keeps login presentation alive until bootstrap finishes`() async {
    let provider = SuspendedBootstrapTestProvider()
    let notifications = PermissionRecordingNotificationService()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider },
        accountDatabaseFactory: { _ in
            try? SakuraCordDatabase(inMemory: true)
        },
        notificationService: notifications
    )
    await model.start()
    #expect(model.sessionState == .signedOut)

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93000"),
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()

    // Switching to `.connecting` here destroys DiscordLoginView, whose
    // disappearance cancels the task that is performing this bootstrap.
    #expect(model.sessionState == .signedOut)

    await provider.releaseBootstrap()
    #expect(await connection.value)
    #expect(model.sessionState == .workspace)
    #expect(model.isAuthenticated)
    #expect(notifications.authorizationRequestCount == 1)
}

@MainActor
@Test func `pending sign in persists only after ready and uses the ready account id`() async throws {
    let pending = try PendingDiscordCredential(
        Data("pending-session-credential-value".utf8)
    )
    let provider = SuspendedBootstrapTestProvider(pendingCredential: pending)
    let credentials = PendingCredentialRecordingStore()
    var openedAccountIDs: [String] = []
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: credentials,
        pendingAuthenticatedProviderFactory: { _, _ in provider },
        accountDatabaseFactory: { accountID in
            openedAccountIDs.append(accountID.description)
            return try? SakuraCordDatabase(inMemory: true)
        }
    )
    await model.start()

    let connection = Task {
        await model.connectPendingAuthenticatedAccount(
            pending,
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()

    #expect(await credentials.storedAccountID == nil)
    #expect(openedAccountIDs.isEmpty)
    #expect(model.credentialHandle == nil)
    #expect(model.sessionState == .signedOut)

    await provider.releaseBootstrap()
    #expect(await connection.value)
    #expect(await credentials.storedAccountID == "93000")
    #expect(await credentials.storedCredential == Data("pending-session-credential-value".utf8))
    #expect(openedAccountIDs == ["93000"])
    #expect(model.credentialHandle == CredentialHandle(accountID: "93000"))
    #expect(model.sessionState == .workspace)
}

@MainActor
@Test func `cancelled pending sign in stores nothing and discards the credential`() async throws {
    let pending = try PendingDiscordCredential(
        Data("cancelled-session-credential-value".utf8)
    )
    let provider = SuspendedBootstrapTestProvider(pendingCredential: pending)
    let credentials = PendingCredentialRecordingStore()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: credentials,
        pendingAuthenticatedProviderFactory: { _, _ in provider },
        accountDatabaseFactory: { _ in nil }
    )
    await model.start()

    let connection = Task {
        await model.connectPendingAuthenticatedAccount(
            pending,
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()
    connection.cancel()
    await provider.releaseBootstrap()

    #expect(await !(connection.value))
    #expect(await credentials.storedAccountID == nil)
    await #expect(throws: PendingDiscordCredentialError.unavailable) {
        try await provider.persistPendingCredential(
            to: credentials,
            accountID: "93000"
        )
    }
    #expect(model.sessionState == .signedOut)
}

@MainActor
@Test func `failed pending bootstrap stores nothing and discards the credential`() async throws {
    let pending = try PendingDiscordCredential(
        Data("failed-session-credential-value".utf8)
    )
    let provider = SuspendedBootstrapTestProvider(
        bootstrapError: "fixture pending bootstrap stopped",
        pendingCredential: pending
    )
    let credentials = PendingCredentialRecordingStore()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: credentials,
        pendingAuthenticatedProviderFactory: { _, _ in provider },
        accountDatabaseFactory: { _ in nil }
    )
    await model.start()

    let connection = Task {
        await model.connectPendingAuthenticatedAccount(
            pending,
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()
    await provider.releaseBootstrap()

    #expect(await !(connection.value))
    #expect(await credentials.storedAccountID == nil)
    await #expect(throws: PendingDiscordCredentialError.unavailable) {
        try await provider.persistPendingCredential(
            to: credentials,
            accountID: "93000"
        )
    }
    #expect(model.sessionState == .signedOut)
    #expect(model.errorMessage == "fixture pending bootstrap stopped")
}

private actor CredentialAccessProbeStore: CredentialStore {
    private(set) var accessCount = 0

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        accessCount += 1
        return CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        accessCount += 1
        return Data()
    }

    func remove(_ handle: CredentialHandle) async throws {
        accessCount += 1
    }

    func handles() async throws -> [CredentialHandle] {
        accessCount += 1
        return []
    }
}

private actor MultiAccountCredentialStore: CredentialStore {
    private(set) var accountIDs: [String]
    private(set) var removedAccountIDs: [String] = []

    init(accountIDs: [String]) {
        self.accountIDs = accountIDs.sorted()
    }

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        if !accountIDs.contains(accountID) {
            accountIDs.append(accountID)
            accountIDs.sort()
        }
        return CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        guard accountIDs.contains(handle.accountID) else {
            throw PendingDiscordCredentialError.unavailable
        }
        return Data("stored-account-credential".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {
        accountIDs.removeAll { $0 == handle.accountID }
        removedAccountIDs.append(handle.accountID)
    }

    func handles() async throws -> [CredentialHandle] {
        accountIDs.map(CredentialHandle.init(accountID:))
    }
}

private actor SavedAccountStoreSpy: SavedAccountStoring {
    private var accountsByID: [String: SavedAccount] = [:]
    private var preferredID: String?

    func accounts(matching handles: [CredentialHandle]) -> [SavedAccount] {
        handles.map { handle in
            accountsByID[handle.accountID] ?? SavedAccount(handle: handle)
        }
    }

    func preferredAccountID() -> String? {
        preferredID
    }

    func record(_ account: SavedAccount) {
        accountsByID[account.accountID] = account
        preferredID = account.accountID
    }

    func remove(accountID: String) {
        accountsByID.removeValue(forKey: accountID)
        if preferredID == accountID {
            preferredID = nil
        }
    }

    func setPreferredAccountID(_ accountID: String?) {
        preferredID = accountID
    }
}

private actor SuspendedSavedAccountStore: SavedAccountStoring {
    private var preferredID: String?
    private var recordStarted = false
    private var recordStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordRelease: CheckedContinuation<Void, Never>?

    func accounts(matching handles: [CredentialHandle]) -> [SavedAccount] {
        handles.map(SavedAccount.init(handle:))
    }

    func preferredAccountID() -> String? {
        preferredID
    }

    func record(_ account: SavedAccount) async {
        recordStarted = true
        let waiters = recordStartWaiters
        recordStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            recordRelease = continuation
        }
        preferredID = account.accountID
    }

    func remove(accountID: String) {}

    func setPreferredAccountID(_ accountID: String?) {
        preferredID = accountID
    }

    func waitUntilRecordStarts() async {
        guard !recordStarted else { return }
        await withCheckedContinuation { continuation in
            recordStartWaiters.append(continuation)
        }
    }

    func releaseRecord() {
        recordRelease?.resume()
        recordRelease = nil
    }
}

private actor PendingCredentialRecordingStore: CredentialStore {
    private(set) var storedAccountID: String?
    private(set) var storedCredential: Data?

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        storedAccountID = accountID
        storedCredential = credential
        return CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        guard handle.accountID == storedAccountID, let storedCredential else {
            throw PendingDiscordCredentialError.unavailable
        }
        return storedCredential
    }

    func remove(_ handle: CredentialHandle) async throws {
        storedAccountID = nil
        storedCredential = nil
    }

    func handles() async throws -> [CredentialHandle] {
        storedAccountID.map { [CredentialHandle(accountID: $0)] } ?? []
    }
}

private actor FailingRemovalCredentialStore: CredentialStore {
    private(set) var accountIDs: [String]

    init(accountID: String) {
        accountIDs = [accountID]
    }

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("credential".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {
        throw ChatProviderError.invalidRequest("fixture credential removal failed")
    }

    func handles() async throws -> [CredentialHandle] {
        accountIDs.map(CredentialHandle.init(accountID:))
    }
}

@MainActor
@Test func `interactive sign in failure stays signed out and exposes bootstrap error`() async {
    let provider = SuspendedBootstrapTestProvider(bootstrapError: "fixture bootstrap stopped")
    let notifications = PermissionRecordingNotificationService()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider },
        accountDatabaseFactory: { _ in
            try? SakuraCordDatabase(inMemory: true)
        },
        notificationService: notifications
    )
    await model.start()

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93000"),
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()
    #expect(model.sessionState == .signedOut)

    await provider.releaseBootstrap()
    #expect(await !(connection.value))
    #expect(model.sessionState == .signedOut)
    #expect(model.errorMessage == "fixture bootstrap stopped")
    #expect(model.provider is SignedOutChatProvider)
    #expect(model.credentialHandle == nil)
    #expect(model.database == nil)
    #expect(await provider.disconnectCount == 1)
    #expect(notifications.authorizationRequestCount == 0)
}

@MainActor
@Test func `logout completes locally when saved credential removal fails`() async {
    let credentials = FailingRemovalCredentialStore(accountID: "93000")
    let provider = SuspendedBootstrapTestProvider()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: credentials,
        authenticatedProviderFactory: { _, _ in provider },
        accountDatabaseFactory: { _ in nil }
    )
    await model.start()

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93000")
        )
    }
    await provider.waitUntilBootstrapStarts()
    await provider.releaseBootstrap()
    #expect(await connection.value)

    await model.logout()

    #expect(model.sessionState == .signedOut)
    #expect(!model.isAuthenticated)
    #expect(model.activeAccountID == nil)
    #expect(model.credentialHandle == nil)
    #expect(model.provider is SignedOutChatProvider)
    #expect(model.errorMessage == "fixture credential removal failed")
    #expect(await credentials.accountIDs == ["93000"])
}

@MainActor
@Test func `failed bootstrap never presents or authenticates a workspace`() async throws {
    let provider = SuspendedBootstrapTestProvider(
        bootstrapError: "fixture bootstrap stopped"
    )
    let database = try SakuraCordDatabase(inMemory: true)
    let notifications = PermissionRecordingNotificationService()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider },
        accountDatabaseFactory: { _ in database },
        notificationService: notifications
    )
    await model.start()

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93100"),
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()
    // Interactive sign-in keeps the login presentation alive until READY;
    // critically, it never substitutes the stored workspace while waiting.
    #expect(model.sessionState == .signedOut)
    #expect(model.snapshot == nil)
    #expect(model.serverRailItems.isEmpty)
    #expect(!model.isAuthenticated)

    await provider.releaseBootstrap()
    #expect(await !(connection.value))
    #expect(model.sessionState == .signedOut)
    #expect(!model.isAuthenticated)
    #expect(model.snapshot == nil)
    #expect(model.errorMessage == "fixture bootstrap stopped")
    #expect(notifications.authorizationRequestCount == 0)
}

@MainActor
@Test func `logout cancels account loads and clears every forum surface`() async throws {
    let oldProvider = SuspendedAccountLoadTestProvider(
        label: "Old",
        suspendsLoads: true
    )
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: CredentialAccessProbeStore(),
        authenticatedProviderFactory: { _, _ in oldProvider },
        accountDatabaseFactory: { _ in nil }
    )
    await model.start()
    #expect(await model.connectAuthenticatedAccount(
        CredentialHandle(accountID: "account-load-old")
    ))
    #expect(await oldProvider.waitUntilLoadsStart())

    let stalePost = oldProvider.post
    model.forumPosts = [stalePost]
    model.forumCataloguePosts = [stalePost]
    model.forumCatalogueIndexByID = [stalePost.id: 0]
    model.forumRecentPostCount = 1
    model.isLoadingForumPosts = true
    model.isSearchingForumPosts = true
    model.hasLoadedForumPosts = true
    model.isLoadingMoreForumPosts = true
    model.hasMoreForumPosts = true
    model.forumPostError = "load"
    model.forumActionError = "action"
    model.forumPaginationError = "pagination"
    model.forumCreateProgress = .submitting
    model.forumSearchText = "stale query"
    model.forumSelectedTagIDs = [ForumTagID(rawValue: 1)]
    model.forumSortOrder = .creationDate
    model.forumLayout = .gallery
    model.forumTagMatch = .matchAll
    model.forumNextOffset = 25
    let staleCallChannelID = ChannelID(rawValue: 98_765)
    model.privateCallsByChannel[staleCallChannelID] = PrivateCall(
        channelID: staleCallChannelID,
        ongoingRings: [
            PrivateCallRing(
                recipientID: UserID(rawValue: 1),
                senderID: UserID(rawValue: 2)
            ),
        ]
    )
    let memberGeneration = model.memberLoadGeneration
    let forumGeneration = model.forumLoadGeneration
    let createGeneration = model.forumCreateGeneration

    await model.logout()

    #expect(model.memberLoadTask == nil)
    #expect(model.forumLoadTask == nil)
    #expect(model.memberLoadGeneration > memberGeneration)
    #expect(model.forumLoadGeneration > forumGeneration)
    #expect(model.forumCreateGeneration > createGeneration)
    #expect(model.forumPosts.isEmpty)
    #expect(model.forumCataloguePosts.isEmpty)
    #expect(model.forumCatalogueIndexByID.isEmpty)
    #expect(model.forumRecentPostCount == 0)
    #expect(!model.isLoadingForumPosts)
    #expect(!model.isSearchingForumPosts)
    #expect(!model.hasLoadedForumPosts)
    #expect(!model.isLoadingMoreForumPosts)
    #expect(!model.hasMoreForumPosts)
    #expect(model.forumPostError == nil)
    #expect(model.forumActionError == nil)
    #expect(model.forumPaginationError == nil)
    #expect(model.forumCreateProgress == nil)
    #expect(model.forumSearchText.isEmpty)
    #expect(model.forumSelectedTagIDs.isEmpty)
    #expect(model.forumSortOrder == .latestActivity)
    #expect(model.forumLayout == .list)
    #expect(model.forumTagMatch == .matchSome)
    #expect(model.forumNextOffset == nil)
    #expect(model.privateCallsByChannel.isEmpty)

    await oldProvider.releaseSuspendedLoads()
    #expect(await oldProvider.waitUntilLoadsReturn())
    for _ in 0 ..< 20 { await Task.yield() }
    #expect(model.members.isEmpty)
    #expect(model.forumPosts.isEmpty)
    #expect(model.forumCataloguePosts.isEmpty)
}

@MainActor
@Test func `reconnect rejects old provider loads when account IDs are identical`() async throws {
    let oldProvider = SuspendedAccountLoadTestProvider(
        label: "Old",
        suspendsLoads: true
    )
    let newProvider = SuspendedAccountLoadTestProvider(
        label: "New",
        suspendsLoads: false
    )
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: CredentialAccessProbeStore(),
        authenticatedProviderFactory: { handle, _ in
            handle.accountID == "account-load-old" ? oldProvider : newProvider
        },
        accountDatabaseFactory: { _ in nil }
    )
    await model.start()
    #expect(await model.connectAuthenticatedAccount(
        CredentialHandle(accountID: "account-load-old")
    ))
    #expect(await oldProvider.waitUntilLoadsStart())

    #expect(await model.connectAuthenticatedAccount(
        CredentialHandle(accountID: "account-load-new")
    ))
    #expect(await eventuallyOnMain {
        model.members.first?.user.displayName == "New member"
            && model.forumPosts.first?.thread.name == "New post"
    })
    #expect(model.selectedGuildID == oldProvider.guildID)
    #expect(model.selectedChannelID == oldProvider.forumID)

    await oldProvider.releaseSuspendedLoads()
    #expect(await oldProvider.waitUntilLoadsReturn())
    for _ in 0 ..< 20 { await Task.yield() }

    #expect(model.members.first?.user.displayName == "New member")
    #expect(model.forumPosts.first?.thread.name == "New post")
    #expect(model.forumCataloguePosts.first?.thread.name == "New post")
}

@MainActor
@Test func `completed old account send and edit cannot enter replacement account state`()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "sakuracord-account-mutation-race-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldProvider = SuspendedAccountOperationTestProvider(suspendsOperations: true)
    let newProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let oldDatabase = try SakuraCordDatabase(
        accountID: AccountID(rawValue: 96_100),
        directory: directory
    )
    let newAccountID = AccountID(rawValue: 96_101)
    let newDatabase = try SakuraCordDatabase(
        accountID: newAccountID,
        directory: directory
    )
    let model = AppModel(launchMode: .offlineTesting, provider: oldProvider)
    model.database = oldDatabase
    model.selectedChannelID = oldProvider.channelID
    model.replaceSelectedMessages(with: [oldProvider.editTarget])

    let send = Task { @MainActor in
        await model.performOutgoingSend(
            SendMessageDraft(
                channelID: oldProvider.channelID,
                content: "old account send"
            ),
            isRetry: false
        )
    }
    let edit = Task { @MainActor in
        await model.edit(oldProvider.editTarget, content: "old account edit")
    }
    #expect(await oldProvider.waitUntilMutationRequestsStart())

    model.invalidateAccountSession()
    model.installAccountSession(provider: newProvider, database: newDatabase)
    var replacementMessage = oldProvider.editTarget
    replacementMessage.content = "replacement account value"
    model.replaceSelectedMessages(with: [replacementMessage])

    await oldProvider.releaseMutationRequests()
    #expect(await !send.value)
    await edit.value

    #expect(model.messages.map(\.id) == [replacementMessage.id])
    #expect(model.messages.first?.content == "replacement account value")
    #expect(
        model.conversationRefreshJournals.values.allSatisfy {
            $0.mutationsByMessageID.isEmpty
        }
    )
}

@MainActor
@Test func `account session identity changes only with an atomically installed provider database pair`() {
    let firstProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let secondProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(launchMode: .offlineTesting, provider: firstProvider)
    let first = model.accountSession()
    let replacementDatabase = try? SakuraCordDatabase(inMemory: true)

    model.installAccountSession(
        provider: secondProvider,
        database: replacementDatabase
    )

    #expect(!model.isCurrentAccountSession(first))
    let second = model.accountSession()
    #expect(model.isCurrentAccountSession(second))
    #expect(second.installedRevision == first.installedRevision + 1)
    #expect(second.database === replacementDatabase)
}

@MainActor
@Test func `account transition fails closed before reaching the installed provider`() async {
    let provider = SuspendedAccountOperationTestProvider(suspendsOperations: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    model.accountTransitionIsActive = true

    let sent = await model.performOutgoingSend(
        SendMessageDraft(channelID: provider.channelID, content: "must not leave"),
        isRetry: false
    )

    #expect(!sent)
    #expect(await !provider.sendRequestHasStarted())
}

@MainActor
@Test func `a started account transition cannot be superseded by credential reuse`() async {
    let provider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider }
    )
    let generation = model.accountSessionGeneration
    #expect(await model.accountTransitionCoordinator.acquireIfAvailable())

    let connected = await model.connectAuthenticatedAccount(
        CredentialHandle(accountID: "account-transition-in-progress")
    )

    #expect(!connected)
    #expect(model.accountSessionGeneration == generation)
    await model.accountTransitionCoordinator.release()
}

@MainActor
@Test func `completed old account earlier pages cannot enter replacement conversations`()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "sakuracord-account-pagination-race-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldProvider = SuspendedAccountOperationTestProvider(suspendsOperations: true)
    let newProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let oldDatabase = try SakuraCordDatabase(
        accountID: AccountID(rawValue: 96_200),
        directory: directory
    )
    let newAccountID = AccountID(rawValue: 96_201)
    let newDatabase = try SakuraCordDatabase(
        accountID: newAccountID,
        directory: directory
    )
    let model = AppModel(launchMode: .offlineTesting, provider: oldProvider)
    model.database = oldDatabase
    model.selectedChannelID = oldProvider.channelID
    model.replaceSelectedMessages(with: [oldProvider.selectedNewest])
    model.hasMoreMessages = true
    model.openThread = oldProvider.thread
    model.threadMessages = [oldProvider.threadNewest]
    model.hasMoreThreadMessages = true

    let selectedLoad = Task { @MainActor in await model.loadEarlier() }
    let threadLoad = Task { @MainActor in await model.loadEarlierThread() }
    #expect(await oldProvider.waitUntilEarlierPageRequestsStart(expected: 2))

    model.invalidateAccountSession()
    model.installAccountSession(provider: newProvider, database: newDatabase)
    var replacementSelected = oldProvider.selectedNewest
    replacementSelected.content = "replacement selected newest"
    var replacementThread = oldProvider.threadNewest
    replacementThread.content = "replacement thread newest"
    model.replaceSelectedMessages(with: [replacementSelected])
    model.hasMoreMessages = true
    model.openThread = oldProvider.thread
    model.threadMessages = [replacementThread]
    model.hasMoreThreadMessages = true
    model.isLoadingEarlier = true
    model.isLoadingEarlierThread = true

    await oldProvider.releaseEarlierPageRequests()
    await selectedLoad.value
    await threadLoad.value

    #expect(model.messages.map(\.id) == [replacementSelected.id])
    #expect(model.messages.first?.content == "replacement selected newest")
    #expect(model.threadMessages.map(\.id) == [replacementThread.id])
    #expect(model.threadMessages.first?.content == "replacement thread newest")
    #expect(model.isLoadingEarlier)
    #expect(model.isLoadingEarlierThread)
}

@MainActor
@Test func `stale GIF send cannot restore an old account draft`() async throws {
    let oldProvider = SuspendedAccountOperationTestProvider(suspendsOperations: true)
    let newProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(launchMode: .offlineTesting, provider: oldProvider)
    let channel = Channel(id: oldProvider.channelID, guildID: nil, name: "shared")
    model.snapshot = BootstrapSnapshot(
        currentUser: oldProvider.editTarget.author,
        guilds: [],
        channels: [channel],
        members: []
    )
    model.visibleChannels = [channel]
    model.selectedChannel = channel
    model.selectedChannelID = oldProvider.channelID
    model.draft = "old account draft"
    let gif = GIFSearchResult(
        id: "account-race-gif",
        title: "Account race",
        url: URL(string: "https://example.com/account-race.gif")!,
        previewURL: URL(string: "https://example.com/account-race-preview.gif")!
    )

    let send = Task { @MainActor in await model.sendGIF(gif) }
    #expect(await oldProvider.waitUntilSendRequestStarts())
    model.invalidateAccountSession()
    model.installAccountSession(provider: newProvider, database: nil)
    model.draft = "replacement account draft"

    await oldProvider.releaseSendRequest()
    #expect(await !send.value)
    #expect(model.draft == "replacement account draft")
}

@MainActor
@Test func `enqueued old account command and call observers never reach replacement provider`()
    async
{
    let oldProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let newProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let commandChannel = Channel(
        id: oldProvider.channelID,
        guildID: nil,
        name: "command-boundary",
        kind: .text
    )
    let commandModel = AppModel(launchMode: .offlineTesting, provider: oldProvider)
    commandModel.snapshot = BootstrapSnapshot(
        currentUser: oldProvider.editTarget.author,
        guilds: [],
        channels: [commandChannel],
        members: []
    )
    commandModel.visibleChannels = [commandChannel]
    commandModel.selectedChannelID = commandChannel.id
    commandModel.supportedCapabilities = [.slashCommands]
    commandModel.loadApplicationCommands()
    let commandTask = commandModel.commandLoadTask

    commandModel.invalidateAccountSession()
    commandModel.installAccountSession(provider: newProvider, database: nil)
    await commandTask?.value

    #expect(await oldProvider.applicationCommandRequestCount == 0)
    #expect(await newProvider.applicationCommandRequestCount == 0)

    let oldCallProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let newCallProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let privateChannel = Channel(
        id: oldCallProvider.channelID,
        guildID: nil,
        name: "private-call-boundary",
        kind: .directMessage
    )
    let callModel = AppModel(launchMode: .offlineTesting, provider: oldCallProvider)
    callModel.snapshot = BootstrapSnapshot(
        currentUser: oldCallProvider.editTarget.author,
        guilds: [],
        channels: [privateChannel],
        members: []
    )
    callModel.visibleChannels = [privateChannel]
    callModel.selectedChannelID = privateChannel.id
    let observerTasks = Array(callModel.accountChildTasks.values)

    callModel.invalidateAccountSession()
    callModel.installAccountSession(provider: newCallProvider, database: nil)
    for task in observerTasks {
        await task.value
    }

    #expect(await oldCallProvider.privateCallSubscriptionRequestCount == 0)
    #expect(await newCallProvider.privateCallSubscriptionRequestCount == 0)
}

@MainActor
@Test func `enqueued old account channel and guild loads never reach replacement provider`() async {
    let oldProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let newProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let sharedChannel = Channel(
        id: oldProvider.channelID,
        guildID: nil,
        name: "shared-channel-boundary",
        kind: .text
    )
    let channelModel = AppModel(launchMode: .offlineTesting, provider: oldProvider)
    channelModel.snapshot = BootstrapSnapshot(
        currentUser: oldProvider.editTarget.author,
        guilds: [],
        channels: [sharedChannel],
        members: []
    )
    channelModel.visibleChannels = [sharedChannel]
    channelModel.selectedChannelID = sharedChannel.id
    let channelTask = channelModel.channelLoadTask

    channelModel.invalidateAccountSession()
    channelModel.installAccountSession(provider: newProvider, database: nil)
    channelModel.selectedChannelID = nil
    await channelTask?.value

    #expect(channelModel.selectedChannelID == nil)
    #expect(await oldProvider.newestMessageRequestCount == 0)
    #expect(await newProvider.newestMessageRequestCount == 0)

    let oldGuildProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let newGuildProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let oldGuildID = GuildID(rawValue: 96_100)
    let replacementGuildID = GuildID(rawValue: 96_101)
    let guildModel = AppModel(launchMode: .offlineTesting, provider: oldGuildProvider)
    guildModel.snapshot = BootstrapSnapshot(
        currentUser: oldGuildProvider.editTarget.author,
        guilds: [Guild(id: oldGuildID, name: "Old account guild")],
        channels: [],
        members: []
    )
    guildModel.selectGuild(oldGuildID)
    let guildTask = guildModel.guildActivationTask

    guildModel.invalidateAccountSession()
    guildModel.installAccountSession(provider: newGuildProvider, database: nil)
    guildModel.selectedGuildID = replacementGuildID
    await guildTask?.value

    #expect(guildModel.selectedGuildID == replacementGuildID)
    #expect(guildModel.selectedChannelID == nil)
    #expect(await oldGuildProvider.channelRequestCount == 0)
    #expect(await newGuildProvider.channelRequestCount == 0)
}

@MainActor
@Test func `cancelled enqueued thread load never leaves a refresh journal`() async {
    let provider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let firstThread = MessageThreadSummary(
        id: provider.threadID,
        parentID: provider.channelID,
        name: "First queued thread"
    )
    let secondThread = MessageThreadSummary(
        id: ChannelID(rawValue: provider.threadID.rawValue + 1),
        parentID: provider.channelID,
        name: "Replacement queued thread"
    )

    model.openThreadConversation(
        firstThread,
        starter: nil,
        startedAt: nil,
        initialMessages: []
    )
    let firstTask = model.threadLoadTask
    model.openThreadConversation(
        secondThread,
        starter: nil,
        startedAt: nil,
        initialMessages: []
    )
    let secondTask = model.threadLoadTask

    await firstTask?.value
    await secondTask?.value

    #expect(model.openThread?.id == secondThread.id)
    #expect(model.conversationRefreshJournals[firstThread.id] == nil)
    #expect(model.conversationRefreshJournals[secondThread.id] == nil)
}

@MainActor
@Test func `old private call deletion cannot tear down replacement voice state`() async {
    let oldProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let newProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(launchMode: .offlineTesting, provider: oldProvider)
    let sharedChannel = Channel(
        id: oldProvider.channelID,
        guildID: nil,
        name: "shared-call",
        kind: .directMessage
    )
    model.activeVoiceChannel = sharedChannel
    model.voiceSessionState = .connected

    model.consumePrivateCallDeleted(channelID: sharedChannel.id, unavailable: false)
    let leaveTasks = Array(model.accountChildTasks.values)
    model.invalidateAccountSession()
    model.installAccountSession(provider: newProvider, database: nil)
    model.activeVoiceChannel = sharedChannel
    model.voiceSessionState = .connected

    for task in leaveTasks {
        await task.value
    }

    #expect(model.activeVoiceChannel == sharedChannel)
    #expect(model.voiceSessionState == .connected)
    #expect(await newProvider.voiceStateUpdateRequestCount == 0)
}

@MainActor
@Test func `account transition cancels and drains stale native notification delivery`() async {
    let notifications = SuspendedAccountNotificationService()
    let notificationPreferences = NotificationPreferences(defaults: InMemoryPreferences())
    notificationPreferences.suppressesCurrentConversation = false
    let oldProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let newProvider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: oldProvider,
        notificationService: notifications,
        notificationPreferences: notificationPreferences
    )
    await model.start()
    let author = oldProvider.editTarget.author
    let message = Message(
        id: MessageID(rawValue: 96_050),
        channelID: oldProvider.channelID,
        author: author,
        content: "old account notification"
    )

    model.deliverNativeNotification(for: message)
    await notifications.waitUntilDeliveryStarts()
    model.invalidateAccountSession()
    model.resetAccountScopedLoadsAndForumState()
    let drain = Task { @MainActor in
        await model.drainAccountChildTasks()
    }
    await Task.yield()
    notifications.releaseDelivery()
    await drain.value
    model.installAccountSession(provider: newProvider, database: nil)

    #expect(notifications.publishedMessageIDs.isEmpty)
    #expect(model.accountChildTasks.isEmpty)
}

@MainActor
@Test func `replying targets the selected message and clears after sending`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let target = try #require(model.messages.first)

    model.reply(to: target)
    #expect(model.replyingTo?.id == target.id)

    model.updateDraft("reply from test")
    await model.send()

    #expect(model.messages.last?.replyTo == target.id)
    #expect(model.messageRows.last?.replyPreview?.messageID == target.id)
    #expect(model.messageRows.last?.replyPreview?.content == target.content)
    #expect(model.replyingTo == nil)
}

@MainActor
@Test func `reply selection navigates both directions without wrapping`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let messages = model.messages
    #expect(messages.count >= 2)

    #expect(model.navigateReplySelection(in: .channel, direction: .older))
    #expect(model.replyingTo?.id == messages.last?.id)

    #expect(model.navigateReplySelection(in: .channel, direction: .older))
    #expect(model.replyingTo?.id == messages.dropLast().last?.id)

    model.reply(to: messages.first!)
    #expect(model.navigateReplySelection(in: .channel, direction: .older))
    #expect(model.replyingTo?.id == messages.first?.id)

    #expect(model.navigateReplySelection(in: .channel, direction: .newer))
    #expect(model.replyingTo?.id == messages.dropFirst().first?.id)

    model.reply(to: messages.last!)
    #expect(model.navigateReplySelection(in: .channel, direction: .newer))
    #expect(model.replyingTo?.id == messages.last?.id)
}

@MainActor
@Test func `reply Escape cancels reply state`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let target = try #require(model.messages.last)

    model.reply(to: target)
    #expect(model.consumeEscapeForReply(in: .channel))
    #expect(model.replyingTo == nil)
    #expect(!model.consumeEscapeForReply(in: .channel))
}

@MainActor
@Test func `supplementary Escape closes thread before voice chat`() {
    let model = AppModel(launchMode: .offlineTesting)
    model.openThread = MessageThreadSummary(
        id: ChannelID(rawValue: 88_001),
        parentID: ChannelID(rawValue: 88_000),
        name: "Escape priority"
    )
    model.isVoiceChatOpen = true

    #expect(model.consumeEscapeForSupplementaryConversation())
    #expect(model.openThread == nil)
    #expect(model.isVoiceChatOpen)

    #expect(model.consumeEscapeForSupplementaryConversation())
    #expect(!model.isVoiceChatOpen)
    #expect(!model.consumeEscapeForSupplementaryConversation())
}

@MainActor
@Test func `replying in a forum post targets the thread message and clears after sending`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(
        model.snapshot?.channels.first(where: { $0.kind == .forum })
    )
    model.selectedChannelID = forum.id
    #expect(
        await eventuallyOnMain {
            model.hasLoadedForumPosts
                && model.forumPosts.contains(where: { !$0.thread.isLocked })
        }
    )
    let post = try #require(
        model.forumPosts.first(where: { !$0.thread.isLocked })
    )
    model.open(post)
    #expect(
        await eventuallyOnMain {
            model.hasCompletedInitialThreadLoad
                && model.openThreadAccess.canSend
                && !model.threadMessages.isEmpty
        }
    )
    let target = try #require(model.threadMessages.first)

    model.reply(to: target)
    #expect(model.threadReplyingTo?.id == target.id)
    #expect(model.replyingTo == nil)

    model.threadDraft = "forum reply from test"
    #expect(await model.sendThreadComposerMessage(attachments: []))
    #expect(
        await eventuallyOnMain {
            model.threadMessages.last?.replyTo == target.id
        }
    )
    #expect(model.threadMessages.last?.replyPreview?.messageID == target.id)
    #expect(model.threadMessages.last?.replyPreview?.content == target.content)
    #expect(model.threadReplyingTo == nil)
}

@MainActor
@Test func `member store merge retains members outside latest range and replaces updates`() {
    let orangeRole = GuildRole(
        id: RoleID(rawValue: 10), name: "Orange", position: 10,
        colorHex: 0xFF8800
    )
    var existing = Member(
        user: User(id: UserID(rawValue: 1), username: "first", displayName: "First"),
        roleName: orangeRole.name,
        status: .online,
        roleID: orangeRole.id,
        rolePosition: orangeRole.position,
        isRoleCategory: true,
        roles: [orangeRole]
    )
    existing.memberListIndex = 73
    let replacement = Member(
        user: existing.user,
        roleName: "Member",
        status: .idle
    )
    let other = Member(
        user: User(id: UserID(rawValue: 2), username: "other", displayName: "Other"),
        roleName: "Member",
        status: .online
    )

    let merged = MemberStoreMerge.merging(
        existing: [existing.id: existing],
        updates: [replacement, other]
    )

    #expect(merged.count == 2)
    #expect(merged[existing.id]?.status == replacement.status)
    #expect(merged[existing.id]?.memberListIndex == 73)
    #expect(merged[other.id] == other)
}

@Test func `timeline member impact ignores members absent from retained message rows`() {
    let author = User(
        id: UserID(rawValue: 81), username: "author", displayName: "Author"
    )
    let replyAuthor = User(
        id: UserID(rawValue: 82), username: "reply", displayName: "Reply"
    )
    let mentioned = User(
        id: UserID(rawValue: 83), username: "mention", displayName: "Mention"
    )
    let unrelated = User(
        id: UserID(rawValue: 84), username: "other", displayName: "Other"
    )
    let message = Message(
        id: MessageID(rawValue: 8_100),
        channelID: ChannelID(rawValue: 8_101),
        author: author,
        content: "Member presentation dependencies",
        replyPreview: MessageReplyPreview(
            messageID: MessageID(rawValue: 8_099),
            author: replyAuthor,
            content: "Referenced reply"
        ),
        mentionedUsers: [mentioned]
    )
    let referenced = TimelineMemberPresentationImpact.referencedUserIDs(
        in: [message]
    )
    #expect(referenced == [author.id, replyAuthor.id, mentioned.id])

    let oldMembers = Dictionary(
        uniqueKeysWithValues: [author, replyAuthor, mentioned, unrelated].map {
            ($0.id, Member(user: $0, roleName: "Member", status: .online))
        }
    )
    let newMembers = oldMembers.mapValues { member in
        var changed = member
        changed.user.displayName += " updated"
        return changed
    }
    let changed = TimelineMemberPresentationImpact.changedUserIDs(
        from: oldMembers,
        to: newMembers,
        guildRoles: [],
        candidates: referenced
    )

    #expect(changed == referenced)
    #expect(!changed.contains(unrelated.id))
    #expect(
        TimelineMemberPresentationImpact.affectedMessageIDs(
            in: [message],
            changedUserIDs: changed
        ) == [message.id]
    )
}

@MainActor
@Test func `member viewport replays after subscription arming and guild reentry`() async throws {
    let provider = DelayedMemberViewportTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let snapshot = try await provider.bootstrap()
    let guild = try #require(snapshot.guilds.first)
    let channel = try #require(snapshot.channels.first { $0.guildID == guild.id })
    model.snapshot = snapshot
    model.selectedGuildID = guild.id
    model.visibleChannels = snapshot.channels.filter { $0.guildID == guild.id }
    model.selectedChannelID = channel.id
    model.beginMemberLoad(for: guild.id)

    #expect(await provider.waitUntilMemberLoadStarts())
    let visibleRange = 200 ... 219

    model.updateMemberListViewport(visibleRange)
    #expect(await provider.waitUntilViewportAttemptCount(1))
    #expect(await provider.acceptedViewportRequests().isEmpty)

    await provider.releaseMemberLoad()
    #expect(await provider.waitUntilAcceptedViewportCount(1))

    #expect(await provider.acceptedViewportRequests() == [
        DelayedMemberViewportTestProvider.ViewportRequest(
            guildID: guild.id,
            channelID: channel.id,
            visibleRange: visibleRange
        )
    ])

    let replacementChannel = try #require(
        snapshot.channels.first {
            $0.guildID == guild.id && $0.id != channel.id && $0.kind != .voice
        }
    )
    model.selectedChannelID = replacementChannel.id
    #expect(await provider.waitUntilAcceptedViewportCount(2))
    #expect(await provider.acceptedViewportRequests().last ==
        DelayedMemberViewportTestProvider.ViewportRequest(
            guildID: guild.id,
            channelID: replacementChannel.id,
            visibleRange: visibleRange
        )
    )

    let directMessage = try #require(
        snapshot.channels.first { $0.guildID == nil }
    )
    await provider.disarmMemberSubscription()
    model.selectedGuildID = nil
    model.selectedChannelID = directMessage.id
    model.selectedGuildID = guild.id
    model.selectedChannelID = channel.id
    model.beginMemberLoad(for: guild.id)

    #expect(await provider.waitUntilAcceptedViewportCount(3))
    #expect(await provider.acceptedViewportRequests().last ==
        DelayedMemberViewportTestProvider.ViewportRequest(
            guildID: guild.id,
            channelID: channel.id,
            visibleRange: visibleRange
        )
    )

    let otherGuildID = GuildID(rawValue: 88_100)
    let otherChannel = Channel(
        id: ChannelID(rawValue: 88_101),
        guildID: otherGuildID,
        name: "other-public"
    )
    await provider.disarmMemberSubscription()
    model.selectedGuildID = otherGuildID
    model.visibleChannels = [otherChannel]
    model.selectedChannelID = otherChannel.id
    model.beginMemberLoad(for: otherGuildID)
    #expect(await provider.waitUntilAcceptedViewportCount(4))

    await provider.disarmMemberSubscription()
    model.selectedGuildID = guild.id
    model.visibleChannels = snapshot.channels.filter { $0.guildID == guild.id }
    model.selectedChannelID = replacementChannel.id
    model.beginMemberLoad(for: guild.id)

    #expect(await provider.waitUntilAcceptedViewportCount(5))
    #expect(await provider.acceptedViewportRequests().last ==
        DelayedMemberViewportTestProvider.ViewportRequest(
            guildID: guild.id,
            channelID: replacementChannel.id,
            visibleRange: visibleRange
        )
    )
}

@MainActor
@Test func `empty member load bootstraps the initial viewport`() async throws {
    let provider = DelayedMemberViewportTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let snapshot = try await provider.bootstrap()
    let guild = try #require(snapshot.guilds.first)
    let channel = try #require(snapshot.channels.first { $0.guildID == guild.id })
    model.snapshot = snapshot
    model.selectedGuildID = guild.id
    model.visibleChannels = snapshot.channels.filter { $0.guildID == guild.id }
    model.selectedChannelID = channel.id

    model.beginMemberLoad(for: guild.id)
    #expect(await provider.waitUntilMemberLoadStarts())
    await provider.releaseMemberLoad()

    #expect(await provider.waitUntilAcceptedViewportCount(1))
    #expect(await provider.acceptedViewportRequests() == [
        DelayedMemberViewportTestProvider.ViewportRequest(
            guildID: guild.id,
            channelID: channel.id,
            visibleRange: 0 ... 0
        ),
    ])
}

@MainActor
@Test func `automatic guild selection follows visible order without preferring general`() {
    let guildID = GuildID(rawValue: 7)
    let voiceGeneral = Channel(
        id: ChannelID(rawValue: 70),
        guildID: guildID,
        name: "general",
        kind: .voice
    )
    let welcome = Channel(
        id: ChannelID(rawValue: 71),
        guildID: guildID,
        name: "welcome",
        kind: .text
    )
    let textGeneral = Channel(
        id: ChannelID(rawValue: 72),
        guildID: guildID,
        name: "general",
        kind: .text
    )

    #expect(
        AppModel.preferredInitialChannelID(
            in: [voiceGeneral, welcome, textGeneral]
        ) == welcome.id
    )
    #expect(
        AppModel.preferredInitialChannelID(in: [voiceGeneral, welcome])
            == welcome.id
    )
    #expect(
        AppModel.preferredInitialChannelID(in: [voiceGeneral])
            == voiceGeneral.id
    )
}

@MainActor
@Test func `first guild visit keeps its channel selected while permissions load`() async {
    let provider = FirstGuildVisitPermissionTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()

    #expect(model.selectedGuildID == provider.guildID)
    #expect(model.selectedChannelID == provider.channelID)
    #expect(model.selectedChannel?.id == provider.channelID)
    #expect(model.selectedConversationAccess == .checking)
    #expect(model.messages.isEmpty)
    #expect(await provider.messageRequestCount() == 0)
    #expect(await provider.waitUntilRoleRequestStarts())

    await provider.releaseRoles()

    #expect(await eventuallyOnMain {
        model.selectedConversationAccess.isReadable
            && model.messages.map(\.content) == ["Loaded automatically"]
    })
    #expect(await provider.messageRequestCount() == 1)
}

@MainActor
@Test func `automatic first channel moves to first readable channel when access resolves hidden`() {
    let model = AppModel(launchMode: .offlineTesting)
    let guildID = GuildID(rawValue: 77_300)
    let privateChannel = Channel(
        id: ChannelID(rawValue: 77_301), guildID: guildID, name: "staff"
    )
    let welcomeChannel = Channel(
        id: ChannelID(rawValue: 77_302), guildID: guildID, name: "welcome"
    )
    model.selectedGuildID = guildID
    model.visibleChannels = [privateChannel, welcomeChannel]
    model.pendingAutomaticChannelAccessID = privateChannel.id
    model.selectedChannelID = privateChannel.id
    model.checkingChannelIDs = [privateChannel.id, welcomeChannel.id]

    model.applyUnreadAccessProjection(UnreadAccessProjection(
        accessByChannelID: [
            privateChannel.id: .hidden,
            welcomeChannel.id: .readable(canSend: false),
        ],
        accessibilityByChannelID: [
            privateChannel.id: false,
            welcomeChannel.id: true,
        ]
    ))

    #expect(model.selectedChannelID == welcomeChannel.id)
    #expect(model.pendingAutomaticChannelAccessID == nil)
}

@MainActor
@Test func `selecting voice channel opens its text chat by default without joining`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let voiceChannel = try #require(model.visibleChannels.first(where: { $0.kind == .voice }))

    model.selectedChannelID = voiceChannel.id

    #expect(model.selectedChannel?.id == voiceChannel.id)
    #expect(model.selectedChannel?.kind == .voice)
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)
    #expect(await eventuallyOnMain { !model.isLoadingMessages && !model.messages.isEmpty })
}

@MainActor
@Test func `voice channel selection reuses the session page when chat is reopened`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let voiceChannel = ChannelID(rawValue: 91003)

    model.selectedChannelID = voiceChannel
    #expect(await eventuallyOnMain { !model.isLoadingMessages })
    #expect(await provider.requestCount(for: voiceChannel) == 1)
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)

    let channel = try #require(model.selectedChannel)
    model.openVoiceChat(for: channel)
    #expect(await provider.requestCount(for: voiceChannel) == 1)
    #expect(model.messages.map(\.channelID) == [voiceChannel])
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)

    model.openVoiceChat(for: channel)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await provider.requestCount(for: voiceChannel) == 1)

    model.closeVoiceChat()
    #expect(!model.isVoiceChatOpen)
    #expect(model.activeVoiceChannel == nil)

    model.openVoiceChat(for: channel)
    #expect(model.isVoiceChatOpen)
    try await Task.sleep(for: .milliseconds(40))
    #expect(!model.isLoadingMessages)
    #expect(await provider.requestCount(for: voiceChannel) == 1)
    #expect(model.activeVoiceChannel == nil)
}

@MainActor
@Test func `connection gap refreshes the selected session page once`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = ChannelID(rawValue: 91001)
    model.connectionState = .ready

    model.selectedChannelID = channelID
    await model.channelLoadTask?.value
    #expect(await provider.requestCount(for: channelID) == 1)
    let loadedMessages = model.messages
    #expect(!loadedMessages.isEmpty)
    #expect(model.readState.presentations[channelID]?.initialHistoryLoaded == true)

    model.consumeConnectionChange(.resuming)
    model.consumeConnectionChange(.ready)

    #expect(model.messages == loadedMessages)
    #expect(!model.isLoadingMessages)
    model.consumeReadStateSnapshot([], version: nil)
    #expect(model.readState.presentations[channelID]?.initialHistoryLoaded == true)

    await model.channelLoadTask?.value
    #expect(await provider.requestCount(for: channelID) == 2)
    model.consumeConnectionChange(.ready)
    try await Task.sleep(for: .milliseconds(40))
    #expect(await provider.requestCount(for: channelID) == 2)
}

@MainActor
@Test func `gateway recovery republishes an active voice state once`() async {
    let provider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    model.activeVoiceChannel = Channel(
        id: provider.channelID,
        guildID: nil,
        name: "Recovered call",
        kind: .directMessage
    )
    model.voiceSessionState = .reconnecting
    model.connectionState = .resuming

    model.consumeConnectionChange(.ready)
    for task in Array(model.accountChildTasks.values) {
        await task.value
    }
    #expect(await provider.voiceStateUpdateRequestCount == 1)

    model.consumeConnectionChange(.ready)
    for task in Array(model.accountChildTasks.values) {
        await task.value
    }
    #expect(await provider.voiceStateUpdateRequestCount == 1)
}

@MainActor
@Test func `server disconnected voice session tears down locally without leaving the replacement client`() async throws {
    let provider = SuspendedAccountOperationTestProvider(suspendsOperations: false)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let snapshot = try await provider.bootstrap()
    model.snapshot = snapshot
    model.activeVoiceChannel = Channel(
        id: provider.channelID,
        guildID: nil,
        name: "Displaced call",
        kind: .directMessage
    )
    model.voiceSessionState = .connected
    let replacementState = VoiceParticipantState(
        userID: snapshot.currentUser.id,
        channelID: provider.channelID,
        guildID: nil,
        sessionID: "replacement-session"
    )
    model.voiceStates[snapshot.currentUser.id] = replacementState

    model.consumeVoiceEvent(.stateChanged(.disconnected))
    for task in Array(model.accountChildTasks.values) {
        await task.value
    }

    #expect(model.activeVoiceChannel == nil)
    #expect(model.voiceSessionState == .idle)
    #expect(model.voiceStates[snapshot.currentUser.id] == replacementState)
    #expect(await provider.voiceStateUpdateRequestCount == 0)
}

@MainActor
@Test func `unchanged unread projection does not republish the account snapshot`() async throws {
    let snapshot = try await MockChatProvider().bootstrap()
    #expect(
        !UnreadPresentationPublicationPolicy.shouldPublish(
            snapshot: snapshot,
            channels: snapshot.channels,
            guilds: snapshot.guilds
        )
    )

    var changedChannels = snapshot.channels
    changedChannels[0].unreadCount += 1
    #expect(
        UnreadPresentationPublicationPolicy.shouldPublish(
            snapshot: snapshot,
            channels: changedChannels,
            guilds: snapshot.guilds
        )
    )
}

@MainActor
@Test func `selecting member loads full profile`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let member = try #require(model.members.first)

    model.selectMember(member)
    #expect(await eventuallyOnMain { model.selectedProfile?.id == member.id })

    let profile = try #require(model.selectedProfile)
    #expect(model.isInspectorProfilePresented)
    #expect(profile.id == member.id)
    #expect(!profile.badges.isEmpty)
    #expect(!profile.mutualGuilds.isEmpty)
    #expect(profile.status == member.status)
}

@MainActor
private func reactionMutationTestModel(provider: any ChatProvider) -> AppModel {
    AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        reactionMutationTiming: .init(debounce: .zero)
    )
}

@MainActor
private func drainReactionMutations(in model: AppModel) async -> Bool {
    for _ in 0 ..< 10_000 {
        if model.reactionMutationTasks.isEmpty, model.reactionMutations.isEmpty {
            return true
        }
        await Task.yield()
    }
    return model.reactionMutationTasks.isEmpty && model.reactionMutations.isEmpty
}

@MainActor
private func waitForReactionRequestCount(
    _ expectedCount: Int,
    from provider: ReactionMutationTestProvider
) async -> Bool {
    for _ in 0 ..< 10_000 {
        if await provider.requests().count >= expectedCount {
            return true
        }
        await Task.yield()
    }
    return await provider.requests().count >= expectedCount
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

private func waitForVoiceLeaveCount(
    _ expectedCount: Int,
    from provider: SuspendedVoiceReplacementProvider
) async -> Bool {
    for _ in 0 ..< 500 {
        if await provider.leaveRequestCount == expectedCount { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await provider.leaveRequestCount == expectedCount
}

private func waitForVoiceJoinCount(
    _ expectedCount: Int,
    from provider: SuspendedVoiceReplacementProvider
) async -> Bool {
    for _ in 0 ..< 500 {
        if await provider.joinedChannelIDs.count == expectedCount { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await provider.joinedChannelIDs.count == expectedCount
}

@MainActor
private func hiddenMockChannel(
    kind: ChannelKindValue,
    in model: AppModel
) throws -> Channel {
    let channelID = ChannelID(rawValue: 215)
    var snapshot = try #require(model.snapshot)
    let index = try #require(
        snapshot.channels.firstIndex { $0.id == channelID }
    )
    var channel = snapshot.channels[index]
    channel.kind = kind
    snapshot.channels[index] = channel
    model.snapshot = snapshot
    model.refreshUnreadPresentation(appliesAccessImmediately: true)
    #expect(model.conversationAccess(for: channel) == .hidden)
    return channel
}

@MainActor
@Test func `app model reconciles lazy production reactors without repeated reads`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let message = try #require(model.messages.first)
    let reaction = try #require(message.reactions.first)
    #expect(reaction.reactors.isEmpty)
    await model.loadReactionReactors(reaction, on: message)

    let loaded = try #require(model.messages.first?.reactions.first)
    #expect(loaded.reactors.map(\.displayName) == ["One", "Two", "Three", "Four", "Five"])
    #expect(await provider.reactorRequestCount() == 1)

    await model.loadReactionReactors(loaded, on: try #require(model.messages.first))
    #expect(await provider.reactorRequestCount() == 1)
}

@MainActor
@Test func `failed earlier page stays retryable without refreshing the newest page`() async throws {
    let provider = ChannelLoadTestProvider(failsFirstEarlierPage: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()
    let channelID = try #require(model.selectedChannelID)
    #expect(model.hasMoreMessages)

    await model.loadEarlier()
    #expect(model.messageLoadError != nil)
    #expect(model.hasMoreMessages)
    #expect(!model.isLoadingEarlier)

    model.retryMessageLoad()

    #expect(await eventuallyOnMain {
        model.messageLoadError == nil
            && !model.isLoadingEarlier
            && !model.hasMoreMessages
            && model.messages.count == 2
    })
    #expect(await provider.requestCount(for: channelID) == 3)
    #expect(await provider.earlierRequestCount() == 2)
}

@MainActor
@Test func `gateway mutations keep exact indexes after repeated history prepends`() async throws {
    let provider = MockChatProvider(timelineMessageCount: 500)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let timelineChannelID = ChannelID(rawValue: 210)
    model.navigate(to: timelineChannelID)
    #expect(await eventuallyOnMain {
        model.selectedChannelID == timelineChannelID
            && model.hasCompletedInitialMessageLoad
    })
    let initialCount = model.messages.count
    for _ in 0 ..< 13 {
        await model.loadEarlier()
    }
    #expect(model.messages.count == min(500, initialCount + 260))

    let updateTarget = model.messages[173]
    var updated = updateTarget
    updated.content = "Updated after repeated prepended pages"
    await provider.emit(.messageUpdated(updated))

    #expect(await eventuallyOnMain {
        model.messages.first(where: { $0.id == updateTarget.id })?.content
            == updated.content
    })

    let deleted = model.messages[211]
    await provider.emit(.messageDeleted(
        channelID: deleted.channelID,
        messageID: deleted.id
    ))
    #expect(await eventuallyOnMain {
        !model.messages.contains(where: { $0.id == deleted.id })
    })
}

@MainActor
@Test func `distant message navigation owns a contiguous bidirectional history window`() async throws {
    let provider = MockChatProvider(timelineMessageCount: 500)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let channelID = ChannelID(rawValue: 210)
    let targetID = MessageID(rawValue: 5_000_100)
    model.navigate(to: GuildID(rawValue: 100), channelID: channelID, messageID: targetID)

    #expect(await eventuallyOnMain {
        model.messageNavigationRequest?.messageID == targetID
            && model.messages.contains(where: { $0.id == targetID })
    })
    #expect(model.messages.map(\.id) == (75 ... 124).map {
        MessageID(rawValue: 5_000_000 + UInt64($0))
    })
    #expect(model.hasMoreMessages)
    #expect(model.hasMoreLaterMessages)

    await model.loadEarlier()
    #expect(model.messages.map(\.id) == (55 ... 124).map {
        MessageID(rawValue: 5_000_000 + UInt64($0))
    })

    await model.loadLater()
    #expect(model.messages.map(\.id) == (55 ... 144).map {
        MessageID(rawValue: 5_000_000 + UInt64($0))
    })
    #expect(model.hasMoreLaterMessages)

    let liveMessage = Message(
        id: MessageID(rawValue: 6_000_000),
        channelID: channelID,
        author: try #require(model.snapshot?.currentUser),
        content: "This must not bridge the unloaded history gap."
    )
    await provider.emit(.messageCreated(liveMessage))
    try await Task.sleep(for: .milliseconds(20))
    #expect(!model.messages.contains(where: { $0.id == liveMessage.id }))

    #expect(await model.loadNewestMessageWindow())
    #expect(model.messages.map(\.id) == (450 ... 499).map {
        MessageID(rawValue: 5_000_000 + UInt64($0))
    })
    #expect(model.hasMoreMessages)
    #expect(!model.hasMoreLaterMessages)
}

@MainActor
@Test func `failed earlier thread page retries inside the shared conversation`() async throws {
    let provider = ChannelLoadTestProvider(failsFirstEarlierPage: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let parentID = try #require(model.selectedChannelID)
    let thread = MessageThreadSummary(
        id: ChannelID(rawValue: 91_099),
        parentID: parentID,
        name: "Pagination retry"
    )

    model.open(thread)
    #expect(await eventuallyOnMain {
        model.hasCompletedInitialThreadLoad
            && model.hasMoreThreadMessages
            && model.threadMessages.count == 1
    })

    await model.loadEarlierThread()
    #expect(model.threadErrorMessage != nil)
    #expect(model.canRetryThreadLoad)
    #expect(model.hasMoreThreadMessages)

    model.retryThreadLoad()

    #expect(await eventuallyOnMain {
        model.threadErrorMessage == nil
            && !model.isLoadingEarlierThread
            && !model.hasMoreThreadMessages
            && model.threadMessages.count == 2
    })
    #expect(await provider.requestCount(for: thread.id) == 3)
}

@MainActor
@Test func `reaction preview enrichment waits for live timeline scrolling to end`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let message = try #require(model.messages.first)
    let reaction = try #require(message.reactions.first)
    let primaryID = message.channelID
    let supplementaryID = ChannelID(rawValue: 910_002)
    model.reportTimelineLiveScrolling(
        true,
        conversationID: primaryID
    )
    model.reportTimelineLiveScrolling(
        true,
        conversationID: supplementaryID
    )
    let load = Task {
        await model.loadReactionReactors(reaction, on: message)
    }
    try await Task.sleep(for: .milliseconds(80))

    #expect(await provider.reactorRequestCount() == 0)
    #expect(model.messages.first?.reactions.first?.reactors.isEmpty == true)

    model.reportTimelineLiveScrolling(
        false,
        conversationID: primaryID
    )
    try await Task.sleep(for: .milliseconds(80))

    #expect(await provider.reactorRequestCount() == 0)
    #expect(model.messages.first?.reactions.first?.reactors.isEmpty == true)

    model.reportTimelineLiveScrolling(
        false,
        conversationID: supplementaryID
    )
    await load.value

    #expect(await provider.reactorRequestCount() == 1)
    #expect(model.messages.first?.reactions.first?.reactors.count == 5)
}

@MainActor
@Test func `unread projection waits for live timeline scrolling to end`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let channelID = model.selectedChannelID ?? ChannelID(rawValue: 1)

    model.reportTimelineLiveScrolling(true, conversationID: channelID)
    model.refreshUnreadPresentation()
    #expect(model.hasDeferredUnreadPresentationRefresh)

    model.reportTimelineLiveScrolling(false, conversationID: channelID)
    #expect(!model.hasDeferredUnreadPresentationRefresh)
}

@MainActor
@Test func `permission revocation applies while unread publication is deferred`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let privateChannelID = ChannelID(rawValue: 215)
    #expect(
        model.snapshot?.channels.contains { $0.id == privateChannelID }
            == true
    )

    model.hiddenChannelIDs.remove(privateChannelID)
    model.readState.applyAccessibility([privateChannelID: true])
    model.reportTimelineLiveScrolling(true, conversationID: privateChannelID)
    model.refreshUnreadPresentation(appliesAccessImmediately: true)

    #expect(model.hasDeferredUnreadPresentationRefresh)
    #expect(model.hiddenChannelIDs.contains(privateChannelID))
    #expect(model.readState.entries[privateChannelID]?.isAccessible == false)

    model.reportTimelineLiveScrolling(false, conversationID: privateChannelID)
}

@MainActor
@Test func `ready role snapshot replaces stale guild role sets`() {
    let model = AppModel(launchMode: .offlineTesting)
    let firstGuildID = GuildID(rawValue: 91_001)
    let secondGuildID = GuildID(rawValue: 91_002)
    let firstRoleID = RoleID(rawValue: 92_001)
    let secondRoleID = RoleID(rawValue: 92_002)

    model.consumePresenceAndCommandEvent(
        .currentUserRolesSnapshot([
            firstGuildID: [firstRoleID],
            secondGuildID: [secondRoleID]
        ])
    )

    #expect(model.currentUserRoleIDsByGuild[firstGuildID] == [firstRoleID])
    #expect(model.currentUserRoleIDsByGuild[secondGuildID] == [secondRoleID])

    model.consumePresenceAndCommandEvent(
        .currentUserRolesSnapshot([firstGuildID: []])
    )

    #expect(model.currentUserRoleIDsByGuild[firstGuildID] == [])
    #expect(model.currentUserRoleIDsByGuild[secondGuildID] == nil)
}

@MainActor
@Test func `guild role updates preserve unrelated guild access projection`() {
    let model = AppModel(launchMode: .offlineTesting)
    let user = User(
        id: UserID(rawValue: 92_100), username: "member", displayName: "Member"
    )
    let updatedGuild = Guild(id: GuildID(rawValue: 92_101), name: "Updated")
    let unrelatedGuild = Guild(id: GuildID(rawValue: 92_102), name: "Unrelated")
    let updatedChannel = Channel(
        id: ChannelID(rawValue: 92_103),
        guildID: updatedGuild.id,
        name: "updated",
        kind: .text
    )
    let unrelatedChannel = Channel(
        id: ChannelID(rawValue: 92_104),
        guildID: unrelatedGuild.id,
        name: "unrelated",
        kind: .text
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: user,
        guilds: [updatedGuild, unrelatedGuild],
        channels: [updatedChannel, unrelatedChannel],
        members: []
    )
    model.serverRailGuildsByID = [
        updatedGuild.id: updatedGuild,
        unrelatedGuild.id: unrelatedGuild,
    ]
    model.currentUserRoleIDsByGuild[updatedGuild.id] = []
    model.hiddenChannelIDs = [unrelatedChannel.id]
    model.selectedGuildID = updatedGuild.id

    model.applyGuildRoles(
        [
            GuildRole(
                id: RoleID(rawValue: updatedGuild.id.rawValue),
                name: "@everyone",
                position: 0,
                permissions: DiscordPermissionBits.viewChannel
                    | DiscordPermissionBits.sendMessages
                    | DiscordPermissionBits.readMessageHistory
            )
        ],
        to: updatedGuild.id
    )

    #expect(model.conversationAccess(for: updatedChannel).isReadable)
    #expect(!model.hiddenChannelIDs.contains(updatedChannel.id))
    #expect(model.hiddenChannelIDs.contains(unrelatedChannel.id))
}

@MainActor
@Test func `role snapshot preserves unchanged guild access projection`() {
    let model = AppModel(launchMode: .offlineTesting)
    let user = User(
        id: UserID(rawValue: 92_200), username: "member", displayName: "Member"
    )
    let changedGuild = Guild(id: GuildID(rawValue: 92_201), name: "Changed")
    let unchangedGuild = Guild(id: GuildID(rawValue: 92_202), name: "Unchanged")
    let changedChannel = Channel(
        id: ChannelID(rawValue: 92_203),
        guildID: changedGuild.id,
        name: "changed",
        kind: .text
    )
    let unchangedChannel = Channel(
        id: ChannelID(rawValue: 92_204),
        guildID: unchangedGuild.id,
        name: "unchanged",
        kind: .text
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: user,
        guilds: [changedGuild, unchangedGuild],
        channels: [changedChannel, unchangedChannel],
        members: []
    )
    model.serverRailGuildsByID = [
        changedGuild.id: changedGuild,
        unchangedGuild.id: unchangedGuild,
    ]
    let readablePermissions = DiscordPermissionBits.viewChannel
        | DiscordPermissionBits.sendMessages
        | DiscordPermissionBits.readMessageHistory
    model.guildRolesByGuildID = [
        changedGuild.id: [
            GuildRole(
                id: RoleID(rawValue: changedGuild.id.rawValue),
                name: "@everyone",
                position: 0,
                permissions: readablePermissions
            )
        ],
        unchangedGuild.id: [
            GuildRole(
                id: RoleID(rawValue: unchangedGuild.id.rawValue),
                name: "@everyone",
                position: 0,
                permissions: readablePermissions
            )
        ],
    ]
    let changedRoleID = RoleID(rawValue: 92_205)
    model.currentUserRoleIDsByGuild = [
        changedGuild.id: [],
        unchangedGuild.id: [],
    ]
    model.hiddenChannelIDs = [unchangedChannel.id]

    model.consumeCurrentUserRolesSnapshot([
        changedGuild.id: [changedRoleID],
        unchangedGuild.id: [],
    ])

    #expect(!model.hiddenChannelIDs.contains(changedChannel.id))
    #expect(model.hiddenChannelIDs.contains(unchangedChannel.id))
}

@MainActor
@Test func `channel replacement removes deleted access projection entries`() {
    let model = AppModel(launchMode: .offlineTesting)
    let user = User(
        id: UserID(rawValue: 92_300), username: "member", displayName: "Member"
    )
    let guild = Guild(id: GuildID(rawValue: 92_301), name: "Guild")
    let deletedChannel = Channel(
        id: ChannelID(rawValue: 92_302),
        guildID: guild.id,
        name: "deleted",
        kind: .text
    )
    let replacementChannel = Channel(
        id: ChannelID(rawValue: 92_303),
        guildID: guild.id,
        name: "replacement",
        kind: .text
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: user,
        guilds: [guild],
        channels: [deletedChannel],
        members: []
    )
    model.serverRailGuildsByID = [guild.id: guild]
    model.currentUserRoleIDsByGuild[guild.id] = []
    model.hiddenChannelIDs = [deletedChannel.id]
    model.checkingChannelIDs = [deletedChannel.id]

    model.consumeChannelsChanged(
        guildID: guild.id,
        channels: [replacementChannel]
    )

    #expect(!model.hiddenChannelIDs.contains(deletedChannel.id))
    #expect(!model.checkingChannelIDs.contains(deletedChannel.id))
    #expect(model.snapshot?.channels == [replacementChannel])
}

@MainActor
@Test func `channel access replacement preserves unchanged access projections`() {
    let model = AppModel(launchMode: .offlineTesting)
    let user = User(
        id: UserID(rawValue: 92_310), username: "member", displayName: "Member"
    )
    let guild = Guild(
        id: GuildID(rawValue: 92_311),
        name: "Guild",
        currentUserPermissions: DiscordPermissionBits.viewChannel
            | DiscordPermissionBits.sendMessages
            | DiscordPermissionBits.readMessageHistory
    )
    let changedChannel = Channel(
        id: ChannelID(rawValue: 92_312),
        guildID: guild.id,
        name: "changed",
        kind: .text
    )
    let unchangedChannel = Channel(
        id: ChannelID(rawValue: 92_313),
        guildID: guild.id,
        name: "unchanged",
        kind: .text
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: user,
        guilds: [guild],
        channels: [changedChannel, unchangedChannel],
        members: []
    )
    model.serverRailGuildsByID = [guild.id: guild]
    model.currentUserRoleIDsByGuild[guild.id] = []
    model.hiddenChannelIDs = [unchangedChannel.id]

    let revokedChannel = Channel(
        id: changedChannel.id,
        guildID: guild.id,
        name: changedChannel.name,
        kind: changedChannel.kind,
        permissionOverwrites: [
            ChannelPermissionOverwrite(
                id: guild.id.description,
                type: 0,
                deny: DiscordPermissionBits.viewChannel
            ),
        ]
    )
    model.consumeChannelsChanged(
        guildID: guild.id,
        channels: [revokedChannel, unchangedChannel]
    )

    #expect(model.hiddenChannelIDs.contains(revokedChannel.id))
    #expect(model.hiddenChannelIDs.contains(unchangedChannel.id))
}

@MainActor
@Test func `gateway lifecycle projections update app workspace state`() {
    let model = AppModel(launchMode: .offlineTesting)
    let oldUser = User(
        id: UserID(rawValue: 93_001), username: "before", displayName: "Before"
    )
    let updatedUser = User(
        id: oldUser.id, username: "after", displayName: "After"
    )
    let guild = Guild(id: GuildID(rawValue: 93_002), name: "Joined Guild")
    let role = GuildRole(
        id: RoleID(rawValue: 93_003), name: "Member", position: 1,
        permissions: 1_024
    )
    model.snapshot = BootstrapSnapshot(
        currentUser: oldUser, guilds: [], channels: [], members: []
    )

    model.consumePresenceAndCommandEvent(
        .guildLayoutChanged(guilds: [guild], railItems: [.guild(guild.id)])
    )
    model.consumePresenceAndCommandEvent(
        .guildRolesChanged(guildID: guild.id, roles: [role])
    )
    model.consumePresenceAndCommandEvent(
        .currentUserRolesSnapshot([guild.id: [role.id]])
    )
    model.consumePresenceAndCommandEvent(.currentUserChanged(updatedUser))

    #expect(model.snapshot?.guilds == [guild])
    #expect(model.serverRailGuildsByID[guild.id] == guild)
    #expect(model.guildRolesByGuildID[guild.id] == [role])
    #expect(model.currentUserRoleIDsByGuild[guild.id] == [role.id])
    #expect(model.snapshot?.currentUser == updatedUser)

    model.consumePresenceAndCommandEvent(
        .guildLayoutChanged(guilds: [], railItems: [])
    )

    #expect(model.currentUserRoleIDsByGuild[guild.id] == nil)
}

@MainActor
@Test func `provider member refresh revokes access during live scrolling`() async {
    let provider = MemberRoleRevocationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = provider.channelID

    #expect(await provider.waitUntilMemberRequestStarts())
    #expect(!model.hiddenChannelIDs.contains(channelID))
    model.reportTimelineLiveScrolling(true, conversationID: channelID)
    await provider.releaseRevokedMember()

    #expect(await eventuallyOnMain {
        model.hiddenChannelIDs.contains(channelID)
            && model.readState.entries[channelID]?.isAccessible == false
    })
    #expect(model.hasDeferredUnreadPresentationRefresh)
    model.reportTimelineLiveScrolling(false, conversationID: channelID)
}

@MainActor
@Test func `visible reaction preview reads stay within the app request budget`() async {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    await withTaskGroup(of: Void.self) { group in
        for value in 0 ..< 12 {
            let message = Message(
                id: MessageID(rawValue: UInt64(92000 + value)),
                channelID: ChannelID(rawValue: 91001),
                author: User(
                    id: UserID(rawValue: 91000),
                    username: "tester",
                    displayName: "Tester"
                ),
                content: "reaction \(value)",
                reactions: [Reaction(emoji: "emoji-\(value)", count: 1)]
            )
            group.addTask {
                await model.loadReactionReactors(message.reactions[0], on: message)
            }
        }
    }

    #expect(await provider.reactorRequestCount() == 12)
    #expect(
        await provider.maximumConcurrentReactorRequestCount()
            <= AppModel.maximumConcurrentReactionReactorLoads
    )
}

@MainActor
@Test func `voice server reallocation keeps the call selected and reconnects`() async throws {
    let provider = VoiceMigrationTestProvider()
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        soundPlayer: sounds
    )
    await model.start()
    let voiceChannel = try #require(model.visibleChannels.first)

    await model.joinVoice(voiceChannel)
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .connected)
    #expect(sounds.played == [.userJoin])

    await provider.emit(.voiceServerChanged(nil))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .reconnecting)

    await provider.emit(.voiceServerChanged(provider.connectionInfo(token: "replacement")))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .connected)
    #expect(sounds.played == [.userJoin])

    await model.leaveVoice()
    #expect(sounds.played == [.userJoin, .disconnect])
}

@MainActor
@Test func `newer voice join wins when prior call teardown completes out of order`() async throws {
    let provider = SuspendedVoiceReplacementProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let channels = provider.testChannels
    let currentUser = provider.currentUser
    model.snapshot = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [],
        channels: channels,
        members: []
    )
    model.activeVoiceChannel = channels[0]
    model.voiceSessionState = .connected

    let firstJoin = Task { await model.joinVoice(channels[1]) }
    #expect(await waitForVoiceLeaveCount(1, from: provider))
    let secondJoin = Task { await model.joinVoice(channels[2]) }
    #expect(await waitForVoiceLeaveCount(2, from: provider))

    await provider.releaseLeave(call: 2)
    #expect(await waitForVoiceJoinCount(1, from: provider))
    await provider.releaseLeave(call: 1)
    await firstJoin.value
    await secondJoin.value

    #expect(model.activeVoiceChannel?.id == channels[2].id)
    #expect(await provider.joinedChannelIDs == [channels[2].id])
}

@MainActor
@Test func `private calls remain app wide and reconcile incoming ongoing and deleted state`() async throws {
    let provider = VoiceMigrationTestProvider()
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: provider,
        soundPlayer: sounds
    )
    await model.start()
    let currentUserID = try #require(model.snapshot?.currentUser.id)
    let channelID = ChannelID(rawValue: 88_800)
    let senderID = UserID(rawValue: 88_801)

    await provider.emit(
        .privateCallChanged(
            PrivateCall(
                channelID: channelID,
                messageID: MessageID(rawValue: 88_802),
                region: "rotterdam",
                ongoingRings: [
                    PrivateCallRing(
                        recipientID: currentUserID,
                        senderID: senderID
                    )
                ],
                voiceStates: []
            )
        )
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.incomingPrivateCalls.map(\.channelID) == [channelID])
    #expect(model.privateCall(in: channelID)?.isRinging(currentUserID) == true)
    #expect(model.joinablePrivateCall(in: channelID) != nil)
    #expect(sounds.looping[.callRinging] == true)

    await provider.emit(
        .privateCallChanged(
            PrivateCall(
                channelID: channelID,
                messageID: MessageID(rawValue: 88_802),
                region: "rotterdam",
                ongoingRings: [],
                voiceStates: [
                    VoiceParticipantState(
                        userID: senderID,
                        channelID: channelID,
                        guildID: nil,
                        sessionID: "private-session"
                    )
                ]
            )
        )
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.incomingPrivateCalls.isEmpty)
    #expect(model.privateCall(in: channelID)?.voiceStates?.map(\.userID) == [senderID])
    #expect(model.joinablePrivateCall(in: channelID) != nil)
    #expect(sounds.looping[.callRinging] == false)

    let destinationChannelID = ChannelID(rawValue: 88_804)
    await provider.emit(
        .privateCallChanged(
            PrivateCall(
                channelID: destinationChannelID,
                messageID: MessageID(rawValue: 88_805),
                region: "rotterdam",
                voiceStates: []
            )
        )
    )
    await provider.emit(
        .voiceStateChanged(
            VoiceParticipantState(
                userID: senderID,
                channelID: destinationChannelID,
                guildID: nil,
                sessionID: "private-session-b"
            )
        )
    )
    #expect(await eventuallyOnMain {
        model.privateCall(in: channelID)?.voiceStates?.isEmpty == true
            && model.privateCall(in: destinationChannelID)?.voiceStates?.map(\.userID)
                == [senderID]
    })
    #expect(model.joinablePrivateCall(in: channelID) == nil)
    #expect(model.joinablePrivateCall(in: destinationChannelID) != nil)

    await provider.emit(.privateCallDeleted(channelID: channelID, unavailable: false))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.privateCall(in: channelID) == nil)
    #expect(sounds.looping[.callRinging] == false)
}

@MainActor
@Test func `concurrent private call actions stay within one request budget`() async throws {
    let provider = PrivateCallActionTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try #require(
        model.snapshot?.channels.first(where: {
            $0.kind == .directMessage
        })
    )
    let baselineCounts = await provider.counts()
    model.privateCallsByChannel[channel.id] = PrivateCall(
        channelID: channel.id,
        messageID: MessageID(rawValue: 88_813),
        region: "rotterdam",
        voiceStates: []
    )

    let firstStart = Task {
        await model.startPrivateCall(in: channel)
    }
    await provider.waitUntilRingabilityStarts()
    #expect(model.isPrivateCallActionInFlight(in: channel.id))

    let duplicateStarts = (0 ..< 4).map { _ in
        Task {
            await model.startPrivateCall(in: channel)
        }
    }
    for duplicate in duplicateStarts {
        await duplicate.value
    }

    let suspendedStartCounts = await provider.counts()
    #expect(suspendedStartCounts.subscriptions == baselineCounts.subscriptions + 1)
    #expect(suspendedStartCounts.ringabilityReads == 1)
    #expect(suspendedStartCounts.voiceJoins == 0)
    #expect(suspendedStartCounts.rings == 0)

    await provider.releaseRingability()
    await firstStart.value

    let completedStartCounts = await provider.counts()
    #expect(completedStartCounts.subscriptions == baselineCounts.subscriptions + 1)
    #expect(completedStartCounts.ringabilityReads == 1)
    #expect(completedStartCounts.voiceJoins == 1)
    #expect(completedStartCounts.rings == 1)
    #expect(!model.isPrivateCallActionInFlight(in: channel.id))

    let currentUserID = try #require(model.snapshot?.currentUser.id)
    let call = PrivateCall(
        channelID: channel.id,
        messageID: MessageID(rawValue: 88_803),
        region: "rotterdam",
        ongoingRings: [
            PrivateCallRing(
                recipientID: currentUserID,
                senderID: channel.recipients[0].id
            )
        ]
    )
    let firstDecline = Task {
        await model.declinePrivateCall(call)
    }
    await provider.waitUntilDeclineStarts()
    #expect(model.isPrivateCallActionInFlight(in: channel.id))

    let duplicateDeclines = (0 ..< 4).map { _ in
        Task {
            await model.declinePrivateCall(call)
        }
    }
    for duplicate in duplicateDeclines {
        await duplicate.value
    }
    #expect((await provider.counts()).declines == 1)

    await provider.releaseDecline()
    await firstDecline.value
    #expect((await provider.counts()).declines == 1)
    #expect(!model.isPrivateCallActionInFlight(in: channel.id))
}

private struct ReactionMutationRequest: Equatable, Sendable {
    var messageID: MessageID
    var emoji: String
    var reacted: Bool
}

private actor ReactionMutationTestProvider: ChatProvider {
    private let user = User(
        id: UserID(rawValue: 98_001),
        username: "reaction-tester",
        displayName: "Reaction Tester"
    )
    private let channel = Channel(
        id: ChannelID(rawValue: 98_002),
        guildID: nil,
        name: "reaction-tests"
    )
    private let blocksFirstRequest: Bool
    private let failingEmoji: String?
    private let initialReaction: Reaction?
    private var recordedRequests: [ReactionMutationRequest] = []
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private var didBlockFirstRequest = false
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    init(
        blocksFirstRequest: Bool = false,
        failingEmoji: String? = nil,
        initialReaction: Reaction? = nil
    ) {
        self.blocksFirstRequest = blocksFirstRequest
        self.failingEmoji = failingEmoji
        self.initialReaction = initialReaction
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [], channels: [channel], members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(
            messages: [
                Message(
                    id: MessageID(rawValue: 98_100),
                    channelID: channel.id,
                    author: user,
                    content: "First",
                    reactions: initialReaction.map { [$0] } ?? []
                ),
                Message(
                    id: MessageID(rawValue: 98_101),
                    channelID: channel.id,
                    author: user,
                    content: "Second"
                ),
            ],
            hasMoreBefore: false
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}

    func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        recordedRequests.append(
            ReactionMutationRequest(messageID: messageID, emoji: emoji, reacted: reacted)
        )
        if blocksFirstRequest, !didBlockFirstRequest {
            didBlockFirstRequest = true
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }
        if failingEmoji == emoji {
            throw ChatProviderError.invalidRequest("Synthetic reaction failure.")
        }
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { continuation = $0 }
    }

    func disconnect() async {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
        continuation?.finish()
        continuation = nil
    }

    func resumeFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    func requests() -> [ReactionMutationRequest] {
        recordedRequests
    }

    func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }
}

private struct ChannelLoadMessageRequest: Equatable, Sendable {
    let before: MessageID?
    let limit: Int
}

private actor SuspendedVoiceReplacementProvider: ChatProvider {
    let currentUser = User(
        id: UserID(rawValue: 90_000),
        username: "voice-user",
        displayName: "Voice User"
    )
    let testChannels = [
        Channel(
            id: ChannelID(rawValue: 90_001),
            guildID: nil,
            name: "Existing call",
            kind: .directMessage
        ),
        Channel(
            id: ChannelID(rawValue: 90_002),
            guildID: nil,
            name: "First replacement",
            kind: .directMessage
        ),
        Channel(
            id: ChannelID(rawValue: 90_003),
            guildID: nil,
            name: "Second replacement",
            kind: .directMessage
        ),
    ]
    private(set) var leaveRequestCount = 0
    private(set) var joinedChannelIDs: [ChannelID] = []
    private var leaveContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: currentUser,
            guilds: [],
            channels: testChannels,
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] { testChannels }
    func members(in guildID: GuildID?) async throws -> [Member] { [] }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(
        in channelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        joinedChannelIDs.append(channelID)
        return VoiceConnectionInfo(
            serverID: channelID.description,
            channelID: channelID,
            guildID: nil,
            userID: currentUser.id,
            sessionID: "voice-replacement-test",
            token: "synthetic",
            endpoint: "mock.sakuracord.invalid"
        )
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        guard channelID == nil else { return }
        leaveRequestCount += 1
        let call = leaveRequestCount
        await withCheckedContinuation { continuation in
            leaveContinuations[call] = continuation
        }
    }

    func releaseLeave(call: Int) {
        leaveContinuations.removeValue(forKey: call)?.resume()
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}

private actor InaccessibleChannelRequestCountingProvider: ChatProvider {
    private let base = MockChatProvider()
    private var messageRequests: [ChannelID: Int] = [:]
    private var forumRequests: [ChannelID: Int] = [:]
    private var voiceJoinRequests = 0

    func bootstrap() async throws -> BootstrapSnapshot {
        try await base.bootstrap()
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        try await base.channels(in: guildID)
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        try await base.members(in: guildID)
    }

    func profile(
        for userID: UserID,
        in guildID: GuildID?
    ) async throws -> UserProfile {
        try await base.profile(for: userID, in: guildID)
    }

    func currentStatus() async -> PresenceStatus {
        await base.currentStatus()
    }

    func updateStatus(_ status: PresenceStatus) async throws {
        try await base.updateStatus(status)
    }

    func messages(
        in channelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        messageRequests[channelID, default: 0] += 1
        return try await base.messages(
            in: channelID,
            before: before,
            limit: limit
        )
    }

    func forumPosts(
        in channelID: ChannelID,
        query: ForumPostQuery
    ) async throws -> ForumPostPage {
        forumRequests[channelID, default: 0] += 1
        return try await base.forumPosts(in: channelID, query: query)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        voiceJoinRequests += 1
        throw ChatProviderError.invalidRequest(
            "Voice joining should be suppressed for this test."
        )
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        await base.eventStream()
    }

    func disconnect() async {
        await base.disconnect()
    }

    func messageRequestCount(for channelID: ChannelID) -> Int {
        messageRequests[channelID, default: 0]
    }

    func forumRequestCount(for channelID: ChannelID) -> Int {
        forumRequests[channelID, default: 0]
    }

    func voiceJoinRequestCount() -> Int {
        voiceJoinRequests
    }
}

private actor ChannelLoadTestProvider: ChatProvider {
    private let user = User(id: UserID(rawValue: 91000), username: "tester", displayName: "Tester")
    private let testChannels = [
        Channel(id: ChannelID(rawValue: 91001), guildID: nil, name: "general"),
        Channel(id: ChannelID(rawValue: 91002), guildID: nil, name: "other"),
        Channel(
            id: ChannelID(rawValue: 91003),
            guildID: nil,
            name: "Voice Room",
            kind: .voice
        ),
    ]
    private var messageRequests: [ChannelID: Int] = [:]
    private var messageRequestParameters:
        [ChannelID: [ChannelLoadMessageRequest]] = [:]
    private var cancelledMessageRequests: Set<ChannelID> = []
    private var reactorRequests = 0
    private var activeReactorRequests = 0
    private var maximumActiveReactorRequests = 0
    private let failsFirstEarlierPage: Bool
    private var earlierRequests = 0

    init(failsFirstEarlierPage: Bool = false) {
        self.failsFirstEarlierPage = failsFirstEarlierPage
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [], channels: testChannels, members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        testChannels
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        messageRequests[channelID, default: 0] += 1
        messageRequestParameters[channelID, default: []].append(
            ChannelLoadMessageRequest(before: before, limit: limit)
        )
        if failsFirstEarlierPage, before != nil {
            earlierRequests += 1
            if earlierRequests == 1 {
                throw ChatProviderError.invalidRequest(
                    "Synthetic earlier-page timeout."
                )
            }
            return MessagePage(
                messages: [
                    Message(
                        id: MessageID(rawValue: channelID.rawValue - 1),
                        channelID: channelID,
                        author: user,
                        content: "earlier"
                    )
                ],
                hasMoreBefore: false
            )
        }
        // Intentionally ignore cancellation to prove the model's generation guard works.
        let delay: Duration =
            channelID == testChannels[1].id ? .milliseconds(100) : .milliseconds(20)
        try? await Task.sleep(for: delay)
        if Task.isCancelled {
            cancelledMessageRequests.insert(channelID)
        }
        let message = Message(
            id: MessageID(rawValue: channelID.rawValue),
            channelID: channelID,
            author: user,
            content: "channel \(channelID)",
            reactions: [Reaction(emoji: "🔥", count: 8)]
        )
        return MessagePage(
            messages: [message],
            hasMoreBefore: failsFirstEarlierPage
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        reactorRequests += 1
        activeReactorRequests += 1
        maximumActiveReactorRequests = max(
            maximumActiveReactorRequests,
            activeReactorRequests
        )
        defer { activeReactorRequests -= 1 }
        try await Task.sleep(for: .milliseconds(25))
        return (1 ... 5).map {
            ReactionReactor(
                id: UserID(rawValue: UInt64($0)),
                displayName: ["One", "Two", "Three", "Four", "Five"][$0 - 1]
            )
        }
    }
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func requestCount(for channelID: ChannelID) -> Int {
        messageRequests[channelID, default: 0]
    }

    func requests(
        for channelID: ChannelID
    ) -> [ChannelLoadMessageRequest] {
        messageRequestParameters[channelID, default: []]
    }

    func earlierRequestCount() -> Int {
        earlierRequests
    }

    func requestWasCancelled(for channelID: ChannelID) -> Bool {
        cancelledMessageRequests.contains(channelID)
    }

    func reactorRequestCount() -> Int {
        reactorRequests
    }

    func maximumConcurrentReactorRequestCount() -> Int {
        maximumActiveReactorRequests
    }
}

private actor LocalHistoryMemberTestProvider: ChatProvider {
    private let guild = Guild(
        id: GuildID(rawValue: 76_000),
        name: "History Guild",
        currentUserPermissions: .max
    )
    private let currentUser = User(
        id: UserID(rawValue: 76_001),
        username: "current",
        displayName: "Current"
    )
    private let author = User(
        id: UserID(rawValue: 76_101),
        username: "cached-author",
        displayName: "Cached Author"
    )
    private let channel = Channel(
        id: ChannelID(rawValue: 76_002),
        guildID: GuildID(rawValue: 76_000),
        name: "general"
    )
    private let role = GuildRole(
        id: RoleID(rawValue: 76_200),
        name: "Orange",
        position: 10,
        colorHex: 0xFF7900
    )
    private var requests: [[UserID]] = []

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: currentUser, guilds: [guild], channels: [channel], members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == guild.id ? [channel] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] { [] }

    func resolveMembers(in guildID: GuildID, userIDs: [UserID]) async throws -> [Member] {
        requests.append(userIDs)
        guard guildID == guild.id, userIDs.contains(author.id) else { return [] }
        return [
            Member(
                user: author,
                roleName: role.name,
                status: .offline,
                roleID: role.id,
                rolePosition: role.position,
                isRoleCategory: true,
                roleIDs: [role.id],
                roles: [role]
            )
        ]
    }

    func roles(in guildID: GuildID) async throws -> [GuildRole] {
        guildID == guild.id ? [role] : []
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(
            messages: [
                Message(
                    id: MessageID(rawValue: 76_300),
                    channelID: channel.id,
                    author: author,
                    content: "Cached history",
                    guildID: guild.id
                )
            ],
            hasMoreBefore: false
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}

    func resolutionRequests() -> [[UserID]] { requests }
}

private actor MemberRoleRevocationTestProvider: ChatProvider {
    private let guildID = GuildID(rawValue: 76_700)
    private let user = User(
        id: UserID(rawValue: 76_701),
        username: "role-refresh-user",
        displayName: "Role Refresh User"
    )
    private let allowedRole = GuildRole(
        id: RoleID(rawValue: 76_702),
        name: "Private Reader"
    )
    let channelID = ChannelID(rawValue: 76_703)
    private var memberContinuation: CheckedContinuation<[Member], Never>?

    private var guild: Guild {
        Guild(
            id: guildID,
            name: "Role Refresh Guild",
            currentUserPermissions: DiscordPermissionBits.readMessageHistory
        )
    }

    private var channel: Channel {
        Channel(
            id: channelID,
            guildID: guildID,
            name: "private-role-channel",
            permissionOverwrites: [
                ChannelPermissionOverwrite(
                    id: allowedRole.id.description,
                    type: 0,
                    allow: DiscordPermissionBits.viewChannel
                ),
            ]
        )
    }

    private var initialMember: Member {
        Member(
            user: user,
            roleName: allowedRole.name,
            isOnline: true,
            roles: [allowedRole]
        )
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            channels: [channel],
            members: [initialMember]
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == self.guildID ? [channel] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        guard guildID == self.guildID else { return [] }
        return await withCheckedContinuation { continuation in
            memberContinuation = continuation
        }
    }

    func roles(in guildID: GuildID) async throws -> [GuildRole] {
        guildID == self.guildID ? [allowedRole] : []
    }

    func waitUntilMemberRequestStarts() async -> Bool {
        for _ in 0 ..< 100 {
            if memberContinuation != nil { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func releaseRevokedMember() {
        memberContinuation?.resume(returning: [
            Member(
                user: user,
                roleName: "Member",
                isOnline: true,
                roles: []
            ),
        ])
        memberContinuation = nil
    }

    func profile(
        for userID: UserID,
        in guildID: GuildID?
    ) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(
        in channelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}

private actor SuspendedAccountOperationTestProvider: ChatProvider {
    nonisolated let channelID = ChannelID(rawValue: 96_001)
    nonisolated let threadID = ChannelID(rawValue: 96_002)
    nonisolated let thread: MessageThreadSummary
    nonisolated let editTarget: Message
    nonisolated let selectedNewest: Message
    nonisolated let threadNewest: Message

    private let user = User(
        id: UserID(rawValue: 96_003),
        username: "account-race",
        displayName: "Account Race"
    )
    private let suspendsOperations: Bool
    private var sendStarted = false
    private var editStarted = false
    private var earlierPageRequestCount = 0
    private(set) var channelRequestCount = 0
    private(set) var newestMessageRequestCount = 0
    private(set) var applicationCommandRequestCount = 0
    private(set) var privateCallSubscriptionRequestCount = 0
    private(set) var voiceStateUpdateRequestCount = 0
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var editContinuation: CheckedContinuation<Void, Never>?
    private var earlierContinuations: [CheckedContinuation<Void, Never>] = []

    init(suspendsOperations: Bool) {
        self.suspendsOperations = suspendsOperations
        thread = MessageThreadSummary(
            id: threadID,
            parentID: channelID,
            name: "Shared thread"
        )
        editTarget = Message(
            id: MessageID(rawValue: 96_010),
            channelID: channelID,
            author: user,
            content: "old editable value"
        )
        selectedNewest = Message(
            id: MessageID(rawValue: 96_020),
            channelID: channelID,
            author: user,
            content: "old selected newest"
        )
        threadNewest = Message(
            id: MessageID(rawValue: 96_021),
            channelID: threadID,
            author: user,
            content: "old thread newest"
        )
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [],
            channels: [Channel(id: channelID, guildID: nil, name: "shared")],
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        channelRequestCount += 1
        return [Channel(id: channelID, guildID: nil, name: "shared")]
    }

    func members(in guildID: GuildID?) async throws -> [Member] { [] }

    func profile(
        for userID: UserID,
        in guildID: GuildID?
    ) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(
        in requestedChannelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        guard before != nil else {
            newestMessageRequestCount += 1
            return MessagePage(messages: [], hasMoreBefore: false)
        }
        earlierPageRequestCount += 1
        if suspendsOperations {
            await withCheckedContinuation { earlierContinuations.append($0) }
        }
        let message = Message(
            id: MessageID(rawValue: requestedChannelID == channelID ? 96_005 : 96_006),
            channelID: requestedChannelID,
            author: user,
            content: "old account earlier page"
        )
        return MessagePage(messages: [message], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        sendStarted = true
        if suspendsOperations {
            await withCheckedContinuation { sendContinuation = $0 }
        }
        return Message(
            id: MessageID(rawValue: 96_011),
            channelID: draft.channelID,
            author: user,
            content: draft.content,
            nonce: draft.nonce
        )
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        editStarted = true
        if suspendsOperations {
            await withCheckedContinuation { editContinuation = $0 }
        }
        var edited = editTarget
        edited.content = content
        return edited
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func applicationCommandCatalog(
        for target: ApplicationCommandIndexTarget
    ) async throws -> ApplicationCommandCatalog {
        applicationCommandRequestCount += 1
        return ApplicationCommandCatalog(target: target)
    }

    func subscribeToPrivateCall(channelID: ChannelID) async throws {
        privateCallSubscriptionRequestCount += 1
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        voiceStateUpdateRequestCount += 1
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func waitUntilMutationRequestsStart() async -> Bool {
        for _ in 0 ..< 5_000 {
            if sendStarted, editStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func releaseMutationRequests() {
        sendContinuation?.resume()
        sendContinuation = nil
        editContinuation?.resume()
        editContinuation = nil
    }

    func waitUntilSendRequestStarts() async -> Bool {
        for _ in 0 ..< 5_000 {
            if sendStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func sendRequestHasStarted() -> Bool {
        sendStarted
    }

    func releaseSendRequest() {
        sendContinuation?.resume()
        sendContinuation = nil
    }

    func waitUntilEarlierPageRequestsStart(expected: Int) async -> Bool {
        for _ in 0 ..< 5_000 {
            if earlierPageRequestCount >= expected { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func releaseEarlierPageRequests() {
        earlierContinuations.forEach { $0.resume() }
        earlierContinuations.removeAll()
    }
}

private actor SuspendedAccountLoadTestProvider: ChatProvider {
    nonisolated let guildID = GuildID(rawValue: 91_000)
    nonisolated let forumID = ChannelID(rawValue: 91_001)
    nonisolated let post: ForumPost
    nonisolated let snapshot: BootstrapSnapshot

    private let member: Member
    private let suspendsLoads: Bool
    private var memberContinuation: CheckedContinuation<[Member], Never>?
    private var forumContinuation: CheckedContinuation<ForumPostPage, Never>?
    private var memberLoadStarted = false
    private var forumLoadStarted = false
    private var memberLoadReturned = false
    private var forumLoadReturned = false

    init(label: String, suspendsLoads: Bool) {
        self.suspendsLoads = suspendsLoads
        let guild = Guild(
            id: guildID,
            name: "Shared guild",
            currentUserPermissions: .max
        )
        let forum = Channel(
            id: forumID,
            guildID: guildID,
            name: "shared-forum",
            kind: .forum
        )
        let currentUser = User(
            id: UserID(rawValue: 91_002),
            username: "account-load-user",
            displayName: "Account Load User"
        )
        member = Member(
            user: User(
                id: UserID(rawValue: 91_003),
                username: "shared-member",
                displayName: "\(label) member"
            ),
            roleName: "Member",
            isOnline: true
        )
        post = ForumPost(
            thread: MessageThreadSummary(
                id: ChannelID(rawValue: 91_004),
                guildID: guildID,
                parentID: forumID,
                name: "\(label) post",
                createdAt: Date(timeIntervalSince1970: 91_004)
            )
        )
        snapshot = BootstrapSnapshot(
            currentUser: currentUser,
            guilds: [guild],
            channels: [forum],
            members: []
        )
    }

    func bootstrap() async throws -> BootstrapSnapshot { snapshot }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        snapshot.channels.filter { $0.guildID == guildID }
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        guard guildID == self.guildID else { return [] }
        memberLoadStarted = true
        let value: [Member]
        if suspendsLoads {
            value = await withCheckedContinuation { memberContinuation = $0 }
        } else {
            value = [member]
        }
        memberLoadReturned = true
        return value
    }

    func roles(in guildID: GuildID) async throws -> [GuildRole] { [] }

    func forumPosts(
        in channelID: ChannelID,
        query _: ForumPostQuery
    ) async throws -> ForumPostPage {
        guard channelID == forumID else {
            throw ChatProviderError.channelNotFound
        }
        forumLoadStarted = true
        let page: ForumPostPage
        if suspendsLoads {
            page = await withCheckedContinuation { forumContinuation = $0 }
        } else {
            page = ForumPostPage(posts: [post], hasMore: false, nextOffset: nil)
        }
        forumLoadReturned = true
        return page
    }

    func waitUntilLoadsStart() async -> Bool {
        for _ in 0 ..< 500 {
            if memberLoadStarted, forumLoadStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func releaseSuspendedLoads() {
        memberContinuation?.resume(returning: [member])
        memberContinuation = nil
        forumContinuation?.resume(returning: ForumPostPage(
            posts: [post],
            hasMore: false,
            nextOffset: nil
        ))
        forumContinuation = nil
    }

    func waitUntilLoadsReturn() async -> Bool {
        for _ in 0 ..< 500 {
            if memberLoadReturned, forumLoadReturned { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func profile(
        for userID: UserID,
        in guildID: GuildID?
    ) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(
        in channelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}

private actor FirstGuildVisitPermissionTestProvider: ChatProvider {
    nonisolated let guildID = GuildID(rawValue: 77_200)
    nonisolated let channelID = ChannelID(rawValue: 77_202)

    private let user = User(
        id: UserID(rawValue: 77_201),
        username: "permission-loading-user",
        displayName: "Permission Loading User"
    )
    private var roleContinuation: CheckedContinuation<[GuildRole], Never>?
    private var recordedMessageRequestCount = 0

    private var guild: Guild {
        Guild(id: guildID, name: "Permission Loading Guild")
    }

    private var channel: Channel {
        Channel(id: channelID, guildID: guildID, name: "general")
    }

    private var everyoneRole: GuildRole {
        GuildRole(
            id: RoleID(rawValue: guildID.rawValue),
            name: "@everyone",
            permissions: DiscordPermissionBits.viewChannel
                | DiscordPermissionBits.readMessageHistory
                | DiscordPermissionBits.sendMessages
        )
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            channels: [channel],
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == self.guildID ? [channel] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        guard guildID == self.guildID else { return [] }
        return [Member(user: user, roleName: "Member", status: .online)]
    }

    func roles(in guildID: GuildID) async throws -> [GuildRole] {
        guard guildID == self.guildID else { return [] }
        return await withCheckedContinuation { continuation in
            roleContinuation = continuation
        }
    }

    func waitUntilRoleRequestStarts() async -> Bool {
        for _ in 0 ..< 500 {
            if roleContinuation != nil { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func releaseRoles() {
        roleContinuation?.resume(returning: [everyoneRole])
        roleContinuation = nil
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(
        in channelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        recordedMessageRequestCount += 1
        return MessagePage(
            messages: [
                Message(
                    id: MessageID(rawValue: 77_203),
                    channelID: channelID,
                    author: user,
                    content: "Loaded automatically",
                    guildID: guildID
                ),
            ],
            hasMoreBefore: false
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {
        releaseRoles()
    }

    func messageRequestCount() -> Int {
        recordedMessageRequestCount
    }
}

private actor StartupUnreadTestProvider: ChatProvider {
    private let guild = Guild(
        id: GuildID(rawValue: 77_000),
        name: "Startup Guild",
        currentUserPermissions: .max
    )
    private let user = User(
        id: UserID(rawValue: 77_001),
        username: "startup-tester",
        displayName: "Startup Tester"
    )
    private let channel = Channel(
        id: ChannelID(rawValue: 77_002),
        guildID: GuildID(rawValue: 77_000),
        name: "general",
        lastMessageID: MessageID(rawValue: 77_200)
    )

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            guildRailItems: [
                .folder(
                    GuildFolder(id: 77, name: "Startup", guildIDs: [guild.id])
                )
            ],
            channels: [channel],
            members: [],
            readStates: [
                ChannelReadState(
                    channelID: channel.id,
                    lastAcknowledgedMessageID: MessageID(rawValue: 77_100),
                    mentionCount: 2
                )
            ]
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == guild.id ? [channel] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {
        throw ChatProviderError.invalidRequest("Deleting is not part of this test.")
    }

    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {
        throw ChatProviderError.invalidRequest("Reactions are not part of this test.")
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}

private actor ForumVisitAcknowledgementTestProvider: ChatProvider {
    struct Acknowledgement: Sendable {
        var channelID: ChannelID
        var messageID: MessageID
    }

    nonisolated let forumID = ChannelID(rawValue: 96_002)
    nonisolated let newPostID = ChannelID(rawValue: 96_300)
    nonisolated let unreadPostID = ChannelID(rawValue: 96_240)
    private let guild = Guild(
        id: GuildID(rawValue: 96_000),
        name: "Forum Visits",
        currentUserPermissions: .max
    )
    private let user = User(
        id: UserID(rawValue: 96_001),
        username: "forum-visitor",
        displayName: "Forum Visitor"
    )
    private var recordedAcknowledgements: [Acknowledgement] = []

    private var forum: Channel {
        Channel(
            id: forumID,
            guildID: guild.id,
            name: "forum",
            kind: .forum,
            lastMessageID: MessageID(rawValue: newPostID.rawValue)
        )
    }

    private var posts: [ForumPost] {
        [
            ForumPost(
                thread: MessageThreadSummary(
                    id: newPostID,
                    guildID: guild.id,
                    parentID: forumID,
                    name: "Brand new",
                    lastMessageID: MessageID(rawValue: newPostID.rawValue)
                )
            ),
            ForumPost(
                thread: MessageThreadSummary(
                    id: unreadPostID,
                    guildID: guild.id,
                    parentID: forumID,
                    name: "Unread replies",
                    lastMessageID: MessageID(rawValue: 96_500)
                ),
                isUnread: true
            ),
        ]
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            channels: [forum],
            members: [],
            readStates: [
                ChannelReadState(
                    channelID: forumID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 96_250)
                ),
                ChannelReadState(
                    channelID: unreadPostID,
                    lastAcknowledgedMessageID: MessageID(rawValue: 96_450)
                ),
            ]
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == guild.id ? [forum] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        guard channelID == forumID else { throw ChatProviderError.channelNotFound }
        return ForumPostPage(posts: posts, hasMore: false, nextOffset: nil)
    }

    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) async throws -> ReadAcknowledgementResponse {
        recordedAcknowledgements.append(
            Acknowledgement(channelID: channelID, messageID: messageID)
        )
        return ReadAcknowledgementResponse(token: token)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func acknowledgements() -> [Acknowledgement] {
        recordedAcknowledgements
    }
}

private actor ForumPaginationTestProvider: ChatProvider {
    private let guild = Guild(
        id: GuildID(rawValue: 95_000),
        name: "Forum Test",
        currentUserPermissions: .max
    )
    private let user = User(
        id: UserID(rawValue: 95_001),
        username: "forum-tester",
        displayName: "Forum Tester"
    )
    private let channel = Channel(
        id: ChannelID(rawValue: 95_002),
        guildID: GuildID(rawValue: 95_000),
        name: "forum",
        kind: .forum
    )
    private var paginationRequests = 0

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [guild],
            channels: [channel],
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        guildID == guild.id ? [channel] : []
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws
        -> ForumPostPage
    {
        guard channelID == channel.id else { throw ChatProviderError.channelNotFound }
        if query.offset == 0 {
            return ForumPostPage(
                posts: [
                    ForumPost(
                        thread: MessageThreadSummary(
                            id: ChannelID(rawValue: 95_010),
                            guildID: guild.id,
                            parentID: channel.id,
                            name: "Recent post",
                            createdAt: Date(timeIntervalSince1970: 200)
                        )
                    )
                ],
                hasMore: true,
                nextOffset: 1
            )
        }

        paginationRequests += 1
        if paginationRequests == 1 {
            throw ChatProviderError.invalidRequest("Older posts are temporarily unavailable.")
        }
        return ForumPostPage(
            posts: [
                ForumPost(
                    thread: MessageThreadSummary(
                        id: ChannelID(rawValue: 95_011),
                        guildID: guild.id,
                        parentID: channel.id,
                        name: "Older post",
                        isArchived: true,
                        archiveTimestamp: Date(timeIntervalSince1970: 100),
                        createdAt: Date(timeIntervalSince1970: 100)
                    )
                )
            ],
            hasMore: false,
            nextOffset: nil
        )
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func paginationRequestCount() -> Int {
        paginationRequests
    }
}

private actor LinkedChannelNavigationTestProvider: ChatProvider {
    private let firstGuild = Guild(id: GuildID(rawValue: 94_000), name: "First")
    private let secondGuild = Guild(id: GuildID(rawValue: 94_100), name: "Second")
    private let user = User(
        id: UserID(rawValue: 94_200),
        username: "navigator",
        displayName: "Navigator"
    )
    private let firstChannel = Channel(
        id: ChannelID(rawValue: 94_001),
        guildID: GuildID(rawValue: 94_000),
        name: "general"
    )
    let targetChannel = Channel(
        id: ChannelID(rawValue: 94_101),
        guildID: GuildID(rawValue: 94_100),
        name: "linked-channel"
    )
    private var forumPostRequests = 0

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: user,
            guilds: [firstGuild, secondGuild],
            channels: [],
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        switch guildID {
        case firstGuild.id: [firstChannel]
        case secondGuild.id: [targetChannel]
        default: []
        }
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func forumPost(threadID: ChannelID) async throws -> ForumPost {
        forumPostRequests += 1
        throw ChatProviderError.invalidRequest("Ordinary channels are not forum posts.")
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func forumPostRequestCount() -> Int {
        forumPostRequests
    }
}

private actor SuspendedBootstrapTestProvider: PendingCredentialChatProvider {
    private let user: User
    private let channel = Channel(id: ChannelID(rawValue: 93001), guildID: nil, name: "general")
    private var bootstrapStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var bootstrapContinuation: CheckedContinuation<Void, Never>?
    private let bootstrapError: String?
    private let pendingCredential: PendingDiscordCredential?
    private let suspendsAuthentication: Bool
    private var authenticationStarted = false
    private var authenticationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var authenticationReleased = false
    private var authenticationContinuation: CheckedContinuation<Void, Never>?
    private let suspendsMessages: Bool
    private let messagePage: MessagePage
    private var messageLoadStarted = false
    private var messageLoadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var messageLoadContinuation: CheckedContinuation<Void, Never>?
    private var nextSentMessageID: UInt64 = 94_000
    private var reactionRequestCount = 0
    private var reactionRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var disconnectCount = 0

    init(
        bootstrapError: String? = nil,
        pendingCredential: PendingDiscordCredential? = nil,
        suspendsAuthentication: Bool = false,
        suspendsMessages: Bool = false,
        messagePage: MessagePage = MessagePage(messages: [], hasMoreBefore: false),
        user: User = User(
            id: UserID(rawValue: 93000),
            username: "tester",
            displayName: "Tester"
        )
    ) {
        self.user = user
        self.bootstrapError = bootstrapError
        self.pendingCredential = pendingCredential
        self.suspendsAuthentication = suspendsAuthentication
        self.suspendsMessages = suspendsMessages
        self.messagePage = messagePage
    }

    func prepareAuthentication() async {
        guard suspendsAuthentication else { return }
        authenticationStarted = true
        authenticationStartWaiters.forEach { $0.resume() }
        authenticationStartWaiters.removeAll()
        guard !authenticationReleased else { return }
        await withCheckedContinuation { authenticationContinuation = $0 }
    }

    func persistPendingCredential(
        to store: any CredentialStore,
        accountID: String
    ) async throws -> CredentialHandle {
        guard let pendingCredential else {
            throw PendingDiscordCredentialError.unavailable
        }
        return try await pendingCredential.persist(to: store, accountID: accountID)
    }

    func discardPendingCredential() async {
        await pendingCredential?.discard()
    }

    func waitUntilAuthenticationStarts() async {
        if authenticationStarted {
            return
        }
        await withCheckedContinuation { authenticationStartWaiters.append($0) }
    }

    func releaseAuthentication() {
        authenticationReleased = true
        authenticationContinuation?.resume()
        authenticationContinuation = nil
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        bootstrapStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { bootstrapContinuation = $0 }
        if let bootstrapError {
            throw ChatProviderError.invalidRequest(bootstrapError)
        }
        return BootstrapSnapshot(currentUser: user, guilds: [], channels: [channel], members: [])
    }

    func waitUntilBootstrapStarts() async {
        if bootstrapStarted {
            return
        }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBootstrap() {
        bootstrapContinuation?.resume()
        bootstrapContinuation = nil
    }

    func waitUntilMessageLoadStarts() async {
        if messageLoadStarted {
            return
        }
        await withCheckedContinuation { messageLoadStartWaiters.append($0) }
    }

    func releaseMessageLoad() {
        messageLoadContinuation?.resume()
        messageLoadContinuation = nil
    }

    func waitUntilReactionRequest() async {
        if reactionRequestCount > 0 {
            return
        }
        await withCheckedContinuation { reactionRequestWaiters.append($0) }
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        if suspendsMessages {
            messageLoadStarted = true
            messageLoadStartWaiters.forEach { $0.resume() }
            messageLoadStartWaiters.removeAll()
            await withCheckedContinuation { messageLoadContinuation = $0 }
        }
        return messagePage
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        nextSentMessageID &+= 1
        return Message(
            id: MessageID(rawValue: nextSentMessageID),
            channelID: draft.channelID,
            author: user,
            content: draft.content,
            nonce: draft.nonce
        )
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        guard var message = messagePage.messages.first(where: { $0.id == messageID }) else {
            throw ChatProviderError.invalidRequest("The synthetic message does not exist.")
        }
        message.content = content
        return message
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {
        reactionRequestCount += 1
        reactionRequestWaiters.forEach { $0.resume() }
        reactionRequestWaiters.removeAll()
    }
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {
        disconnectCount += 1
    }
}

private actor RestoredCredentialHandleStore: CredentialStore {
    private let handle: CredentialHandle

    init(handle: CredentialHandle) {
        self.handle = handle
    }

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("credential".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        [handle]
    }
}

@MainActor
private final class PermissionRecordingNotificationService: NativeNotificationService {
    private(set) var authorizationRequestCount = 0
    private var status: UNAuthorizationStatus = .notDetermined

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        status = .authorized
        return true
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func deliver(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {}

    func cancel(accountID: String, channelID: ChannelID) async {}

    func setDockBadge(_ count: Int, enabled: Bool) {}
}

@MainActor
private final class SuspendedAccountNotificationService: NativeNotificationService {
    private(set) var publishedMessageIDs: [MessageID] = []
    private var deliveryStarted = false
    private var deliveryContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func requestAuthorization() async throws -> Bool { true }
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }

    func deliver(
        message: Message,
        channel: Channel?,
        guild: Guild?,
        accountID: String,
        preferences: NotificationPreferences
    ) async {
        deliveryStarted = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters = []
        await withCheckedContinuation { continuation in
            deliveryContinuation = continuation
        }
        guard !Task.isCancelled else { return }
        publishedMessageIDs.append(message.id)
    }

    func cancel(accountID: String, channelID: ChannelID) async {}
    func setDockBadge(_ count: Int, enabled: Bool) {}

    func waitUntilDeliveryStarts() async {
        guard !deliveryStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseDelivery() {
        deliveryContinuation?.resume()
        deliveryContinuation = nil
    }
}

private actor VoiceMigrationTestProvider: ChatProvider {
    private let guild = Guild(
        id: GuildID(rawValue: 92000),
        name: "Voice Test",
        currentUserPermissions: .max
    )
    private let user = User(id: UserID(rawValue: 92001), username: "tester", displayName: "Tester")
    private let channel = Channel(
        id: ChannelID(rawValue: 92002),
        guildID: GuildID(rawValue: 92000),
        name: "Lounge",
        kind: .voice
    )
    private var continuation: AsyncStream<ClientEvent>.Continuation?

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [guild], channels: [channel], members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        connectionInfo(token: "initial")
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { continuation = $0 }
    }

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }

    func connectionInfo(token: String) -> VoiceConnectionInfo {
        VoiceConnectionInfo(
            serverID: guild.id.description,
            channelID: channel.id,
            guildID: guild.id,
            userID: user.id,
            sessionID: "session",
            token: token,
            endpoint: "mock.sakuracord.invalid"
        )
    }
}

private struct PrivateCallActionRequestCounts: Equatable, Sendable {
    var subscriptions = 0
    var ringabilityReads = 0
    var voiceJoins = 0
    var rings = 0
    var declines = 0
}

private actor PrivateCallActionTestProvider: ChatProvider {
    private let currentUser = User(
        id: UserID(rawValue: 88_810),
        username: "call-tester",
        displayName: "Call Tester"
    )
    private let recipient = User(
        id: UserID(rawValue: 88_811),
        username: "recipient",
        displayName: "Recipient"
    )
    private var requestCounts = PrivateCallActionRequestCounts()
    private var ringabilityContinuation: CheckedContinuation<Void, Never>?
    private var declineContinuation: CheckedContinuation<Void, Never>?

    private var channel: Channel {
        Channel(
            id: ChannelID(rawValue: 88_812),
            guildID: nil,
            name: "Recipient",
            kind: .directMessage,
            recipients: [recipient]
        )
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(
            currentUser: currentUser,
            guilds: [],
            channels: [channel],
            members: []
        )
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(
        for userID: UserID,
        in guildID: GuildID?
    ) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest(
            "Profiles are not part of this test."
        )
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(
        in channelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest(
            "Sending is not part of this test."
        )
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        throw ChatProviderError.invalidRequest(
            "Editing is not part of this test."
        )
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func subscribeToPrivateCall(channelID: ChannelID) async throws {
        requestCounts.subscriptions += 1
    }

    func privateCallIsRingable(channelID: ChannelID) async throws -> Bool {
        requestCounts.ringabilityReads += 1
        await withCheckedContinuation { continuation in
            ringabilityContinuation = continuation
        }
        return true
    }

    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        requestCounts.voiceJoins += 1
        return VoiceConnectionInfo(
            serverID: channelID.description,
            channelID: channelID,
            guildID: nil,
            userID: currentUser.id,
            sessionID: "private-call-action-test",
            token: "synthetic",
            endpoint: "mock.sakuracord.invalid"
        )
    }

    func ringPrivateCall(
        channelID: ChannelID,
        recipients: [UserID]?
    ) async throws {
        requestCounts.rings += 1
    }

    func stopRingingPrivateCall(
        channelID: ChannelID,
        recipients: [UserID]
    ) async throws {
        requestCounts.declines += 1
        await withCheckedContinuation { continuation in
            declineContinuation = continuation
        }
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { _ in }
    }

    func disconnect() async {}

    func counts() -> PrivateCallActionRequestCounts {
        requestCounts
    }

    func waitUntilRingabilityStarts() async {
        while requestCounts.ringabilityReads == 0 {
            await Task.yield()
        }
    }

    func releaseRingability() {
        ringabilityContinuation?.resume()
        ringabilityContinuation = nil
    }

    func waitUntilDeclineStarts() async {
        while requestCounts.declines == 0 {
            await Task.yield()
        }
    }

    func releaseDecline() {
        declineContinuation?.resume()
        declineContinuation = nil
    }
}

private actor DelayedMemberViewportTestProvider: ChatProvider {
    struct ViewportRequest: Equatable, Sendable {
        let guildID: GuildID
        let channelID: ChannelID
        let visibleRange: ClosedRange<Int>
    }

    private let base = MockChatProvider()
    private var memberLoadStarted = false
    private var memberLoadReleased = false
    private var memberSubscriptionArmed = false
    private var memberLoadContinuation: CheckedContinuation<Void, Never>?
    private var viewportAttempts: [ViewportRequest] = []
    private var acceptedViewports: [ViewportRequest] = []

    func bootstrap() async throws -> BootstrapSnapshot {
        try await base.bootstrap()
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        try await base.channels(in: guildID)
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        memberLoadStarted = true
        if !memberLoadReleased {
            await withCheckedContinuation { continuation in
                memberLoadContinuation = continuation
            }
        }
        memberSubscriptionArmed = true
        return try await base.members(in: guildID)
    }

    func updateMemberListViewport(
        in guildID: GuildID,
        channelID: ChannelID,
        visibleRange: ClosedRange<Int>
    ) async throws {
        let request = ViewportRequest(
            guildID: guildID,
            channelID: channelID,
            visibleRange: visibleRange
        )
        viewportAttempts.append(request)
        if memberSubscriptionArmed {
            acceptedViewports.append(request)
        }
    }

    func profile(
        for userID: UserID,
        in guildID: GuildID?
    ) async throws -> UserProfile {
        try await base.profile(for: userID, in: guildID)
    }

    func currentStatus() async -> PresenceStatus {
        await base.currentStatus()
    }

    func updateStatus(_ status: PresenceStatus) async throws {
        try await base.updateStatus(status)
    }

    func messages(
        in channelID: ChannelID,
        before: MessageID?,
        limit: Int
    ) async throws -> MessagePage {
        try await base.messages(in: channelID, before: before, limit: limit)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(
        messageID: MessageID,
        channelID: ChannelID,
        content: String
    ) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}

    func toggleReaction(
        _ emoji: String,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {}

    func eventStream() async -> AsyncStream<ClientEvent> {
        await base.eventStream()
    }

    func disconnect() async {
        memberLoadContinuation?.resume()
        memberLoadContinuation = nil
        await base.disconnect()
    }

    func waitUntilMemberLoadStarts() async -> Bool {
        for _ in 0 ..< 5_000 {
            if memberLoadStarted { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return memberLoadStarted
    }

    func waitUntilViewportAttemptCount(_ expectedCount: Int) async -> Bool {
        for _ in 0 ..< 5_000 {
            if viewportAttempts.count >= expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return viewportAttempts.count >= expectedCount
    }

    func waitUntilAcceptedViewportCount(_ expectedCount: Int) async -> Bool {
        for _ in 0 ..< 5_000 {
            if acceptedViewports.count >= expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return acceptedViewports.count >= expectedCount
    }

    func acceptedViewportRequests() -> [ViewportRequest] {
        acceptedViewports
    }

    func disarmMemberSubscription() {
        memberSubscriptionArmed = false
    }

    func releaseMemberLoad() {
        memberLoadReleased = true
        memberLoadContinuation?.resume()
        memberLoadContinuation = nil
    }
}
