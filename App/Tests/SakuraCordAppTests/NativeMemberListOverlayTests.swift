@testable import SakuraCord
import AppKit
import SakuraCordModels
import Testing

@Test @MainActor
func `member list recycles animated avatar overlays during scrolling`() {
    let staticMember = member(
        id: 0,
        name: "Static",
        avatarURL: URL(string: "https://cdn.example/static.webp")
    )
    let first = member(
        id: 1,
        name: "First",
        avatarURL: URL(string: "https://cdn.example/first.webp?animated=true")
    )
    let second = member(
        id: 2,
        name: "Second",
        avatarURL: URL(string: "https://cdn.example/second.webp?animated=true")
    )
    #expect(!NativeMemberListCanvasView.requiresAvatarOverlay(for: staticMember))
    #expect(NativeMemberListCanvasView.requiresAvatarOverlay(for: first))
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
    var first = member(id: 1, name: "First")
    first.user.primaryGuild = PrimaryGuildIdentity(guildID: GuildID(rawValue: 42), tag: "TEST")
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
    let firstPrepared = canvas.preparedText[.member(first.id)]
    let firstPreparedName = firstPrepared?.name

    canvas.updateDocumentIfNeeded(sections: [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 2,
            members: [first, second]
        ),
    ])
    #expect(canvas.preparedText[.member(first.id)]?.name === firstPreparedName)
    #expect(canvas.preparedText[.member(second.id)] != nil)
    #expect(canvas.preparedText[.member(first.id)] === firstPrepared)
    #expect(firstPrepared?.serverTag?.identity == first.user.primaryGuild)

    // A tag identity update must invalidate its prepared content even when
    // the member's display name and row position remain unchanged.
    first.user.primaryGuild = PrimaryGuildIdentity(guildID: GuildID(rawValue: 43), tag: "NEW")
    canvas.updateDocumentIfNeeded(sections: [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 2,
            members: [first, second]
        ),
    ])
    #expect(canvas.preparedText[.member(first.id)] !== firstPrepared)
    #expect(canvas.preparedText[.member(first.id)]?.serverTag?.identity == first.user.primaryGuild)
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
    #expect(document?.preparedText[.member(loaded.id)] != nil)
}

@Test @MainActor
func `member list patches stable gateway slots without rebuilding layout`() {
    var first = member(id: 7, name: "First")
    first.memberListIndex = 11
    var second = member(id: 8, name: "Second")
    second.memberListIndex = 13
    let inferred = member(id: 9, name: "Inferred")
    let canvas = NativeMemberListCanvasView()
    canvas.updateDocumentIfNeeded(sections: [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 3,
            members: [first],
            gatewayStartIndex: 10
        ),
    ])
    let originalOrigins = canvas.origins
    let firstPreparedName = canvas.preparedText[.member(first.id)]?.name

    let added = NativeMemberListCanvasView.prepareDocument(
        sections: [
            MemberSection(
                id: .online,
                title: "Online",
                colorHex: nil,
                totalCount: 3,
                members: [first, inferred, second],
                gatewayStartIndex: 10
            ),
        ],
        reusing: canvas.preparationSnapshot()
    )
    #expect(added?.stableLayoutChangedIndexes == [2, 3])
    #expect(added?.origins == originalOrigins)
    #expect(added?.preparedText[.member(first.id)]?.name === firstPreparedName)
    if let added { canvas.applyPreparedDocument(added) }
    #expect(canvas.items.map(\.id) == [
        .header(.online),
        .member(first.id),
        .member(inferred.id),
        .member(second.id),
    ])

    let removed = NativeMemberListCanvasView.prepareDocument(
        sections: [
            MemberSection(
                id: .online,
                title: "Online",
                colorHex: nil,
                totalCount: 3,
                members: [inferred, second],
                gatewayStartIndex: 10
            ),
        ],
        reusing: canvas.preparationSnapshot()
    )
    #expect(removed?.stableLayoutChangedIndexes == [1, 2])
    if let removed { canvas.applyPreparedDocument(removed) }
    #expect(canvas.items.map(\.id) == [
        .header(.online),
        .member(inferred.id),
        .placeholder(12),
        .member(second.id),
    ])
    #expect(canvas.itemIndexesByID[.member(first.id)] == nil)
    #expect(canvas.preparedText[.member(first.id)] == nil)
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

@Test @MainActor
func `member list cursor rebuild handles server tags outside the viewport`() throws {
    var taggedMember = member(id: 1, name: "Tagged")
    taggedMember.user.primaryGuild = PrimaryGuildIdentity(guildID: GuildID(rawValue: 42), tag: "TEST")
    let model = AppModel(launchMode: .offlineTesting)
    let canvas = NativeMemberListCanvasView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
    let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
    let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    scrollView.documentView = canvas
    canvas.serverTagCardModel = model
    canvas.updateDocumentIfNeeded(sections: [
        MemberSection(id: .online, title: "Online", colorHex: nil, totalCount: 1, members: [taggedMember]),
    ])
    defer {
        canvas.tearDown()
        window.close()
    }

    let index = try #require(canvas.itemIndexesByID[.member(taggedMember.id)])
    let tagFrame = try #require(canvas.serverTagFrame(at: index))
    #expect(canvas.canActivateServerTag(at: index))
    #expect(canvas.window === window)
    withExtendedLifetime(model) {
        // The row remains visible even when its tag is wholly above the viewport.
        // Rebuilding cursors must also handle an edge touch and a partly visible tag.
        for top in [tagFrame.maxY + 1, tagFrame.maxY, tagFrame.midY] {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: top))
            let visibleRect = scrollView.documentVisibleRect
            #expect(visibleRect.minY == top)
            #expect(canvas.itemRange(intersecting: visibleRect).contains(index))
            let intersection = tagFrame.intersection(visibleRect)
            #expect(intersection.isEmpty == (top >= tagFrame.maxY))
            window.resetCursorRects()
        }

        // A row can also enter the viewport before its tag at the bottom edge.
        window.setContentSize(NSSize(width: 300, height: tagFrame.minY - 1))
        scrollView.contentView.scroll(to: .zero)
        let visibleRect = scrollView.documentVisibleRect
        #expect(canvas.itemRange(intersecting: visibleRect).contains(index))
        #expect(tagFrame.intersection(visibleRect).isNull)
        window.resetCursorRects()

        window.setContentSize(NSSize(width: 300, height: tagFrame.midY))
        #expect(!tagFrame.intersection(scrollView.documentVisibleRect).isEmpty)
        window.resetCursorRects()
    }
}

private func member(
    id: UInt64,
    name: String,
    avatarURL: URL? = nil
) -> Member {
    Member(
        user: User(
            id: UserID(rawValue: id),
            username: name.lowercased(),
            displayName: name,
            avatarURL: avatarURL
        ),
        roleName: "Member",
        status: .online
    )
}
