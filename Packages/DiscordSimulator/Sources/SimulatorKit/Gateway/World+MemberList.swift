import Foundation

/// The lazily loaded member sidebar: hoisted roles, then online, then offline,
/// each group header followed by its members with their presence.
extension World {
    func renderMemberList(guildID: Snowflake, channelID: Snowflake, ranges: [ClosedRange<Int>]) -> JSON? {
        guard let guild = guilds[guildID], let channel = channels[channelID] else { return nil }
        let viewers = guild.memberOrder.compactMap { guild.members[$0] }.filter { canView($0.userID, channel) }
        func isOnline(_ id: Snowflake) -> Bool { ![.offline, .invisible].contains(presences[id]?.status ?? .offline) }
        func name(_ member: Member) -> String {
            (member.nick ?? users[member.userID]?.globalName ?? users[member.userID]?.username ?? "").lowercased()
        }
        let hoisted = guild.roles.filter(\.hoist).sorted { $0.position > $1.position }
        var groups: [(id: String, members: [Member])] = []
        var placed: Set<Snowflake> = []
        for role in hoisted {
            let members = viewers.filter { isOnline($0.userID) && $0.roles.contains(role.id) && !placed.contains($0.userID) }.sorted { name($0) < name($1) }
            placed.formUnion(members.map(\.userID))
            if !members.isEmpty { groups.append((role.id.description, members)) }
        }
        groups.append(("online", viewers.filter { isOnline($0.userID) && !placed.contains($0.userID) }.sorted { name($0) < name($1) }))
        groups.append(("offline", viewers.filter { !isOnline($0.userID) }.sorted { name($0) < name($1) }))

        var items: [JSON] = []
        for group in groups where !group.members.isEmpty || group.id == "online" {
            items.append(.object(JSONObject([("group", .object(JSONObject([("id", .string(group.id)), ("count", .int(group.members.count))])))])))
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
        let online = viewers.filter { isOnline($0.userID) }.count
        // Discord names a list by its channel's overwrites; channels everyone sees share "everyone".
        let listID = channel.overwrites.isEmpty ? "everyone" : String(channel.id.rawValue.description.hashValueStable % 4_294_967_296)
        return .object(JSONObject([
            ("ops", .array(ops)), ("online_count", .int(online)), ("member_count", .int(viewers.count)),
            ("id", .string(listID)), ("guild_id", guildID.json),
            ("groups", .array(groups.filter { !$0.members.isEmpty || $0.id == "online" }.map { group in
                .object(JSONObject([("id", .string(group.id)), ("count", .int(group.members.count))]))
            })),
        ]))
    }
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
