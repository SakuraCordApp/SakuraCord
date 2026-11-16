import Foundation
import SakuraCordModels

nonisolated enum DirectMessageMemberResolver {
    static func members(
        for channel: Channel,
        knownMembers: [Member],
        currentUser: User?,
        currentStatus: PresenceStatus
    ) -> [Member] {
        let knownMembersByID = Dictionary(
            knownMembers.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let currentUserID = currentUser?.id
        var resolved: [Member] = []
        var seen: Set<UserID> = []

        func append(_ member: Member) {
            guard seen.insert(member.id).inserted else { return }
            resolved.append(member)
        }

        for user in channel.recipients where user.id != currentUserID {
            append(
                knownMembersByID[user.id]
                    ?? Member(
                        user: user,
                        roleName: "Members",
                        status: .offline
                    )
            )
        }

        if channel.kind == .groupDirectMessage,
           let ownerID = channel.ownerID,
           ownerID != currentUserID,
           let owner = knownMembersByID[ownerID]
        {
            append(owner)
        }

        if let currentUser {
            append(
                knownMembersByID[currentUser.id]
                    ?? Member(
                        user: currentUser,
                        roleName: "You",
                        status: currentStatus
                    )
            )
        }
        return resolved
    }
}

nonisolated struct MemberSection: Identifiable, Equatable, Sendable {
    nonisolated enum SectionIdentifier: Hashable, Sendable {
        case role(name: String, position: Int)
        case online
        case offline
    }

    let id: SectionIdentifier
    let title: String
    let colorHex: UInt32?
    let totalCount: Int
    let members: [Member]
    let gatewayStartIndex: Int?
    let isLoadingSkeleton: Bool
    let role: GuildRole?

    init(
        id: SectionIdentifier,
        title: String,
        colorHex: UInt32?,
        totalCount: Int,
        members: [Member],
        gatewayStartIndex: Int? = nil,
        isLoadingSkeleton: Bool = false,
        role: GuildRole? = nil
    ) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.totalCount = totalCount
        self.members = members
        self.gatewayStartIndex = gatewayStartIndex
        self.isLoadingSkeleton = isLoadingSkeleton
        self.role = role
    }

    static var loadingSkeletonSections: [MemberSection] {
        let memberCounts = [5, 6, 7]
        var gatewayStartIndex = 0
        return memberCounts.enumerated().map { index, count in
            defer { gatewayStartIndex += count + 1 }
            return MemberSection(
                id: .role(name: "Loading members \(index)", position: index),
                title: "",
                colorHex: nil,
                totalCount: count,
                members: [],
                gatewayStartIndex: gatewayStartIndex,
                isLoadingSkeleton: true
            )
        }
    }

    static func make(
        from members: [Member],
        groups: [GuildMemberListGroup] = [],
        roles: [GuildRole] = [],
        forThread: Bool = false
    ) -> [MemberSection] {
        if !groups.isEmpty {
            return makeServerOrderedSections(members: members, groups: groups, roles: roles)
        }
        var roleMembers: [SectionIdentifier: [Member]] = [:]
        var ungroupedOnline: [Member] = []
        var offlineMembers: [Member] = []
        ungroupedOnline.reserveCapacity(members.count)
        offlineMembers.reserveCapacity(members.count)

        for member in members {
            guard forThread ? member.isOnline : member.isListedOnline else {
                offlineMembers.append(member)
                continue
            }
            if member.isRoleCategory == true {
                let id = SectionIdentifier.role(
                    name: member.roleName,
                    position: member.rolePosition ?? 0
                )
                roleMembers[id, default: []].append(member)
            } else {
                ungroupedOnline.append(member)
            }
        }

        let sort = forThread ? threadMemberNameSort : memberNameSort
        var sections = makeRoleSections(roleMembers, roles: roles, sort: sort)

        if !ungroupedOnline.isEmpty {
            ungroupedOnline.sort(by: sort)
            sections.append(MemberSection(
                id: .online,
                title: "Online",
                colorHex: nil,
                totalCount: ungroupedOnline.count,
                members: ungroupedOnline
            ))
        }

        if !offlineMembers.isEmpty {
            offlineMembers.sort(by: sort)
            sections.append(MemberSection(
                id: .offline,
                title: "Offline",
                colorHex: nil,
                totalCount: offlineMembers.count,
                members: offlineMembers
            ))
        }
        return sections
    }

    private static func makeRoleSections(
        _ roleMembers: [SectionIdentifier: [Member]],
        roles: [GuildRole],
        sort: (Member, Member) -> Bool
    ) -> [MemberSection] {
        let rolesByID = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, $0) })
        return roleMembers.map { id, members in
            let name = switch id {
            case let .role(name, _): name
            case .online, .offline: ""
            }
            let position = switch id {
            case let .role(_, pos): pos
            case .online, .offline: 0
            }
            let role = members.lazy.compactMap { member in
                if let roleID = member.roleID, let matchedRole = rolesByID[roleID] { return matchedRole }
                return member.roles.first {
                    if let roleID = member.roleID, $0.id == roleID { return true }
                    return $0.name == member.roleName && $0.position == member.rolePosition
                }
            }.first ?? roles.first { $0.name == name && $0.position == position }
            return MemberSection(
                id: id,
                title: name,
                colorHex: role?.colorHex ?? members.lazy.compactMap { member in
                    member.roles.first {
                        $0.name == member.roleName && $0.position == member.rolePosition
                    }?.colorHex
                }.first,
                totalCount: members.count,
                members: members.sorted(by: sort),
                role: role
            )
        }
        .sorted { lhs, rhs in
            let lhsPosition = lhs.members.first?.rolePosition ?? 0
            let rhsPosition = rhs.members.first?.rolePosition ?? 0
            if lhsPosition != rhsPosition {
                return lhsPosition > rhsPosition
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func makeServerOrderedSections(
        members: [Member],
        groups: [GuildMemberListGroup],
        roles: [GuildRole]
    ) -> [MemberSection] {
        let rolesByID = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, $0) })
        let inferredMembersByGroup = Dictionary(grouping: members.lazy.filter {
            $0.memberListIndex == nil
        }) { member in
            member.roleID?.description ?? (member.isListedOnline ? "online" : "offline")
        }
        let indexedMembers = members.lazy.compactMap { member -> (Int, Member)? in
            member.memberListIndex.map { ($0, member) }
        }.sorted { lhs, rhs in
            lhs.0 < rhs.0
        }
        var indexedMemberCursor = 0
        var startIndex = 0
        var sections: [MemberSection] = []
        sections.reserveCapacity(groups.count)
        for group in groups {
            defer { startIndex += group.count + 1 }
            let memberRange: ClosedRange<Int>? = if group.count > 0 {
                (startIndex + 1) ... (startIndex + group.count)
            } else {
                nil
            }
            var membersInRange: [Member] = []
            if let memberRange {
                while indexedMemberCursor < indexedMembers.count,
                      indexedMembers[indexedMemberCursor].0 < memberRange.lowerBound
                {
                    indexedMemberCursor += 1
                }
                let rangeStart = indexedMemberCursor
                while indexedMemberCursor < indexedMembers.count,
                      indexedMembers[indexedMemberCursor].0 <= memberRange.upperBound
                {
                    indexedMemberCursor += 1
                }
                membersInRange.reserveCapacity(indexedMemberCursor - rangeStart)
                membersInRange.append(contentsOf: indexedMembers[
                    rangeStart ..< indexedMemberCursor
                ].map(\.1))
            }
            let loadedMembers = membersInRange
                + (inferredMembersByGroup[group.id] ?? [])
            if group.id == "online" || group.id == "offline" {
                sections.append(MemberSection(
                    id: group.id == "online" ? .online : .offline,
                    title: group.id == "online" ? "Online" : "Offline",
                    colorHex: nil,
                    totalCount: group.count,
                    members: loadedMembers,
                    gatewayStartIndex: startIndex
                ))
                continue
            }
            guard let roleID = RoleID(group.id) else { continue }
            let role = rolesByID[roleID]
            let title = role?.name ?? loadedMembers.first?.roleName ?? "Members"
            sections.append(MemberSection(
                id: .role(name: title, position: role?.position ?? 0),
                title: title,
                colorHex: role?.colorHex,
                totalCount: group.count,
                members: loadedMembers,
                gatewayStartIndex: startIndex,
                role: role
            ))
        }
        return sections
    }

    private static func threadMemberNameSort(_ lhs: Member, _ rhs: Member) -> Bool {
        let left = lhs.user.displayName.lowercased()
        let right = rhs.user.displayName.lowercased()
        return left == right ? lhs.id < rhs.id : left < right
    }

    private static func memberNameSort(_ lhs: Member, _ rhs: Member) -> Bool {
        lhs.user.displayName.localizedStandardCompare(rhs.user.displayName)
            == .orderedAscending
    }
}
