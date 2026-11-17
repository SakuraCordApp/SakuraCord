import Foundation

/// The lazily loaded member sidebar: hoisted roles, then online, then offline,
/// each group header followed by its members with their presence.
extension World {
    func renderMemberList(guildID: Snowflake, channelID: Snowflake, ranges: [ClosedRange<Int>]) -> JSON? {
        // Each list row is a member or a group header, so this makes a few more than the rows asked for.
        materializeMembers(guildID, onlineUpTo: (ranges.map(\.upperBound).max() ?? 0) + 1)
        guard let guild = guilds[guildID], let channel = channels[channelID] else { return nil }
        let viewers = guild.memberOrder.compactMap { guild.members[$0] }.filter { canView($0.userID, channel) }
        let hoisted = guild.roles.filter(\.hoist).sorted { $0.position > $1.position }
        struct Group {
            var id: String
            var members: [Member]
            /// Can exceed `members` in a server too big to hold everyone.
            var count: Int
        }
        var groups: [Group] = []
        var placed: Set<Snowflake> = []
        for role in hoisted {
            let members = viewers.filter { isOnline($0.userID) && $0.roles.contains(role.id) && !placed.contains($0.userID) }.sorted(by: listsBefore)
            placed.formUnion(members.map(\.userID))
            if !members.isEmpty { groups.append(Group(id: role.id.description, members: members, count: members.count)) }
        }
        let online = viewers.filter { isOnline($0.userID) && !placed.contains($0.userID) }.sorted(by: listsBefore)
        let listID = memberListID(channel, in: guild)
        // The everyone list of a server too big to hold every member counts all the members it
        // reports, though only the rows asked for exist; a channel's own list groups who can see it.
        let reported = guild.approximateMemberCount != nil && listID == "everyone"
        let staff = groups.reduce(0) { $0 + $1.count }
        let othersOnline = reported ? max(online.count, onlineCount(guild) - staff) : online.count
        // Discord lists only groups that have members.
        if othersOnline > 0 { groups.append(Group(id: "online", members: online, count: othersOnline)) }
        if guild.listsOfflineMembers {
            let offline = viewers.filter { !isOnline($0.userID) }.sorted(by: listsBefore)
            if !offline.isEmpty { groups.append(Group(id: "offline", members: offline, count: offline.count)) }
        }

        enum Row { case group(Group), member(Member) }
        let rows = groups.flatMap { [Row.group($0)] + $0.members.map(Row.member) }
        // Only the rows a range asks for are rendered.
        func render(_ row: Row) -> JSON {
            switch row {
            case let .group(group):
                return .object(JSONObject([("group", .object(JSONObject([("id", .string(group.id)), ("count", .int(group.count))])))]))
            case let .member(member):
                var rendered = renderMember(member, guildID: guildID, includeUser: true).objectValue ?? JSONObject()
                rendered["presence"] = renderPresence(member.userID, guildID: nil).removing("broadcast")
                return .object(JSONObject([("member", .object(rendered))]))
            }
        }
        let ops: [JSON] = ranges.map { range in
            let slice = rows.indices.contains(range.lowerBound) ? rows[range.lowerBound ... min(range.upperBound, rows.count - 1)].map(render) : []
            return .object(JSONObject([("op", "SYNC"), ("range", .array([.int(range.lowerBound), .int(range.upperBound)])), ("items", .array(slice))]))
        }
        return .object(JSONObject([
            ("ops", .array(ops)),
            // Both counts are the whole server's, even for a private channel's list (as captured).
            ("online_count", .int(onlineCount(guild))),
            ("member_count", .int(guild.memberCount)),
            ("id", .string(listID)), ("guild_id", guildID.json),
            ("groups", .array(groups.map { group in .object(JSONObject([("id", .string(group.id)), ("count", .int(group.count))])) })),
        ]))
    }

    /// Op 8's GUILD_MEMBERS_CHUNK for one server; nil when the server is unknown.
    func renderMembersChunk(guildID: Snowflake, query: String?, limit: Int, requested: Set<Snowflake>,
                            nonce: String?, presences: Bool) -> JSON? {
        if let query { materializeMembers(guildID, matching: query, limit: limit) }
        guard let guild = guilds[guildID] else { return nil }
        var members: [JSON] = []
        var memberIDs: [Snowflake] = []
        for id in guild.memberOrder {
            guard let member = guild.members[id], let user = users[id] else { continue }
            if !requested.isEmpty, !requested.contains(id) { continue }
            if let query, !query.isEmpty,
               !(user.username.lowercased().hasPrefix(query) || (user.globalName ?? "").lowercased().hasPrefix(query)
                   || (member.nick ?? "").lowercased().hasPrefix(query)) { continue }
            members.append(renderMember(member, guildID: guildID, includeUser: true))
            memberIDs.append(id)
            if limit > 0, members.count >= limit { break }
        }
        var chunk = JSONObject([("guild_id", guildID.json), ("members", .array(members)),
                                ("chunk_index", 0), ("chunk_count", 1)])
        if let nonce { chunk["nonce"] = .string(nonce) }
        // Requests by ID list the IDs that aren't members.
        if !requested.isEmpty {
            chunk["not_found"] = .array(requested.subtracting(guild.members.keys).sorted().map(\.json))
        }
        if presences { chunk["presences"] = .array(memberIDs.map { renderPresence($0, guildID: guildID) }) }
        return .object(chunk)
    }

    /// The list ID the official client derives for a channel (web client bundle): `everyone` when
    /// @everyone can view it and no overwrite denies viewing; otherwise MurmurHash3 of the
    /// channel's own overwrites that allow or deny viewing. Threads check their parent but hash
    /// their own (empty) overwrites, and private threads never count as viewable by everyone.
    func memberListID(_ channel: Channel, in guild: Guild) -> String {
        let source = channel.type == .privateThread ? nil : permissionChannel(channel)
        let everyone = guild.everyoneRole?.permissions.contains(.viewChannel) == true
        if let source, everyone, !source.overwrites.contains(where: { $0.deny.contains(.viewChannel) }) { return "everyone" }
        let entries = channel.overwrites.compactMap { overwrite -> String? in
            if overwrite.allow.contains(.viewChannel) { return "allow:\(overwrite.id)" }
            return overwrite.deny.contains(.viewChannel) ? "deny:\(overwrite.id)" : nil
        }
        return String(Self.murmur3(Array(entries.sorted().joined(separator: ",").utf8)))
    }

    /// MurmurHash3 x86 32-bit, seed 0.
    static func murmur3(_ bytes: [UInt8]) -> UInt32 {
        let c1: UInt32 = 0xcc9e_2d51, c2: UInt32 = 0x1b87_3593
        var hash: UInt32 = 0
        func mix(_ value: UInt32) -> UInt32 { (value &* c1).rotatedLeft(15) &* c2 }
        let blocks = bytes.count / 4
        for block in 0 ..< blocks {
            let index = block * 4
            let word = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            hash = (hash ^ mix(word)).rotatedLeft(13) &* 5 &+ 0xe654_6b64
        }
        var tail: UInt32 = 0
        for (offset, byte) in bytes[(blocks * 4)...].enumerated() { tail |= UInt32(byte) << (8 * UInt32(offset)) }
        if bytes.count % 4 > 0 { hash ^= mix(tail) }
        hash ^= UInt32(truncatingIfNeeded: bytes.count)
        hash ^= hash >> 16
        hash &*= 0x85eb_ca6b
        hash ^= hash >> 13
        hash &*= 0xc2b2_ae35
        return hash ^ (hash >> 16)
    }

    /// The name a member list sorts by.
    func memberListName(_ member: Member) -> String {
        (member.nick ?? users[member.userID]?.globalName ?? users[member.userID]?.username ?? "").lowercased()
    }

    /// Member-list order: by name, then by ID, so people with the same name keep their rows.
    func listsBefore(_ lhs: Member, _ rhs: Member) -> Bool {
        (memberListName(lhs), lhs.userID) < (memberListName(rhs), rhs.userID)
    }

    func isOnline(_ userID: Snowflake) -> Bool { ![.offline, .invisible].contains(presences[userID]?.status ?? .offline) }
}

/// Forum and thread lists: active threads arrive through THREAD_LIST_SYNC and
/// post previews through `POST /channels/{id}/post-data`, as the official client loads them.
extension World {
    func renderThreadListSync(guildID: Snowflake, viewer: Snowflake) -> JSON? {
        guard let guild = guilds[guildID] else { return nil }
        let threads = guild.channelIDs.compactMap { channels[$0] }
            .filter { $0.type.isThread && $0.thread?.archived == false && canView(viewer, $0) }
        return .object(JSONObject([
            ("guild_id", guildID.json),
            ("threads", .array(threads.map { renderThread($0, viewer: viewer) })),
            ("most_recent_messages", .array(threads.compactMap { thread in
                thread.messages.last.map { renderMessage($0, viewer: viewer).merging(["is_thread_dispatch": true]) }
            })),
        ]))
    }

    func renderPostData(threadIDs: [Snowflake], viewer: Snowflake) -> JSON {
        var threads = JSONObject()
        for id in threadIDs {
            guard let thread = channels[id], canView(viewer, thread), let first = thread.messages.first else { continue }
            var entry = JSONObject([("first_message", renderMessage(first, viewer: viewer))])
            if let guildID = thread.guildID, let owner = thread.ownerID, let member = guilds[guildID]?.members[owner] {
                entry["owner"] = renderMember(member, guildID: guildID, includeUser: true)
            }
            threads[id.description] = .object(entry)
        }
        return .object(JSONObject([("threads", .object(threads))]))
    }
}

extension Guild {
    /// Discord's server decides this, so the client has no threshold to copy. Discord support-forum
    /// posts say offline members are hidden "once a server has more than 1,000 members", in every list,
    /// private channels included. Captures agree: a 784-member server lists offline members, a
    /// 1,463-member one doesn't (not even in a small private channel), and neither does a small private
    /// channel in a 500k server.
    var listsOfflineMembers: Bool { memberCount <= 1_000 }
}

private extension UInt32 {
    func rotatedLeft(_ count: UInt32) -> UInt32 { self << count | self >> (32 - count) }
}
