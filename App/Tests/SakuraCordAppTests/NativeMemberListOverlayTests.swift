@testable import SakuraCord
import AppKit
import SakuraCordModels
import Testing

@Test @MainActor
func `member list recycles animated avatar overlays during scrolling`() {
    let first = member(id: 1, name: "First")
    let second = member(id: 2, name: "Second")
    let canvas = NativeMemberListCanvasView()
    canvas.updateDocumentIfNeeded(sections: [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 2,
            members: [first, second]
        ),
    ])

    canvas.installAvatarOverlays(in: 1 ..< 2)
    let firstHost = canvas.avatarOverlays[.member(first.id)]
    #expect(firstHost != nil)

    canvas.isScrolling = true
    canvas.installAvatarOverlays(in: 2 ..< 3)
    let secondHost = canvas.avatarOverlays[.member(second.id)]

    #expect(secondHost === firstHost)
    #expect(secondHost?.superview === canvas)
    #expect(canvas.avatarOverlays.count == 1)
    canvas.tearDown()
}

private func member(id: UInt64, name: String) -> Member {
    Member(
        user: User(
            id: UserID(rawValue: id),
            username: name.lowercased(),
            displayName: name
        ),
        roleName: "Member",
        status: .online
    )
}
