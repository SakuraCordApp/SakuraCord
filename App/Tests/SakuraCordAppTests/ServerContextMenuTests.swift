import AppKit
import DiscordProtocol
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `server context menu matches channel menu structure and actions`() throws {
    var markedRead = false
    var mutedFor: ChannelMuteDuration?
    var selectedLevel: MessageNotificationLevel?
    var copiedID = false
    let bridge = ServerContextMenuBridge(
        isUnread: true,
        isMutationPending: false,
        notificationSettings: GuildNotificationSettings(
            guildID: GuildID(rawValue: 100),
            messageNotifications: .onlyMentions
        ),
        markRead: { markedRead = true },
        mute: { mutedFor = $0 },
        unmute: {},
        setNotificationLevel: { selectedLevel = $0 },
        copyServerID: { copiedID = true }
    )

    let coordinator = bridge.makeCoordinator()
    let menu = coordinator.makeMenu()
    #expect(
        menu.items.map { $0.isSeparatorItem ? nil : $0.title }
            == [
                "Mark as Read",
                nil,
                "Mute Server",
                "Notification Settings",
                nil,
                "Copy Server ID",
            ]
    )
    #expect(menu.item(withTitle: "Mark as Read")?.isEnabled == true)
    #expect(
        menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil }
    )

    let muteMenu = try #require(menu.item(withTitle: "Mute Server")?.submenu)
    #expect(muteMenu.items.map(\.title) == ChannelMuteDuration.allCases.map(\.title))
    let notifications = try #require(
        menu.item(withTitle: "Notification Settings")?.submenu
    )
    #expect(
        notifications.items.map(\.title)
            == ["All Messages", "Only @mentions", "Nothing"]
    )
    #expect(notifications.item(withTitle: "Only @mentions")?.state == .on)
    #expect(menu.item(withTitle: "Notification Settings")?.subtitle == "Only @mentions")

    _ = menu.item(withTitle: "Mark as Read")?.target?.perform(
        menu.item(withTitle: "Mark as Read")?.action
    )
    let oneHour = try #require(muteMenu.item(withTitle: "For 1 Hour"))
    _ = oneHour.target?.perform(oneHour.action, with: oneHour)
    let nothing = try #require(notifications.item(withTitle: "Nothing"))
    _ = nothing.target?.perform(nothing.action, with: nothing)
    _ = menu.item(withTitle: "Copy Server ID")?.target?.perform(
        menu.item(withTitle: "Copy Server ID")?.action
    )

    #expect(markedRead)
    #expect(mutedFor == .oneHour)
    #expect(selectedLevel == .nothing)
    #expect(copiedID)
}

@MainActor
@Test func `muted server menu exposes unmute with remaining duration`() throws {
    var unmuted = false
    let bridge = ServerContextMenuBridge(
        isUnread: false,
        isMutationPending: false,
        notificationSettings: GuildNotificationSettings(
            guildID: GuildID(rawValue: 100),
            isMuted: true,
            muteConfiguration: DiscordMuteConfiguration(
                endTime: .now.addingTimeInterval(3 * 60 * 60)
            )
        ),
        markRead: {},
        mute: { _ in },
        unmute: { unmuted = true },
        setNotificationLevel: { _ in },
        copyServerID: {}
    )

    let coordinator = bridge.makeCoordinator()
    let menu = coordinator.makeMenu()
    #expect(menu.item(withTitle: "Mute Server") == nil)
    let item = try #require(menu.item(withTitle: "Unmute Server"))
    #expect(item.subtitle == "3 hours remaining")
    _ = item.target?.perform(item.action)
    #expect(unmuted)
}

@MainActor
@Test func `app model applies server menu mutations with bounded requests`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guild = try #require(
        model.serverRailGuildsByID.values.first { $0.unreadCount > 0 }
    )

    model.markGuildRead(guild.id)
    #expect(await eventuallyServerMenu {
        await provider.bulkAcknowledgementRequests.count == 1
            && model.serverRailGuildsByID[guild.id]?.unreadCount == 0
    })
    let acknowledged = try #require(await provider.bulkAcknowledgementRequests.first)
    #expect(!acknowledged.isEmpty)
    #expect(
        acknowledged.allSatisfy { readState in
            model.snapshot?.channels.first { channel in
                channel.id == readState.channelID
            }?.guildID
                == guild.id
        }
    )

    model.setGuildNotificationLevel(.allMessages, for: guild)
    #expect(await eventuallyServerMenu {
        await provider.guildNotificationRequests.count == 1
            && model.guildNotificationSettings(for: guild).messageNotifications == .allMessages
    })

    let endTime = Date.now.addingTimeInterval(900)
    model.setGuildMute(true, until: endTime, for: guild)
    #expect(await eventuallyServerMenu {
        await provider.guildNotificationRequests.count == 2
            && model.guildNotificationSettings(for: guild).isMuted
    })
    let requests = await provider.guildNotificationRequests
    #expect(requests.map(\.guildID) == [guild.id, guild.id])
    #expect(requests[0].level == .allMessages)
    #expect(requests[1].isMuted == true)
    #expect(requests[1].muteEndTime == endTime)
}

@MainActor
@Test func `server read partial bulk failure keeps the accepted first batch read`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guild = try #require(model.snapshot?.guilds.first)
    let channels = (0 ..< 101).map { offset in
        Channel(
            id: ChannelID(rawValue: UInt64(10_000 + offset)),
            guildID: guild.id,
            name: "bulk-\(offset)",
            lastMessageID: MessageID(rawValue: UInt64(20_000 + offset))
        )
    }
    let readStates = channels.map {
        ChannelReadState(
            channelID: $0.id,
            lastAcknowledgedMessageID: MessageID(rawValue: 1),
            mentionCount: 1
        )
    }
    model.readState.configure(
        accountID: "offline",
        guilds: [guild],
        channels: channels,
        readStates: readStates,
        notificationSettings: []
    )
    await provider.failBulkAcknowledgement(afterAcceptedCount: 100)

    model.markGuildRead(guild.id)

    #expect(await eventuallyServerMenu {
        await provider.bulkAcknowledgementRequests.count == 1
            && model.errorMessage?.contains("accepted part") == true
    })
    let requested = try #require(await provider.bulkAcknowledgementRequests.first)
    #expect(requested.count >= 101)
    #expect(requested.prefix(100).allSatisfy {
        !model.readState.unread(channelID: $0.channelID)
    })
    #expect(requested.dropFirst(100).allSatisfy {
        model.readState.unread(channelID: $0.channelID)
    })
    #expect(model.errorMessage?.contains("did not accept the server") == false)
}

@MainActor
private func eventuallyServerMenu(
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 500 {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
