import Foundation

/// A Go Live stream: one person sharing their screen to viewers in their voice channel or call.
public struct GoLiveStream: Sendable {
    public var key: String
    public var userID: Snowflake
    public var guildID: Snowflake?
    public var channelID: Snowflake
    /// The stream's own media server, the `server_id` its connections identify with.
    public var rtcServerID: Snowflake
    public var region: String
    public var viewers: [Snowflake] = []
    public var paused = false

    /// `guild:{guild}:{channel}:{user}` in a server, `call:{channel}:{user}` in a call.
    public static func key(userID: Snowflake, channelID: Snowflake, guildID: Snowflake?) -> String {
        guildID.map { "guild:\($0):\(channelID):\(userID)" } ?? "call:\(channelID):\(userID)"
    }
}

/// Go Live (Gateway ops 18–22). No capture has these yet (needs a second
/// account streaming), so the stream key format, STREAM_CREATE, STREAM_UPDATE,
/// STREAM_SERVER_UPDATE and STREAM_DELETE follow Discord's known payloads;
/// the streamer's VOICE_STATE_UPDATE gains `self_stream` as captured.
public extension World {
    func stream(_ key: String) -> GoLiveStream? { voice.streams[key] }

    func stream(rtcServerID: Snowflake) -> GoLiveStream? { voice.streams.values.first { $0.rtcServerID == rtcServerID } }

    /// Op 18: start streaming into the voice channel or call the user is in.
    func createStream(_ userID: Snowflake, sessionID: String, channelID: Snowflake, guildID: Snowflake?, region: String?) async throws {
        guard voice.states[userID]?.channelID == channelID, let state = voice.states[userID] else { throw WorldError.invalidBody("not in that voice channel") }
        let channel = try channel(channelID)
        if !channel.type.isPrivate { try require(.stream, userID, channel) }
        let key = GoLiveStream.key(userID: userID, channelID: channelID, guildID: guildID)
        await endStream(key, reason: "stream_ended")
        let stream = GoLiveStream(key: key, userID: userID, guildID: guildID, channelID: channelID, rtcServerID: nextID(),
                                  region: region ?? voice.calls[channelID]?.region ?? "rotterdam")
        voice.streams[key] = stream
        try await updateVoiceFlags(userID) { $0.selfStream = true }
        await emit("STREAM_CREATE", renderStream(stream), to: .users([userID]))
        await grantStream(stream, to: userID, sessionID: sessionID)
        if state.simulated { await voice.media?.participantsChanged(in: stream.rtcServerID) }
    }

    /// Op 20: watch a stream in the channel the viewer is connected to.
    func watchStream(_ key: String, by userID: Snowflake, sessionID: String) async throws {
        guard var stream = voice.streams[key] else { throw WorldError.unknown("Stream", code: 10_049) }
        guard voice.states[userID]?.channelID == stream.channelID else { throw WorldError.missingAccess }
        if !stream.viewers.contains(userID), userID != stream.userID { stream.viewers.append(userID) }
        voice.streams[key] = stream
        await emit("STREAM_CREATE", renderStream(stream), to: .users([userID]))
        await grantStream(stream, to: userID, sessionID: sessionID)
        await emit("STREAM_UPDATE", renderStream(stream), to: .users(Set([stream.userID] + stream.viewers).subtracting([userID])))
    }

    /// Op 19: the streamer ends the stream; a viewer stops watching.
    func deleteStream(_ key: String, by userID: Snowflake) async {
        guard let stream = voice.streams[key] else { return }
        if stream.userID == userID {
            await endStream(key, reason: "user_requested")
        } else if stream.viewers.contains(userID) {
            await stopWatching(key, viewer: userID)
        }
    }

    /// Op 22: pause or resume.
    func setStreamPaused(_ key: String, by userID: Snowflake, paused: Bool) async {
        guard var stream = voice.streams[key], stream.userID == userID else { return }
        stream.paused = paused
        voice.streams[key] = stream
        await emit("STREAM_UPDATE", renderStream(stream), to: .users(Set([stream.userID] + stream.viewers)))
        await voice.media?.participantsChanged(in: stream.rtcServerID)
    }

    /// A simulated person already streaming when the world starts (scenarios; no events).
    func seedStream(_ userID: Snowflake, channelID: Snowflake, guildID: Snowflake?) {
        let key = GoLiveStream.key(userID: userID, channelID: channelID, guildID: guildID)
        voice.streams[key] = GoLiveStream(key: key, userID: userID, guildID: guildID, channelID: channelID, rtcServerID: nextID(), region: "rotterdam")
    }

    /// Who is in a media room: a stream's streamer (sending video unless paused) and viewers, or a voice channel's people.
    func mediaParticipants(in room: Snowflake) -> [VoiceState] {
        guard let stream = stream(rtcServerID: room) else { return voiceStates(in: room) }
        return ([stream.userID] + stream.viewers).compactMap { userID in
            guard var state = voice.states[userID] else { return nil }
            state.channelID = room
            state.selfVideo = userID == stream.userID && !stream.paused
            state.chatters = false
            return state
        }
    }

    /// `GET /streams/{key}/preview`: a thumbnail of the stream.
    func streamPreview(_ key: String, viewer: Snowflake) throws -> JSON {
        guard let stream = voice.streams[key] else { throw WorldError.unknown("Stream", code: 10_049) }
        // The preview tile shows to anyone who can see the channel, not only people connected to it.
        guard let channel = channels[stream.channelID], canView(viewer, channel) else { throw WorldError.missingAccess }
        let path = "/stream-previews/\(stream.rtcServerID).jpg"
        storeLazyMedia(path) { (MediaGenerator.photoJPEG(seed: stream.userID.rawValue, width: 640, height: 360), "image/jpeg") }
        return .object(JSONObject([("url", .string("https://media.discordapp.net\(path)?version=\(Int64(clock.now.timeIntervalSince1970))"))]))
    }

    /// Someone left voice: their stream ends and they stop watching others.
    internal func leaveStreams(_ userID: Snowflake) async {
        // The leave's own VOICE_STATE_UPDATE ends `self_stream`; no separate update.
        for stream in voice.streams.values where stream.userID == userID {
            voice.states[userID]?.selfStream = false
            await endStream(stream.key, reason: "stream_ended")
        }
        for stream in voice.streams.values where stream.viewers.contains(userID) { await stopWatching(stream.key, viewer: userID) }
    }

    private func endStream(_ key: String, reason: String) async {
        guard let stream = voice.streams.removeValue(forKey: key) else { return }
        voice.grants = voice.grants.filter { $0.value.rtcServerID != stream.rtcServerID }
        await emit("STREAM_DELETE", renderStreamDelete(stream, reason: reason), to: .users(Set([stream.userID] + stream.viewers)))
        if voice.states[stream.userID]?.selfStream == true { try? await updateVoiceFlags(stream.userID) { $0.selfStream = false } }
        await voice.media?.participantsChanged(in: stream.rtcServerID)
    }

    private func stopWatching(_ key: String, viewer: Snowflake) async {
        guard var stream = voice.streams[key] else { return }
        stream.viewers.removeAll { $0 == viewer }
        voice.streams[key] = stream
        voice.grants = voice.grants.filter { !($0.value.rtcServerID == stream.rtcServerID && $0.value.userID == viewer) }
        await emit("STREAM_DELETE", renderStreamDelete(stream, reason: "user_requested"), to: .users([viewer]))
        await emit("STREAM_UPDATE", renderStream(stream), to: .users(Set([stream.userID] + stream.viewers)))
        await voice.media?.participantsChanged(in: stream.rtcServerID)
    }

    private func grantStream(_ stream: GoLiveStream, to userID: Snowflake, sessionID: String) async {
        let grant = VoiceServerGrant(token: String(nextHash().prefix(16)), endpoint: voiceEndpoint(region: stream.region), userID: userID,
                                     sessionID: sessionID, guildID: stream.guildID, channelID: stream.channelID, rtcServerID: stream.rtcServerID)
        voice.grants = voice.grants.filter { !($0.value.rtcServerID == stream.rtcServerID && $0.value.userID == userID) }
        voice.grants[grant.token] = grant
        await emit("STREAM_SERVER_UPDATE", .object(JSONObject([
            ("stream_key", .string(stream.key)), ("endpoint", .string(grant.endpoint)), ("token", .string(grant.token)), ("guild_id", .null),
        ])), to: .users([userID]))
    }

    private func renderStream(_ stream: GoLiveStream) -> JSON {
        .object(JSONObject([
            ("stream_key", .string(stream.key)), ("rtc_server_id", stream.rtcServerID.json), ("viewer_ids", .array(stream.viewers.map(\.json))),
            ("region", .string(stream.region)), ("paused", .bool(stream.paused)),
        ]))
    }

    private func renderStreamDelete(_ stream: GoLiveStream, reason: String) -> JSON {
        .object(JSONObject([("stream_key", .string(stream.key)), ("unavailable", false), ("reason", .string(reason))]))
    }
}
