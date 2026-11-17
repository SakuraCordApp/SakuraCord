import Foundation

/// Favorites suggestions: who and where the user talks most, ranked from the world's messages.
enum AffinityRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/users/@me/affinities/v2/users"] = { context in
            .json(.object(JSONObject([("user_affinities", .array(await context.world.userAffinities(for: context.userID)))])))
        }
        routes["GET /api/v9/users/@me/affinities/v2/channels"] = { context in
            .json(.object(JSONObject([("channel_affinities", .array(await context.world.channelAffinities(for: context.userID)))])))
        }
    }
}

extension World {
    func userAffinities(for userID: Snowflake) -> [JSON] {
        var direct: [Snowflake: Int] = [:], server: [Snowflake: Int] = [:]
        for channel in channels.values where canView(userID, channel) {
            for message in channel.messages where message.authorID != userID && users[message.authorID]?.bot == false {
                if channel.type.isPrivate { direct[message.authorID, default: 0] += 1 } else { server[message.authorID, default: 0] += 1 }
            }
        }
        let friends = Set((relationships[userID] ?? [:]).values.filter { $0.type == .friend }.map(\.userID))
        let people = Set(direct.keys).union(server.keys)
        // Probabilities saturate with message count; ranks order each measure independently.
        func probability(_ count: Int) -> Double { Double(count) / Double(count + 10) }
        func ranks(_ counts: [Snowflake: Int]) -> [Snowflake: Int] {
            Dictionary(uniqueKeysWithValues: people.sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }.enumerated().map { ($1, $0 + 1) })
        }
        let total = Dictionary(uniqueKeysWithValues: people.map { ($0, (direct[$0] ?? 0) * 2 + (server[$0] ?? 0)) })
        let (dmRanks, serverRanks, communicationRanks) = (ranks(direct), ranks(server), ranks(total))
        return people.sorted { communicationRanks[$0]! < communicationRanks[$1]! }.map { other in
            .object(JSONObject([
                ("other_user_id", other.json), ("user_segment", "HFU_MAU"), ("other_user_segment", "HFU_MAU"),
                ("is_friend", .bool(friends.contains(other))),
                ("dm_probability", .double(probability(direct[other] ?? 0))), ("dm_rank", .int(dmRanks[other]!)),
                ("vc_probability", .double(0)), ("vc_rank", .int(communicationRanks[other]!)),
                ("server_message_probability", .double(probability(server[other] ?? 0))), ("server_message_rank", .int(serverRanks[other]!)),
                ("communication_probability", .double(probability(total[other]!) / 2)), ("communication_rank", .int(communicationRanks[other]!)),
            ]))
        }
    }

    /// Channels the user posts in, scored against their busiest one.
    func channelAffinities(for userID: Snowflake) -> [JSON] {
        let counts = channels.values.filter { canView(userID, $0) }
            .map { ($0.id, $0.messages.count { $0.authorID == userID }) }.filter { $0.1 > 0 }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }
        guard let busiest = counts.first?.1 else { return [] }
        return counts.map { channelID, count in
            .object(JSONObject([("channel_id", channelID.json), ("score", .double(Double(count) / Double(busiest)))]))
        }
    }
}
