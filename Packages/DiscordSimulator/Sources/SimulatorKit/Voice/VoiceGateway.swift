import Foundation

/// Discord's voice server: the voice gateway (v8, JSON text frames) that a
/// client reaches through the endpoint in VOICE_SERVER_UPDATE. No capture
/// covers it (the official client's native voice module talks to it outside
/// the captured browser layer), so messages, close codes and sequencing follow
/// Discord's documented voice connection protocol
/// (discord.com/developers/docs/topics/voice-connections).
///
/// Simulated people in a channel have no connection of their own; the server
/// announces them like any other client.
public actor VoiceGateway: VoiceMediaHost {
    static let heartbeatIntervalMilliseconds = 13_750
    static let encryptionModes = ["aead_aes256_gcm_rtpsize", "aead_xchacha20_poly1305_rtpsize"]
    /// Messages kept per client for a buffered resume.
    static let resumeBuffer = 200

    final class Client {
        let grant: VoiceServerGrant
        let ssrc: UInt32
        var connection: WebSocketConnection?
        var sequence: Int64 = 0
        var sent: [(sequence: Int64, text: String)] = []
        /// The op 12 state last sent to this client for each peer in its channel.
        var peers: [Snowflake: JSON] = [:]
        /// This client's own op 12 state, as it last sent it.
        var video: JSON?
        var mode: String?
        var secretKey: [UInt8] = []

        init(grant: VoiceServerGrant, ssrc: UInt32) {
            self.grant = grant
            self.ssrc = ssrc
        }
    }

    let world: World
    let log: SimulatorLog
    /// The UDP media port announced in Ready.
    let mediaPort: UInt16
    private var random: SeededRandom
    /// Connected clients by Gateway session ID (one voice connection per session).
    private var clients: [String: Client] = [:]
    private var ssrcs: [Snowflake: UInt32] = [:]
    private var nextSSRC: UInt32 = 0x2000

    public init(world: World, log: SimulatorLog, seed: UInt64, mediaPort: UInt16) {
        self.world = world
        self.log = log
        self.mediaPort = mediaPort
        random = SeededRandom(seed: seed).fork("voice")
    }

    // MARK: Connections

    public func handle(_ connection: WebSocketConnection) async {
        await connection.send(text: Self.frame(op: 8, ["v": 8, "heartbeat_interval": .int(Self.heartbeatIntervalMilliseconds)]))
        var client: Client?
        for await message in connection.messages {
            guard case let .text(text) = message else {
                if case .binary = message {
                    log.error("voice", "binary voice gateway message with DAVE off; closing 4002")
                    await connection.close(code: 4002, reason: "Failed to decode payload.")
                    return
                }
                break
            }
            guard let payload = try? JSON.parse(text), let op = payload["op"]?.intValue else {
                log.error("voice", "undecodable voice gateway message; closing 4002")
                await connection.close(code: 4002, reason: "Failed to decode payload.")
                return
            }
            guard await route(op: op, data: payload["d"] ?? .null, client: &client, connection: connection) else { return }
        }
        if let client, client.connection === connection {
            client.connection = nil
            await syncPeers(in: client.grant.channelID)
        }
    }

    /// Returns false when the connection was closed.
    private func route(op: Int64, data: JSON, client: inout Client?, connection: WebSocketConnection) async -> Bool {
        if op == 3 {
            await connection.send(text: Self.frame(op: 6, ["t": data["t"] ?? .null]))
            return true
        }
        if op == 0 || op == 7 {
            guard client == nil else { return await reject(connection, 4005, "Already authenticated.") }
            client = op == 0 ? await identify(data, connection: connection) : await resume(data, connection: connection)
            return client != nil
        }
        guard let client else { return await reject(connection, 4003, "Not authenticated.") }
        switch op {
        case 1:
            return await selectProtocol(client, data, connection: connection)
        case 5:
            let speaking = JSONObject([("user_id", .string(client.grant.userID.description)), ("ssrc", .int(Int64(client.ssrc))),
                                       ("speaking", data["speaking"] ?? 0)])
            for peer in peers(of: client) { await send(5, .object(speaking), to: peer) }
        case 12:
            client.video = data
            await syncPeers(in: client.grant.channelID)
        case 15:
            // Media sink wants only shape what this client is sent.
            break
        default:
            log.error("voice", "unknown voice opcode \(op); closing 4001")
            return await reject(connection, 4001, "Unknown opcode.")
        }
        return true
    }

    private func identify(_ data: JSON, connection: WebSocketConnection) async -> Client? {
        guard let token = data["token"]?.stringValue, let grant = await world.voiceGrant(token: token),
              data["server_id"]?.stringValue == grant.serverID.description, data["user_id"]?.stringValue == grant.userID.description,
              data["session_id"]?.stringValue == grant.sessionID
        else {
            log.error("voice", "identify with an unknown or mismatched token; closing 4004")
            await connection.close(code: 4004, reason: "Authentication failed.")
            return nil
        }
        if let replaced = clients[grant.sessionID]?.connection, replaced !== connection { await replaced.close(code: 4014, reason: "Disconnected.") }
        let client = Client(grant: grant, ssrc: ssrc(for: grant.userID))
        client.connection = connection
        clients[grant.sessionID] = client
        let streams = (data["streams"]?.arrayValue ?? []).enumerated().map { index, stream in
            JSON.object(JSONObject([
                ("type", stream["type"] ?? "video"), ("ssrc", .int(Int64(client.ssrc) + 1 + Int64(index) * 2)),
                ("rtx_ssrc", .int(Int64(client.ssrc) + 2 + Int64(index) * 2)), ("rid", stream["rid"] ?? "100"),
                ("quality", stream["quality"] ?? 100), ("active", false),
            ]))
        }
        await send(2, .object(JSONObject([
            ("ssrc", .int(Int64(client.ssrc))), ("ip", "127.0.0.1"), ("port", .int(Int64(mediaPort))),
            ("modes", .array(Self.encryptionModes.map(JSON.string))), ("experiments", []), ("streams", .array(streams)),
        ])), to: client)
        await syncPeers(in: grant.channelID)
        return client
    }

    private func resume(_ data: JSON, connection: WebSocketConnection) async -> Client? {
        guard let sessionID = data["session_id"]?.stringValue, let client = clients[sessionID],
              data["token"]?.stringValue == client.grant.token, data["server_id"]?.stringValue == client.grant.serverID.description,
              await world.voiceGrant(token: client.grant.token) != nil
        else {
            await connection.close(code: 4006, reason: "Session is no longer valid.")
            return nil
        }
        let acknowledged = data["seq_ack"]?.intValue ?? 0
        client.connection = connection
        for (sequence, text) in client.sent where sequence > acknowledged { await connection.send(text: text) }
        await send(9, .null, to: client)
        await syncPeers(in: client.grant.channelID)
        return client
    }

    private func selectProtocol(_ client: Client, _ data: JSON, connection: WebSocketConnection) async -> Bool {
        guard data["protocol"]?.stringValue == "udp" else { return await reject(connection, 4012, "Unknown protocol.") }
        guard let mode = data["data"]?["mode"]?.stringValue, Self.encryptionModes.contains(mode) else {
            return await reject(connection, 4016, "Unknown encryption mode.")
        }
        client.mode = mode
        client.secretKey = (0 ..< 32).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        await send(4, .object(JSONObject([
            ("audio_codec", "opus"), ("video_codec", "H264"),
            ("media_session_id", .string(String(format: "%016llx%016llx", random.next(), random.next()))),
            ("mode", .string(mode)), ("secret_key", .array(client.secretKey.map { .int(Int64($0)) })),
            ("dave_protocol_version", 0),
        ])), to: client)
        return true
    }

    private func reject(_ connection: WebSocketConnection, _ code: UInt16, _ reason: String) async -> Bool {
        await connection.close(code: code, reason: reason)
        return false
    }

    // MARK: Peers

    public func participantsChanged(in channelID: Snowflake) async { await syncPeers(in: channelID) }

    public func disconnect(sessionID: String) async {
        guard let client = clients.removeValue(forKey: sessionID) else { return }
        await client.connection?.close(code: 4014, reason: "Disconnected.")
        await syncPeers(in: client.grant.channelID)
    }

    /// Tells each connected client in the channel who joined (op 11, 18, 20, then their op 12 media state),
    /// whose media changed (op 12) and who left (op 13).
    private func syncPeers(in channelID: Snowflake) async {
        let present = await world.voiceStates(in: channelID).filter { state in
            state.simulated || clients.values.contains { $0.grant.userID == state.userID && $0.grant.channelID == channelID && $0.connection != nil }
        }
        for client in clients.values where client.grant.channelID == channelID && client.connection != nil {
            let others = present.filter { $0.userID != client.grant.userID }
            let joined = others.filter { client.peers[$0.userID] == nil }
            if !joined.isEmpty { await send(11, .object(JSONObject([("user_ids", .array(joined.map { .string($0.userID.description) }))])), to: client) }
            for state in joined {
                await send(18, .object(JSONObject([("user_id", .string(state.userID.description)), ("flags", 0)])), to: client)
                await send(20, .object(JSONObject([("user_id", .string(state.userID.description)), ("platform", 0)])), to: client)
            }
            for state in others {
                let media = mediaState(of: state)
                if client.peers[state.userID] != media { await send(12, media, to: client) }
                client.peers[state.userID] = media
            }
            for gone in client.peers.keys.sorted() where !others.contains(where: { $0.userID == gone }) {
                client.peers[gone] = nil
                await send(13, .object(JSONObject([("user_id", .string(gone.description))])), to: client)
            }
        }
    }

    /// A simulated person starts or stops speaking (op 5 with the microphone flag).
    public func setSpeaking(_ userID: Snowflake, _ speaking: Bool) async throws {
        guard let state = await world.voiceState(of: userID), state.simulated else { throw WorldError.invalidBody("user is not a simulated person in voice") }
        let payload = JSON.object(JSONObject([("user_id", .string(userID.description)), ("ssrc", .int(Int64(ssrc(for: userID)))),
                                              ("speaking", .int(speaking ? 1 : 0))]))
        for client in clients.values where client.grant.channelID == state.channelID && client.connection != nil {
            await send(5, payload, to: client)
        }
    }

    private func peers(of client: Client) -> [Client] {
        clients.values.filter { $0 !== client && $0.grant.channelID == client.grant.channelID && $0.connection != nil }
    }

    /// A participant's op 12: their SSRCs and video stream, from their own op 12 or, for simulated people, their camera flag.
    private func mediaState(of state: VoiceState) -> JSON {
        let audio = Int64(ssrc(for: state.userID))
        let user = JSON.object(JSONObject([("user_id", .string(state.userID.description))]))
        if let client = clients.values.first(where: { $0.grant.userID == state.userID && $0.grant.channelID == state.channelID }) {
            return user.merging(client.video?.objectValue.map { Dictionary($0.map { ($0.key, $0.value) }) { first, _ in first } }
                ?? ["audio_ssrc": .int(audio), "video_ssrc": 0, "rtx_ssrc": 0, "streams": []])
        }
        let on = state.selfVideo
        return user.merging([
            "audio_ssrc": .int(audio), "video_ssrc": .int(on ? audio + 1 : 0), "rtx_ssrc": .int(on ? audio + 2 : 0),
            "streams": .array([.object(JSONObject([
                ("type", "video"), ("rid", "100"), ("ssrc", .int(audio + 1)), ("rtx_ssrc", .int(audio + 2)),
                ("active", .bool(on)), ("quality", 100),
                ("max_resolution", .object(JSONObject([("type", "fixed"), ("width", 1280), ("height", 720)]))),
                ("max_framerate", 30), ("max_bitrate", 2_500_000),
            ]))]),
        ])
    }

    /// Audio SSRC per user; video and RTX use the next two.
    func ssrc(for userID: Snowflake) -> UInt32 {
        if let known = ssrcs[userID] { return known }
        nextSSRC += 3
        ssrcs[userID] = nextSSRC
        return nextSSRC
    }

    // MARK: Frames

    /// Sends a sequenced server message, kept for a buffered resume.
    private func send(_ op: Int64, _ data: JSON, to client: Client) async {
        client.sequence += 1
        let text = JSON.object(JSONObject([("op", .int(op)), ("d", data), ("seq", .int(client.sequence))])).serialized(spaced: false)
        client.sent.append((client.sequence, text))
        if client.sent.count > Self.resumeBuffer { client.sent.removeFirst(client.sent.count - Self.resumeBuffer) }
        await client.connection?.send(text: text)
    }

    /// Hello and heartbeat ACKs carry no sequence number.
    static func frame(op: Int64, _ data: [String: JSON]) -> String {
        JSON.object(JSONObject([("op", .int(op)), ("d", .object(JSONObject(data.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })))])).serialized(spaced: false)
    }
}
