import AppKit
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `forum context menu keeps universal actions without permissions`() {
    var opened = false
    var copiedLink = false
    var copiedThreadID = false
    let bridge = ForumPostContextMenuBridge(
        tags: [],
        appliedTagIDs: [],
        customEmojiURLsByID: [:],
        isArchived: false,
        isLocked: false,
        isPinned: false,
        isUnread: true,
        isMutationPending: false,
        notificationSettings: nil,
        inheritedNotificationLevel: .onlyMentions,
        requiresTag: false,
        canManage: false,
        canArchive: false,
        canEditTags: false,
        canDelete: false,
        markRead: { opened = true },
        mute: { _ in },
        unmute: {},
        setNotificationLevel: { _ in },
        copyLink: { copiedLink = true },
        copyThreadID: { copiedThreadID = true },
        toggleTag: { _ in },
        toggleArchive: {},
        toggleLock: {},
        togglePin: {},
        delete: {}
    )

    let coordinator = bridge.makeCoordinator()
    let menu = coordinator.makeMenu()
    #expect(
        menu.items.map { $0.isSeparatorItem ? nil : $0.title }
            == [
                "Mark as Read",
                nil,
                "Mute Post",
                "Notification Settings",
                nil,
                "Copy Link",
                "Copy Thread ID",
            ]
    )
    #expect(
        menu.items
            .filter { !$0.isSeparatorItem }
            .allSatisfy { $0.image != nil }
    )
    #expect(menu.item(withTitle: "Mark as Read")?.isEnabled == true)
    #expect(
        menu.item(withTitle: "Mute Post")?.submenu?.items
            .allSatisfy { $0.image == nil } == true
    )
    #expect(
        menu.item(withTitle: "Notification Settings")?.submenu?.items
            .allSatisfy { $0.image == nil } == true
    )
    #expect(
        menu.item(withTitle: "Notification Settings")?.submenu?.items.map(\.title)
            == ["All Messages", "Only @mentions", "Nothing"]
    )
    #expect(
        menu.item(withTitle: "Notification Settings")?.submenu?
            .item(withTitle: "Only @mentions")?.state == .on
    )
    #expect(
        menu.item(withTitle: "Notification Settings")?.subtitle
            == "Only @mentions"
    )

    _ = menu.item(withTitle: "Mark as Read")?.target?.perform(
        menu.item(withTitle: "Mark as Read")?.action
    )
    _ = menu.item(withTitle: "Copy Link")?.target?.perform(
        menu.item(withTitle: "Copy Link")?.action
    )
    _ = menu.item(withTitle: "Copy Thread ID")?.target?.perform(
        menu.item(withTitle: "Copy Thread ID")?.action
    )

    #expect(opened)
    #expect(copiedLink)
    #expect(copiedThreadID)
}

@MainActor
@Test func `forum context menu keeps moderation and deletion in separate sections`() {
    let bridge = ForumPostContextMenuBridge(
        tags: [],
        appliedTagIDs: [],
        customEmojiURLsByID: [:],
        isArchived: false,
        isLocked: false,
        isPinned: false,
        isUnread: false,
        isMutationPending: false,
        notificationSettings: nil,
        inheritedNotificationLevel: .onlyMentions,
        requiresTag: false,
        canManage: true,
        canArchive: true,
        canEditTags: true,
        canDelete: true,
        markRead: {},
        mute: { _ in },
        unmute: {},
        setNotificationLevel: { _ in },
        copyLink: {},
        copyThreadID: {},
        toggleTag: { _ in },
        toggleArchive: {},
        toggleLock: {},
        togglePin: {},
        delete: {}
    )

    let items = bridge.makeCoordinator().makeMenu().items
    #expect(
        items.map { $0.isSeparatorItem ? nil : $0.title }
            == [
                "Mark as Read",
                nil,
                "Mute Post",
                "Notification Settings",
                nil,
                "Tags",
                "Close Post",
                "Lock Post",
                "Pin Post",
                nil,
                "Copy Link",
                "Copy Thread ID",
                nil,
                "Delete Post…",
            ]
    )
    #expect(
        items
            .filter { !$0.isSeparatorItem }
            .allSatisfy { $0.image != nil }
    )
    #expect(items.first?.isEnabled == false)
    let destructiveColor =
        items.first { $0.title == "Delete Post…" }?
        .attributedTitle?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
    #expect(destructiveColor == .systemRed)
}

@MainActor
@Test func `forum post menu exposes current mute and notification settings`() throws {
    var didUnmute = false
    var selectedLevel: MessageNotificationLevel?
    let bridge = ForumPostContextMenuBridge(
        tags: [],
        appliedTagIDs: [],
        customEmojiURLsByID: [:],
        isArchived: false,
        isLocked: false,
        isPinned: false,
        isUnread: true,
        isMutationPending: false,
        notificationSettings: ThreadNotificationSettings(
            flags: ThreadNotificationSettings.allMessagesFlag,
            isMuted: true,
            muteConfiguration: DiscordMuteConfiguration(
                endTime: Date.now.addingTimeInterval(90 * 60)
            )
        ),
        inheritedNotificationLevel: .onlyMentions,
        requiresTag: false,
        canManage: false,
        canArchive: false,
        canEditTags: false,
        canDelete: false,
        markRead: {},
        mute: { _ in },
        unmute: { didUnmute = true },
        setNotificationLevel: { selectedLevel = $0 },
        copyLink: {},
        copyThreadID: {},
        toggleTag: { _ in },
        toggleArchive: {},
        toggleLock: {},
        togglePin: {},
        delete: {}
    )

    let coordinator = bridge.makeCoordinator()
    let menu = coordinator.makeMenu()
    let unmute = try #require(menu.item(withTitle: "Unmute Post"))
    #expect(unmute.subtitle?.contains("hours remaining") == true)
    #expect(menu.item(withTitle: "Notification Settings")?.subtitle == "All Messages")
    let notificationMenu = try #require(
        menu.item(withTitle: "Notification Settings")?.submenu
    )
    #expect(notificationMenu.item(withTitle: "All Messages")?.state == .on)
    #expect(notificationMenu.item(withTitle: "Use Forum Default") == nil)

    _ = unmute.target?.perform(unmute.action)
    let nothing = try #require(notificationMenu.item(withTitle: "Nothing"))
    _ = nothing.target?.perform(nothing.action, with: nothing)
    #expect(didUnmute)
    #expect(selectedLevel == .nothing)
}

@MainActor
@Test func `forum post owners can edit ordinary but not moderated tags`() throws {
    let ordinary = ForumTag(id: ForumTagID(rawValue: 1), name: "Open")
    let moderated = ForumTag(
        id: ForumTagID(rawValue: 2),
        name: "Complete",
        isModerated: true
    )
    let bridge = ForumPostContextMenuBridge(
        tags: [ordinary, moderated],
        appliedTagIDs: [],
        customEmojiURLsByID: [:],
        isArchived: false,
        isLocked: false,
        isPinned: false,
        isUnread: true,
        isMutationPending: false,
        notificationSettings: nil,
        inheritedNotificationLevel: .onlyMentions,
        requiresTag: false,
        canManage: false,
        canArchive: true,
        canEditTags: true,
        canDelete: true,
        markRead: {},
        mute: { _ in },
        unmute: {},
        setNotificationLevel: { _ in },
        copyLink: {},
        copyThreadID: {},
        toggleTag: { _ in },
        toggleArchive: {},
        toggleLock: {},
        togglePin: {},
        delete: {}
    )

    let menu = bridge.makeCoordinator().makeMenu()
    let tagsMenu = try #require(menu.item(withTitle: "Tags")?.submenu)
    #expect(tagsMenu.item(withTitle: ordinary.name)?.isEnabled == true)
    #expect(tagsMenu.item(withTitle: moderated.name)?.isEnabled == false)
    #expect(menu.item(withTitle: "Close Post") != nil)
    #expect(menu.item(withTitle: "Lock Post") == nil)
    #expect(menu.item(withTitle: "Pin Post") == nil)
}

@MainActor
@Test func `required forum tag cannot be removed when it is the last applied tag`() throws {
    let required = ForumTag(id: ForumTagID(rawValue: 1), name: "Required")
    let bridge = ForumPostContextMenuBridge(
        tags: [required],
        appliedTagIDs: [required.id],
        customEmojiURLsByID: [:],
        isArchived: false,
        isLocked: false,
        isPinned: false,
        isUnread: true,
        isMutationPending: false,
        notificationSettings: nil,
        inheritedNotificationLevel: .onlyMentions,
        requiresTag: true,
        canManage: true,
        canArchive: true,
        canEditTags: true,
        canDelete: true,
        markRead: {},
        mute: { _ in },
        unmute: {},
        setNotificationLevel: { _ in },
        copyLink: {},
        copyThreadID: {},
        toggleTag: { _ in },
        toggleArchive: {},
        toggleLock: {},
        togglePin: {},
        delete: {}
    )

    let menu = bridge.makeCoordinator().makeMenu()
    let tagsMenu = try #require(menu.item(withTitle: "Tags")?.submenu)
    #expect(tagsMenu.item(withTitle: required.name)?.isEnabled == false)
}

@Test func `forum post links target the thread channel`() {
    #expect(
        ForumPostContextValue.link(
            guildID: GuildID(rawValue: 100),
            threadID: ChannelID(rawValue: 200)
        ) == "https://discord.com/channels/100/200"
    )
}
