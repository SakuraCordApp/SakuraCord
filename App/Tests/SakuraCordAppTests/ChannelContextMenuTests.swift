import AppKit
import DiscordProtocol
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `channel context menu groups actions and keeps top level icons visible`() throws {
    var markedRead = false
    var mutedFor: ChannelMuteDuration?
    var selectedLevel: MessageNotificationLevel?
    var copiedID = false
    var copiedLink = false
    let bridge = ChannelContextMenuBridge(
        isSelected: false,
        isUnread: false,
        isMutationPending: false,
        directOverride: nil,
        inheritedLevel: .onlyMentions,
        inheritanceSource: .category,
        markRead: { markedRead = true },
        mute: { mutedFor = $0 },
        unmute: {},
        setNotificationLevel: { selectedLevel = $0 },
        copyChannelID: { copiedID = true },
        copyLink: { copiedLink = true }
    )

    let coordinator = bridge.makeCoordinator()
    let menu = coordinator.makeMenu()
    #expect(
        menu.items.map { $0.isSeparatorItem ? nil : $0.title }
            == [
                "Mark as Read",
                nil,
                "Mute Channel",
                "Notification Settings",
                nil,
                "Copy Channel ID",
                "Copy Link",
            ]
    )
    #expect(menu.item(withTitle: "Mark as Read")?.isEnabled == false)
    let muteMenu = try #require(menu.item(withTitle: "Mute Channel")?.submenu)
    #expect(muteMenu.items.map(\.title) == ChannelMuteDuration.allCases.map(\.title))
    let notificationMenu =
        try #require(menu.item(withTitle: "Notification Settings")?.submenu)
    #expect(
        menu.item(withTitle: "Notification Settings")?.subtitle
            == "Only @mentions"
    )
    #expect(
        notificationMenu.items.map(\.title)
            == [
                "Use Category Default",
                "All Messages",
                "Only @mentions",
                "Nothing",
            ]
    )
    #expect(notificationMenu.items.first?.subtitle == "Only @mentions")
    #expect(notificationMenu.items.first?.state == .on)

    #expect(
        menu.items
            .filter { !$0.isSeparatorItem }
            .allSatisfy { $0.image != nil }
    )
    #expect(muteMenu.items.allSatisfy { $0.image == nil })
    #expect(notificationMenu.items.allSatisfy { $0.image == nil })

    let oneHour = try #require(muteMenu.item(withTitle: "For 1 Hour"))
    _ = oneHour.target?.perform(oneHour.action, with: oneHour)
    let nothing = try #require(notificationMenu.item(withTitle: "Nothing"))
    _ = nothing.target?.perform(nothing.action, with: nothing)
    let copyID = try #require(menu.item(withTitle: "Copy Channel ID"))
    _ = copyID.target?.perform(copyID.action)
    let copyLinkItem = try #require(menu.item(withTitle: "Copy Link"))
    _ = copyLinkItem.target?.perform(copyLinkItem.action)

    #expect(!markedRead)
    #expect(mutedFor == .oneHour)
    #expect(selectedLevel == .nothing)
    #expect(copiedID)
    #expect(copiedLink)
}

@MainActor
@Test func `muted channel menu exposes unmute as the direct action`() throws {
    var unmuted = false
    let bridge = ChannelContextMenuBridge(
        isSelected: false,
        isUnread: true,
        isMutationPending: false,
        directOverride: ChannelNotificationOverride(
            channelID: ChannelID(rawValue: 200),
            messageNotifications: .allMessages,
            isMuted: true,
            muteConfiguration: DiscordMuteConfiguration(endTime: nil)
        ),
        inheritedLevel: .onlyMentions,
        inheritanceSource: .server,
        markRead: {},
        mute: { _ in },
        unmute: { unmuted = true },
        setNotificationLevel: { _ in },
        copyChannelID: {},
        copyLink: {}
    )

    let coordinator = bridge.makeCoordinator()
    let menu = coordinator.makeMenu()
    #expect(menu.item(withTitle: "Mute Channel") == nil)
    let item = try #require(menu.item(withTitle: "Unmute Channel"))
    #expect(item.subtitle == nil)
    #expect(
        menu.item(withTitle: "Notification Settings")?.subtitle
            == "All Messages"
    )
    _ = item.target?.perform(item.action)
    #expect(unmuted)
}

@MainActor
@Test func `category context menu mirrors channel actions without a copy link`() throws {
    var markedRead = false
    var copiedID = false
    let bridge = ChannelContextMenuBridge(
        subject: .category,
        isSelected: false,
        isUnread: true,
        isMutationPending: false,
        directOverride: nil,
        inheritedLevel: .onlyMentions,
        inheritanceSource: .server,
        markRead: { markedRead = true },
        mute: { _ in },
        unmute: {},
        setNotificationLevel: { _ in },
        copyChannelID: { copiedID = true },
        copyLink: {}
    )

    let coordinator = bridge.makeCoordinator()
    let menu = coordinator.makeMenu()
    #expect(
        menu.items.map { $0.isSeparatorItem ? nil : $0.title }
            == [
                "Mark as Read",
                nil,
                "Mute Category",
                "Notification Settings",
                nil,
                "Copy Category ID",
            ]
    )
    #expect(menu.item(withTitle: "Copy Link") == nil)
    #expect(
        menu.item(withTitle: "Notification Settings")?.submenu?
            .items.first?.title == "Use Server Default"
    )

    let markRead = try #require(menu.item(withTitle: "Mark as Read"))
    _ = markRead.target?.perform(markRead.action)
    let copyID = try #require(menu.item(withTitle: "Copy Category ID"))
    _ = copyID.target?.perform(copyID.action)
    #expect(markedRead)
    #expect(copiedID)
}

@MainActor
@Test func `direct message menu identifies its inherited notification default`() throws {
    let bridge = ChannelContextMenuBridge(
        isSelected: false,
        isUnread: false,
        isMutationPending: false,
        directOverride: nil,
        inheritedLevel: .allMessages,
        inheritanceSource: .directMessages,
        markRead: {},
        mute: { _ in },
        unmute: {},
        setNotificationLevel: { _ in },
        copyChannelID: {},
        copyLink: {}
    )

    let menu = try #require(
        bridge.makeCoordinator().makeMenu()
            .item(withTitle: "Notification Settings")?.submenu
    )
    #expect(menu.items.first?.title == "Use Direct Message Default")
    #expect(menu.items.first?.subtitle == "All Messages")
    #expect(menu.items.first?.state == .on)
}

@MainActor
@Test func `timed mute menu shows its remaining duration`() throws {
    let bridge = ChannelContextMenuBridge(
        isSelected: false,
        isUnread: false,
        isMutationPending: false,
        directOverride: ChannelNotificationOverride(
            channelID: ChannelID(rawValue: 200),
            isMuted: true,
            muteConfiguration: DiscordMuteConfiguration(
                endTime: .now.addingTimeInterval(3 * 60 * 60)
            )
        ),
        inheritedLevel: .onlyMentions,
        inheritanceSource: .server,
        markRead: {},
        mute: { _ in },
        unmute: {},
        setNotificationLevel: { _ in },
        copyChannelID: {},
        copyLink: {}
    )

    let subtitle = try #require(
        bridge.makeCoordinator().makeMenu()
            .item(withTitle: "Unmute Channel")?.subtitle
    )
    #expect(subtitle == "3 hours remaining")
}

@MainActor
@Test func `scrolling channel rows clears displaced native hover state`() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
    scrollView.hasVerticalScroller = true
    window.contentView = scrollView

    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
    scrollView.documentView = documentView
    let interactionView = ChannelNativeRowInteractionView(
        frame: NSRect(x: 0, y: 20, width: 240, height: 32)
    )
    documentView.addSubview(interactionView)

    let pointerInWindow = interactionView.convert(
        NSPoint(x: 120, y: 16),
        to: nil
    )
    interactionView.pointerLocationInWindowProvider = { pointerInWindow }
    var hoverChanges: [Bool] = []
    interactionView.hoverChanged = { hoverChanges.append($0) }
    interactionView.refreshHoverTracking()

    #expect(hoverChanges == [true])

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    #expect(hoverChanges == [true, false])
    interactionView.refreshHoverTracking()
    #expect(hoverChanges == [true, false])
}

@MainActor
@Test func `channel hover template survives selected row virtualization`() throws {
    let tableView = NSTableView(
        frame: NSRect(x: 0, y: 0, width: 240, height: 160)
    )
    let selectionHost = NSView(
        frame: NSRect(x: 0, y: 0, width: 240, height: 28)
    )
    let selectionView = NSVisualEffectView(
        frame: NSRect(x: 6, y: 2, width: 228, height: 24)
    )
    selectionView.material = .selection
    selectionView.wantsLayer = true
    selectionView.layer?.cornerRadius = 7
    selectionHost.addSubview(selectionView)

    let template = ChannelNativeHoverTemplate(
        selectionView: selectionView,
        fallbackRowBounds: selectionHost.bounds
    )
    let store = ChannelNativeHoverTemplateStore()
    store.set(template, for: tableView)

    selectionView.removeFromSuperview()
    let virtualizedTemplate = try #require(store.template(for: tableView))
    #expect(
        virtualizedTemplate.frame(
            in: NSRect(x: 0, y: 0, width: 300, height: 28)
        ) == NSRect(x: 6, y: 2, width: 288, height: 24)
    )
    #expect(virtualizedTemplate.cornerRadius == 7)
}

@MainActor
@Test func `channel hover fallback always has visible row geometry`() {
    #expect(
        ChannelNativeHoverTemplate.fallback.frame(
            in: NSRect(x: 0, y: 0, width: 240, height: 28)
        ) == NSRect(x: 5, y: 2, width: 230, height: 24)
    )
}

@Test func `channel context values preserve discord links and mute windows`() {
    #expect(
        ChannelContextMenuValue.link(
            guildID: GuildID(rawValue: 100),
            channelID: ChannelID(rawValue: 200)
        ) == "https://discord.com/channels/100/200"
    )
    #expect(
        ChannelContextMenuValue.link(
            guildID: nil,
            channelID: ChannelID(rawValue: 300)
        ) == "https://discord.com/channels/@me/300"
    )
    let now = Date(timeIntervalSince1970: 100)
    #expect(
        ChannelMuteDuration.fifteenMinutes.endDate(from: now)
            == now.addingTimeInterval(900)
    )
    #expect(ChannelMuteDuration.indefinitely.endDate(from: now) == nil)
    #expect(
        ChannelContextMenuSubtitle.muteRemaining(
            until: now.addingTimeInterval(900),
            now: now
        ) == "15 minutes remaining"
    )
    #expect(
        ChannelContextMenuSubtitle.muteRemaining(
            until: now.addingTimeInterval(3 * 60 * 60),
            now: now
        ) == "3 hours remaining"
    )
    #expect(
        ChannelContextMenuSubtitle.muteRemaining(until: nil, now: now)
            == nil
    )
    #expect(
        !ChannelCategoryPresentation.initiallyExpanded(
            isCollapsedByDefault: true
        )
    )
    #expect(
        ChannelCategoryPresentation.initiallyExpanded(
            isCollapsedByDefault: false
        )
    )
}

@MainActor
@Test func `app model applies each channel notification mutation after one request`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try #require(
        model.snapshot?.channels.first { $0.guildID == GuildID(rawValue: 100) }
    )

    model.setChannelNotificationLevel(.allMessages, for: channel)
    #expect(await eventuallyChannelMenu {
        await provider.channelNotificationRequests.count == 1
            && model.channelNotificationOverride(for: channel)?
                .messageNotifications == .allMessages
    })

    let endTime = Date.now.addingTimeInterval(900)
    model.setChannelMute(true, until: endTime, for: channel)
    #expect(await eventuallyChannelMenu {
        await provider.channelNotificationRequests.count == 2
            && model.channelNotificationOverride(for: channel)?.isMuted == true
            && model.isChannelMuted(channel)
    })
    let requests = await provider.channelNotificationRequests
    #expect(requests.map(\.channelID) == [channel.id, channel.id])
    #expect(requests[0].level == .allMessages)
    #expect(requests[1].isMuted == true)
    #expect(requests[1].muteEndTime == endTime)

    model.setChannelMute(false, until: nil, for: channel)
    #expect(await eventuallyChannelMenu {
        await provider.channelNotificationRequests.count == 3
            && !model.isChannelMuted(channel)
    })
}

@MainActor
@Test func `app model keeps category settings separate from child channel overrides`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let child = try #require(
        model.snapshot?.channels.first {
            $0.guildID == GuildID(rawValue: 100) && $0.categoryID != nil
        }
    )
    let guildID = try #require(child.guildID)
    let categoryID = try #require(child.categoryID)

    model.setCategoryNotificationLevel(
        .allMessages,
        guildID: guildID,
        categoryID: categoryID
    )
    #expect(await eventuallyChannelMenu {
        await provider.categoryNotificationRequests.count == 1
            && model.categoryNotificationOverride(
                guildID: guildID,
                categoryID: categoryID
            )?.messageNotifications == .allMessages
    })

    model.setCategoryMute(
        true,
        until: nil,
        guildID: guildID,
        categoryID: categoryID
    )
    #expect(await eventuallyChannelMenu {
        await provider.categoryNotificationRequests.count == 2
            && model.isCategoryMuted(
                guildID: guildID,
                categoryID: categoryID
            )
            && !model.isCategoryCollapsed(
                guildID: guildID,
                categoryID: categoryID
            )
    })
    #expect(!model.isChannelMuted(child))
    #expect(model.channelNotificationOverride(for: child) == nil)

    model.setCategoryCollapsed(
        true,
        guildID: guildID,
        categoryID: categoryID
    )
    #expect(await eventuallyChannelMenu {
        await provider.categoryNotificationRequests.count == 3
            && model.isCategoryCollapsed(
                guildID: guildID,
                categoryID: categoryID
            )
    })
    let requests = await provider.categoryNotificationRequests
    #expect(requests.map(\.categoryID) == [categoryID, categoryID, categoryID])
    #expect(requests[0].level == .allMessages)
    #expect(requests[1].isMuted == true)
    #expect(requests[1].isCollapsed == nil)
    #expect(requests[2].isCollapsed == true)
}

@MainActor
@Test func `category collapse is optimistic and coalesces rapid changes`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let child = try #require(
        model.snapshot?.channels.first {
            $0.guildID == GuildID(rawValue: 100) && $0.categoryID != nil
        }
    )
    let guildID = try #require(child.guildID)
    let categoryID = try #require(child.categoryID)
    await provider.suspendCategoryCollapsedUpdates()

    model.setCategoryCollapsed(true, guildID: guildID, categoryID: categoryID)
    #expect(model.isCategoryCollapsed(guildID: guildID, categoryID: categoryID))
    #expect(await eventuallyChannelMenu {
        await provider.categoryNotificationRequests.count == 1
    })

    model.setCategoryCollapsed(false, guildID: guildID, categoryID: categoryID)
    model.setCategoryCollapsed(true, guildID: guildID, categoryID: categoryID)
    model.setCategoryCollapsed(false, guildID: guildID, categoryID: categoryID)
    #expect(!model.isCategoryCollapsed(guildID: guildID, categoryID: categoryID))
    #expect(await provider.categoryNotificationRequests.count == 1)

    await provider.resumeCategoryCollapsedUpdates()
    #expect(await eventuallyChannelMenu {
        let requests = await provider.categoryNotificationRequests
        return requests.count == 2
            && requests.map(\.isCollapsed) == [true, false]
            && !model.isChannelNotificationMutationPending(categoryID)
            && !model.isCategoryCollapsed(guildID: guildID, categoryID: categoryID)
    })
}

@MainActor
@Test func `mark category read acknowledges only conversations in that category`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let child = try #require(
        model.snapshot?.channels.first {
            $0.id == ChannelID(rawValue: 210)
        }
    )
    let guildID = try #require(child.guildID)
    let categoryID = try #require(child.categoryID)
    let categoryChannelIDs = Set(
        model.snapshot?.channels.compactMap {
            $0.categoryID == categoryID ? $0.id : nil
        } ?? []
    )
    let categoryConversationIDs = categoryChannelIDs.union(
        model.snapshot?.threads.compactMap {
            categoryChannelIDs.contains($0.parentID ?? ChannelID(rawValue: 0))
                ? $0.id : nil
        } ?? []
    )

    model.markCategoryRead(categoryID: categoryID, guildID: guildID)

    #expect(await eventuallyChannelMenu {
        await provider.bulkAcknowledgementRequests.count == 1
    })
    let request = try #require(await provider.bulkAcknowledgementRequests.first)
    #expect(!request.isEmpty)
    #expect(request.contains { $0.channelID == child.id })
    #expect(request.allSatisfy { categoryConversationIDs.contains($0.channelID) })
}

@MainActor
@Test func `app model applies direct message notification mutations in the private scope`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channel = try #require(
        model.snapshot?.channels.first { $0.kind == .directMessage }
    )

    #expect(channel.guildID == nil)
    #expect(model.inheritedChannelNotificationLevel(for: channel) == .allMessages)

    model.setChannelNotificationLevel(.onlyMentions, for: channel)
    #expect(await eventuallyChannelMenu {
        await provider.channelNotificationRequests.count == 1
            && model.channelNotificationOverride(for: channel)?
                .messageNotifications == .onlyMentions
    })

    model.setChannelMute(true, until: nil, for: channel)
    #expect(await eventuallyChannelMenu {
        await provider.channelNotificationRequests.count == 2
            && model.isChannelMuted(channel)
    })

    let requests = await provider.channelNotificationRequests
    #expect(requests.map(\.guildID) == [nil, nil])
    #expect(requests.map(\.channelID) == [channel.id, channel.id])
}

@MainActor
@Test func `app model applies forum post member notification mutations`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let forum = try #require(
        model.snapshot?.channels.first { $0.kind == .forum }
    )
    model.selectedChannelID = forum.id
    #expect(await eventuallyChannelMenu {
        model.hasLoadedForumPosts && !model.forumPosts.isEmpty
    })
    let post = try #require(model.forumPosts.first)

    model.setForumPostNotificationLevel(.allMessages, for: post)
    #expect(await eventuallyChannelMenu {
        await provider.threadNotificationRequests.count == 1
            && model.forumPosts.first { $0.id == post.id }?
                .thread.notificationSettings?.notificationLevel == .allMessages
    })

    let endTime = Date.now.addingTimeInterval(900)
    let updated = try #require(model.forumPosts.first { $0.id == post.id })
    model.setForumPostMute(true, until: endTime, for: updated)
    #expect(await eventuallyChannelMenu {
        await provider.threadNotificationRequests.count == 2
            && model.forumPosts.first { $0.id == post.id }?
                .thread.notificationSettings?.isMuted == true
    })

    let requests = await provider.threadNotificationRequests
    #expect(requests.map(\.threadID) == [post.id, post.id])
    #expect(requests[0].level == .allMessages)
    #expect(requests[1].isMuted == true)
    #expect(requests[1].muteEndTime == endTime)
}

@MainActor
@Test func `mark as read works for an unselected sidebar channel`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    model.selectedChannelID = ChannelID(rawValue: 211)
    #expect(await eventuallyChannelMenu {
        model.selectedChannelID == ChannelID(rawValue: 211)
            && !model.isLoadingMessages
    })
    #expect(model.isChannelUnread(channelID))
    #expect(model.selectedChannelID != channelID)

    model.markConversationRead(channelID: channelID)

    #expect(await eventuallyChannelMenu {
        await provider.acknowledgementRequests.contains {
            $0.channelID == channelID && !$0.manual
        }
    })
    #expect(!model.isChannelUnread(channelID))
}

@MainActor
private func eventuallyChannelMenu(
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
