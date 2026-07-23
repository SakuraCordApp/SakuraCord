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
        requiresTag: false,
        canManage: false,
        canArchive: false,
        canEditTags: false,
        canDelete: false,
        open: { opened = true },
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
    #expect(menu.items.map(\.title) == ["Open Post", "Copy Link", "Copy Thread ID"])

    _ = menu.item(withTitle: "Open Post")?.target?.perform(
        menu.item(withTitle: "Open Post")?.action
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
        requiresTag: false,
        canManage: true,
        canArchive: true,
        canEditTags: true,
        canDelete: true,
        open: {},
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
                "Open Post",
                "Copy Link",
                "Copy Thread ID",
                nil,
                "Tags",
                "Close Post",
                "Lock Post",
                "Pin Post",
                nil,
                "Delete Post",
            ]
    )
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
        requiresTag: false,
        canManage: false,
        canArchive: true,
        canEditTags: true,
        canDelete: true,
        open: {},
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
        requiresTag: true,
        canManage: true,
        canArchive: true,
        canEditTags: true,
        canDelete: true,
        open: {},
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
