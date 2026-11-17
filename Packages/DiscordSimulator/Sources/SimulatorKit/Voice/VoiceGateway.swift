import Foundation

/// Discord's voice server: the voice gateway (JSON text frames, binary for DAVE)
/// that a client reaches through the endpoint in VOICE_SERVER_UPDATE. No capture
/// has its frames, so the ops and fields the server sends follow the captured
/// official client's own voice-gateway parser, and close codes and sequencing
/// follow Discord's documented voice protocol
/// (discord.com/developers/docs/topics/voice-connections); DESIGN.md lists what is inferred.
///
/// Simulated people in a channel have no connection of their own; the server
/// announces them like any other client.
public actor VoiceGateway: VoiceMediaHost {
    static let heartbeatIntervalMilliseconds = 13_750
    /// Messages kept per client for a buffered resume.
    static let resumeBuffer = 200

    final class Client {
        let grant: VoiceServerGrant
        let ssrc: UInt32
        var connection: WebSocketConnection?
        var sequence: Int64 = 0
        var sent: [(sequence: Int64, message: WebSocketMessage)] = []
        /// The op 12 state last sent to this client for each peer in its channel.
        var peers: [Snowflake: JSON] = [:]
        /// This client's own op 12 state, as it last sent it.
        var video: JSON?
        var secretKey: [UInt8] = []
        /// The DAVE protocol version in use: 1 when the client offered it in Identify, else 0.
        var daveVersion: Int64 = 0

        init(grant: VoiceServerGrant, ssrc: UInt32) {
            self.grant = grant
            self.ssrc = ssrc
        }
    }

    let world: World
    let log: SimulatorLog
    let media: VoiceMediaServer
    private var random: SeededRandom
    /// Connected clients by server and Gateway session (a voice connection, plus one per stream).
    var clients: [String: Client] = [:]
    private var ssrcs: [String: UInt32] = [:]
    private var nextSSRC: UInt32 = 0x2000
    /// Turn-taking among chatty simulated people, per channel with a listener.
    var conversations: [Snowflake: Task<Void, Never>] = [:]
    /// DAVE groups per room with a DAVE client.
    var daveRooms: [Snowflake: DaveRoom] = [:]

    public init(world: World, log: SimulatorLog, seed: UInt64, mediaPort: UInt16) {
        self.world = world
        self.log = log
        media = VoiceMediaServer(port: mediaPort, log: log)
        Dave.routeLogs(to: log)
        random = SeededRandom(seed: seed).fork("voice")
    }

    public func start() async throws { try await media.start() }

    public nonisolated func stop() { media.stop() }

    // MARK: Connections

    public func handle(_ connection: WebSocketConnection) async {
        connection.send(text: Self.frame(op: 8, ["v": 8, "heartbeat_interval": .int(Self.heartbeatIntervalMilliseconds)]))
        var client: Client?
        for await message in connection.messages {
            guard case let .text(text) = message else {
                guard case let .binary(data) = message else { break }
                guard let client, client.daveVersion > 0 else {
                    log.error("voice", "binary voice gateway message without DAVE; closing 4002")
                    await connection.close(code: 4002, reason: "Failed to decode payload.")
                    return
                }
                await receiveDave(data, from: client)
                continue
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
            await syncPeers(in: client.grant.room)
        }
    }

    /// Returns false when the connection was closed.
    private func route(op: Int64, data: JSON, client: inout Client?, connection: WebSocketConnection) async -> Bool {
        if op == 3 {
            connection.send(text: Self.frame(op: 6, ["t": data["t"] ?? .null]))
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
            for peer in connectedClients(in: client.grant.room) where peer !== client { send(5, .object(speaking), to: peer) }
        case 12:
            client.video = data
            await media.addAliases([data["video_ssrc"], data["rtx_ssrc"]].compactMap { $0?.intValue.map(UInt32.init) }, to: client.ssrc)
            await syncPeers(in: client.grant.room)
        case 15:
            // Media sink wants only shape what this client is sent.
            break
        case 23, 31:
            guard client.daveVersion > 0 else { return await reject(connection, 4001, "Unknown opcode.") }
            await daveTransitionReply(op, data, from: client)
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
        if let replaced = clients[Self.key(grant.serverID, grant.sessionID)]?.connection, replaced !== connection { await replaced.close(code: 4014, reason: "Disconnected.") }
        let client = Client(grant: grant, ssrc: ssrc(for: grant.userID, in: grant.room))
        client.connection = connection
        client.daveVersion = min(1, data["max_dave_protocol_version"]?.intValue ?? 0)
        clients[Self.key(grant.serverID, grant.sessionID)] = client
        let streams = (data["streams"]?.arrayValue ?? []).enumerated().map { index, stream in
            JSON.object(JSONObject([
                ("type", stream["type"] ?? "video"), ("ssrc", .int(Int64(client.ssrc) + 1 + Int64(index) * 2)),
                ("rtx_ssrc", .int(Int64(client.ssrc) + 2 + Int64(index) * 2)), ("rid", stream["rid"] ?? "100"),
                ("quality", stream["quality"] ?? 100), ("active", false),
            ]))
        }
        await media.addAliases(streams.flatMap { [$0["ssrc"], $0["rtx_ssrc"]] }.compactMap { $0?.intValue.map(UInt32.init) }, to: client.ssrc)
        send(2, .object(JSONObject([
            ("ssrc", .int(Int64(client.ssrc))), ("ip", "127.0.0.1"), ("port", .int(Int64(media.port))),
            ("modes", .array(VoiceCrypto.Mode.allCases.map { .string($0.rawValue) })), ("experiments", []), ("streams", .array(streams)),
        ])), to: client)
        await syncPeers(in: grant.room)
        return client
    }

    private func resume(_ data: JSON, connection: WebSocketConnection) async -> Client? {
        guard let sessionID = data["session_id"]?.stringValue, let serverID = data["server_id"]?.stringValue.flatMap(Snowflake.init),
              let client = clients[Self.key(serverID, sessionID)],
              data["token"]?.stringValue == client.grant.token, data["server_id"]?.stringValue == client.grant.serverID.description,
              await world.voiceGrant(token: client.grant.token) != nil
        else {
            await connection.close(code: 4006, reason: "Session is no longer valid.")
            return nil
        }
        let acknowledged = data["seq_ack"]?.intValue ?? 0
        client.connection = connection
        for (sequence, message) in client.sent where sequence > acknowledged { Self.transmit(message, over: connection) }
        send(9, .null, to: client)
        await syncPeers(in: client.grant.room)
        return client
    }

    private func selectProtocol(_ client: Client, _ data: JSON, connection: WebSocketConnection) async -> Bool {
        guard data["protocol"]?.stringValue == "udp" else { return await reject(connection, 4012, "Unknown protocol.") }
        guard let mode = data["data"]?["mode"]?.stringValue.flatMap(VoiceCrypto.Mode.init(rawValue:)) else {
            return await reject(connection, 4016, "Unknown encryption mode.")
        }
        client.secretKey = (0 ..< 32).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        send(4, .object(JSONObject([
            ("audio_codec", "opus"), ("video_codec", "H264"),
            ("media_session_id", .string(String(format: "%016llx%016llx", random.next(), random.next()))),
            ("mode", .string(mode.rawValue)), ("secret_key", .array(client.secretKey.map { .int(Int64($0)) })),
            ("dave_protocol_version", .int(client.daveVersion)),
        ])), to: client)
        await media.register(ssrc: client.ssrc, userID: client.grant.userID, channelID: client.grant.room, mode: mode, key: client.secretKey)
        if client.daveVersion > 0 { await daveJoined(client) }
        return true
    }

    private func reject(_ connection: WebSocketConnection, _ code: UInt16, _ reason: String) async -> Bool {
        await connection.close(code: code, reason: reason)
        return false
    }

    // MARK: Peers

    public func participantsChanged(in channelID: Snowflake) async { await syncPeers(in: channelID) }

    public func disconnect(sessionID: String) async {
        for (key, client) in clients where client.grant.sessionID == sessionID {
            clients[key] = nil
            await media.unregister(ssrc: client.ssrc)
            await client.connection?.close(code: 4014, reason: "Disconnected.")
            await syncPeers(in: client.grant.room)
        }
    }

    /// Tells each connected client in the channel who joined (op 11, 18, 20, then their op 12 media state),
    /// whose media changed (op 12) and who left (op 13).
    private func syncPeers(in channelID: Snowflake) async {
        let present = await world.mediaParticipants(in: channelID).filter { state in
            state.simulated || clients.values.contains { $0.grant.userID == state.userID && $0.grant.room == channelID && $0.connection != nil }
        }
        await media.keepTalkers(in: channelID, only: Set(present.filter { $0.simulated && !$0.selfMute }.map(\.userID)))
        let cameras = hasListeners(in: channelID) ? present.filter { $0.simulated && $0.selfVideo } : []
        await media.syncVideo(in: channelID, senders: Dictionary(uniqueKeysWithValues: cameras.map { (ssrc(for: $0.userID, in: channelID) + 1, $0.userID) }),
                              kind: await world.stream(rtcServerID: channelID) == nil ? .camera : .screen)
        updateConversation(in: channelID, present: present)
        await syncDave(in: channelID)
        for client in connectedClients(in: channelID) {
            let others = present.filter { $0.userID != client.grant.userID }
            let joined = others.filter { client.peers[$0.userID] == nil }
            if !joined.isEmpty { send(11, .object(JSONObject([("user_ids", .array(joined.map { .string($0.userID.description) }))])), to: client) }
            for state in joined {
                send(18, .object(JSONObject([("user_id", .string(state.userID.description)), ("flags", 0)])), to: client)
                send(20, .object(JSONObject([("user_id", .string(state.userID.description)), ("platform", 0)])), to: client)
            }
            for state in others {
                let current = mediaState(of: state)
                if client.peers[state.userID] != current { send(12, current, to: client) }
                client.peers[state.userID] = current
            }
            for gone in client.peers.keys.sorted() where !others.contains(where: { $0.userID == gone }) {
                client.peers[gone] = nil
                send(13, .object(JSONObject([("user_id", .string(gone.description))])), to: client)
            }
        }
    }

    /// A simulated person starts or stops speaking (op 5 with the microphone flag).
    public func setSpeaking(_ userID: Snowflake, _ speaking: Bool) async throws {
        guard let state = await world.voiceState(of: userID), state.simulated else { throw WorldError.invalidBody("user is not a simulated person in voice") }
        guard !speaking || !state.selfMute else { throw WorldError.invalidBody("user is muted") }
        let payload = JSON.object(JSONObject([("user_id", .string(userID.description)), ("ssrc", .int(Int64(ssrc(for: userID, in: state.channelID)))),
                                              ("speaking", .int(speaking ? 1 : 0))]))
        for client in connectedClients(in: state.channelID) { send(5, payload, to: client) }
        if speaking { await media.startTalking(userID, ssrc: ssrc(for: userID, in: state.channelID), channelID: state.channelID) } else { await media.stopTalking(userID) }
    }

    func hasListeners(in channelID: Snowflake) -> Bool { !connectedClients(in: channelID).isEmpty }

    /// Clients connected to a room right now (a dropped one may still resume).
    func connectedClients(in room: Snowflake) -> [Client] {
        clients.values.filter { $0.grant.room == room && $0.connection != nil }
    }

    /// A participant's op 12: their SSRCs and video stream, from their own op 12 or, for simulated people, their camera flag.
    private func mediaState(of state: VoiceState) -> JSON {
        let audio = Int64(ssrc(for: state.userID, in: state.channelID))
        let user = JSON.object(JSONObject([("user_id", .string(state.userID.description))]))
        if let client = clients.values.first(where: { $0.grant.userID == state.userID && $0.grant.room == state.channelID }) {
            guard var video = client.video?.objectValue else { return user.merging(["audio_ssrc": .int(audio), "video_ssrc": 0, "rtx_ssrc": 0, "streams": []]) }
            video["user_id"] = .string(state.userID.description)
            return .object(video)
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
    func ssrc(for userID: Snowflake, in room: Snowflake) -> UInt32 {
        let key = Self.key(room, userID.description)
        if let known = ssrcs[key] { return known }
        nextSSRC += 3
        ssrcs[key] = nextSSRC
        return nextSSRC
    }

    /// Connections and SSRCs are per voice server (guild, call or stream) and session or user.
    static func key(_ server: Snowflake, _ member: String) -> String { "\(server)/\(member)" }

    // MARK: Frames

    /// Sends a sequenced server message, kept for a buffered resume.
    func send(_ op: Int64, _ data: JSON, to client: Client) {
        client.sequence += 1
        let text = JSON.object(JSONObject([("op", .int(op)), ("d", data), ("seq", .int(client.sequence))])).serialized(spaced: false)
        deliver(.text(text), to: client)
    }

    /// A binary DAVE message: sequence number (big-endian), opcode, payload.
    func sendBinary(_ op: UInt8, _ payload: Data, to client: Client) {
        client.sequence += 1
        let sequence = UInt16(truncatingIfNeeded: client.sequence)
        deliver(.binary(Data([UInt8(sequence >> 8), UInt8(sequence & 0xFF), op]) + payload), to: client)
    }

    private func deliver(_ message: WebSocketMessage, to client: Client) {
        client.sent.append((client.sequence, message))
        if client.sent.count > Self.resumeBuffer { client.sent.removeFirst(client.sent.count - Self.resumeBuffer) }
        if let connection = client.connection { Self.transmit(message, over: connection) }
    }

    private static func transmit(_ message: WebSocketMessage, over connection: WebSocketConnection) {
        switch message {
        case let .text(text): connection.send(text: text)
        case let .binary(data): connection.send(binary: data)
        case .close: break
        }
    }

    /// Connected clients in a room that use DAVE.
    func daveClients(in room: Snowflake) -> [Client] { connectedClients(in: room).filter { $0.daveVersion > 0 } }

    /// Hello and heartbeat ACKs carry no sequence number.
    static func frame(op: Int64, _ data: [String: JSON]) -> String {
        JSON.object(JSONObject([("op", .int(op)), ("d", .object(JSONObject(data.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })))])).serialized(spaced: false)
    }
}
