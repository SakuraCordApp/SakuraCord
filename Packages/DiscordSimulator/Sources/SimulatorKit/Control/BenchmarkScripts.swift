import Foundation

/// Live event streams for benchmarks, started with `POST /control/scripts`.
/// Every event goes through the same world mutations (and so the same
/// Gateway dispatches) as real activity.
enum BenchmarkScripts {
    static let all: [String: ScriptRunner.Script] = [
        "timeline-stress": timelineStress,
        "unread-churn": unreadChurn,
        "presence-churn": presenceChurn,
        "rail-badges": railBadges,
    ]

    /// Reactions, message arrivals and edits/deletes streaming into one channel at
    /// once, starting half a second in. Params: `channel_id` (or `channel` name),
    /// `reactions`, `arrivals`, `mutations` (counts; missing or 0 skips that
    /// stream), `burst` 4 and `interval_ms` 32 for arrivals and mutations.
    /// Reactions land every 25 ms on the latest 300 messages; mutations edit
    /// the latest 600 and delete every fifth.
    static let timelineStress: ScriptRunner.Script = { world, params in
        let channelID = try await resolveChannel(world, params)
        let interval = Duration.milliseconds(params["interval_ms"]?.intValue ?? 32)
        let burst = max(1, Int(params["burst"]?.intValue ?? 4))
        guard let guildID = try await world.channel(channelID).guildID else { return }
        let me = await world.primaryUserID
        let authors = try await world.guild(guildID).memberOrder.filter { $0 != me }
        guard !authors.isEmpty else { return }
        let reactions = Int(params["reactions"]?.intValue ?? 0)
        let arrivals = Int(params["arrivals"]?.intValue ?? 0)
        let mutations = Int(params["mutations"]?.intValue ?? 0)
        try await Task.sleep(for: .milliseconds(500))
        try await withThrowingTaskGroup(of: Void.self) { group in
            if reactions > 0 {
                group.addTask { try await streamReactions(world, channelID, authors, count: reactions) }
            }
            if arrivals > 0 {
                group.addTask { try await streamArrivals(world, channelID, authors, count: arrivals, burst: burst, interval: interval) }
            }
            if mutations > 0 {
                group.addTask { try await streamMutations(world, channelID, count: mutations, burst: burst, interval: interval) }
            }
            try await group.waitForAll()
        }
    }

    static func streamReactions(_ world: World, _ channelID: Snowflake, _ authors: [Snowflake], count: Int) async throws {
        var random = SeededRandom(seed: world.seed).fork("timeline-stress-reactions")
        let emojis = ["👍", "😂", "❤️", "🔥", "👀", "🎉"]
        for index in 0 ..< count {
            let recent = try await world.channel(channelID).messages.suffix(300)
            guard let message = recent.randomElement(using: &random)?.id else { break }
            let author = authors[index % authors.count]
            let emoji = emojis[index % emojis.count]
            if index % 3 == 2 {
                try? await world.unreact(message, in: channelID, by: author, emojiName: emoji, emojiID: nil, burst: false)
            } else {
                try? await world.react(message, in: channelID, by: author, emojiName: emoji, emojiID: nil, burst: false)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func streamArrivals(_ world: World, _ channelID: Snowflake, _ authors: [Snowflake], count: Int, burst: Int,
                               interval: Duration) async throws {
        var random = SeededRandom(seed: world.seed).fork("timeline-stress-arrivals")
        for index in 0 ..< count {
            _ = try await world.sendMessage(MessageDraft(content: DemoText.message(&random)),
                                            as: authors[(index * 5) % authors.count], in: channelID, checkPermissions: false)
            if index % burst == burst - 1 { try await Task.sleep(for: interval) }
        }
    }

    static func streamMutations(_ world: World, _ channelID: Snowflake, count: Int, burst: Int, interval: Duration) async throws {
        var random = SeededRandom(seed: world.seed).fork("timeline-stress-mutations")
        for index in 0 ..< count {
            let recent = try await world.channel(channelID).messages.suffix(600)
            guard let target = recent.randomElement(using: &random) else { break }
            if index % 5 == 4 {
                try? await world.deleteMessage(target.id, in: channelID, by: target.authorID)
            } else {
                _ = try? await world.editMessage(target.id, in: channelID, by: target.authorID,
                                                 content: target.content + " (edited)", embeds: nil, flags: nil)
            }
            if index % burst == burst - 1 { try await Task.sleep(for: interval) }
        }
    }

    /// Mentions of the signed-in user arriving in other servers. Params: `rate` per second 5, `duration_s` 10,
    /// `exclude_guild_id` (the server on screen).
    static let unreadChurn: ScriptRunner.Script = { world, params in
        guard let me = await world.primaryUserID else { return }
        try await mentionChurn(world, me: me, rate: params["rate"]?.intValue ?? 5, duration: params["duration_s"]?.intValue ?? 10,
                               label: "unread-churn", excluding: params["exclude_guild_id"]?.stringValue.flatMap(Snowflake.init))
    }

    /// Mentions spread across the whole server rail. Params: `rate` 5, `duration_s` 10.
    static let railBadges: ScriptRunner.Script = { world, params in
        guard let me = await world.primaryUserID else { return }
        try await mentionChurn(world, me: me, rate: params["rate"]?.intValue ?? 5, duration: params["duration_s"]?.intValue ?? 10,
                               label: "rail-badges")
    }

    /// Friends changing status. Params: `rate` per second 20, `duration_s` 20.
    static let presenceChurn: ScriptRunner.Script = { world, params in
        guard let me = await world.primaryUserID else { return }
        let friends = await (world.relationships[me] ?? [:]).values.filter { $0.type == .friend }.map(\.userID).sorted()
        guard !friends.isEmpty else { return }
        let rate = max(1, params["rate"]?.intValue ?? 20)
        let total = Int(rate * (params["duration_s"]?.intValue ?? 20))
        let statuses: [PresenceStatus] = [.online, .idle, .dnd, .offline]
        for index in 0 ..< total {
            let friend = friends[(index * 37) % friends.count]
            var presence = await world.presences[friend] ?? Presence()
            presence.status = statuses[index % statuses.count]
            await world.updatePresence(friend, presence)
            try await Task.sleep(for: .milliseconds(1_000 / rate))
        }
    }

    static func mentionChurn(_ world: World, me: Snowflake, rate: Int64, duration: Int64, label: String,
                             excluding excluded: Snowflake? = nil) async throws {
        let guilds = await world.guilds(of: me).filter { $0.id != excluded }
        var targets: [(channel: Snowflake, author: Snowflake)] = []
        for guild in guilds {
            for channel in await world.visibleChannels(in: guild, for: me) where channel.type == .text {
                if let author = guild.memberOrder.first(where: { $0 != me }) { targets.append((channel.id, author)) }
            }
        }
        guard !targets.isEmpty else { return }
        var random = SeededRandom(seed: world.seed).fork(label)
        let total = Int(max(1, rate) * duration)
        for index in 0 ..< total {
            let target = targets[(index * 7) % targets.count]
            let draft = MessageDraft(content: "<@\(me)> \(DemoText.message(&random))")
            _ = try await world.sendMessage(draft, as: target.author, in: target.channel, checkPermissions: false)
            try await Task.sleep(for: .milliseconds(1_000 / max(1, rate)))
        }
    }

    static func resolveChannel(_ world: World, _ params: JSON) async throws -> Snowflake {
        if let id = params["channel_id"]?.stringValue.flatMap(Snowflake.init) { return id }
        let name = params["channel"]?.stringValue ?? "general"
        guard let channel = await world.channels.values.filter({ $0.name == name && $0.guildID != nil }).max(by: { $0.messages.count < $1.messages.count })
        else { throw WorldError.unknown("Channel \(name)", code: 10003) }
        return channel.id
    }
}
