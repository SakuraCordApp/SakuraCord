import AppKit
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `gateway member sections preserve arbitrary group order authoritative counts and slice order`() {
    let moderator = GuildRole(
        id: RoleID(rawValue: 10),
        name: "Moderator",
        position: 10,
        colorHex: 0xFF_88_00
    )
    let helper = GuildRole(
        id: RoleID(rawValue: 20),
        name: "Helper",
        position: 20,
        colorHex: 0x33_AA_FF
    )
    let members = [
        member(1, "Zulu", status: .online, role: moderator),
        member(2, "Beta", status: .offline),
        member(3, "Alpha", status: .online, role: moderator),
        member(4, "Gamma", status: .online),
    ]

    let sections = MemberSection.make(
        from: members,
        groups: [
            GuildMemberListGroup(id: "offline", count: 341),
            GuildMemberListGroup(id: helper.id.description, count: 27),
            GuildMemberListGroup(id: moderator.id.description, count: 92),
            GuildMemberListGroup(id: "online", count: 418),
        ],
        roles: [moderator, helper]
    )

    #expect(sections.map(\.id) == [
        .offline,
        .role(name: "Helper", position: 20),
        .role(name: "Moderator", position: 10),
        .online,
    ])
    #expect(sections.map(\.title) == ["Offline", "Helper", "Moderator", "Online"])
    #expect(sections.map(\.totalCount) == [341, 27, 92, 418])
    #expect(sections.map(\.gatewayStartIndex) == [0, 342, 370, 463])
    #expect(sections.map(\.colorHex) == [nil, 0x33_AA_FF, 0xFF_88_00, nil])
    #expect(sections.map { $0.members.map(\.id) } == [
        [UserID(rawValue: 2)],
        [],
        [UserID(rawValue: 1), UserID(rawValue: 3)],
        [UserID(rawValue: 4)],
    ])
}

@MainActor
@Test func `gateway member sections omit unknown group IDs without reordering supported groups`() {
    let uncataloguedRoleID = RoleID(rawValue: 90)
    let roleMember = Member(
        user: user(1, "Role member"),
        roleName: "Uncatalogued",
        status: .online,
        roleID: uncataloguedRoleID,
        rolePosition: 99,
        isRoleCategory: true
    )
    let onlineMember = member(2, "Online", status: .online)

    let sections = MemberSection.make(
        from: [onlineMember, roleMember],
        groups: [
            GuildMemberListGroup(id: "future-group", count: 12),
            GuildMemberListGroup(id: uncataloguedRoleID.description, count: 1),
            GuildMemberListGroup(id: "online", count: 44),
        ]
    )

    #expect(sections.map(\.id) == [
        .role(name: "Uncatalogued", position: 0),
        .online,
    ])
    #expect(sections.map(\.totalCount) == [1, 44])
    #expect(sections.map(\.gatewayStartIndex) == [13, 15])
    #expect(sections.map { $0.members.map(\.id) } == [
        [roleMember.id],
        [onlineMember.id],
    ])
}

@MainActor
@Test func `native member canvas preserves section order and absolute gateway slots`() {
    let role = GuildRole(
        id: RoleID(rawValue: 10),
        name: "Contributor",
        position: 10,
        colorHex: 0xFF_88_00
    )
    var online = member(1, "Online", status: .online, role: role)
    online.memberListIndex = 1
    let fallback = member(2, "Fallback", status: .online, role: role)
    var offline = member(3, "Offline", status: .offline)
    offline.memberListIndex = 5

    let sections = MemberSection.make(
        from: [online, fallback, offline],
        groups: [
            GuildMemberListGroup(id: role.id.description, count: 3),
            GuildMemberListGroup(id: "offline", count: 1),
        ],
        roles: [role]
    )
    #expect(sections[0].members == [online, fallback])
    #expect(sections[1].members == [offline])
    let items = NativeMemberListCanvasView.makeItems(sections: sections)

    #expect(items.count == 6)
    #expect(items[1] == .member(online, gatewayIndex: 1))
    #expect(items[2] == .member(fallback, gatewayIndex: 2))
    #expect(items[3] == .placeholder(gatewayIndex: 3))
    #expect(items[5] == .member(offline, gatewayIndex: 5))
}

@MainActor
@Test func `native member canvas does not compact sparse gateway ranges`() {
    var first = member(1, "First", status: .online)
    first.memberListIndex = 1
    var distant = member(2, "Distant", status: .online)
    distant.memberListIndex = 205
    let sections = MemberSection.make(
        from: [first, distant],
        groups: [GuildMemberListGroup(id: "online", count: 300)]
    )

    let items = NativeMemberListCanvasView.makeItems(sections: sections)

    #expect(items.count == 301)
    #expect(items[1] == .member(first, gatewayIndex: 1))
    #expect(items[2] == .placeholder(gatewayIndex: 2))
    #expect(items[204] == .placeholder(gatewayIndex: 204))
    #expect(items[205] == .member(distant, gatewayIndex: 205))
    #expect(items[206] == .placeholder(gatewayIndex: 206))
    #expect(items[300] == .placeholder(gatewayIndex: 300))
}

@MainActor
@Test func `native member canvas indexes a large sparse document once`() {
    var first = member(1, "First", status: .online)
    first.memberListIndex = 1
    var distant = member(2, "Distant", status: .online)
    distant.memberListIndex = 50_000
    let sections = MemberSection.make(
        from: [first, distant],
        groups: [GuildMemberListGroup(id: "online", count: 50_000)]
    )
    let canvas = NativeMemberListCanvasView()

    #expect(canvas.updateDocumentIfNeeded(sections: sections))
    #expect(canvas.items.count == 50_001)
    #expect(canvas.itemIndexesByID[.member(first.id)] == 1)
    #expect(canvas.itemIndexesByID[.member(distant.id)] == 50_000)
    #expect(!canvas.updateDocumentIfNeeded(sections: sections))
    canvas.tearDown()
}

@MainActor
@Test func `native member hover preserves avatar overlays and native foreground`() {
    let members = (1 ... 3).map {
        member(UInt64($0), "Member \($0)", status: .online)
    }
    let section = MemberSection(
        id: .online,
        title: "Online",
        colorHex: nil,
        totalCount: members.count,
        members: members
    )
    let canvas = NativeMemberListCanvasView(frame: CGRect(x: 0, y: 0, width: 250, height: 300))
    let scrollView = NSScrollView(frame: canvas.frame)
    scrollView.documentView = canvas
    canvas.update(
        sections: [section],
        profilePresentation: nil,
        isProfilePresented: false,
        dismissProfile: {}
    )
    canvas.frame.size.height = canvas.contentHeight
    canvas.updateVisibleOverlaysAndPrewarming()

    #expect(canvas.avatarOverlays.count == members.count)
    let avatarHosts = Set(canvas.avatarOverlays.values.map(ObjectIdentifier.init))

    canvas.hoveredIndex = 1
    canvas.updateVisibleOverlaysAndPrewarming()

    #expect(canvas.rowOverlayIndex == 1)
    #expect(canvas.avatarOverlays.count == members.count)
    #expect(Set(canvas.avatarOverlays.values.map(ObjectIdentifier.init)) == avatarHosts)
    #expect(canvas.rowForegroundOverlay?.itemIndex == 1)

    canvas.hoveredIndex = nil
    canvas.updateVisibleOverlaysAndPrewarming()

    #expect(canvas.rowOverlayIndex == nil)
    #expect(canvas.avatarOverlays.count == members.count)
    #expect(Set(canvas.avatarOverlays.values.map(ObjectIdentifier.init)) == avatarHosts)
    #expect(canvas.rowForegroundOverlay == nil)
    canvas.tearDown()
}

@MainActor
@Test func `native member status uses discord muted color and truncates to the row width`() {
    let color = NativeMemberListCanvasView.memberActivityColor.usingColorSpace(.sRGB)
    #expect(abs((color?.redComponent ?? 0) - 122.0 / 255.0) < 0.000_001)
    #expect(abs((color?.greenComponent ?? 0) - 123.0 / 255.0) < 0.000_001)
    #expect(abs((color?.blueComponent ?? 0) - 131.0 / 255.0) < 0.000_001)

    let font = NSFont.systemFont(ofSize: 12)
    let source = NativeMemberListCanvasView.line(
        "what if i start having lovey statuses about this very long activity",
        font: font,
        color: NativeMemberListCanvasView.memberActivityColor
    )
    let token = NativeMemberListCanvasView.line(
        "…",
        font: font,
        color: NativeMemberListCanvasView.memberActivityColor
    )
    let truncated = NativeMemberListCanvasView.truncatedLine(
        source,
        token: token,
        maximumWidth: 140
    )

    #expect(CTLineGetTypographicBounds(truncated, nil, nil, nil) <= 140.5)
    #expect(
        CTLineGetTypographicBounds(truncated, nil, nil, nil)
            < CTLineGetTypographicBounds(source, nil, nil, nil)
    )
}

@MainActor
@Test func `native member names reserve trailing room for every tag`() {
    let layout = NativeMemberNameLayout.layout(
        measuredNameWidth: 260,
        availableWidth: 150,
        accessoryWidths: [30, 54]
    )

    #expect(layout.nameWidth == 56)
    #expect(layout.accessoryFrames.count == 2)
    #expect(layout.accessoryFrames[0] == CGRect(x: 61, y: 0, width: 30, height: 0))
    #expect(layout.accessoryFrames[1].maxX == 150)
}

@MainActor
@Test func `native member status lays out static and animated custom emoji as inline media`() {
    let font = NSFont.systemFont(ofSize: 12)
    let line = NativeMemberActivityPresentation.line(
        "<:still:123> hello <a:wave:456>",
        font: font,
        color: NativeMemberListCanvasView.memberActivityColor
    )
    let regions = NativeMemberActivityPresentation.emojiRegions(
        in: line,
        origin: CGPoint(x: 50, y: 24)
    )

    #expect(regions.map(\.rawToken) == ["<:still:123>", "<a:wave:456>"])
    #expect(regions.map(\.reference.isAnimated) == [false, true])
    #expect(regions.allSatisfy {
        abs($0.frame.width - NativeMemberListMetrics.activityEmojiSize) < 0.001
            && abs($0.frame.height - NativeMemberListMetrics.activityEmojiSize) < 0.001
    })
    #expect(regions[0].frame.minX == 50)
    #expect(regions[1].frame.minX > regions[0].frame.maxX)
}

@MainActor
@Test func `native member status truncation excludes custom emoji beyond the visible width`() {
    let font = NSFont.systemFont(ofSize: 12)
    let source = NativeMemberActivityPresentation.line(
        "<a:first:123> a long status before <a:last:456>",
        font: font,
        color: NativeMemberListCanvasView.memberActivityColor
    )
    let token = NativeMemberListCanvasView.line(
        "…",
        font: font,
        color: NativeMemberListCanvasView.memberActivityColor
    )
    let truncated = NativeMemberListCanvasView.truncatedLine(
        source,
        token: token,
        maximumWidth: 90
    )
    let regions = NativeMemberActivityPresentation.emojiRegions(
        in: truncated,
        origin: .zero
    )

    #expect(regions.map(\.rawToken) == ["<a:first:123>"])
    #expect(CTLineGetTypographicBounds(truncated, nil, nil, nil) <= 90.5)
}

@MainActor
@Test func `native member status exposes emoji names instead of protocol tokens to accessibility`() {
    #expect(
        NativeMemberActivityPresentation.accessibilityText(
            "<:still:123> hello <a:wave:456>"
        ) == ":still: hello :wave:"
    )
}

@MainActor
@Test func `native member status prefers catalog emoji assets over the CDN fallback`() throws {
    let localURL = URL(fileURLWithPath: "/tmp/member-status-emoji.png")
    let canvas = NativeMemberListCanvasView()
    canvas.customEmojiURLsByID = ["123": localURL]

    let resolved = canvas.activityEmojiURL(
        for: EmojiReference(rawToken: "<a:wave:123>")
    )
    let fallback = try #require(canvas.activityEmojiURL(
        for: EmojiReference(rawToken: "<:still:456>")
    ))

    #expect(resolved == localURL)
    #expect(fallback.host == "cdn.discordapp.com")
    #expect(fallback.path == "/emojis/456.png")
}

@MainActor
@Test func `visible member image request promotes an in flight prefetch`() async throws {
    let url = try #require(URL(string: "https://cdn.example/member-avatar.png"))
    var visibleMember = member(1, "Visible", status: .online)
    visibleMember.user.avatarURL = url
    let canvas = NativeMemberListCanvasView()
    let probe = MemberImagePromotionProbe()
    canvas.items = [.member(visibleMember, gatewayIndex: 0)]
    canvas.imageTasks[url] = Task {
        try? await Task.sleep(for: .seconds(60))
    }
    canvas.imageTaskPriorities[url] = .prefetch
    canvas.imageLoadPromotion = { url, dimension in
        await probe.record(url: url, dimension: dimension)
    }

    canvas.requestImageIfNeeded(url: url, index: 0, priority: .visible)
    for _ in 0 ..< 20 {
        if await probe.calls.count == 1 { break }
        await Task.yield()
    }

    #expect(await probe.calls == [.init(url: url, dimension: 512)])
    #expect(canvas.imageTaskPriorities[url] == .visible)
    canvas.tearDown()
}

@MainActor
@Test func `native member canvas mounts animated status emoji only while its row is visible`() {
    let animatedURL = URL(fileURLWithPath: "/tmp/member-status-animated.gif")
    var animatedMember = member(1, "Animated", status: .online)
    animatedMember.activityText = "<a:wave:123> hello"
    let canvas = NativeMemberListCanvasView(
        frame: CGRect(x: 0, y: 0, width: 250, height: 180)
    )
    let scrollView = NSScrollView(frame: canvas.frame)
    scrollView.documentView = canvas
    canvas.update(
        sections: [MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 1,
            members: [animatedMember]
        )],
        customEmojiURLsByID: ["123": animatedURL],
        profilePresentation: nil,
        isProfilePresented: false,
        dismissProfile: {}
    )
    canvas.frame.size.height = canvas.contentHeight
    canvas.updateVisibleOverlaysAndPrewarming()

    #expect(canvas.activityEmojiOverlays.count == 1)
    #expect(canvas.activityEmojiOverlayConfigurations.values.first?.url == animatedURL)
    #expect(canvas.activityEmojiOverlays.values.first?.frame.width == NativeMemberListMetrics.activityEmojiSize)

    canvas.installActivityEmojiOverlays(in: 0 ..< 0)

    #expect(canvas.activityEmojiOverlays.isEmpty)
    #expect(canvas.activityEmojiOverlayConfigurations.isEmpty)
    canvas.tearDown()
}

@MainActor
@Test func `native member profile popover keeps its anchor while hovering another row`() {
    let members = (1 ... 3).map {
        member(UInt64($0), "Member \($0)", status: .online)
    }
    let presentation = ProfilePresentationState(
        requestID: UUID(),
        member: members[0],
        profile: nil,
        isLoading: true,
        errorMessage: nil
    )
    let canvas = NativeMemberListCanvasView(
        frame: CGRect(x: 0, y: 0, width: 250, height: 300)
    )
    let scrollView = NSScrollView(frame: canvas.frame)
    scrollView.documentView = canvas
    canvas.update(
        sections: [MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: members.count,
            members: members
        )],
        profilePresentation: presentation,
        isProfilePresented: true,
        dismissProfile: {}
    )
    canvas.frame.size.height = canvas.contentHeight
    canvas.updateVisibleOverlaysAndPrewarming()

    let anchorID = ObjectIdentifier(canvas.profilePopoverAnchor)
    #expect(canvas.profileAnchorIndex == 1)

    canvas.hoveredIndex = 2
    canvas.updateVisibleOverlaysAndPrewarming()

    #expect(canvas.rowOverlayIndex == 2)
    #expect(canvas.profileAnchorIndex == 1)
    #expect(anchorID == ObjectIdentifier(canvas.profilePopoverAnchor))

    canvas.hoveredIndex = 3
    canvas.updateVisibleOverlaysAndPrewarming()

    #expect(canvas.rowOverlayIndex == 3)
    #expect(canvas.profileAnchorIndex == 1)
    #expect(anchorID == ObjectIdentifier(canvas.profilePopoverAnchor))
    canvas.tearDown()
}

@MainActor
@Test func `native member selection invalidates both the old and new rows`() {
    let members = (1 ... 3).map {
        member(UInt64($0), "Member \($0)", status: .online)
    }
    let sections = [
        MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: members.count,
            members: members
        ),
    ]
    let canvas = NativeMemberListCanvasView()
    canvas.updateDocumentIfNeeded(sections: sections)

    #expect(canvas.selectionInvalidationIndexes(
        previous: members[0].id,
        current: members[1].id
    ) == [1, 2])
    #expect(canvas.selectionInvalidationIndexes(
        previous: members[1].id,
        current: nil
    ) == [2])
    #expect(canvas.selectionInvalidationIndexes(
        previous: members[1].id,
        current: members[1].id
    ).isEmpty)
    canvas.tearDown()
}

@MainActor
@Test func `stale member profile dismissal cannot close its replacement`() {
    let members = (1 ... 2).map {
        member(UInt64($0), "Member \($0)", status: .online)
    }
    let oldRequestID = UUID()
    let newRequestID = UUID()
    let canvas = NativeMemberListCanvasView()
    var dismissalCount = 0
    canvas.dismissProfile = { dismissalCount += 1 }
    canvas.profilePresentation = ProfilePresentationState(
        requestID: newRequestID,
        member: members[1],
        profile: nil,
        isLoading: true,
        errorMessage: nil
    )

    canvas.dismissProfile(ifCurrent: oldRequestID)
    #expect(dismissalCount == 0)

    canvas.dismissProfile(ifCurrent: newRequestID)
    #expect(dismissalCount == 1)
    canvas.tearDown()
}

@MainActor
@Test func `native member canvas discards stale hover when a gateway snapshot shrinks`() {
    let members = (1 ... 3).map {
        member(UInt64($0), "Member \($0)", status: .online)
    }
    let canvas = NativeMemberListCanvasView(frame: CGRect(x: 0, y: 0, width: 250, height: 300))
    let scrollView = NSScrollView(frame: canvas.frame)
    scrollView.documentView = canvas
    canvas.update(
        sections: [MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: members.count,
            members: members
        )],
        profilePresentation: nil,
        isProfilePresented: false,
        dismissProfile: {}
    )
    canvas.frame.size.height = canvas.contentHeight
    canvas.hoveredIndex = 3
    canvas.updateVisibleOverlaysAndPrewarming()
    #expect(canvas.rowOverlayIndex == 3)

    canvas.update(
        sections: [MemberSection(
            id: .online,
            title: "Online",
            colorHex: nil,
            totalCount: 1,
            members: [members[0]]
        )],
        profilePresentation: nil,
        isProfilePresented: false,
        dismissProfile: {}
    )

    #expect(canvas.hoveredIndex == nil)
    #expect(canvas.rowOverlayIndex == nil)
    #expect(canvas.avatarOverlays.count == 1)
    canvas.tearDown()
}

@MainActor
@Test func `fallback member sections preserve role priority name tie break and member sorting`() {
    let alphaRole = GuildRole(
        id: RoleID(rawValue: 10),
        name: "Alpha",
        position: 10,
        colorHex: 0x11_22_33
    )
    let betaRole = GuildRole(
        id: RoleID(rawValue: 20),
        name: "Beta",
        position: 10,
        colorHex: 0x44_55_66
    )
    let leadRole = GuildRole(
        id: RoleID(rawValue: 30),
        name: "Lead",
        position: 30,
        colorHex: 0x77_88_99
    )
    let members = [
        member(1, "Zulu lead", status: .online, role: leadRole),
        member(2, "Zulu beta", status: .idle, role: betaRole),
        member(3, "Alpha beta", status: .dnd, role: betaRole),
        member(4, "Alpha role", status: .online, role: alphaRole),
        member(5, "Zulu online", status: .online),
        member(6, "Alpha online", status: .idle),
        member(7, "Offline role", status: .offline, role: leadRole),
        member(8, "Offline plain", status: .offline),
    ]

    let sections = MemberSection.make(from: members)

    #expect(sections.map(\.id) == [
        .role(name: "Lead", position: 30),
        .role(name: "Alpha", position: 10),
        .role(name: "Beta", position: 10),
        .online,
        .offline,
    ])
    #expect(sections.map(\.totalCount) == [1, 1, 2, 2, 2])
    #expect(sections.map { $0.members.map(\.user.displayName) } == [
        ["Zulu lead"],
        ["Alpha role"],
        ["Alpha beta", "Zulu beta"],
        ["Alpha online", "Zulu online"],
        ["Offline plain", "Offline role"],
    ])
}

private func member(
    _ id: UInt64,
    _ displayName: String,
    status: PresenceStatus,
    role: GuildRole? = nil
) -> Member {
    Member(
        user: user(id, displayName),
        roleName: role?.name ?? "Member",
        status: status,
        roleID: role?.id,
        rolePosition: role?.position,
        isRoleCategory: role != nil,
        roleIDs: role.map { [$0.id] } ?? [],
        roles: role.map { [$0] } ?? []
    )
}

private func user(_ id: UInt64, _ displayName: String) -> User {
    User(
        id: UserID(rawValue: id),
        username: "user-\(id)",
        displayName: displayName
    )
}

private actor MemberImagePromotionProbe {
    struct Call: Equatable {
        let url: URL
        let dimension: Int
    }

    private(set) var calls: [Call] = []

    func record(url: URL, dimension: Int) {
        calls.append(Call(url: url, dimension: dimension))
    }
}
