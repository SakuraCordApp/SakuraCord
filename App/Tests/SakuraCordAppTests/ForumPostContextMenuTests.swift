import AppKit
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `forum post tags menu enables only the tags the post can toggle`() throws {
    let ordinary = ForumTag(id: ForumTagID(rawValue: 1), name: "Open")
    let moderated = ForumTag(
        id: ForumTagID(rawValue: 2),
        name: "Complete",
        isModerated: true
    )
    let menu = ForumPostMenuBuilder().makeMenu(
        actionsMenu: ThreadActionsMenu(sections: [[
            ThreadMenuEntry(id: ThreadActionsMenu.tagsSlotID, title: "Tags", content: .slot),
        ]]),
        tags: [ordinary, moderated],
        appliedTagIDs: [moderated.id],
        customEmojiURLsByID: [:],
        canToggle: { !$0.isModerated },
        toggleTag: { _ in }
    )

    let tagsMenu = try #require(menu.item(withTitle: "Tags")?.submenu)
    #expect(tagsMenu.item(withTitle: ordinary.name)?.isEnabled == true)
    #expect(tagsMenu.item(withTitle: moderated.name)?.isEnabled == false)
    #expect(tagsMenu.item(withTitle: moderated.name)?.state == .on)
}
