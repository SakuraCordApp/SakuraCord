import Foundation

/// One user's voice connection, as Discord tracks it: a user is in at most one
/// voice channel or private call at a time.
public struct VoiceState: Sendable {
    public var userID: Snowflake
    public var guildID: Snowflake?
    public var channelID: Snowflake
    /// The Gateway session that joined (for simulated people, a made-up one).
    public var sessionID: String
    /// Unix seconds.
    public var connectedAt: Int64
    public var selfMute = false
    public var selfDeaf = false
    public var selfVideo = false
    public var selfStream = false
    public var mute = false
    public var deaf = false
    public var suppress = false
    /// Simulated people have no voice connection of their own; the voice server stands in for them.
    public var simulated = false
    /// A simulated person who takes part in the channel's conversation whenever someone is listening.
    public var chatters = false
}

/// What a client needs to reach the voice server: the payload of VOICE_SERVER_UPDATE.
public struct VoiceServerGrant: Sendable {
    public var token: String
    public var endpoint: String
    public var userID: Snowflake
    public var sessionID: String
    public var guildID: Snowflake?
    public var channelID: Snowflake
    /// A Go Live stream's own media server; nil for voice.
    public var rtcServerID: Snowflake?
    /// The voice gateway's `server_id`: a stream's server, the guild, or the private channel for calls.
    public var serverID: Snowflake { rtcServerID ?? guildID ?? channelID }
    /// Where the connection's media goes: the stream's server for Go Live, else the voice channel.
    public var room: Snowflake { rtcServerID ?? channelID }
}

/// The voice server, told when who is in a channel changes.
public protocol VoiceMediaHost: AnyObject, Sendable {
    func participantsChanged(in channelID: Snowflake) async
    /// Closes the voice connections a Gateway session opened (it left voice).
    func disconnect(sessionID: String) async
}

/// Voice and call state, kept in one place on `World`.
struct VoiceRegistry {
    var states: [Snowflake: VoiceState] = [:]
    var calls: [Snowflake: Call] = [:]
    var grants: [String: VoiceServerGrant] = [:]
    var channelStatus: [Snowflake: String] = [:]
    /// Go Live streams by stream key.
    var streams: [String: GoLiveStream] = [:]
    /// Activities on the shelf, running instances by application and channel, proxy tickets and acknowledged disclosures.
    var activityApps: [Snowflake: ActivityApp] = [:]
    var activities: [String: ActivityInstance] = [:]
    var activityTickets: [String: Snowflake] = [:]
    var ackedDisclosures: [Snowflake: [Snowflake: Set<Int>]] = [:]
    weak var media: (any VoiceMediaHost)?
}

/// A voice state change requested with Gateway op 4.
public struct VoiceStateRequest: Sendable {
    public var guildID: Snowflake?
    public var channelID: Snowflake?
    public var selfMute = false
    public var selfDeaf = false
    public var selfVideo = false
    public var region: String?

    public init(guildID: Snowflake?, channelID: Snowflake?) {
        self.guildID = guildID
        self.channelID = channelID
    }

    init(_ data: JSON) {
        guildID = data["guild_id"]?.stringValue.flatMap(Snowflake.init)
        channelID = data["channel_id"]?.stringValue.flatMap(Snowflake.init)
        selfMute = data["self_mute"]?.boolValue ?? false
        selfDeaf = data["self_deaf"]?.boolValue ?? false
        selfVideo = data["self_video"]?.boolValue ?? false
        region = data["preferred_region"]?.stringValue
    }
}

/// Joining, moving and leaving voice (Gateway op 4). Event order and payloads
/// follow captures of the official client: VOICE_STATE_UPDATE to the guild or
/// the call's recipients, VOICE_CHANNEL_START_TIME_UPDATE when a channel
/// fills or empties (with VOICE_CHANNEL_STATUS_UPDATE clearing the status on
/// empty), then VOICE_SERVER_UPDATE to the joining session only.
public extension World {
    func voiceStates(in channelID: Snowflake) -> [VoiceState] {
        voice.states.values.filter { $0.channelID == channelID }.sorted { $0.connectedAt == $1.connectedAt ? $0.userID < $1.userID : $0.connectedAt < $1.connectedAt }
    }

    func voiceState(of userID: Snowflake) -> VoiceState? { voice.states[userID] }

    func voiceGrant(token: String) -> VoiceServerGrant? { voice.grants[token] }

    func attachVoiceMedia(_ host: any VoiceMediaHost) { voice.media = host }

    /// Applies op 4 for `sessionID`. Returns the grant to send as VOICE_SERVER_UPDATE when the user joined or moved.
    func updateVoiceState(_ userID: Snowflake, sessionID: String, _ request: VoiceStateRequest, simulated: Bool = false) async throws -> VoiceServerGrant? {
        guard let channelID = request.channelID else {
            if voice.states[userID]?.sessionID == sessionID { await leaveVoice(userID) }
            return nil
        }
        let channel = try channel(channelID)
        try checkCanJoin(userID, channel, guildID: request.guildID)
        let previous = voice.states[userID]
        let changedChannel = previous?.channelID != channelID
        let moved = changedChannel || previous?.sessionID != sessionID
        var carried = previous
        // Leaving a call or another guild is a separate leave; a move within a guild is one update.
        if let previous, changedChannel, previous.guildID == nil || previous.guildID != channel.guildID {
            await leaveVoice(userID)
            carried = nil
        }
        if channel.type.isPrivate, voice.calls[channelID] == nil {
            try await startCall(channelID, by: userID, region: request.region)
        }
        let wasEmpty = voiceStates(in: channelID).allSatisfy { $0.userID == userID }
        let now = Int64(clock.now.timeIntervalSince1970)
        var state = carried ?? VoiceState(userID: userID, guildID: channel.guildID, channelID: channelID, sessionID: sessionID, connectedAt: now)
        if moved {
            state.channelID = channelID
            state.sessionID = sessionID
            state.connectedAt = now
        }
        state.selfMute = request.selfMute
        state.selfDeaf = request.selfDeaf
        state.selfVideo = request.selfVideo
        state.simulated = simulated
        if let guildID = channel.guildID, let member = guilds[guildID]?.members[userID] {
            state.mute = member.mute
            state.deaf = member.deaf
        }
        voice.states[userID] = state
        await emitVoiceState(state)
        if let guildID = channel.guildID, wasEmpty, changedChannel {
            await emitStartTime(guildID: guildID, channelID: channelID, start: .int(now))
        }
        if channel.type.isPrivate, changedChannel { await answeredRing(channelID, by: userID) }
        await voice.media?.participantsChanged(in: channelID)
        if let carried, changedChannel {
            await channelEmptied(carried)
            await voice.media?.participantsChanged(in: carried.channelID)
        }
        guard moved, !simulated else { return nil }
        let grant = VoiceServerGrant(token: String(nextHash().prefix(16)), endpoint: voiceEndpoint(region: request.region),
                                     userID: userID, sessionID: sessionID, guildID: channel.guildID, channelID: channelID)
        voice.grants = voice.grants.filter { $0.value.sessionID != sessionID || $0.value.rtcServerID != nil }
        voice.grants[grant.token] = grant
        return grant
    }

    /// Changes a connected user's own flags (mute, deafen, camera, Go Live) and announces it.
    func updateVoiceFlags(_ userID: Snowflake, _ change: (inout VoiceState) -> Void) async throws {
        guard var state = voice.states[userID] else { throw WorldError.invalidBody("user is not in voice") }
        change(&state)
        voice.states[userID] = state
        await emitVoiceState(state)
        await voice.media?.participantsChanged(in: state.channelID)
    }

    /// Whether a simulated person joins in the channel's conversation (simulator-side only; nothing is dispatched).
    func setChatters(_ userID: Snowflake, _ chatters: Bool) async throws {
        guard let state = voice.states[userID], state.simulated else { throw WorldError.invalidBody("user is not a simulated person in voice") }
        voice.states[userID]?.chatters = chatters
        await voice.media?.participantsChanged(in: state.channelID)
    }

    /// Leaves voice: VOICE_STATE_UPDATE with no channel, then the channel or call's own clean-up.
    func leaveVoice(_ userID: Snowflake) async {
        guard voice.states[userID] != nil else { return }
        await leaveStreams(userID)
        guard let state = voice.states.removeValue(forKey: userID) else { return }
        voice.grants = voice.grants.filter { $0.value.sessionID != state.sessionID }
        await emitVoiceState(state, left: true)
        await leaveActivities(userID, in: state.channelID)
        await channelEmptied(state)
        await voice.media?.disconnect(sessionID: state.sessionID)
        await voice.media?.participantsChanged(in: state.channelID)
    }

    /// A Gateway session ended: its voice connection goes with it.
    func leaveVoice(session sessionID: String) async {
        if let state = voice.states.values.first(where: { $0.sessionID == sessionID }) { await leaveVoice(state.userID) }
    }

    /// `left` renders the state a leave carries: the last one, with no channel.
    func renderVoiceState(_ state: VoiceState, left: Bool = false, includeMember: Bool = true) -> JSON {
        var object = JSONObject([
            ("channel_id", left ? .null : state.channelID.json), ("connected_at", .int(state.connectedAt)),
            ("deaf", .bool(state.deaf)),
        ])
        // Discord marks guild voice states discoverable; private calls have no such flag.
        if state.guildID != nil { object["discoverable"] = true }
        object["guild_id"] = state.guildID?.json ?? .null
        object["mute"] = .bool(state.mute)
        object["request_to_speak_timestamp"] = .null
        object["self_deaf"] = .bool(state.selfDeaf)
        object["self_mute"] = .bool(state.selfMute)
        if state.selfStream { object["self_stream"] = true }
        object["self_video"] = .bool(state.selfVideo)
        object["session_id"] = .string(state.sessionID)
        object["suppress"] = .bool(state.suppress)
        object["user_id"] = state.userID.json
        if includeMember, let guildID = state.guildID, let member = guilds[guildID]?.members[state.userID] {
            object["member"] = renderMember(member, guildID: guildID, includeUser: true)
        }
        return .object(object)
    }

    /// READY_SUPPLEMENTAL's per-guild `voice_states`.
    func renderGuildVoiceStates(_ guildID: Snowflake) -> JSON {
        .array(voice.states.values.filter { $0.guildID == guildID }.sorted { $0.userID < $1.userID }.map { renderVoiceState($0, includeMember: false) })
    }

    /// Seeds someone already sitting in a voice channel, with no events (scenarios).
    func seedVoiceState(_ state: VoiceState) { voice.states[state.userID] = state }

    private func checkCanJoin(_ userID: Snowflake, _ channel: Channel, guildID: Snowflake?) throws {
        if channel.type.isPrivate {
            guard channel.recipients.contains(userID) else { throw WorldError.missingAccess }
            return
        }
        guard channel.type == .voice || channel.type == .stage, channel.guildID == guildID else {
            throw WorldError.invalidBody("channel_id is not a voice channel in guild_id")
        }
        try require(.connect, userID, channel)
        let others = voiceStates(in: channel.id).filter { $0.userID != userID }.count
        if channel.userLimit > 0, others >= channel.userLimit, !permissions(of: userID, in: channel).contains(.moveMembers) {
            throw WorldError(status: 403, code: 50013, message: "Channel is full")
        }
    }

    private func emitVoiceState(_ state: VoiceState, left: Bool = false) async {
        let payload = renderVoiceState(state, left: left)
        if let guildID = state.guildID {
            await emit("VOICE_STATE_UPDATE", payload, to: .guild(guildID, channel: nil))
        } else if let channel = channels[state.channelID] {
            await emit("VOICE_STATE_UPDATE", payload, to: .users(Set(channel.recipients)))
        }
    }

    private func emitStartTime(guildID: Snowflake, channelID: Snowflake, start: JSON) async {
        await emit("VOICE_CHANNEL_START_TIME_UPDATE", .object(JSONObject([
            ("guild_id", guildID.json), ("id", channelID.json), ("voice_start_time", start),
        ])), to: .guild(guildID, channel: channelID))
    }

    /// After someone left `state`'s channel: an emptied guild channel loses its start time and status; an emptied call ends.
    private func channelEmptied(_ state: VoiceState) async {
        guard voiceStates(in: state.channelID).isEmpty else { return }
        guard let guildID = state.guildID else {
            await endCall(state.channelID)
            return
        }
        voice.channelStatus[state.channelID] = nil
        await emitStartTime(guildID: guildID, channelID: state.channelID, start: .null)
        await emit("VOICE_CHANNEL_STATUS_UPDATE", .object(JSONObject([
            ("guild_id", guildID.json), ("id", state.channelID.json), ("status", .null),
        ])), to: .guild(guildID, channel: state.channelID))
    }

    /// A Discord media host name for the region, e.g. `c-rtm06-1a2b3c4d.discord.media:2096`.
    internal func voiceEndpoint(region: String?) -> String {
        let codes = ["rotterdam": "rtm", "frankfurt": "fra", "milan": "mxp", "madrid": "mad", "stockholm": "arn",
                     "brussels": "bru", "paris": "cdg", "london": "lhr", "us-east": "iad", "us-west": "lax"]
        let code = codes[region ?? "rotterdam"] ?? "rtm"
        return "c-\(code)07-\(nextHash().prefix(8)).discord.media:2096"
    }
}
