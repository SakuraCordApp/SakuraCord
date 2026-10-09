import SakuraCordModels

/// Reuses the native member canvas without making relationship state a view concern.
struct FriendsProjection {
    let query: String
    private let section: FriendsSection
    private(set) var sections: [MemberSection]
    let pendingIDs: Set<UserID>
    let count: Int
    private let positions: [UserID: (section: Int, row: Int)]

    init(section: FriendsSection, query: String, groups: [FriendsListGroup], revealed: Set<UserID>) {
        self.query = query
        self.section = section
        count = groups.reduce(0) { $0 + $1.rows.count }
        pendingIDs = section == .pending ? Set(groups.flatMap(\.rows).map(\.id)) : []
        var positions: [UserID: (section: Int, row: Int)] = [:]
        sections = groups.enumerated().map { index, group in
            for (rowIndex, row) in group.rows.enumerated() { positions[row.id] = (index, rowIndex) }
            return MemberSection(
                id: .role(name: "Friends \(section) \(index)", position: index),
                title: section == .pending ? (group.rows.first?.relationship.type == .incomingRequest ? "Received" : "Sent") : "",
                colorHex: nil, totalCount: group.rows.count,
                members: group.rows.map { Self.member($0, revealed: revealed.contains($0.id)) }
            )
        }
        self.positions = positions
    }

    var displaySections: [MemberSection] {
        let title = switch section {
        case .online: "Online"
        case .all: "All Friends"
        case .pending: "Pending"
        case .addFriend: ""
        }
        let header = MemberSection(
            id: .role(name: "Friends category", position: -1),
            title: title, colorHex: nil, totalCount: count, members: []
        )
        return [header] + sections
    }

    /// Presence does not change name ordering or search matches. Replace only
    /// the affected member; the owner invalidates Online when membership changes.
    mutating func updatePresence(_ row: FriendRow) {
        guard let position = positions[row.id] else { return }
        let section = sections[position.section]
        var members = section.members
        members[position.row] = Self.member(row, revealed: false)
        sections[position.section] = MemberSection(
            id: section.id, title: section.title, colorHex: section.colorHex,
            totalCount: section.totalCount, members: members
        )
    }

    private static func member(_ row: FriendRow, revealed: Bool) -> Member {
        var user = row.user
        user.displayName = row.name
        let subtitle: String
        switch row.relationship.type {
        case .incomingRequest:
            if let note = row.relationship.note, !note.isEmpty {
                subtitle = revealed ? "“\(note)”" : "View Request"
            } else { subtitle = "Incoming Friend Request" }
        case .outgoingRequest:
            subtitle = row.relationship.note.map { "“\($0)”" } ?? "Outgoing Friend Request"
        default:
            subtitle = row.presence.customStatus ?? row.presence.activityText
                ?? PresenceIndicatorPresentation.accessibilityLabel(for: row.presence.status, isMobile: false)
        }
        return Member(user: user, roleName: "", status: row.presence.status,
                      activityText: subtitle,
                      isListeningToMusic: row.relationship.type == .friend && row.presence.customStatus == nil && row.presence.isListeningToMusic,
                      isMobileOnly: row.presence.isMobileOnly)
    }
}
