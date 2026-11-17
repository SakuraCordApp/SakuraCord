import Foundation
import Synchronization

/// Drives a running simulator over real HTTP and WebSocket connections, the
/// way the official client would, and compares every response, Gateway frame
/// and event order with the captured shapes.
public enum ParitySuite {
    public struct Finding: Sendable, CustomStringConvertible {
        public var subject: String
        public var violation: ShapeViolation
        public var description: String { "\(subject): \(violation)" }
    }

    public struct Report: Sendable {
        public var checked: [String] = []
        public var failures: [Finding] = []
        public var unverified: [Finding] = []
        public var uncapturedRoutes: [String] = []
        public var sequenceFailures: [String] = []

        public var passed: Bool { failures.isEmpty && sequenceFailures.isEmpty }

        public var summary: String {
            var lines = ["parity: \(checked.count) checks, \(failures.count) failures, \(sequenceFailures.count) sequence failures, \(unverified.count) unverified"]
            lines += failures.map { "FAIL \($0)" }
            lines += sequenceFailures.map { "FAIL sequence \($0)" }
            if !uncapturedRoutes.isEmpty { lines.append("implemented but never captured: \(uncapturedRoutes.joined(separator: ", "))") }
            let unverifiedSubjects = Set(unverified.map(\.subject)).sorted()
            if !unverifiedSubjects.isEmpty { lines.append("unverified (capture never had a value there): \(unverifiedSubjects.count) subjects") }
            lines.append(passed ? "PASS" : "FAILED")
            return lines.joined(separator: "\n")
        }
    }

    /// Lets tests and `--break` corrupt one response to prove the suite catches it.
    public typealias Mutation = @Sendable (_ subject: String, _ body: JSON) -> JSON

    /// Removes the first field of the first object in `body` (the element of an array body).
    public static func dropFirstField(_ body: JSON) -> JSON {
        switch body {
        case var .object(object):
            guard let first = object.keys.first else { return body }
            object[first] = nil
            return .object(object)
        case var .array(elements) where !elements.isEmpty:
            elements[0] = dropFirstField(elements[0])
            return .array(elements)
        default:
            return body
        }
    }

    /// The captured flows this suite replays and checks for event order.
    static let replayedFlows: Set<String> = [
        "send-message", "reply", "edit-message", "unreact", "pin", "upload", "create-thread", "delete-message", "history-variants",
    ]

    public static func run(seed: UInt64 = 7, mutate: Mutation? = nil) async -> Report {
        // The flows pick their targets from the hand-written servers; `runWorld` covers the generated ones.
        await run(scenario: DemoScenario.name, seed: seed, mutate: mutate) { try await $0.execute() }
    }

    static func run(scenario: String, parameters: [String: String] = [:], seed: UInt64, mutate: Mutation?,
                    _ body: (inout ParityRun) async throws -> Void) async -> Report {
        var configuration = DiscordSimulator.Configuration()
        configuration.seed = seed
        configuration.enforcesRateLimits = false
        // Parity checks shapes and order, not timing, so it runs without network delay.
        configuration.network = .instant
        configuration.scenario = scenario
        configuration.parameters = parameters
        configuration.epoch = Date(timeIntervalSince1970: 1_794_778_200) // a Sunday, 21:30 UTC
        configuration.basePort = UInt16(40_000 + Int(ProcessInfo.processInfo.processIdentifier % 2_000) * 10)
        var report = Report()
        do {
            let simulator = try await DiscordSimulator.make(configuration: configuration)
            try await simulator.start()
            defer { simulator.stop() }
            var run = ParityRun(simulator: simulator, mutate: mutate)
            try await body(&run)
            report = run.report
        } catch {
            report.sequenceFailures.append("suite could not run: \(error)")
        }
        return report
    }
}

struct ParityRun {
    let simulator: DiscordSimulator
    let mutate: ParitySuite.Mutation?
    var report = ParitySuite.Report()
    var catalog: ShapeCatalog { simulator.catalog }
    let elsewhere: FieldIndex
    let session = URLSession(configuration: .ephemeral)
    var token = ""
    var gateway: GatewayProbe?
    /// REST templates sent since the last `flowStart`.
    var flowRequests: [String] = []

    init(simulator: DiscordSimulator, mutate: ParitySuite.Mutation?) {
        self.simulator = simulator
        self.mutate = mutate
        // Captured shapes only: a field from the client's code mustn't make a missing field elsewhere look merely unverified.
        elsewhere = FieldIndex((try? ShapeCatalog.captured()) ?? simulator.catalog)
    }

    struct SignedIn {
        let me: Snowflake
        let probe: GatewayProbe
        /// The frames up to READY_SUPPLEMENTAL.
        let startup: [GatewayProbe.Frame]
    }

    /// Signs the primary account in on a new Gateway connection.
    mutating func connect(timeout: Duration = .seconds(10)) async throws -> SignedIn {
        let world = simulator.world
        guard let me = await world.primaryUserID, let token = await world.tokens.first(where: { $0.value == me })?.key else {
            throw WorldError.invalidBody("scenario has no primary account")
        }
        self.token = token
        let probe = try GatewayProbe(url: URL(string: "ws://127.0.0.1:\(simulator.port(.gateway))/?v=9&encoding=etf&compress=zstd-stream")!)
        gateway = probe
        try await probe.identify(token: token)
        return SignedIn(me: me, probe: probe, startup: try await probe.waitFor("READY_SUPPLEMENTAL", timeout: timeout))
    }

    mutating func execute() async throws {
        let world = simulator.world
        let signedIn = try await connect()
        let (me, probe, startup) = (signedIn.me, signedIn.probe, signedIn.startup)
        checkSequence("startup", observed: startup.map(\.name))
        for frame in startup where frame.op == 0 { checkFrame(frame) }

        let target = try await pickTargets(me: me)
        let messagesPath = "/api/v9/channels/\(target.channel)/messages"
        _ = try await rest("GET", "\(messagesPath)?limit=50")
        _ = try await rest("GET", "/api/v9/users/@me/relationships")
        _ = try await rest("GET", "/api/v9/users/\(target.otherUser)/profile?with_mutual_guilds=true&with_mutual_friends=true&guild_id=\(target.guild)")
        _ = try await rest("GET", "/api/v9/channels/\(target.channel)/messages/pins")
        _ = try await rest("GET", "/api/v9/users/@me/settings-proto/2")
        _ = try await rest("PATCH", "/api/v9/users/@me/settings-proto/2", body: ["settings": ""])
        _ = try await rest("GET", "/api/v9/guilds/\(target.guild)/messages/search?content=the")
        if let forum = target.forum {
            _ = try await rest("GET", "/api/v9/channels/\(forum)/threads/search?sort_by=last_message_time&sort_order=desc&limit=25&offset=0")
            let posts = await world.channels.values.filter { $0.parentID == forum }.map { JSON.string($0.id.description) }
            _ = try await rest("POST", "/api/v9/channels/\(forum)/post-data", body: .object(JSONObject([("thread_ids", .array(posts))])))
        }

        // Opening a guild subscribes to its channel, member list and threads (op 37).
        try await probe.send(Self.subscribe(guild: target.guild, channel: target.channel))
        for frame in try await probe.waitFor("THREAD_LIST_SYNC") where frame.op == 0 { checkFrame(frame) }

        // send-message / reply / edit / react / unreact / pin / delete, as captured.
        await flowStart()
        let sent = try await postMessage(in: target.channel, "parity check message")
        await flowEnd("send-message")
        guard let sentID = sent["id"]?.stringValue else { throw WorldError.invalidBody("send returned no id") }

        await flowStart()
        _ = try await postMessage(in: target.channel, "parity reply", [
            ("message_reference", .object(JSONObject([
                ("guild_id", .string(target.guild.description)), ("channel_id", .string(target.channel.description)),
                ("message_id", .string(sentID)), ("type", 0),
            ]))),
        ])
        await flowEnd("reply")

        await flowStart()
        _ = try await rest("PATCH", "\(messagesPath)/\(sentID)", body: ["content": "parity check message (edited)"])
        _ = try await rest("PUT", "\(messagesPath)/\(sentID)/reactions/%F0%9F%91%8D/%40me?location=Message&type=0")
        await flowEnd("edit-message")

        await flowStart()
        _ = try await rest("DELETE", "\(messagesPath)/\(sentID)/reactions/%F0%9F%91%8D/0/%40me?location=Message&burst=false")
        await flowEnd("unreact")

        await flowStart()
        _ = try await rest("PUT", "/api/v9/channels/\(target.channel)/messages/pins/\(sentID)")
        await flowEnd("pin")

        await flowStart()
        let slots = try await rest("POST", "/api/v9/channels/\(target.channel)/attachments",
                                   body: ["files": [["filename": "parity.png", "file_size": 70, "id": "0", "is_clip": false]]])
        if let slot = slots["attachments"]?.arrayValue?.first, let uploadURL = slot["upload_url"]?.stringValue,
           let uploadName = slot["upload_filename"]?.stringValue, let url = URL(string: uploadURL) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(simulator.port(.upload))\(url.path(percentEncoded: true))?\(url.query ?? "")")!)
            request.httpMethod = "PUT"
            let png = MediaGenerator.avatarPNG(seed: 3, size: 16)
            _ = try await session.upload(for: request, from: png)
            _ = try await rest("POST", messagesPath, body: .object(JSONObject([
                ("content", ""), ("nonce", .string(nonce())), ("channel_id", .string(target.channel.description)), ("type", 0), ("sticker_ids", []),
                ("attachments", [["id": "0", "filename": "parity.png", "uploaded_filename": .string(uploadName)]]),
            ])))
        }
        await flowEnd("upload")
        try await discardedUpload(target)

        await flowStart()
        _ = try await rest("POST", "\(messagesPath)/\(sentID)/threads", body: ["name": "parity thread", "type": 11, "auto_archive_duration": 4320, "location": "Message"])
        await flowEnd("create-thread")

        try await historyVariants(target, messagesPath: messagesPath)
        try await slashCommand(target)
        try await servers(target)
        try await eventsAndModeration(target, me: me)
        try await applications(target)
        try await guildChannels(target, me: me)
        try await channelSettingsAndAutoMod(target, me: me)
        try await reorderChannels(target, me: me)
        try await modalsAndFailures(target)
        try await inboxAndScheduling(target)
        try await voice(target, me: me)
        try await activities(target)
        try await threadMembership(target)
        try await editedReplyMentions(target)
        try await accountFlows(target, me: me)

        await flowStart()
        _ = try await rest("DELETE", "\(messagesPath)/\(sentID)")
        await flowEnd("delete-message")

        let latest = await world.channels[target.channel]?.lastMessageID
        if let latest { _ = try await rest("POST", "\(messagesPath)/\(latest)/ack", body: ["token": .null, "last_viewed": 3000]) }

        let captured = Set(catalog.routes.keys)
        report.uncapturedRoutes = simulator.router.routeTemplates.filter { !captured.contains($0) }
        report.sequenceFailures += probe.sequenceErrors.map { "gateway sequence: \($0)" }
        probe.close()
    }

    /// A message with two reactions, a sticker, a forward and a voted poll, then history: the variants history must keep.
    mutating func historyVariants(_ target: Targets, messagesPath: String) async throws {
        await flowStart()
        let base = try await postMessage(in: target.channel, "parity variants")
        guard let baseID = base["id"]?.stringValue else { throw WorldError.invalidBody("send returned no id") }
        for emoji in ["%F0%9F%91%8D", "%F0%9F%8E%89"] {
            _ = try await rest("PUT", "\(messagesPath)/\(baseID)/reactions/\(emoji)/%40me?location=Message&type=0")
        }
        guard let sticker = await simulator.world.standardStickers.first?.id else { throw WorldError.invalidBody("scenario has no standard sticker") }
        _ = try await postMessage(in: target.channel, "", [("sticker_ids", [.string(sticker.description)])])
        _ = try await postMessage(in: target.channel, "", [("message_reference", .object(JSONObject([
            ("channel_id", .string(target.channel.description)), ("guild_id", .string(target.guild.description)),
            ("message_id", .string(baseID)), ("type", 1),
        ])))])
        let poll = try await postMessage(in: target.channel, "", [("poll", .object(JSONObject([
            ("question", ["text": "parity poll?"]), ("answers", [["poll_media": ["text": "yes"]], ["poll_media": ["text": "no"]]]),
            ("allow_multiselect", false), ("duration", 24), ("layout_type", 1),
        ])))])
        if let pollID = poll["id"]?.stringValue {
            _ = try await rest("PUT", "/api/v9/channels/\(target.channel)/polls/\(pollID)/answers/@me", body: ["answer_ids": ["1"]])
        }
        await flowEnd("history-variants")
        _ = try await rest("GET", "\(messagesPath)?limit=50")
        if let pollID = poll["id"]?.stringValue {
            _ = try await rest("GET", "/api/v9/channels/\(target.channel)/polls/\(pollID)/answers/1?limit=25")
        }
    }

    /// A slash command: INTERACTION_CREATE, the bot's reply and INTERACTION_SUCCESS, checked by shape.
    mutating func slashCommand(_ target: Targets) async throws {
        let bot = try await targetBot(target)
        await flowStart()
        _ = try await rest("POST", "/api/v9/interactions", body: .object(JSONObject([
            ("type", 2), ("application_id", .string(bot.description)),
            ("guild_id", .string(target.guild.description)), ("channel_id", .string(target.channel.description)),
            ("session_id", "parity"), ("nonce", .string(nonce())),
            ("data", .object(JSONObject([("type", 1), ("name", "gamenight"), ("options", [])]))),
        ])))
        await flowEnd(nil)
    }

    /// The official client's nonces are snowflakes for "now".
    func nonce() -> String { Snowflake(date: Date(), increment: UInt64.random(in: 0 ..< 4096)).description }

    /// Sends a message the way the official client does; `extra` fields follow the client's defaults.
    mutating func postMessage(in channel: Snowflake, _ content: String, _ extra: [(String, JSON)] = []) async throws -> JSON {
        try await rest("POST", "/api/v9/channels/\(channel)/messages", body: .object(JSONObject(
            [("content", .string(content)), ("nonce", .string(nonce())), ("tts", false), ("flags", 0)] + extra)))
    }

    /// Op 37: subscribes to a guild's typing, threads, activities and one channel's member list `ranges`.
    static func subscribe(guild: Snowflake, channel: Snowflake, ranges: JSON = [[0, 99]]) -> JSON {
        .object(JSONObject([("op", 37), ("d", .object(JSONObject([("subscriptions", .object(JSONObject([
            (guild.description, .object(JSONObject([
                ("typing", true), ("threads", true), ("activities", true), ("member_updates", true),
                ("channels", .object(JSONObject([(channel.description, ranges)]))),
            ]))),
        ])))])))]))
    }

    // MARK: Targets

    struct Targets { var guild: Snowflake; var channel: Snowflake; var forum: Snowflake?; var otherUser: Snowflake }

    /// The target server's bot (the lowest ID if there are several).
    func targetBot(_ target: Targets) async throws -> Snowflake {
        let users = await simulator.world.users
        guard let bot = try await simulator.world.guild(target.guild).members.keys.sorted().first(where: { users[$0]?.bot == true }) else {
            throw WorldError.invalidBody("scenario has no bot in the target guild")
        }
        return bot
    }

    func pickTargets(me: Snowflake) async throws -> Targets {
        let world = simulator.world
        for guild in await world.guilds(of: me) {
            let channels = await world.visibleChannels(in: guild, for: me)
            guard let text = channels.first(where: { $0.type == .text && !$0.messages.isEmpty }),
                  let other = guild.memberOrder.first(where: { $0 != me }) else { continue }
            return Targets(guild: guild.id, channel: text.id, forum: channels.first { $0.type == .forum }?.id, otherUser: other)
        }
        throw WorldError.invalidBody("scenario has no guild with a text channel and another member")
    }

    // MARK: REST

    mutating func rest(_ method: String, _ pathAndQuery: String, body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(simulator.port(.api))\(pathAndQuery)")!)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body.data()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let path = String(pathAndQuery.split(separator: "?").first ?? "")
        let route = RouteTemplate.template(method: method, path: path)
        flowRequests.append(route)
        report.checked.append("REST \(route) \(status)")
        guard let captured = catalog.routes[route] else { return (try? JSON.parse(data)) ?? .null }
        guard let shape = captured.responses[status] else {
            report.failures.append(.init(subject: "REST \(route)", violation: ShapeViolation(
                kind: .type, path: "status", detail: "\(status), captured \(captured.responses.keys.sorted())")))
            return (try? JSON.parse(data)) ?? .null
        }
        guard !data.isEmpty else {
            if !shape.kinds.isEmpty { report.failures.append(.init(subject: "REST \(route)", violation: ShapeViolation(kind: .missingField, path: "", detail: "empty body"))) }
            return .null
        }
        var json = try JSON.parse(data)
        if let mutate { json = mutate("REST \(route)", json) }
        record("REST \(route)", ShapeChecker.check(json, against: shape, elsewhere: elsewhere))
        return json
    }

    // MARK: Gateway

    mutating func flowStart() async {
        _ = await gateway?.drain(settle: .milliseconds(150))
        flowRequests = []
    }

    /// Compares the events about the flow's channel with the captured order.
    mutating func flowEnd(_ sequence: String?) async {
        let executed = flowRequests
        flowRequests = []
        guard let frames = await gateway?.drain(settle: .milliseconds(400)) else { return }
        for frame in frames where frame.op == 0 { checkFrame(frame) }
        guard let sequence else { return }
        checkSequence(sequence, observed: frames.compactMap { $0.op == 0 ? $0.name : nil }, executed: executed)
    }

    mutating func checkFrame(_ frame: GatewayProbe.Frame) {
        let subject = "GW \(frame.name)"
        report.checked.append(subject)
        guard let shape = catalog.gateway[frame.name] else {
            report.unverified.append(.init(subject: subject, violation: ShapeViolation(kind: .unverified, path: "", detail: "event never captured")))
            return
        }
        var payload = frame.payload
        var tags = frame.tags
        if let mutate {
            payload = mutate(subject, payload)
            // A corrupted payload is checked as if it had been sent that way.
            if payload != frame.payload { tags = ETFEncoder.encode(payload, shape: shape).tags }
        }
        record(subject, ShapeChecker.check(payload, against: shape, elsewhere: elsewhere))
        // Term types as received on the wire, not re-encoded.
        record(subject, ShapeChecker.checkETF(tags, against: shape, elsewhere: elsewhere))
    }

    /// With `executed`, only the captured events that followed those same requests are expected.
    mutating func checkSequence(_ name: String, observed: [String], executed: [String]? = nil) {
        guard let captured = catalog.sequences[name] else { return }
        report.checked.append("SEQ \(name)")
        var expected: [String] = []
        var remaining = executed.map { $0[...] }
        var following = executed == nil
        for step in captured {
            if step.hasPrefix("REST ") {
                guard var pending = remaining else { continue }
                following = pending.first == String(step.dropFirst(5))
                if following { pending.removeFirst() }
                remaining = pending
            } else if following, step.hasPrefix("GW ") {
                expected.append(String(step.dropFirst(3)))
            }
        }
        // Captured events must appear in the captured order; extra events in between are allowed
        // only if the capture also had them somewhere in the flow.
        // Each captured event appears exactly as often as captured (duplicates fail).
        for event in Set(expected) where observed.count(where: { $0 == event }) != expected.count(where: { $0 == event }) {
            report.sequenceFailures.append("\(name): \(event) \(observed.count(where: { $0 == event }))×, captured \(expected.count(where: { $0 == event }))×")
        }
        var cursor = observed.startIndex
        for event in expected {
            guard let found = observed[cursor...].firstIndex(of: event) else {
                report.sequenceFailures.append("\(name): expected \(expected), observed \(observed)")
                return
            }
            cursor = observed.index(after: found)
        }
        let unexpected = Set(observed).subtracting(expected).subtracting(ShapeExtractor.noiseEvents)
        if !unexpected.isEmpty { report.sequenceFailures.append("\(name): events the capture never had: \(unexpected.sorted())") }
    }

    mutating func record(_ subject: String, _ violations: [ShapeViolation]) {
        for violation in violations {
            if violation.kind == .unverified { report.unverified.append(.init(subject: subject, violation: violation)) } else {
                report.failures.append(.init(subject: subject, violation: violation))
            }
        }
    }
}

/// A minimal ETF + zstd-stream Gateway client, independent of the simulator's own server code paths.
final class GatewayProbe: @unchecked Sendable {
    struct Frame: Sendable {
        var op: Int64
        var name: String
        var payload: JSON
        var tags: [String: String]
    }

    private let task: URLSessionWebSocketTask
    private let decompressor = ZstdStreamDecompressor()
    private let frames = Mutex<[Frame]>([])
    /// Guarded by `frames`' lock.
    private var lastSequence: Int64?
    private(set) var sequenceErrors: [String] = []

    init(url: URL) throws {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, case let .success(message) = result else { return }
            if case let .data(data) = message, let plain = try? self.decompressor.decompress(data),
               let (frame, tags) = try? ETFDecoder.decodeWithTags(plain) {
                let op = frame["op"]?.intValue ?? -1
                self.frames.withLock { frames in
                    // Dispatch sequence numbers must rise by one with no gaps or repeats.
                    if op == 0, let sequence = frame["s"]?.intValue {
                        if let last = self.lastSequence, sequence != last + 1 { self.sequenceErrors.append("s=\(sequence) after \(last)") }
                        self.lastSequence = sequence
                    }
                    frames.append(Frame(op: op, name: frame["t"]?.stringValue ?? "op\(op)", payload: frame, tags: tags))
                }
            }
            self.receive()
        }
    }

    func identify(token: String) async throws {
        let identify: JSON = .object(JSONObject([("op", 2), ("d", .object(JSONObject([
            ("token", .string(token)), ("capabilities", 1_734_653),
            ("properties", .object(JSONObject([("os", "Mac OS X"), ("browser", "Discord Client"), ("release_channel", "stable")]))),
            ("presence", .object(JSONObject([("status", "online"), ("since", 0), ("activities", []), ("afk", false)]))),
            ("compress", false), ("client_state", .object(JSONObject([("guild_versions", .object(JSONObject()))]))),
        ])))]))
        try await send(identify)
    }

    func send(_ payload: JSON) async throws {
        try await task.send(.data(ETFEncoder.encode(payload, shape: nil).bytes))
    }

    func waitFor(_ name: String, timeout: Duration = .seconds(10)) async throws -> [Frame] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if frames.withLock({ $0.contains { $0.name == name } }) { return frames.withLock { all in defer { all.removeAll() }; return all } }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorldError.invalidBody("Gateway never sent \(name)")
    }

    func drain(settle: Duration) async -> [Frame] {
        try? await Task.sleep(for: settle)
        return frames.withLock { all in defer { all.removeAll() }; return all }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
