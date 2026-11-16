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
        try await probe.send(.object(JSONObject([("op", 37), ("d", .object(JSONObject([("subscriptions", .object(JSONObject([
            (guild.id.description, .object(JSONObject([
                ("typing", true), ("threads", true), ("activities", true), ("member_updates", true),
                ("channels", .object(JSONObject([(channel.description, [[0, 99], [100, 199]])]))),
            ]))),
        ])))])))])))
        for frame in try await probe.waitFor("GUILD_MEMBER_LIST_UPDATE") where frame.op == 0 { checkFrame(frame) }
        try await checkReadOnlyListID(probe)
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

    /// A channel whose @everyone overwrite only stops sending is still everyone's list: the official
    /// client names it `everyone` and ignores updates for any other ID.
    private mutating func checkReadOnlyListID(_ probe: GatewayProbe) async throws {
        let channels = await simulator.world.channels.values.sorted { $0.id < $1.id }
        guard let channel = channels.first(where: { channel in
            !channel.overwrites.isEmpty && channel.overwrites.allSatisfy { $0.id == channel.guildID && $0.deny == .sendMessages }
        }), let guildID = channel.guildID else { throw WorldError.invalidBody("scenario has no read-only channel") }
        try await probe.send(.object(JSONObject([("op", 37), ("d", .object(JSONObject([("subscriptions", .object(JSONObject([
            (guildID.description, .object(JSONObject([("channels", .object(JSONObject([(channel.id.description, [[0, 99]])])))]))),
        ])))])))])))
        report.checked.append("LIST ID read-only channel")
        for frame in try await probe.waitFor("GUILD_MEMBER_LIST_UPDATE") where frame.name == "GUILD_MEMBER_LIST_UPDATE" {
            checkFrame(frame)
            let id = frame.payload["d"]?["id"]?.stringValue ?? "none"
            if id != "everyone" { report.sequenceFailures.append("member list of read-only channel \(channel.id) is \(id), expected everyone") }
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
