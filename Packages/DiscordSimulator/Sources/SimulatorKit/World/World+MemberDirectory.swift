import Foundation

/// The members of a huge server the account hasn't met yet. Discord reports
/// such a server's full member count; its members are made here, the same
/// person for the same index whatever order they're asked for in, when the
/// member list scrolls to them or the client searches them by name.
struct MemberDirectory: Sendable {
    /// `DemoText.person` index of the directory's first person.
    var firstIndex: Int
    /// How many people the directory can make (capped well below the reported count).
    var size: Int
    /// People made so far, by offset.
    var made: [Int: Snowflake] = [:]
    var founded: Date
    /// Roles members may hold: none hoisted, so made people always list under Online.
    var roles: [Snowflake]
    /// The directory's online people in member-list order (by name), worked out on the first scroll.
    var onlineByName: [(offset: Int, name: String)]?
}

extension World {
    func addMemberDirectory(_ guildID: Snowflake, _ directory: MemberDirectory) { memberDirectories[guildID] = directory }

    /// Makes the people the member list's first `count` rows need. Rows sort by name, so people are
    /// made in name order, interleaved with the members the server already holds: rows already sent
    /// never move when a later page makes more people.
    func materializeMembers(_ guildID: Snowflake, onlineUpTo count: Int) {
        guard var directory = memberDirectories[guildID], let guild = guilds[guildID] else { return }
        let order = directory.onlineByName ?? (0 ..< directory.size).compactMap { offset in
            let person = DemoText.person(index: directory.firstIndex + offset)
            return person.presence.status == .offline ? nil : (offset, person.displayName.lowercased())
            // Later people get earlier-dated IDs, so same-name ties follow the list's ID order.
        }.sorted { ($0.name, -$0.offset) < ($1.name, -$1.offset) }
        directory.onlineByName = order
        let made = Set(directory.made.values)
        var held = guild.members.values.filter { !made.contains($0.userID) && isOnline($0.userID) }.map(memberListName).sorted()[...]
        var rows = 0
        for entry in order where rows < count {
            while let first = held.first, first <= entry.name, rows < count {
                held.removeFirst()
                rows += 1
            }
            guard rows < count else { break }
            if directory.made[entry.offset] == nil { makeMember(guildID, &directory, entry.offset) }
            rows += 1
        }
        memberDirectories[guildID] = directory
    }

    /// Makes up to `limit` members whose name starts with `query`, as a member search finds them.
    func materializeMembers(_ guildID: Snowflake, matching query: String, limit: Int) {
        guard var directory = memberDirectories[guildID], !query.isEmpty else { return }
        var found = 0
        for offset in 0 ..< directory.size where found < max(1, limit) {
            let person = DemoText.person(index: directory.firstIndex + offset)
            guard person.username.hasPrefix(query) || person.displayName.lowercased().hasPrefix(query) else { continue }
            found += 1
            if directory.made[offset] == nil { makeMember(guildID, &directory, offset) }
        }
        memberDirectories[guildID] = directory
    }

    @discardableResult
    private func makeMember(_ guildID: Snowflake, _ directory: inout MemberDirectory, _ offset: Int) -> Snowflake {
        let index = directory.firstIndex + offset
        let person = DemoText.person(index: index)
        let created = ScenarioEpoch.accountsReference(for: epoch).addingTimeInterval(-Double(300 + index % 2_000) * 86_400)
        let avatar = person.avatar.map { String(format: "%016llx%016llx", $0.seed, index.description.hashValueStable) }
        let userID = addPerson(person, created: created, avatar: avatar)
        var member = Member(userID: userID, joinedAt: directory.founded.addingTimeInterval(Double(offset % 997) * 3_600))
        if !directory.roles.isEmpty, offset % 3 == 0 { member.roles = [directory.roles[offset % directory.roles.count]] }
        guilds[guildID]?.members[userID] = member
        guilds[guildID]?.memberOrder.append(userID)
        directory.made[offset] = userID
        return userID
    }

    /// A generated person as a user with their presence; returns their ID.
    func addPerson(_ person: DemoPerson, created: Date, avatar: String?) -> Snowflake {
        var user = User(id: nextID(at: created), username: person.username, globalName: person.displayName)
        user.bio = person.bio
        user.pronouns = person.pronouns
        user.premiumType = person.premium.premiumType
        user.avatar = avatar
        if let avatar, let style = person.avatar { setPalette(style.palette, forHash: avatar) }
        let status = PresenceStatus(rawValue: person.presence.status.rawValue) ?? .offline
        let presence = person.presence.customStatus.map { WorldBuilder.presence(status, custom: $0, emoji: person.presence.customStatusEmoji) }
        addUser(user, presence: presence ?? Presence(status: status))
        return user.id
    }
}
