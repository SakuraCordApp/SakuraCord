import Foundation
import Synchronization

/// Voice: joining and leaving a guild voice channel and a private call over
/// the main Gateway (checked against the captured events and order), and the
/// voice gateway handshake (uncaptured; checked against the documented protocol).
extension ParityRun {
    mutating func voice(_ target: Targets, me: Snowflake) async throws {
        let world = simulator.world
        guard let probe = gateway else { return }
        let channels = await world.visibleChannels(in: try await world.guild(target.guild), for: me)
        guard let voiceChannel = channels.first(where: { $0.type == .voice }) else {
            throw WorldError.invalidBody("scenario has no voice channel in the target guild")
        }
        // Empty the channel first, so joining starts it and leaving ends it.
        await flowStart()
        let seated = await world.voiceStates(in: voiceChannel.id)
        for state in seated { await world.leaveVoice(state.userID) }
        await voiceFlow("voice-empty", expecting: Array(repeating: "VOICE_STATE_UPDATE", count: seated.count)
            + ["VOICE_CHANNEL_START_TIME_UPDATE", "VOICE_CHANNEL_STATUS_UPDATE"])

        await flowStart()
        try await probe.send(Self.voiceStateUpdate(guild: target.guild, channel: voiceChannel.id))
        let joined = await voiceFlow("voice-join", expecting: ["VOICE_STATE_UPDATE", "VOICE_CHANNEL_START_TIME_UPDATE", "VOICE_SERVER_UPDATE"])
        if let grant = joined.last(where: { $0.name == "VOICE_SERVER_UPDATE" })?.payload["d"],
           let sessionID = await world.voiceState(of: me)?.sessionID {
            await voiceHandshake(grant: grant, serverID: target.guild, userID: me, sessionID: sessionID)
        }

        await flowStart()
        try await probe.send(Self.voiceStateUpdate(guild: target.guild, channel: nil))
        await voiceFlow("voice-leave", expecting: ["VOICE_STATE_UPDATE", "VOICE_CHANNEL_START_TIME_UPDATE", "VOICE_CHANNEL_STATUS_UPDATE"])

        try await privateCall(me: me)
    }

    /// Starting a DM call, ringing, cancelling the ring and hanging up.
    private mutating func privateCall(me: Snowflake) async throws {
        let world = simulator.world
        var dm: Channel?
        for id in await world.openPrivateChannels[me] ?? [] where dm == nil {
            if let channel = await world.channels[id], channel.type == .dm { dm = channel }
        }
        guard let probe = gateway, let channel = dm, let other = channel.recipients.first(where: { $0 != me }) else {
            throw WorldError.invalidBody("scenario has no DM for the primary account")
        }
        await flowStart()
        try await probe.send(Self.voiceStateUpdate(guild: nil, channel: channel.id))
        await voiceFlow("call-start", expecting: ["MESSAGE_CREATE", "CALL_CREATE", "VOICE_STATE_UPDATE", "VOICE_SERVER_UPDATE"])

        await flowStart()
        _ = try await rest("GET", "/api/v9/channels/\(channel.id)/call")
        _ = try await rest("POST", "/api/v9/channels/\(channel.id)/call/ring", body: ["recipients": .null])
        _ = try await rest("POST", "/api/v9/channels/\(channel.id)/call/stop-ringing", body: ["recipients": [.string(other.description)]])
        await voiceFlow("call-ring", expecting: ["CALL_UPDATE", "CALL_UPDATE"])

        await flowStart()
        try await probe.send(Self.voiceStateUpdate(guild: nil, channel: nil))
        await voiceFlow("call-end", expecting: ["VOICE_STATE_UPDATE", "CALL_DELETE", "MESSAGE_UPDATE"])
    }

    /// Checks every frame's shape and that `expected` is exactly the dispatches observed, in order.
    @discardableResult
    private mutating func voiceFlow(_ name: String, expecting expected: [String]) async -> [GatewayProbe.Frame] {
        flowRequests = []
        guard let frames = await gateway?.drain(settle: .milliseconds(400)) else { return [] }
        for frame in frames where frame.op == 0 { checkFrame(frame) }
        let observed = frames.filter { $0.op == 0 && !ShapeExtractor.noiseEvents.contains($0.name) }.map(\.name)
        report.checked.append("SEQ \(name)")
        if observed != expected { report.sequenceFailures.append("\(name): expected \(expected), observed \(observed)") }
        return frames
    }

    /// Hello, Identify → Ready (and the channel's other participants), Select Protocol → Session Description, heartbeat ACK.
    private mutating func voiceHandshake(grant: JSON, serverID: Snowflake, userID: Snowflake, sessionID: String) async {
        guard let endpoint = grant["endpoint"]?.stringValue, endpoint.hasSuffix(".discord.media:2096"), let token = grant["token"]?.stringValue else {
            report.sequenceFailures.append("voice: VOICE_SERVER_UPDATE has no discord.media endpoint")
            return
        }
        let probe = VoiceProbe(url: URL(string: "ws://127.0.0.1:\(simulator.port(.voice))/?v=8")!)
        defer { probe.close() }
        var failures: [String] = []
        func expect(_ op: Int64, after message: JSON?) async -> JSON? {
            if let message { probe.send(message) }
            guard let reply = await probe.waitFor(op: op) else {
                failures.append("voice gateway never sent op \(op)")
                return nil
            }
            return reply
        }
        _ = await expect(8, after: nil)
        let ready = await expect(2, after: Self.voiceFrame(0, [
            ("server_id", .string(serverID.description)), ("user_id", .string(userID.description)), ("session_id", .string(sessionID)),
            ("token", .string(token)), ("max_dave_protocol_version", 1), ("video", true),
            ("streams", [["type": "video", "rid": "100", "quality": 100]]),
        ]))
        if ready?["d"]?["modes"]?.arrayValue?.contains(.string("aead_aes256_gcm_rtpsize")) != true { failures.append("voice ready lacks aead_aes256_gcm_rtpsize") }
        let description = await expect(4, after: Self.voiceFrame(1, [
            ("protocol", "udp"), ("data", .object(JSONObject([("address", "127.0.0.1"), ("port", 50_000), ("mode", "aead_aes256_gcm_rtpsize")]))),
        ]))
        if description?["d"]?["secret_key"]?.arrayValue?.count != 32 { failures.append("session description has no 32-byte secret_key") }
        _ = await expect(6, after: Self.voiceFrame(3, [("t", 1_234), ("seq_ack", ready?["seq"] ?? 0)]))
        report.checked.append("VOICE handshake")
        report.sequenceFailures += failures.map { "voice gateway: \($0)" }
    }

    static func voiceStateUpdate(guild: Snowflake?, channel: Snowflake?) -> JSON {
        .object(JSONObject([("op", 4), ("d", .object(JSONObject([
            ("guild_id", guild.map { .string($0.description) } ?? .null), ("channel_id", channel.map { .string($0.description) } ?? .null),
            ("self_mute", false), ("self_deaf", false), ("self_video", false), ("flags", 0), ("preferred_region", "rotterdam"),
        ])))]))
    }

    static func voiceFrame(_ op: Int64, _ fields: [(String, JSON)]) -> JSON {
        .object(JSONObject([("op", .int(op)), ("d", .object(JSONObject(fields)))]))
    }
}

/// A minimal voice gateway client (JSON text frames).
final class VoiceProbe: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let messages = Mutex<[JSON]>([])

    init(url: URL) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, case let .success(message) = result else { return }
            if case let .string(text) = message, let json = try? JSON.parse(text) { messages.withLock { $0.append(json) } }
            receive()
        }
    }

    func send(_ message: JSON) { task.send(.string(message.serialized(spaced: false))) { _ in } }

    func waitFor(op: Int64, timeout: Duration = .seconds(5)) async -> JSON? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = messages.withLock({ all in all.firstIndex { $0["op"]?.intValue == op }.map { all.remove(at: $0) } }) { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
