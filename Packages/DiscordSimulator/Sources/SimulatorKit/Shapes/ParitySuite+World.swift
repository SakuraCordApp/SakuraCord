import Foundation

public extension ParitySuite {
    /// The generated account modes' shapes: READY, GUILD_CREATE, lazily generated
    /// history, threads and forum posts, on-demand member lists and member chunks,
    /// and whatever the live activity sends meanwhile, all from the biggest generated server.
    static func runWorld(scenario: String, seed: UInt64 = 7) async -> Report {
        // Live activity starts after the startup check, so READY's sequence never sees it.
        await run(scenario: scenario, parameters: ["activity": "off"], seed: seed, mutate: nil) { try await $0.executeWorld() }
    }
}

extension ParityRun {
    mutating func executeWorld() async throws {
        let world = simulator.world
        guard let me = await world.primaryUserID, let token = await world.tokens.first(where: { $0.value == me })?.key else {
            throw WorldError.invalidBody("scenario has no primary account")
        }
        self.token = token
        let probe = try GatewayProbe(url: URL(string: "ws://127.0.0.1:\(simulator.port(.gateway))/?v=9&encoding=etf&compress=zstd-stream")!)
        gateway = probe
        try await probe.identify(token: token)
        // A big account's READY is megabytes, as on Discord; debug builds take seconds to send it.
        let startup = try await probe.waitFor("READY_SUPPLEMENTAL", timeout: .seconds(60))
        checkSequence("startup", observed: startup.map(\.name))
        for frame in startup where frame.op == 0 { checkFrame(frame) }
        _ = try await simulator.scripts.start(LiveActivity.name, params: .object(JSONObject()))

        guard let guild = await world.guilds.values.filter({ $0.approximateMemberCount != nil }).max(by: { $0.memberCount < $1.memberCount }),
              let channel = guild.systemChannelID else { throw WorldError.invalidBody("scenario has no huge generated server") }
        await checkGuildCreate(guild, viewer: me)

        // History beyond the latest message is generated on this first look.
        let page = try await rest("GET", "/api/v9/channels/\(channel)/messages?limit=50")
        if let oldest = page.arrayValue?.last?["id"]?.stringValue {
            _ = try await rest("GET", "/api/v9/channels/\(channel)/messages?before=\(oldest)&limit=50")
        }
        let threads = await world.channels.values.filter { $0.guildID == guild.id && $0.type.isThread }.map(\.id).sorted()
        if let thread = threads.first { _ = try await rest("GET", "/api/v9/channels/\(thread)/messages?limit=50") }
        if let forum = await world.channels.values.first(where: { $0.guildID == guild.id && $0.type == .forum })?.id {
            _ = try await rest("GET", "/api/v9/channels/\(forum)/threads/search?sort_by=last_message_time&sort_order=desc&limit=25&offset=0")
        }

        // Scrolling the member list and searching members make people on demand.
        let everyone = try await memberList(probe, guild: guild.id, channel: channel, ranges: [[0, 99], [100, 199]])
        expectList(everyone, "huge server's everyone list", everyone: true, offline: false)
        try await checkListRules(probe)
        try await probe.send(.object(JSONObject([("op", 8), ("d", .object(JSONObject([
            ("guild_id", .array([guild.id.json])), ("query", "a"), ("limit", 10), ("presences", true),
        ])))])))
        for frame in try await probe.waitFor("GUILD_MEMBERS_CHUNK") where frame.op == 0 { checkFrame(frame) }
        if let stranger = await world.guilds[guild.id]?.memberOrder.last {
            _ = try await rest("GET", "/api/v9/users/\(stranger)/profile?with_mutual_guilds=true&with_mutual_friends=true&guild_id=\(guild.id)")
        }
        // Live activity that arrived meanwhile.
        for frame in await probe.drain(settle: .seconds(2)) where frame.op == 0 { checkFrame(frame) }
    }

    /// Discord's list rules: a channel whose @everyone overwrite only stops sending is still everyone's
    /// list (the official client ignores updates for any other ID); only servers of up to 1,000 members
    /// show an offline group, so a hidden room in a huge server has none while a small server's list does;
    /// every list carries the server's member count; and only groups with members are listed.
    private mutating func checkListRules(_ probe: GatewayProbe) async throws {
        let world = simulator.world
        let channels = await world.channels.values.sorted { $0.id < $1.id }
        guard let readOnly = channels.first(where: { channel in
            !channel.overwrites.isEmpty && channel.overwrites.allSatisfy { $0.id == channel.guildID && $0.deny == .sendMessages }
        }), let readOnlyGuild = readOnly.guildID else { throw WorldError.invalidBody("scenario has no read-only channel") }
        expectList(try await memberList(probe, guild: readOnlyGuild, channel: readOnly.id), "read-only channel", everyone: true, offline: nil)

        var hiddenRoom: (guild: Guild, viewers: Int)?
        var hiddenChannel = Snowflake(0)
        for channel in channels where hiddenRoom == nil && channel.overwrites.contains(where: { $0.deny.contains(.viewChannel) }) {
            guard let guildID = channel.guildID, let guild = await world.guilds[guildID], guild.approximateMemberCount != nil else { continue }
            var viewers = 0, someoneOffline = false
            for id in guild.members.keys where await world.canView(id, channel) {
                viewers += 1
                if await !world.isOnline(id) { someoneOffline = true }
            }
            if someoneOffline { (hiddenRoom, hiddenChannel) = ((guild, viewers), channel.id) }
        }
        guard let hiddenRoom else { throw WorldError.invalidBody("scenario has no hidden room in a huge server") }
        let hidden = try await memberList(probe, guild: hiddenRoom.guild.id, channel: hiddenChannel)
        expectList(hidden, "hidden room in a huge server", everyone: false, offline: false)
        let counts = (hidden["groups"]?.arrayValue ?? []).compactMap { $0["count"]?.intValue }
        if hidden["member_count"]?.intValue != Int64(hiddenRoom.guild.memberCount) || counts.contains(0) || counts.reduce(0, +) > hiddenRoom.viewers {
            report.sequenceFailures.append("hidden room in a huge server: member_count \(hidden["member_count"]?.intValue ?? -1) for a server of "
                + "\(hiddenRoom.guild.memberCount), group counts \(counts) for \(hiddenRoom.viewers) members who can see it")
        }

        var smallList: (guild: Snowflake, channel: Snowflake)?
        let me = await world.primaryUserID
        for guild in await world.guilds.values.sorted(by: { $0.id < $1.id }) where smallList == nil && guild.listsOfflineMembers
            && guild.members.keys.contains(where: { $0 == me }) {
            for id in guild.members.keys where await !world.isOnline(id) {
                let channel = channels.first { $0.guildID == guild.id && $0.type == .text && $0.overwrites.isEmpty }
                smallList = channel.map { (guild.id, $0.id) }
            }
        }
        guard let smallList else { throw WorldError.invalidBody("scenario has no small server with someone offline") }
        expectList(try await memberList(probe, guild: smallList.guild, channel: smallList.channel), "small server's list", everyone: true, offline: true)
    }

    /// Subscribes to a channel's member list (op 37) and returns the GUILD_MEMBER_LIST_UPDATE it gets.
    private mutating func memberList(_ probe: GatewayProbe, guild: Snowflake, channel: Snowflake, ranges: JSON = [[0, 99]]) async throws -> JSON {
        try await probe.send(.object(JSONObject([("op", 37), ("d", .object(JSONObject([("subscriptions", .object(JSONObject([
            (guild.description, .object(JSONObject([
                ("typing", true), ("threads", true), ("activities", true), ("member_updates", true),
                ("channels", .object(JSONObject([(channel.description, ranges)]))),
            ]))),
        ])))])))])))
        var update = JSON.null
        for frame in try await probe.waitFor("GUILD_MEMBER_LIST_UPDATE") where frame.op == 0 {
            checkFrame(frame)
            if frame.name == "GUILD_MEMBER_LIST_UPDATE" { update = frame.payload["d"] ?? .null }
        }
        return update
    }

    /// `offline` nil skips the offline-group check.
    private mutating func expectList(_ update: JSON, _ subject: String, everyone: Bool, offline: Bool?) {
        report.checked.append("LIST \(subject)")
        let id = update["id"]?.stringValue ?? "none"
        let hasOffline = update["groups"]?.arrayValue?.contains { $0["id"]?.stringValue == "offline" } == true
        if (id == "everyone") != everyone || offline.map({ $0 != hasOffline }) == true {
            report.sequenceFailures.append("\(subject): list \(id) \(hasOffline ? "with" : "without") an offline group")
        }
    }

    /// Discord sends GUILD_CREATE when a server becomes available; check the generated server's as it would be sent.
    private mutating func checkGuildCreate(_ guild: Guild, viewer: Snowflake) async {
        guard let shape = catalog.gateway["GUILD_CREATE"] else { return }
        let payload = await simulator.world.renderGuildCreate(guild, viewer: viewer)
        let frame = JSON.object(JSONObject([("t", "GUILD_CREATE"), ("s", 1), ("op", 0), ("d", payload)]))
        let (conformed, _) = shape.conform(frame)
        report.checked.append("GW GUILD_CREATE")
        record("GW GUILD_CREATE", ShapeChecker.check(conformed, against: shape, elsewhere: elsewhere))
        record("GW GUILD_CREATE", ShapeChecker.checkETF(ETFEncoder.encode(conformed, shape: shape).tags, against: shape, elsewhere: elsewhere))
    }
}
