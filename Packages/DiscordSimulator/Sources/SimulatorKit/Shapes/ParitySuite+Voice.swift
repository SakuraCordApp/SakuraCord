import Foundation
import Network
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
        await voiceFlow("voice-empty", expecting: seated.isEmpty ? []
            : Array(repeating: "VOICE_STATE_UPDATE", count: seated.count) + ["VOICE_CHANNEL_START_TIME_UPDATE", "VOICE_CHANNEL_STATUS_UPDATE"])

        await flowStart()
        try await probe.send(Self.voiceStateUpdate(guild: target.guild, channel: voiceChannel.id))
        let joined = await voiceFlow("voice-join", expecting: ["VOICE_STATE_UPDATE", "VOICE_CHANNEL_START_TIME_UPDATE", "VOICE_SERVER_UPDATE"])
        if let grant = joined.last(where: { $0.name == "VOICE_SERVER_UPDATE" })?.payload["d"],
           let sessionID = await world.voiceState(of: me)?.sessionID {
            await voiceHandshake(grant: grant, channel: voiceChannel.id, serverID: target.guild, userID: me, sessionID: sessionID,
                                 speaker: target.otherUser)
        }

        try await soundboardAndGoLive(guild: target.guild, channel: voiceChannel.id, me: me)
        try await watchSimulatedStream(guild: target.guild, channel: voiceChannel.id, me: me, streamer: target.otherUser)

        // Leaving voice while streaming, as captured: the leave, the channel's clean-up, STREAM_DELETE; then op 19 gets another.
        await flowStart()
        try await probe.send(Self.goLive(guild: target.guild, channel: voiceChannel.id))
        // Wait for the stream to start, so a slow runner doesn't count its events as the leave's.
        _ = try await probe.waitFor("STREAM_SERVER_UPDATE")
        await flowStart()
        try await probe.send(Self.voiceStateUpdate(guild: target.guild, channel: nil))
        await voiceFlow("voice-leave-streaming",
                        expecting: ["VOICE_STATE_UPDATE", "VOICE_CHANNEL_START_TIME_UPDATE", "VOICE_CHANNEL_STATUS_UPDATE", "STREAM_DELETE"])
        await flowStart()
        let key = GoLiveStream.key(userID: me, channelID: voiceChannel.id, guildID: target.guild)
        try await probe.send(.object(JSONObject([("op", 19), ("d", .object(JSONObject([("stream_key", .string(key))])))])))
        await voiceFlow("go-live-delete-after-leave", expecting: ["STREAM_DELETE"])

        try await privateCall(me: me)
    }

    /// Playing a default sound, then starting, pausing, previewing and ending a Go Live stream.
    private mutating func soundboardAndGoLive(guild: Snowflake, channel: Snowflake, me: Snowflake) async throws {
        guard let probe = gateway else { return }
        await flowStart()
        _ = try await rest("POST", "/api/v9/channels/\(channel)/send-soundboard-sound", body: ["sound_id": "1", "emoji_id": .null, "emoji_name": "🔔"])
        await voiceFlow("soundboard", expecting: ["VOICE_CHANNEL_EFFECT_SEND"])

        // Starting, as the official client does: op 18, then op 22 (not paused).
        let key = GoLiveStream.key(userID: me, channelID: channel, guildID: guild)
        let previewPath = "/api/v9/streams/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)/preview"
        await flowStart()
        try await probe.send(Self.goLive(guild: guild, channel: channel))
        try await probe.send(Self.pauseStream(key, paused: false))
        // The streamer's own preview isn't uploaded yet: a 404, as captured.
        if try await rest("GET", previewPath)["url"] != nil { report.sequenceFailures.append("go-live: a new stream's own preview should be a 404") }
        await voiceFlow("go-live-start", expecting: ["STREAM_CREATE", "VOICE_STATE_UPDATE", "STREAM_SERVER_UPDATE", "STREAM_UPDATE"])
        await flowStart()
        try await probe.send(Self.pauseStream(key, paused: true))
        await voiceFlow("go-live-pause", expecting: ["STREAM_UPDATE"])
        // Stopping while staying in voice, as captured: STREAM_DELETE, then the voice state without `self_stream`; the preview is gone.
        await flowStart()
        try await probe.send(.object(JSONObject([("op", 19), ("d", .object(JSONObject([("stream_key", .string(key))])))])))
        let ended = await voiceFlow("go-live-end", expecting: ["STREAM_DELETE", "VOICE_STATE_UPDATE"])
        if ended.last?.payload["d"]?["self_stream"] != nil { report.sequenceFailures.append("go-live: self_stream should be gone after stopping") }
        _ = try await rest("GET", previewPath)
    }

    static func pauseStream(_ key: String, paused: Bool) -> JSON {
        .object(JSONObject([("op", 22), ("d", .object(JSONObject([("stream_key", .string(key)), ("paused", .bool(paused))])))]))
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
        await voiceFlow("call-end", expecting: ["VOICE_STATE_UPDATE", "MESSAGE_UPDATE", "CALL_DELETE"])
    }

    /// Checks every frame's shape and that `expected` is exactly the dispatches observed, in order.
    @discardableResult
    mutating func voiceFlow(_ name: String, expecting expected: [String]) async -> [GatewayProbe.Frame] {
        flowRequests = []
        guard let frames = await gateway?.drain(settle: .milliseconds(400)) else { return [] }
        for frame in frames where frame.op == 0 { checkFrame(frame) }
        let observed = frames.filter { $0.op == 0 && !ShapeExtractor.noiseEvents.contains($0.name) }.map(\.name)
        report.checked.append("SEQ \(name)")
        if observed != expected { report.sequenceFailures.append("\(name): expected \(expected), observed \(observed)") }
        return frames
    }

    /// Hello, Identify → Ready, IP discovery, Select Protocol → Session Description, heartbeat ACK, then a
    /// simulated person joining (op 11) and speaking (op 5 and Opus over encrypted RTP).
    private mutating func voiceHandshake(grant: JSON, channel: Snowflake, serverID: Snowflake, userID: Snowflake, sessionID: String, speaker: Snowflake) async {
        guard let endpoint = grant["endpoint"]?.stringValue, endpoint.hasSuffix(".discord.media:2096"), let token = grant["token"]?.stringValue else {
            report.sequenceFailures.append("voice: VOICE_SERVER_UPDATE has no discord.media endpoint")
            return
        }
        let probe = VoiceProbe(url: URL(string: "ws://127.0.0.1:\(simulator.port(.voice))/?v=8")!)
        let udp = UDPProbe(port: simulator.port(.voiceMedia))
        defer {
            probe.close()
            udp.close()
        }
        guard let connection = await probe.connect([
            ("server_id", .string(serverID.description)), ("user_id", .string(userID.description)), ("session_id", .string(sessionID)),
            ("token", .string(token)), ("max_dave_protocol_version", 1), ("video", true),
            ("streams", [["type": "video", "rid": "100", "quality": 100]]),
        ], udp: udp) else {
            report.sequenceFailures.append("voice: no ready, IP discovery or session description")
            return
        }
        var failures: [String] = []
        func expect(_ op: Int64, after message: JSON? = nil) async -> JSON? {
            if let message { probe.send(message) }
            let reply = await probe.waitFor(op: op)
            if reply == nil { failures.append("voice gateway never sent op \(op)") }
            return reply
        }
        let key = connection.key
        if connection.description["d"]?["dave_protocol_version"]?.intValue != 1 { failures.append("session description doesn't select DAVE") }
        _ = await expect(6, after: Self.voiceFrame(3, [("t", 1_234), ("seq_ack", connection.ready["seq"] ?? 0)]))

        // DAVE: take the external sender (op 25) and send a key package (op 26).
        guard let package = await probe.waitForBinary(op: 25),
              let member = DaveMember(userID: userID, groupID: channel, externalSender: package, recognized: [speaker])
        else {
            report.sequenceFailures += (failures + ["no DAVE external sender package"]).map { "voice: \($0)" }
            return
        }
        probe.sendBinary(Data([26]) + member.keyPackage())
        let world = simulator.world
        _ = try? await world.updateVoiceState(speaker, sessionID: "parity-speaker", VoiceStateRequest(guildID: serverID, channelID: channel), simulated: true)
        _ = await expect(11)
        // The simulated person creates the group and welcomes us (op 30); we're ready (op 23) and it executes (op 22).
        if await !probe.acceptWelcome(into: member) { failures.append("no DAVE welcome and transition from the simulated person's commit") }
        try? await simulator.voice.setSpeaking(speaker, true)
        let speaking = await expect(5)
        if let packet = await udp.receive(), let (header, body) = try? VoiceCrypto.open(packet, key: key, mode: .aes256GCM) {
            let packetSSRC = header[8 ..< 12].reduce(0) { $0 << 8 | Int64($1) }
            if packetSSRC != speaking?["d"]?["ssrc"]?.intValue { failures.append("RTP from the speaker has the wrong SSRC") }
            if (member.decrypt(body, from: speaker, video: false)?.count ?? 0) < 3 { failures.append("the speaker's Opus doesn't DAVE-decrypt") }
        } else {
            failures.append("no decryptable RTP from the simulated speaker")
        }
        try? await simulator.voice.setSpeaking(speaker, false)
        _ = await expect(5)
        // A chatty simulated person talks on their own while someone listens.
        try? await world.setChatters(speaker, true)
        if await expect(5)?["d"]?["speaking"]?.intValue != 1 { failures.append("a chatty simulated person never started talking") }
        try? await world.updateVoiceFlags(speaker) { $0.selfVideo = true }
        let video = await probe.waitFor(op: 12) { $0["d"]?["video_ssrc"]?.intValue != 0 }?["d"]?["video_ssrc"]?.intValue
        if let failure = await Self.checkVideo(from: udp, ssrc: video, key: key) { failures.append(failure) }
        await world.leaveVoice(speaker)
        _ = await expect(13)
        failures += await checkDaveRejoin(probe: probe, udp: udp, key: key, package: package, room: (serverID, channel), userID: userID,
                                          speaker: speaker)
        report.checked.append("VOICE handshake and media")
        report.sequenceFailures += failures.map { "voice: \($0)" }
    }

    /// The speaker leaves and comes back while we stay: alone, we get op 24 with exactly `epoch` 1 and
    /// `protocol_version` (no `transition_id`), start over with a new key package, are welcomed into the
    /// speaker's new group and decrypt their audio again.
    private func checkDaveRejoin(probe: VoiceProbe, udp: UDPProbe, key: [UInt8], package: Data,
                                 room: (guild: Snowflake, channel: Snowflake), userID: Snowflake, speaker: Snowflake) async -> [String] {
        let world = simulator.world, voice = simulator.voice
        guard let epoch = await probe.waitFor(op: 24)?["d"]?.objectValue else { return ["no op 24 after the group shrank to one member"] }
        var failures: [String] = []
        if Set(epoch.keys) != ["epoch", "protocol_version"] || epoch["epoch"] != 1 || epoch["protocol_version"] != 1 {
            failures.append("op 24 isn't exactly {epoch: 1, protocol_version: 1}: \(JSON.object(epoch).serialized(spaced: false))")
        }
        guard let member = DaveMember(userID: userID, groupID: room.channel, externalSender: package, recognized: [speaker]) else { return failures }
        probe.sendBinary(Data([26]) + member.keyPackage())
        _ = try? await world.updateVoiceState(speaker, sessionID: "parity-speaker-2", VoiceStateRequest(guildID: room.guild, channelID: room.channel),
                                              simulated: true)
        guard await probe.acceptWelcome(into: member) else { return failures + ["no DAVE welcome and transition after the rejoin"] }
        try? await voice.setSpeaking(speaker, true)
        let ssrc = await probe.waitFor(op: 5)?["d"]?["ssrc"]?.intValue
        // Packets from before the rejoin may still be queued; they carry the old group's keys.
        var decrypted = false
        for _ in 0 ..< 200 where !decrypted {
            guard let packet = await udp.receive() else { break }
            guard let (header, body) = try? VoiceCrypto.open(packet, key: key, mode: .aes256GCM),
                  header[8 ..< 12].reduce(0, { $0 << 8 | Int64($1) }) == ssrc else { continue }
            decrypted = member.decrypt(body, from: speaker, video: false) != nil
        }
        try? await voice.setSpeaking(speaker, false)
        await world.leaveVoice(speaker)
        return decrypted ? failures : failures + ["the rejoined speaker's audio doesn't DAVE-decrypt"]
    }

    /// A simulated camera's H.264 arrives on its video SSRC: an IDR frame's SPS, PPS or FU-A start within the first packets.
    private static func checkVideo(from udp: UDPProbe, ssrc: Int64?, key: [UInt8]) async -> String? {
        guard let ssrc, ssrc != 0 else { return "camera on, but op 12 has no video SSRC" }
        for _ in 0 ..< 200 {
            guard let packet = await udp.receive() else { break }
            guard let (header, body) = try? VoiceCrypto.open(packet, key: key, mode: .aes256GCM),
                  header[8 ..< 12].reduce(0, { $0 << 8 | Int64($1) }) == ssrc else { continue }
            return header[1] & 0x7F == VoiceMediaServer.h264PayloadType && !body.isEmpty ? nil : "video RTP is not H.264"
        }
        return "no video RTP from a simulated camera"
    }

    static func goLive(guild: Snowflake, channel: Snowflake) -> JSON {
        .object(JSONObject([("op", 18), ("d", .object(JSONObject([
            ("type", "guild"), ("guild_id", .string(guild.description)), ("channel_id", .string(channel.description)), ("preferred_region", .null),
        ])))]))
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

/// A minimal voice gateway client (JSON text frames, binary DAVE frames).
final class VoiceProbe: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let messages = Mutex<[JSON]>([])
    /// Binary (DAVE) messages: sequence number, opcode, payload.
    private let binaries = Mutex<[Data]>([])

    init(url: URL) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, case let .success(message) = result else { return }
            switch message {
            case let .string(text): if let json = try? JSON.parse(text) { messages.withLock { $0.append(json) } }
            case let .data(data): binaries.withLock { $0.append(data) }
            @unknown default: break
            }
            receive()
        }
    }

    func send(_ message: JSON) { task.send(.string(message.serialized(spaced: false))) { _ in } }

    func sendBinary(_ data: Data) { task.send(.data(data)) { _ in } }

    /// The payload of the next binary message with `op`.
    func waitForBinary(op: UInt8, timeout: Duration = .seconds(5)) async -> Data? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = binaries.withLock({ all in all.firstIndex { $0.count > 2 && $0[$0.startIndex + 2] == op }.map { all.remove(at: $0) } }) {
                return Data(found.dropFirst(3))
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func waitFor(op: Int64, timeout: Duration = .seconds(5), where matches: (JSON) -> Bool = { _ in true }) async -> JSON? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = messages.withLock({ all in all.firstIndex { $0["op"]?.intValue == op && matches($0) }.map { all.remove(at: $0) } }) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    struct Connection {
        var ready: JSON
        var description: JSON
        var key: [UInt8]
    }

    /// Hello, Identify → Ready, IP discovery, Select Protocol (AES-GCM) → Session Description, and the transport key.
    func connect(_ identify: [(String, JSON)], udp: UDPProbe) async -> Connection? {
        guard await waitFor(op: 8) != nil else { return nil }
        send(ParityRun.voiceFrame(0, identify))
        guard let ready = await waitFor(op: 2), let ssrc = ready["d"]?["ssrc"]?.intValue,
              let (address, port) = await udp.discover(ssrc: UInt32(ssrc)) else { return nil }
        send(ParityRun.voiceFrame(1, [
            ("protocol", "udp"), ("data", .object(JSONObject([("address", .string(address)), ("port", .int(Int64(port))), ("mode", "aead_aes256_gcm_rtpsize")]))),
        ]))
        guard let description = await waitFor(op: 4) else { return nil }
        return Connection(ready: ready, description: description,
                          key: (description["d"]?["secret_key"]?.arrayValue ?? []).compactMap { $0.intValue.map(UInt8.init) })
    }

    /// The welcome into a DAVE group (op 30), ready (op 23), execute (op 22), then the new keys.
    func acceptWelcome(into member: DaveMember) async -> Bool {
        guard let welcome = await waitForBinary(op: 30), welcome.count > 2, member.join(welcome: welcome.dropFirst(2)) else { return false }
        send(ParityRun.voiceFrame(23, [("transition_id", .int(Int64(welcome[welcome.startIndex]) << 8 | Int64(welcome[welcome.startIndex + 1])))]))
        guard await waitFor(op: 22) != nil else { return false }
        member.useCurrentKey()
        return true
    }
}

/// A minimal voice UDP client: IP discovery, then receiving RTP.
final class UDPProbe: @unchecked Sendable {
    private let connection: NWConnection

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: .udp)
        connection.start(queue: DispatchQueue(label: "parity.voice-udp"))
    }

    /// The address and port the server saw, from its type 0x2 answer.
    func discover(ssrc: UInt32) async -> (String, UInt16)? {
        var request: [UInt8] = [0, 1, 0, 70] + withUnsafeBytes(of: ssrc.bigEndian, Array.init)
        request += [UInt8](repeating: 0, count: 66)
        connection.send(content: Data(request), completion: .idempotent)
        guard let answer = await receive().map(Array.init), answer.count == 74, answer[1] == 2 else { return nil }
        guard let address = String(bytes: answer[8 ..< 72].prefix { $0 != 0 }, encoding: .utf8) else { return nil }
        return (address, UInt16(answer[72]) << 8 | UInt16(answer[73]))
    }

    func receive(timeout: Duration = .seconds(5)) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { [connection] in
                await withCheckedContinuation { continuation in
                    connection.receiveMessage { data, _, _, _ in continuation.resume(returning: data) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func close() { connection.cancel() }
}
