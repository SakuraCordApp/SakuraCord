import Foundation

/// The agent-facing control API. It is a separate host and port from every
/// Discord route, so nothing here leaks into the simulated Discord surface.
public final class ControlAPI: Sendable {
    let simulator: DiscordSimulator

    init(simulator: DiscordSimulator) { self.simulator = simulator }

    var world: World { simulator.world }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let segments = request.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard segments.first == "control" else { return notFound(request) }
        let route = Array(segments.dropFirst())
        do {
            let body = request.body.isEmpty ? JSON.object(JSONObject()) : try JSON.parse(request.body)
            for handler in [observeRoute, messageRoute, worldRoute, simulationRoute, voiceRoute, serverRoute] {
                if let response = try await handler(request, route, body) { return response }
            }
            return notFound(request)
        } catch let error as WorldError {
            return .json(error.status, .object(JSONObject([("error", .string(error.message)), ("code", .int(error.code))])))
        } catch {
            return .json(400, .object(JSONObject([("error", .string(String(describing: error)))])))
        }
    }

    private func observeRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        switch (request.method, route.first ?? "", route.count) {
        case ("GET", "health", _):
            return ok(["status": "ok", "scenario": .string(simulator.configuration.scenario), "seed": .int(Int64(simulator.configuration.seed))])
        case ("GET", "world", _):
            return .json(200, await world.summary())
        case ("GET", "log", _):
            let level = request.query["level"]?.first ?? "WARN"
            return .json(200, .array(simulator.log.recent(minimumLevel: level).map { entry in
                .object(JSONObject([("time", World.timestamp(entry.time)), ("level", .string(entry.level)),
                                    ("area", .string(entry.area)), ("message", .string(entry.message))]))
            }))
        case ("GET", "routes", _):
            return .json(200, .array(simulator.router.routeTemplates.map(JSON.string)))
        case ("GET", "network", _):
            let records = simulator.conditioners.values.flatMap(\.delays).sorted { ($0.request, $0.occurrence) < ($1.request, $1.occurrence) }
            return .json(200, .object(JSONObject([("delays", .array(records.map { record in
                .object(JSONObject([("request", .string(record.request)), ("occurrence", .int(record.occurrence)),
                                    ("ms", .double((record.milliseconds * 1000).rounded() / 1000))]))
            }))])))
        default:
            return nil
        }
    }

    private func messageRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        switch (request.method, route.first ?? "", route.count) {
        case ("POST", "messages", 1):
            let message = try await postMessage(body)
            return .json(200, .object(JSONObject([("id", message.id.json), ("channel_id", message.channelID.json)])))
        case ("PATCH", "messages", 2):
            let channel = try await resolveChannel(body)
            let message = try await world.message(try snowflake(route[1]), in: channel)
            try await world.editMessage(message.id, in: channel, by: message.authorID, content: body["content"]?.stringValue,
                                        embeds: body["embeds"]?.arrayValue, flags: nil)
            return ok([:])
        case ("DELETE", "messages", 2):
            let channel = try await resolveChannel(body)
            let message = try await world.message(try snowflake(route[1]), in: channel)
            try await world.deleteMessage(message.id, in: channel, by: message.authorID)
            return ok([:])
        case ("POST", "reactions", _):
            let channel = try await resolveChannel(body)
            let author = try await resolveUser(body["author"])
            let (name, id) = try MessageRoutes.emoji(body["emoji"]?.stringValue ?? "👍")
            try await world.react(try snowflake(body["message_id"]?.stringValue ?? ""), in: channel, by: author,
                                  emojiName: name, emojiID: id, burst: body["burst"]?.boolValue ?? false)
            return ok([:])
        case ("POST", "typing", _):
            try await world.startTyping(try await resolveUser(body["author"]), in: try await resolveChannel(body))
            return ok([:])
        case ("POST", "calls", _):
            // `caller` rings the signed-in user in their DM (opened if needed), or in `channel_id`.
            let caller = try await resolveUser(body["caller"])
            guard let me = await world.primaryUserID else { throw WorldError.invalidBody("no signed-in account") }
            let channel: Snowflake
            if let given = body["channel_id"]?.stringValue.flatMap(Snowflake.init) {
                channel = given
            } else {
                channel = try await world.openPrivateChannel(for: me, with: [caller]).id
            }
            try await world.placeCall(channel, from: caller)
            return ok(["channel_id": channel.json])
        default:
            return nil
        }
    }

    private func worldRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        switch (request.method, route.first ?? "", route.count) {
        case ("PATCH", "users", 2):
            let userID = try await resolveUser(.string(route[1]))
            let now = world.clock.now
            try await world.updateUser(userID) { user in
                if let premium = body["premium_type"]?.intValue, let type = PremiumType(rawValue: Int(premium)) {
                    user.premiumType = type
                    user.premiumSince = type == .none ? nil : (user.premiumSince ?? now)
                }
                if let name = body["global_name"]?.stringValue { user.globalName = name }
                if let bio = body["bio"]?.stringValue { user.bio = bio }
                if let pronouns = body["pronouns"]?.stringValue { user.pronouns = pronouns }
                if let accent = body["accent_color"]?.intValue { user.accentColor = Int(accent) }
            }
            return ok([:])
        case ("PUT", "guilds", 3) where route[2] == "boosts":
            let guildID = try await resolveGuild(route[1])
            let guild = try await world.guild(guildID)
            var boosters: [Snowflake] = []
            if let list = body["boosters"]?.arrayValue {
                for entry in list { boosters.append(try await resolveUser(entry)) }
            } else {
                let count = Int(body["count"]?.intValue ?? 0)
                let members = guild.memberOrder.filter { guild.members[$0] != nil }
                boosters = (0 ..< count).map { members[$0 % max(1, members.count)] }
            }
            try await world.setBoosts(guildID, boosters: boosters)
            let updated = try await world.guild(guildID)
            return ok(["premium_subscription_count": .int(updated.premiumSubscriptionCount), "premium_tier": .int(updated.premiumTier)])
        case ("POST", "presence", _):
            let userID = try await resolveUser(body["user"])
            var presence = await world.presences[userID] ?? Presence()
            if let status = body["status"]?.stringValue.flatMap(PresenceStatus.init) { presence.status = status }
            if let activities = body["activities"]?.arrayValue { presence.activities = activities }
            await world.updatePresence(userID, presence)
            return ok([:])
        default:
            return nil
        }
    }

    private func simulationRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        switch (request.method, route.first ?? "", route.count) {
        case ("PUT", "network", _):
            let profile = try networkProfile(body)
            simulator.setNetworkProfile(profile)
            return ok(["latency_ms": .double(profile.latencyMilliseconds), "jitter_ms": .double(profile.jitterMilliseconds)])
        case ("POST", "faults", _):
            return try await injectFault(body)
        case ("DELETE", "faults", _):
            simulator.faults.clear()
            return ok([:])
        case ("POST", "clock", _):
            if let freeze = body["freeze"]?.boolValue { world.clock.freeze(freeze) }
            if let seconds = body["advance_seconds"]?.doubleValue { world.clock.advance(by: seconds) }
            return ok(["now": World.timestamp(world.clock.now), "frozen": .bool(world.clock.isFrozen)])
        case ("POST", "scripts", _):
            let name = body["name"]?.stringValue ?? route.dropFirst().first ?? ""
            let started = try await simulator.scripts.start(name, params: body["params"] ?? .object(JSONObject()))
            return ok(["script": .string(name), "id": .string(started)])
        default:
            return nil
        }
    }

    func ok(_ fields: [String: JSON]) -> HTTPResponse {
        var object = JSONObject([("ok", true)])
        for key in fields.keys.sorted() { object[key] = fields[key] }
        return .json(200, .object(object))
    }

    private func notFound(_ request: HTTPRequest) -> HTTPResponse {
        simulator.log.error("control", "UNKNOWN CONTROL ROUTE \(request.method) \(request.path)")
        return .json(404, .object(JSONObject([("error", .string("unknown control route \(request.method) \(request.path)"))])))
    }

    private func snowflake(_ text: String) throws -> Snowflake {
        guard let id = Snowflake(text) else { throw WorldError.invalidBody("not an ID: \(text)") }
        return id
    }

    private func doubleValue(_ json: JSON) throws -> Double {
        guard let value = json.doubleValue else { throw WorldError.invalidBody("not a number") }
        return value
    }

    /// Users by ID, username or display name.
    func resolveUser(_ value: JSON?) async throws -> Snowflake {
        guard let text = value?.stringValue ?? value?.intValue.map(String.init) else {
            guard let selfID = await world.primaryUserID else { throw WorldError.invalidBody("author is required") }
            return selfID
        }
        if let id = Snowflake(text), await world.users[id] != nil { return id }
        let lowered = text.lowercased()
        if let match = await world.users.values.first(where: { $0.username == lowered || $0.globalName?.lowercased() == lowered }) { return match.id }
        throw WorldError.unknown("User \(text)", code: 10013)
    }

    /// Channels by `channel_id`, or `channel` as an ID or name (optionally with `guild`).
    func resolveChannel(_ body: JSON) async throws -> Snowflake {
        let text = body["channel_id"]?.stringValue ?? body["channel"]?.stringValue ?? ""
        if let id = Snowflake(text), await world.channels[id] != nil { return id }
        let name = text.hasPrefix("#") ? String(text.dropFirst()) : text
        let guildID = try await body["guild"]?.stringValue.asyncMap(resolveGuild)
        let candidates = await world.channels.values.filter { $0.name == name && (guildID == nil || $0.guildID == guildID) }
        guard let match = candidates.sorted(by: { $0.id < $1.id }).first else { throw WorldError.unknown("Channel \(text)", code: 10003) }
        return match.id
    }

    func resolveGuild(_ text: String) async throws -> Snowflake {
        if let id = Snowflake(text), await world.guilds[id] != nil { return id }
        if let match = await world.guilds.values.first(where: { $0.name.lowercased() == text.lowercased() }) { return match.id }
        throw WorldError.unknown("Guild \(text)", code: 10004)
    }

    private func postMessage(_ body: JSON) async throws -> Message {
        let channel = try await resolveChannel(body)
        let author = try await resolveUser(body["author"])
        var draft = MessageDraft(content: body["content"]?.stringValue ?? "")
        draft.embeds = body["embeds"]?.arrayValue ?? []
        draft.components = body["components"]?.arrayValue ?? []
        if let reply = body["reply_to"]?.stringValue.flatMap(Snowflake.init) {
            draft.reference = MessageReference(type: 0, messageID: reply, channelID: channel, guildID: try await world.channel(channel).guildID)
        }
        for (index, attachment) in (body["attachments"]?.arrayValue ?? []).enumerated() {
            let width = Int(attachment["width"]?.intValue ?? 1280), height = Int(attachment["height"]?.intValue ?? 960)
            let filename = attachment["filename"]?.stringValue ?? "photo_\(index + 1).jpg"
            let data = MediaGenerator.photoJPEG(seed: UInt64(attachment["seed"]?.intValue ?? Int64(index + 1)), width: width, height: height)
            draft.attachments.append(await world.storeAttachment(data, filename: filename, channelID: channel,
                                                                  description: attachment["description"]?.stringValue,
                                                                  durationSeconds: nil, waveform: nil, flags: 0))
        }
        // Control posts may come from users without send permission (e.g. announcements), as staff tools do.
        return try await world.sendMessage(draft, as: author, in: channel, checkPermissions: false)
    }

    private func networkProfile(_ body: JSON) throws -> NetworkConditioner.Profile {
        if let name = body["profile"]?.stringValue {
            guard let profile = NetworkConditioner.Profile.named(name) else { throw WorldError.invalidBody("unknown profile \(name)") }
            return profile
        }
        return NetworkConditioner.Profile(
            latencyMilliseconds: try body["latency_ms"].map(doubleValue) ?? 0,
            jitterMilliseconds: try body["jitter_ms"].map(doubleValue) ?? 0,
            downloadBytesPerSecond: try body["download_bytes_per_second"].map(doubleValue),
            uploadBytesPerSecond: try body["upload_bytes_per_second"].map(doubleValue)
        )
    }

    private func injectFault(_ body: JSON) async throws -> HTTPResponse {
        let kind = body["kind"]?.stringValue ?? ""
        if let gatewayFault = GatewayHub.Fault(rawValue: kind.replacingOccurrences(of: "gateway-", with: "")) {
            let user = try await body["user"].asyncMap { try await resolveUser($0) }
            let affected = await simulator.hub.inject(gatewayFault, userID: user)
            return ok(["sessions": .int(affected)])
        }
        guard let status = Int(kind), status == 429 || (500 ... 599).contains(status) else {
            throw WorldError.invalidBody("kind must be 429, a 5xx status, or one of \(GatewayHub.Fault.allCases.map { "gateway-\($0.rawValue)" })")
        }
        simulator.faults.add(FaultInjector.Rule(
            status: status, route: body["route"]?.stringValue ?? "",
            remaining: body["count"]?.intValue.map(Int.init) ?? 1,
            retryAfter: try body["retry_after"].map(doubleValue) ?? 1.5,
            global: body["global"]?.boolValue ?? false
        ))
        return ok(["rules": .int(simulator.faults.activeRules.count)])
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

public extension World {
    func summary() -> JSON {
        .object(JSONObject([
            ("now", World.timestamp(clock.now)),
            ("accounts", .array(tokens.sorted { $0.key < $1.key }.map { token, id in
                .object(JSONObject([("user_id", id.json), ("username", .optional(users[id]?.username)), ("token", .string(token)),
                                    ("email", .optional(users[id]?.email)), ("password", .optional(users[id]?.password))]))
            })),
            ("guilds", .array(guildOrder.compactMap { guilds[$0] }.map { guild in
                .object(JSONObject([
                    ("id", guild.id.json), ("name", .string(guild.name)), ("members", .int(guild.members.count)),
                    ("boosts", .int(guild.premiumSubscriptionCount)), ("premium_tier", .int(guild.premiumTier)),
                    ("channels", .array(guild.channelIDs.compactMap { channels[$0] }.filter { !$0.type.isThread }.map { channel in
                        .object(JSONObject([("id", channel.id.json), ("name", .optional(channel.name)),
                                            ("type", .int(channel.type.rawValue)), ("messages", .int(channel.messages.count))]))
                    })),
                ]))
            })),
            ("users", .int(users.count)),
        ]))
    }
}
