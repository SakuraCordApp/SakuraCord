import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `gateway member sections preserve arbitrary group order authoritative counts and slice order`() {
    let moderator = GuildRole(
        id: RoleID(rawValue: 10), name: "Moderator", position: 10, colorHex: 0xFF_88_00
    )
    let helper = GuildRole(
        id: RoleID(rawValue: 20), name: "Helper", position: 20, colorHex: 0x33_AA_FF
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
@Test func `gateway member sections assign indexed members to ordered ranges once`() {
    let role = GuildRole(
        id: RoleID(rawValue: 40), name: "Indexed", position: 20,
        colorHex: 0x44_55_66
    )
    var offlineFirst = member(1, "Offline first", status: .offline)
    offlineFirst.memberListIndex = 1
    var offlineSecond = member(2, "Offline second", status: .offline)
    offlineSecond.memberListIndex = 2
    var skipped = member(3, "Unknown group", status: .online)
    skipped.memberListIndex = 4
    var roleFirst = member(4, "Role first", status: .online, role: role)
    roleFirst.memberListIndex = 6
    var roleSecond = member(5, "Role second", status: .online, role: role)
    roleSecond.memberListIndex = 7

    let sections = MemberSection.make(
        from: [roleSecond, skipped, offlineSecond, roleFirst, offlineFirst],
        groups: [
            GuildMemberListGroup(id: "offline", count: 2),
            GuildMemberListGroup(id: "future-group", count: 1),
            GuildMemberListGroup(id: role.id.description, count: 2),
        ],
        roles: [role]
    )

    #expect(sections.map(\.id) == [
        .offline,
        .role(name: "Indexed", position: 20),
    ])
    #expect(sections.map { $0.members.map(\.id) } == [
        [offlineFirst.id, offlineSecond.id],
        [roleFirst.id, roleSecond.id],
    ])
}

@MainActor
@Test func `fallback member sections preserve role priority name tie break and member sorting`() {
    let alphaRole = GuildRole(
        id: RoleID(rawValue: 10), name: "Alpha", position: 10, colorHex: 0x11_22_33
    )
    let betaRole = GuildRole(
        id: RoleID(rawValue: 20), name: "Beta", position: 10, colorHex: 0x44_55_66
    )
    let leadRole = GuildRole(
        id: RoleID(rawValue: 30), name: "Lead", position: 30, colorHex: 0x77_88_99
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
