import AppKit
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `forum post owners can edit ordinary but not moderated tags`() throws {
    let ordinary = ForumTag(id: ForumTagID(rawValue: 1), name: "Open")
    let moderated = ForumTag(
        id: ForumTagID(rawValue: 2),
        name: "Complete",
        isModerated: true
    )
    let bridge = ForumPostContextMenuBridge(
        actionsMenu: ThreadActionsMenu(sections: [[
            ThreadMenuEntry(id: ThreadActionsMenu.tagsSlotID, title: "Tags", content: .slot),
        ]]),
        tags: [ordinary, moderated],
        appliedTagIDs: [],
        customEmojiURLsByID: [:],
        requiresTag: false,
        canManage: false,
        toggleTag: { _ in }
    )

    let menu = bridge.makeCoordinator().makeMenu()
    let tagsMenu = try #require(menu.item(withTitle: "Tags")?.submenu)
    #expect(tagsMenu.item(withTitle: ordinary.name)?.isEnabled == true)
    #expect(tagsMenu.item(withTitle: moderated.name)?.isEnabled == false)
}

@MainActor
@Test func `required forum tag cannot be removed when it is the last applied tag`() throws {
    let required = ForumTag(id: ForumTagID(rawValue: 1), name: "Required")
    let bridge = ForumPostContextMenuBridge(
        actionsMenu: ThreadActionsMenu(sections: [[
            ThreadMenuEntry(id: ThreadActionsMenu.tagsSlotID, title: "Tags", content: .slot),
        ]]),
        tags: [required],
        appliedTagIDs: [required.id],
        customEmojiURLsByID: [:],
        requiresTag: true,
        canManage: true,
        toggleTag: { _ in }
    )

    let menu = bridge.makeCoordinator().makeMenu()
    let tagsMenu = try #require(menu.item(withTitle: "Tags")?.submenu)
    #expect(tagsMenu.item(withTitle: required.name)?.isEnabled == false)
}
