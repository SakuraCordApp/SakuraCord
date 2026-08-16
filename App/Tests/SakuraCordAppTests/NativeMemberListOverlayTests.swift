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

@Test @MainActor
func `member list reuses prepared text for unchanged members`() {
    let first = member(id: 1, name: "First")
    let second = member(id: 2, name: "Second")
    let canvas = NativeMemberListCanvasView()
    canvas.updateDocumentIfNeeded(sections: [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 1,
            members: [first]
        ),
    ])
    canvas.prepareRows(in: canvas.items.indices)
    let firstPreparedName = canvas.preparedText[.member(first.id)]?.name

    canvas.updateDocumentIfNeeded(sections: [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 2,
            members: [first, second]
        ),
    ])
    canvas.prepareRows(in: canvas.items.indices)

    #expect(canvas.preparedText[.member(first.id)]?.name === firstPreparedName)
    #expect(canvas.preparedText[.member(second.id)] != nil)
}

@Test @MainActor
func `member list prepares stable gateway document off main`() async {
    let loaded = member(id: 7, name: "Loaded")
    let sections = [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 3,
            members: [loaded],
            gatewayStartIndex: 10
        ),
    ]

    let document = await Task.detached {
        NativeMemberListCanvasView.prepareDocument(sections: sections)
    }.value

    #expect(document?.items.map(\.id) == [
        .header(.online),
        .member(loaded.id),
        .placeholder(12),
        .placeholder(13),
    ])
    #expect(document?.itemIndexesByID[.member(loaded.id)] == 1)
    #expect(document?.origins.count == document?.items.count)
}

@Test @MainActor
func `cancelled member document preparation stops cooperatively`() async {
    let sections = [
        MemberSection(
            id: .offline,
            title: "Offline",
            colorHex: nil,
            totalCount: 1_000_000,
            members: [],
            gatewayStartIndex: 0
        ),
    ]
    let task = Task.detached {
        NativeMemberListCanvasView.prepareDocument(
            sections: sections,
            cancelsCooperatively: true
        )
    }
    task.cancel()

    #expect(await task.value == nil)
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
