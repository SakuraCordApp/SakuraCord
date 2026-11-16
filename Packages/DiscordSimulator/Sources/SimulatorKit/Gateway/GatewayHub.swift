import Foundation

/// Gateway sessions: Hello, Identify, heartbeats, Resume, dispatch fan-out and
/// connection faults. Frames are conformed to the captured event shapes and
/// encoded the way the client asked for in its connection URL.
public actor GatewayHub: WorldEventSink {
    public static let heartbeatIntervalMilliseconds: Int64 = 41_250

    final class Session {
        let id: String
        let userID: Snowflake
        var connection: WebSocketConnection?
        var codec: GatewayFrameCodec?
        var sequence: Int64 = 0
        var threadSyncedGuilds: Set<Snowflake> = []
        /// Dispatches kept for Resume, oldest first.
        var buffer: [Dispatch] = []

        struct Dispatch {
            let sequence: Int64
            let frame: JSON
            let shape: ShapeNode?
        }

        init(id: String, userID: Snowflake) {
            self.id = id
            self.userID = userID
        }
    }

    let world: World
    let catalog: ShapeCatalog
    let log: SimulatorLog
    let resumeURL: String
    /// QR sign-in connections arrive on the same port, as `?v=2`.
    public let remoteAuth: RemoteAuthGateway
    private var sessions: [String: Session] = [:]
    private var random: SeededRandom
    /// Every dispatch sent, in order, for the parity harness.
    public private(set) var sentDispatches: [(userID: Snowflake, name: String)] = []

    public init(world: World, catalog: ShapeCatalog, log: SimulatorLog, seed: UInt64,
                resumeURL: String = "wss://gateway-us-east1-c.discord.gg") {
        self.world = world
        self.catalog = catalog
        self.log = log
        self.resumeURL = resumeURL
        remoteAuth = RemoteAuthGateway(world: world, log: log, seed: seed)
        random = SeededRandom(seed: seed).fork("gateway")
    }

    // MARK: Connections

    public func handle(_ connection: WebSocketConnection) async {
        let query = connection.request.query
        if query["v"]?.first == "2" { return await remoteAuth.handle(connection) }
        let codec = GatewayFrameCodec(encoding: query["encoding"]?.first ?? "json", compression: query["compress"]?.first)
        var session: Session?
        await send(frame(op: 10, data: .object(JSONObject([
            ("heartbeat_interval", .int(Self.heartbeatIntervalMilliseconds)),
            ("_trace", .array([.string("[\"gateway-sim\",{\"micros\":0.0}]")])),
        ]))), shapeKey: "op10", over: connection, codec: codec)

        for await message in connection.messages {
            if case let .close(code, _) = message {
                // A normal close ends the session; Discord won't resume it.
                if let session, code == 1000 || code == 1001 {
                    sessions[session.id] = nil
                    await world.leaveVoice(session: session.id)
                }
                break
            }
            guard let payload = await decodeClientMessage(message, connection: connection, codec: codec) else { return }
            let op = payload["op"]?.intValue ?? -1
            checkSent(op: op, payload: payload)
            guard await route(op: op, data: payload["d"] ?? .null, session: &session, connection: connection, codec: codec) else { return }
        }
        // A resumed session may already belong to a newer connection.
        if session?.connection === connection { session?.connection = nil }
    }

    /// Closes the connection with 4002 and returns nil when the frame cannot be decoded.
    private func decodeClientMessage(_ message: WebSocketMessage, connection: WebSocketConnection, codec: GatewayFrameCodec) async -> JSON? {
        let decoded: JSON?
        switch message {
        case let .binary(data):
            decoded = try? codec.decodeClientFrame(data)
            if decoded == nil { log.error("gateway", "undecodable client frame (\(data.count) bytes); closing 4002") }
        case let .text(text):
            decoded = try? JSON.parse(text)
        case .close:
            decoded = nil
        }
        if decoded == nil { await connection.close(code: 4002, reason: "Error while decoding payload.") }
        return decoded
    }

    /// Returns false when the connection should stop reading.
    private func route(op: Int64, data: JSON, session: inout Session?, connection: WebSocketConnection, codec: GatewayFrameCodec) async -> Bool {
        switch op {
        case 1, 40:
            await send(frame(op: 11, data: .null), shapeKey: "op11", over: connection, codec: codec)
        case 2:
            session = await identify(data, connection: connection, codec: codec)
            return session != nil
        case 6:
            session = await resume(data, connection: connection, codec: codec)
            return session != nil
        case 3:
            if let session { await updatePresence(session.userID, data) }
        case 8:
            if let session { await requestMembers(session, data) }
        case 37:
            if let session { await subscribe(session, data) }
        case 4:
            if let session { await updateVoiceState(session, data) }
        case 13:
            if let session { await connectPrivateCall(session, data) }
        case 14, 41, 43:
            // The legacy lazy request and client telemetry need no reply.
            break
        default:
            log.error("gateway", "unknown opcode \(op); closing 4001")
            await connection.close(code: 4001, reason: "Unknown opcode.")
            return false
        }
        return true
    }

    private func identify(_ data: JSON, connection: WebSocketConnection, codec: GatewayFrameCodec) async -> Session? {
        guard let token = data["token"]?.stringValue, let userID = await world.userID(forToken: token) else {
            log.error("gateway", "identify with an unknown token; closing 4004")
            await connection.close(code: 4004, reason: "Authentication failed.")
            return nil
        }
        let sessionID = String(format: "%016llx%016llx", random.next(), random.next())
        let session = Session(id: sessionID, userID: userID)
        session.connection = connection
        session.codec = codec
        if let status = data["presence"]?["status"]?.stringValue, let parsed = PresenceStatus(rawValue: status) {
            var presence = await world.presences[userID] ?? Presence()
            presence.status = parsed
            await world.setPresence(userID, presence)
        }
        await dispatch("READY", await world.renderReady(for: userID, sessionID: sessionID, resumeURL: resumeURL), to: session)
        await dispatch("READY_SUPPLEMENTAL", await world.renderReadySupplemental(for: userID), to: session)
        // Only now can world events reach it, so READY is always its first dispatch.
        sessions[sessionID] = session
        return session
    }

    private func resume(_ data: JSON, connection: WebSocketConnection, codec: GatewayFrameCodec) async -> Session? {
        guard let sessionID = data["session_id"]?.stringValue, let session = sessions[sessionID],
              let token = data["token"]?.stringValue, await world.userID(forToken: token) == session.userID
        else {
            await send(frame(op: 9, data: false), shapeKey: "op9", over: connection, codec: codec)
            return nil
        }
        let last = data["seq"]?.intValue ?? 0
        guard last >= (session.buffer.first?.sequence ?? 1) - 1 else {
            await send(frame(op: 9, data: false), shapeKey: "op9", over: connection, codec: codec)
            sessions[sessionID] = nil
            return nil
        }
        // Replay with no live connection attached, so dispatches arriving meanwhile
        // are buffered and replayed in order rather than interleaved.
        session.connection = nil
        var replayed = last
        while let next = session.buffer.first(where: { $0.sequence > replayed }) {
            await send(next.frame, shape: next.shape, over: connection, codec: codec)
            replayed = next.sequence
        }
        session.connection = connection
        session.codec = codec
        await dispatch("RESUMED", .object(JSONObject([("_trace", .array([.string("[\"gateway-sim\",{\"micros\":0.0}]")]))])), to: session)
        return session
    }

    private func updatePresence(_ userID: Snowflake, _ data: JSON) async {
        var presence = await world.presences[userID] ?? Presence()
        if let status = data["status"]?.stringValue, let parsed = PresenceStatus(rawValue: status) { presence.status = parsed }
        presence.activities = data["activities"]?.arrayValue ?? []
        await world.updatePresence(userID, presence)
    }

    private func requestMembers(_ session: Session, _ data: JSON) async {
        let guildIDs = (data["guild_id"]?.arrayValue ?? [data["guild_id"] ?? .null]).compactMap { $0.stringValue.flatMap(Snowflake.init) }
        let query = data["query"]?.stringValue?.lowercased()
        let limit = Int(data["limit"]?.intValue ?? 100)
        let requested = Set((data["user_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) })
        for guildID in guildIDs {
            guard let guild = await world.guilds[guildID] else { continue }
            var members: [JSON] = []
            for id in guild.memberOrder {
                guard let member = guild.members[id], let user = await world.users[id] else { continue }
                if !requested.isEmpty, !requested.contains(id) { continue }
                if let query, !query.isEmpty,
                   !(user.username.lowercased().hasPrefix(query) || (user.globalName ?? "").lowercased().hasPrefix(query)
                       || (member.nick ?? "").lowercased().hasPrefix(query)) { continue }
                members.append(await world.renderMember(member, guildID: guildID, includeUser: true))
                if limit > 0, members.count >= limit { break }
            }
            var chunk = JSONObject([("guild_id", guildID.json), ("members", .array(members)),
                                    ("chunk_index", 0), ("chunk_count", 1)])
            if let nonce = data["nonce"]?.stringValue { chunk["nonce"] = .string(nonce) }
            if data["presences"]?.boolValue == true {
                var presences: [JSON] = []
                for member in members {
                    if let id = member["user"]?["id"]?.stringValue.flatMap(Snowflake.init) { presences.append(await world.renderPresence(id, guildID: guildID)) }
                }
                chunk["presences"] = .array(presences)
            }
            await dispatch("GUILD_MEMBERS_CHUNK", .object(chunk), to: session)
        }
    }

    /// Op 37 subscriptions: member-list ranges per channel get a GUILD_MEMBER_LIST_UPDATE SYNC.
    private func subscribe(_ session: Session, _ data: JSON) async {
        for (guildText, subscription) in data["subscriptions"]?.objectValue ?? JSONObject() {
            guard let guildID = Snowflake(guildText) else { continue }
            // Subscribing to a guild's threads syncs its active threads once per session.
            if subscription["threads"]?.boolValue == true, session.threadSyncedGuilds.insert(guildID).inserted,
               let sync = await world.renderThreadListSync(guildID: guildID, viewer: session.userID) {
                await dispatch("THREAD_LIST_SYNC", sync, to: session)
            }
            for (channelText, ranges) in subscription["channels"]?.objectValue ?? JSONObject() {
                guard let channelID = Snowflake(channelText) else { continue }
                let pairs = (ranges.arrayValue ?? []).compactMap { range -> ClosedRange<Int>? in
                    guard let bounds = range.arrayValue, bounds.count == 2, let low = bounds[0].intValue, let high = bounds[1].intValue,
                          low >= 0, low <= high else { return nil }
                    return Int(low) ... Int(high)
                }
                if let update = await world.renderMemberList(guildID: guildID, channelID: channelID, ranges: pairs) {
                    await dispatch("GUILD_MEMBER_LIST_UPDATE", update, to: session)
                }
            }
        }
    }

    // MARK: Dispatch

    public func deliver(_ events: [WorldEvent]) async {
        for event in events {
            let recipients = await world.recipients(of: event.audience)
            for session in sessions.values where recipients.contains(session.userID) {
                await dispatch(event.name, event.data, to: session)
            }
        }
    }

    func dispatch(_ name: String, _ data: JSON, to session: Session) async {
        session.sequence += 1
        let shape = catalog.gateway[name]
        if shape == nil { log.warning("gateway", "dispatching \(name), which no capture contains") }
        let frame = JSON.object(JSONObject([("t", .string(name)), ("s", .int(session.sequence)), ("op", 0), ("d", data)]))
        let (conformed, dropped) = shape?.conform(frame) ?? (frame, [])
        if !dropped.isEmpty { log.debug("gateway", "\(name): dropped uncaptured fields \(dropped.joined(separator: ", "))") }
        session.buffer.append(.init(sequence: session.sequence, frame: conformed, shape: shape))
        if session.buffer.count > 2_000 { session.buffer.removeFirst(session.buffer.count - 2_000) }
        sentDispatches.append((session.userID, name))
        guard let connection = session.connection, let codec = session.codec else { return }
        await send(conformed, shape: shape, over: connection, codec: codec)
    }

    private func frame(op: Int64, data: JSON) -> JSON {
        .object(JSONObject([("t", .null), ("s", .null), ("op", .int(op)), ("d", data)]))
    }

    private func send(_ frame: JSON, shapeKey: String, over connection: WebSocketConnection, codec: GatewayFrameCodec) async {
        await send(frame, shape: catalog.gateway[shapeKey], over: connection, codec: codec)
    }

    private func send(_ frame: JSON, shape: ShapeNode?, over connection: WebSocketConnection, codec: GatewayFrameCodec) async {
        let encoded = codec.encode(frame, shape: shape)
        if encoded.isBinary { await connection.send(binary: encoded.data) } else { await connection.send(text: String(bytes: encoded.data, encoding: .utf8) ?? "") }
    }

    private func checkSent(op: Int64, payload: JSON) {
        guard let shape = catalog.gatewaySent["op\(op)"] else { return }
        let violations = ShapeChecker.check(payload, against: shape).filter { $0.kind != .unverified && $0.kind != .missingField }
        if !violations.isEmpty {
            log.debug("gateway", "client op \(op) differs from the official client: \(violations.prefix(3).map(\.description).joined(separator: "; "))")
        }
    }

    // MARK: Faults

    public enum Fault: String, Sendable, CaseIterable {
        /// TCP drops with no close frame; the client must Resume.
        case drop
        /// Op 7: Discord asks the client to reconnect and Resume.
        case reconnect
        /// Op 9 with `d: false`: the session is gone; the client must Identify again.
        case invalidSession = "invalid-session"
        /// Close code 4000, which allows Resume.
        case closeResumable = "close-resumable"
    }

    /// Applies a fault to every live session (or one user's sessions). Returns how many were affected.
    @discardableResult
    public func inject(_ fault: Fault, userID: Snowflake? = nil) async -> Int {
        var count = 0
        for session in sessions.values where userID == nil || session.userID == userID {
            guard let connection = session.connection, let codec = session.codec else { continue }
            count += 1
            switch fault {
            case .drop:
                session.connection = nil
                connection.drop()
            case .reconnect:
                await send(frame(op: 7, data: .null), shapeKey: "op7", over: connection, codec: codec)
            case .invalidSession:
                await send(frame(op: 9, data: false), shapeKey: "op9", over: connection, codec: codec)
                sessions[session.id] = nil
                await connection.close(code: 4000, reason: "Session invalidated.")
            case .closeResumable:
                session.connection = nil
                await connection.close(code: 4000, reason: "Unknown error.")
            }
        }
        return count
    }

}
