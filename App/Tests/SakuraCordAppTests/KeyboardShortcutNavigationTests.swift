@testable import SakuraCord
import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@MainActor
struct KeyboardShortcutNavigationTests {
    @Test func `sidebar thread traversal includes its parent and hides parent read presentation`() {
        let model = makeModel()
        let parentID = ChannelID(rawValue: 10)
        let thread = MessageThreadSummary(
            id: ChannelID(rawValue: 1000), guildID: GuildID(rawValue: 1), parentID: parentID,
            name: "Thread", archiveTimestamp: .now, autoArchiveDuration: 1440,
            notificationSettings: ThreadNotificationSettings(joinedAt: .now)
        )
        model.snapshot?.activeJoinedThreads = [thread]
        model.selectedChannelID = parentID
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: false) == thread.id)
        model.sideConversations.thread = .thread(thread, isFullWidth: true)
        #expect(model.isConversationPresented(thread.id))
        #expect(!model.isConversationPresented(parentID))
        #expect(model.keyboardShortcutConversationDestination(direction: -1, unreadOnly: false) == parentID)
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: false) == ChannelID(rawValue: 11))
        model.closeThread()
        #expect(model.isConversationPresented(parentID))
    }

    @Test func `channel shortcuts wrap within the current server and skip inaccessible channels`() {
        let model = makeModel()
        model.selectedChannelID = ChannelID(rawValue: 12)
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: false) == ChannelID(rawValue: 10))
        model.selectedChannelID = ChannelID(rawValue: 10)
        #expect(model.keyboardShortcutConversationDestination(direction: -1, unreadOnly: false) == ChannelID(rawValue: 12))

        model.hiddenChannelIDs = [ChannelID(rawValue: 11)]
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: false) == ChannelID(rawValue: 12))
        model.checkingChannelIDs = [ChannelID(rawValue: 12)]
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: false) == nil)

        model.hiddenChannelIDs = []
        model.checkingChannelIDs = []
        model.applyNotificationSettings(.init(guildID: GuildID(rawValue: 1), hideMutedChannels: true,
            channelOverrides: [.init(channelID: ChannelID(rawValue: 11), isMuted: true)]))
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: false) == ChannelID(rawValue: 12))
        #expect(model.hasKeyboardShortcutConversationDestination(unreadOnly: false))
        model.updateLocalChannelNotificationOverride(guildID: GuildID(rawValue: 1), channelID: ChannelID(rawValue: 12)) {
            $0.isMuted = true
        }
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: false) == nil)
        #expect(!model.hasKeyboardShortcutConversationDestination(unreadOnly: false))
    }

    @Test func `unread shortcuts keep their position across read channels and wrap across servers`() {
        let model = makeModel()
        model.selectedChannelID = ChannelID(rawValue: 11)
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true) == ChannelID(rawValue: 12))
        #expect(model.keyboardShortcutConversationDestination(direction: -1, unreadOnly: true) == ChannelID(rawValue: 10))

        model.selectedChannelID = ChannelID(rawValue: 12)
        model.checkingChannelIDs = [ChannelID(rawValue: 20)]
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true) == ChannelID(rawValue: 20))
        model.hiddenChannelIDs = [ChannelID(rawValue: 20)]
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true) == ChannelID(rawValue: 30))
        model.readState.setAccessible(false, channelID: ChannelID(rawValue: 30))
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true) == ChannelID(rawValue: 10))

        model.selectedGuildID = GuildID(rawValue: 3)
        model.selectedChannelID = ChannelID(rawValue: 30)
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true) == ChannelID(rawValue: 10))
        #expect(model.keyboardShortcutConversationDestination(direction: -1, unreadOnly: true) == ChannelID(rawValue: 12))
        model.readState.reset(accountID: nil)
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true) == nil)
    }

    @Test func `server shortcuts wrap in rail order including folders and skip missing servers`() {
        let model = makeModel()
        #expect(model.keyboardShortcutServerDestination(direction: 1) == .guild(GuildID(rawValue: 2)))
        let removed = model.serverRailGuildsByID.removeValue(forKey: GuildID(rawValue: 2))
        #expect(model.keyboardShortcutServerDestination(direction: 1) == .guild(GuildID(rawValue: 3)))
        #expect(!model.serverRailPresentation.navigationGuildIDs.contains(GuildID(rawValue: 2)))
        model.serverRailGuildsByID[GuildID(rawValue: 2)] = removed
        #expect(model.keyboardShortcutServerDestination(direction: 1) == .guild(GuildID(rawValue: 2)))
        #expect(model.keyboardShortcutServerDestination(direction: -1) == .directMessages)
        model.selectedGuildID = GuildID(rawValue: 3)
        #expect(model.keyboardShortcutServerDestination(direction: 1) == .directMessages)
        #expect(model.keyboardShortcutServerDestination(direction: -1) == .guild(GuildID(rawValue: 2)))
        model.selectedGuildID = nil
        #expect(model.keyboardShortcutServerDestination(direction: 1) == .guild(GuildID(rawValue: 1)))
        #expect(model.keyboardShortcutServerDestination(direction: -1) == .guild(GuildID(rawValue: 3)))
        model.serverRailItems = [.guild(GuildID(rawValue: 1))]
        model.selectedGuildID = GuildID(rawValue: 1)
        #expect(model.keyboardShortcutServerDestination(direction: 1) == .directMessages)
        model.serverRailItems = []
        model.selectedGuildID = nil
        #expect(model.keyboardShortcutServerDestination(direction: -1) == nil)
    }

    @Test func `mention shortcuts skip unread channels without mentions across servers`() {
        let model = makeModel()
        model.readState.applyRemote(ChannelReadState(
            channelID: ChannelID(rawValue: 20),
            lastAcknowledgedMessageID: MessageID(rawValue: 50),
            mentionCount: 2
        ))
        model.selectedChannelID = ChannelID(rawValue: 10)
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true, mentionsOnly: true) == ChannelID(rawValue: 20))
        #expect(model.keyboardShortcutConversationDestination(direction: -1, unreadOnly: true, mentionsOnly: true) == ChannelID(rawValue: 20))
        model.readState.setAccessible(false, channelID: ChannelID(rawValue: 20))
        #expect(model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true, mentionsOnly: true) == nil)
    }

    @Test func `menu availability matches ordered navigation without constructing destinations`() {
        let model = makeModel()
        model.readState.applyRemote(ChannelReadState(channelID: ChannelID(rawValue: 20),
                                                    lastAcknowledgedMessageID: MessageID(rawValue: 50), mentionCount: 2))
        for selected in [10, 11, 12, 20, 30, 999] {
            model.selectedChannelID = ChannelID(rawValue: UInt64(selected))
            for hidden in [Set<ChannelID>(), [ChannelID(rawValue: 10), ChannelID(rawValue: 20)]] {
                model.hiddenChannelIDs = hidden
                for unreadOnly in [false, true] {
                    for mentionsOnly in [false, true] {
                        #expect(model.hasKeyboardShortcutConversationDestination(unreadOnly: unreadOnly, mentionsOnly: mentionsOnly)
                            == (model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: unreadOnly, mentionsOnly: mentionsOnly) != nil))
                    }
                }
            }
        }
        // A cached navigation candidate must follow both in-place snapshot
        // edits and account teardown, even while read entries still exist.
        model.selectedChannelID = ChannelID(rawValue: 10)
        model.hiddenChannelIDs = []
        #expect(model.hasKeyboardShortcutConversationDestination(unreadOnly: true, mentionsOnly: true))
        let originalSnapshot = model.snapshot
        model.snapshot?.channels.reverse()
        #expect(model.hasKeyboardShortcutConversationDestination(unreadOnly: true, mentionsOnly: true))
        model.snapshot?.channels.removeAll { $0.id == ChannelID(rawValue: 20) }
        #expect(!model.hasKeyboardShortcutConversationDestination(unreadOnly: true, mentionsOnly: true))
        model.snapshot = originalSnapshot
        #expect(model.hasKeyboardShortcutConversationDestination(unreadOnly: true, mentionsOnly: true))
        model.snapshot = nil
        #expect(!model.hasKeyboardShortcutConversationDestination(unreadOnly: true, mentionsOnly: true))
        model.snapshot = originalSnapshot
        model.readState.reset(accountID: nil)
        #expect(!model.hasKeyboardShortcutConversationDestination(unreadOnly: true))
        model.serverRailItems = []
        #expect(model.hasKeyboardShortcutConversationDestination(unreadOnly: true)
            == (model.keyboardShortcutConversationDestination(direction: 1, unreadOnly: true) != nil))
    }

    @Test func `conversation history commits visits and skips unavailable destinations`() throws {
        let channels = (1 ... 4).map {
            Channel(id: ChannelID(rawValue: UInt64($0)), guildID: nil, name: "Channel \($0)")
        }
        let available = Set(channels.map(\.id))
        var history = ConversationNavigationHistory()
        for channel in channels.prefix(3) { history.record(channel) }

        let back = try #require(history.destination(direction: -1, isAvailable: available.contains))
        let traversal = history.beginNavigation(to: back)
        history.record(channels[0]) // Guild activation's intermediate selection.
        history.finishNavigation(traversal, at: channels[1])
        #expect(history.previousTextChannelID == channels[2].id)
        #expect(history.destination(direction: 1, isAvailable: available.contains)?.channelID == channels[2].id)

        // Superseding a pending traversal must retain the last committed visit.
        let pendingBack = try #require(history.destination(direction: -1, isAvailable: available.contains))
        let cancelled = history.beginNavigation(to: pendingBack)
        let replacement = history.beginNavigation()
        history.finishNavigation(cancelled, at: channels[0])
        history.record(channels[2])
        history.finishNavigation(replacement, at: channels[3])
        #expect(history.previousTextChannelID == channels[1].id)
        #expect(history.destination(direction: -1, isAvailable: available.contains)?.channelID == channels[1].id)
        #expect(history.destination(direction: 1, isAvailable: available.contains) == nil)

        let remaining = available.subtracting([channels[1].id])
        let pastDeletedChannel = try #require(history.destination(direction: -1, isAvailable: remaining.contains))
        #expect(pastDeletedChannel.channelID == channels[0].id)
        let cancelledTraversal = history.beginNavigation(to: pastDeletedChannel)
        history.finishNavigation(cancelledTraversal, at: nil)
        #expect(history.destination(direction: -1, isAvailable: remaining.contains) == pastDeletedChannel)
        let completedTraversal = history.beginNavigation(to: pastDeletedChannel)
        history.finishNavigation(completedTraversal, at: channels[0])
        #expect(history.destination(direction: 1, isAvailable: remaining.contains)?.channelID == channels[3].id)
    }

    @Test func `cross server navigation commits only the requested conversation`() async {
        let model = makeModel()
        let original = ChannelID(rawValue: 10)
        let remembered = ChannelID(rawValue: 20)
        let target = Channel(id: ChannelID(rawValue: 21), guildID: GuildID(rawValue: 2), name: "Target")
        model.snapshot?.channels.append(target)
        model.lastOpenedChannelIDsByGuild[GuildID(rawValue: 2)] = remembered
        model.channelSidebarSelection = original
        model.navigate(to: target.id)
        await model.guildActivationTask?.value

        #expect(model.selectedChannelID == target.id)
        #expect(model.conversationNavigationHistory.previousTextChannelID == original)
        #expect(model.keyboardShortcutHistoryDestination(direction: -1)?.channelID == original)
        model.navigateConversationHistory(direction: -1)
        await model.guildActivationTask?.value
        #expect(model.selectedChannelID == original)
        #expect(model.keyboardShortcutHistoryDestination(direction: 1)?.channelID == target.id)
    }

    @Test func `sidebar navigation supersedes tasks before startup and during suspension`() async {
        let model = makeModel()
        model.channelSidebarSelection = ChannelID(rawValue: 10)
        model.navigate(to: ChannelID(rawValue: 20))
        let neverStarted = model.guildActivationTask
        model.channelSidebarSelection = ChannelID(rawValue: 11)
        await neverStarted?.value
        #expect(model.keyboardShortcutHistoryDestination(direction: -1)?.channelID == ChannelID(rawValue: 10))

        var resumeNavigation: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { started in
            model.startConversationNavigation { model, _ in
                model.selectedChannelID = ChannelID(rawValue: 20)
                await withCheckedContinuation { continuation in
                    resumeNavigation = continuation
                    started.resume()
                }
            }
        }
        let suspended = model.guildActivationTask
        model.channelSidebarSelection = ChannelID(rawValue: 12)
        resumeNavigation?.resume()
        await suspended?.value
        #expect(model.selectedChannelID == ChannelID(rawValue: 12))
        #expect(model.conversationNavigationHistory.previousTextChannelID == ChannelID(rawValue: 11))
        #expect(model.keyboardShortcutHistoryDestination(direction: -1)?.channelID == ChannelID(rawValue: 11))
    }

    @Test func `DM shortcuts follow sidebar order including Friends and restore the last page`() async {
        let model = makeModel()
        let first = Channel(id: ChannelID(rawValue: 101), guildID: nil, name: "Zebra", kind: .directMessage)
        let second = Channel(id: ChannelID(rawValue: 102), guildID: nil, name: "Alpha", kind: .groupDirectMessage)
        model.snapshot?.channels.append(contentsOf: [first, second])
        model.openFriends()
        await model.guildActivationTask?.value
        #expect(model.isFriendsPresented)
        #expect(model.hasKeyboardShortcutConversationDestination(unreadOnly: false))
        #expect(model.keyboardShortcutDirectMessageDestination(direction: 1) == .channel(first.id))
        #expect(model.keyboardShortcutDirectMessageDestination(direction: -1) == .channel(second.id))

        model.navigateShortcutConversation(direction: 1, unreadOnly: false)
        await model.guildActivationTask?.value
        #expect(model.selectedChannelID == first.id)
        #expect(!model.isFriendsPresented)
        #expect(model.keyboardShortcutDirectMessageDestination(direction: -1) == .friends)
        model.navigateShortcutConversation(direction: 1, unreadOnly: false)
        await model.guildActivationTask?.value
        #expect(model.selectedChannelID == second.id)

        model.selectGuild(GuildID(rawValue: 1))
        await model.guildActivationTask?.value
        model.navigateShortcutServer(direction: -1)
        await model.guildActivationTask?.value
        #expect(model.selectedGuildID == nil)
        #expect(model.selectedChannelID == second.id)
        #expect(!model.isFriendsPresented)

        model.navigateShortcutConversation(direction: 1, unreadOnly: false)
        #expect(model.isFriendsPresented)
        model.selectGuild(GuildID(rawValue: 1))
        await model.guildActivationTask?.value
        model.selectGuild(nil)
        await model.guildActivationTask?.value
        #expect(model.isFriendsPresented)
        #expect(model.selectedChannelID == nil)
        model.invalidateAccountSession()
        #expect(model.lastDirectMessageSelection == nil)
    }

    @Test func `DM restoration drops closed conversations and empty DM shortcuts are disabled`() async {
        let model = makeModel()
        let channel = Channel(id: ChannelID(rawValue: 101), guildID: nil, name: "DM", kind: .directMessage)
        model.snapshot?.channels.append(channel)
        model.navigate(to: channel.id)
        await model.guildActivationTask?.value
        model.selectGuild(GuildID(rawValue: 1))
        await model.guildActivationTask?.value
        model.snapshot?.channels.removeAll { $0.id == channel.id }
        if let snapshot = model.snapshot { model.provider = MockChatProvider(snapshot: snapshot, messages: []) }
        model.selectGuild(nil)
        await model.guildActivationTask?.value
        #expect(model.selectedChannelID != channel.id)
        #expect(model.isFriendsPresented)
        #expect(model.lastDirectMessageSelection == .friends)
        #expect(!model.hasKeyboardShortcutConversationDestination(unreadOnly: false))
        #expect(model.keyboardShortcutDirectMessageDestination(direction: 1) == nil)
    }

    private func makeModel() -> AppModel {
        let model = AppModel(launchMode: .offlineTesting)
        let guilds = (1 ... 3).map {
            Guild(id: GuildID(rawValue: UInt64($0)), name: "Server \($0)", defaultMessageNotifications: .allMessages)
        }
        let channels = [10, 11, 12, 20, 30].map { id in
            Channel(
                id: ChannelID(rawValue: UInt64(id)),
                guildID: GuildID(rawValue: UInt64(id / 10)),
                name: "Channel \(id)",
                position: id % 10,
                lastMessageID: MessageID(rawValue: 100)
            )
        }
        model.snapshot = BootstrapSnapshot(
            currentUser: User(id: UserID(rawValue: 1), username: "current", displayName: "Current"),
            guilds: guilds.reversed(),
            channels: channels.reversed(),
            members: []
        )
        model.serverRailGuildsByID = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
        model.serverRailItems = [
            .guild(guilds[0].id),
            .folder(GuildFolder(id: 1, guildIDs: [guilds[1].id, GuildID(rawValue: 999)])),
            .guild(guilds[2].id),
        ]
        model.selectedGuildID = guilds[0].id
        model.visibleChannels = channels.filter { $0.guildID == guilds[0].id }.reversed()
        model.readState.configure(
            accountID: "shortcut-navigation-tests",
            guilds: guilds,
            channels: channels,
            readStates: channels.map {
                ChannelReadState(
                    channelID: $0.id,
                    lastAcknowledgedMessageID: MessageID(rawValue: $0.id.rawValue == 11 ? 100 : 50)
                )
            },
            notificationSettings: []
        )
        return model
    }
}
