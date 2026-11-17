import Foundation

/// The lazily loaded member sidebar: hoisted roles, then online, then offline,
/// each group header followed by its members with their presence.
extension World {
    func renderMemberList(guildID: Snowflake, channelID: Snowflake, ranges: [ClosedRange<Int>]) -> JSON? {
        // Each list row is a member or a group header, so this makes a few more than the rows asked for.
        materializeMembers(guildID, onlineUpTo: (ranges.map(\.upperBound).max() ?? 0) + 1)
        guard let guild = guilds[guildID], let channel = channels[channelID] else { return nil }
        let viewers = guild.memberOrder.compactMap { guild.members[$0] }.filter { canView($0.userID, channel) }
        func name(_ member: Member) -> String {
            (member.nick ?? users[member.userID]?.globalName ?? users[member.userID]?.username ?? "").lowercased()
        }
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
            let members = viewers.filter { isOnline($0.userID) && $0.roles.contains(role.id) && !placed.contains($0.userID) }.sorted { name($0) < name($1) }
            placed.formUnion(members.map(\.userID))
            if !members.isEmpty { groups.append(Group(id: role.id.description, members: members, count: members.count)) }
        }
        let online = viewers.filter { isOnline($0.userID) && !placed.contains($0.userID) }.sorted { name($0) < name($1) }
        let listID = memberListID(channel, in: guild)
        // The everyone list of a server too big to hold every member counts all the members it
        // reports, though only the rows asked for exist; a channel's own list groups who can see it.
        let reported = guild.approximateMemberCount != nil && listID == "everyone"
        let staff = groups.reduce(0) { $0 + $1.count }
        let othersOnline = reported ? max(online.count, onlineCount(guild) - staff) : online.count
        // Discord lists only groups that have members.
        if othersOnline > 0 { groups.append(Group(id: "online", members: online, count: othersOnline)) }
        if guild.listsOfflineMembers {
            let offline = viewers.filter { !isOnline($0.userID) }.sorted { name($0) < name($1) }
            if !offline.isEmpty { groups.append(Group(id: "offline", members: offline, count: offline.count)) }
        }

        var items: [JSON] = []
        for group in groups {
            items.append(.object(JSONObject([("group", .object(JSONObject([("id", .string(group.id)), ("count", .int(group.count))])))])))
            for member in group.members {
                guard case var .object(rendered) = renderMember(member, guildID: guildID, includeUser: true) else { continue }
                rendered["presence"] = renderPresence(member.userID, guildID: nil).removing("broadcast")
                items.append(.object(JSONObject([("member", .object(rendered))])))
            }
        }
        let ops: [JSON] = ranges.map { range in
            let slice = items.indices.contains(range.lowerBound) ? Array(items[range.lowerBound ... min(range.upperBound, items.count - 1)]) : []
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
