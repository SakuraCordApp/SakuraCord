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
    var made: Set<Int> = []
    var founded: Date
    /// Roles members may hold (none of the staff roles).
    var roles: [Snowflake]
}

extension World {
    func addMemberDirectory(_ guildID: Snowflake, _ directory: MemberDirectory) { memberDirectories[guildID] = directory }

    /// Makes members until the server holds `count` online ones, for the member list's rows.
    func materializeMembers(_ guildID: Snowflake, onlineUpTo count: Int) {
        guard var directory = memberDirectories[guildID] else { return }
        var online = guilds[guildID]?.members.keys.count(where: isOnline) ?? count
        var offset = 0
        while online < count, offset < directory.size {
            if !directory.made.contains(offset), isOnline(makeMember(guildID, &directory, offset)) { online += 1 }
            offset += 1
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
            if !directory.made.contains(offset) { makeMember(guildID, &directory, offset) }
        }
        memberDirectories[guildID] = directory
    }

    @discardableResult
    private func makeMember(_ guildID: Snowflake, _ directory: inout MemberDirectory, _ offset: Int) -> Snowflake {
        let index = directory.firstIndex + offset
        let person = DemoText.person(index: index)
        let created = ScenarioEpoch.accountsReference(for: epoch).addingTimeInterval(-Double(300 + index % 2_000) * 86_400)
        let userID = addPerson(person, created: created, avatar: String(format: "%016llx%016llx", person.avatar.seed, index.description.hashValueStable))
        var member = Member(userID: userID, joinedAt: directory.founded.addingTimeInterval(Double(offset % 997) * 3_600))
        if !directory.roles.isEmpty, offset % 3 == 0 { member.roles = [directory.roles[offset % directory.roles.count]] }
        guilds[guildID]?.members[userID] = member
        guilds[guildID]?.memberOrder.append(userID)
        directory.made.insert(offset)
        return userID
    }

    /// A generated person as a user with their presence; returns their ID.
    func addPerson(_ person: DemoPerson, created: Date, avatar: String) -> Snowflake {
        var user = User(id: nextID(at: created), username: person.username, globalName: person.displayName)
        user.bio = person.bio
        user.pronouns = person.pronouns
        user.premiumType = person.premium.premiumType
        user.avatar = avatar
        setPalette(person.avatar.palette, forHash: avatar)
        let status = PresenceStatus(rawValue: person.presence.status.rawValue) ?? .offline
        let presence = person.presence.customStatus.map { WorldBuilder.presence(status, custom: $0, emoji: person.presence.customStatusEmoji) }
        addUser(user, presence: presence ?? Presence(status: status))
        return user.id
    }
}
