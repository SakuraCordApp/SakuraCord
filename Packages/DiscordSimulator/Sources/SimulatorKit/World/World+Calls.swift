import Foundation

/// A private call in a DM or group DM.
public struct Call: Sendable {
    public var channelID: Snowflake
    public var messageID: Snowflake
    public var region: String
    public var ringing: [Snowflake] = []
    /// Who rang each ringing recipient.
    public var ongoingRings: [Snowflake: Snowflake] = [:]
    /// Everyone who joined, for the call message.
    public var participants: [Snowflake] = []
}

/// Private calls. The first join starts one: the call message, CALL_CREATE,
/// then the joiner's VOICE_STATE_UPDATE; ringing is CALL_UPDATE, rings time out
/// after 30 seconds, and the last leave ends the call: the call message's end,
/// then CALL_DELETE. Order and payloads follow captures of the official client
/// placing a call; the callee's side can't be captured without a second
/// person, so it receives the same events.
public extension World {
    func call(in channelID: Snowflake) -> Call? { voice.calls[channelID] }

    /// `caller` (a simulated person) joins `channelID` and rings everyone else.
    func placeCall(_ channelID: Snowflake, from caller: Snowflake) async throws {
        _ = try await updateVoiceState(caller, sessionID: nextHash(), VoiceStateRequest(guildID: nil, channelID: channelID), simulated: true)
        try await ring(channelID, by: caller, recipients: nil)
    }

    /// `POST /channels/{id}/call/ring`: rings `recipients` (nil: everyone not in the call).
    func ring(_ channelID: Snowflake, by userID: Snowflake, recipients: [Snowflake]?) async throws {
        let channel = try privateCallChannel(channelID, member: userID)
        guard var call = voice.calls[channelID] else { return }
        let targets = (recipients ?? channel.recipients).filter { recipient in
            recipient != userID && channel.recipients.contains(recipient) && voice.states[recipient]?.channelID != channelID
        }
        guard !targets.isEmpty else { return }
        for target in targets where !call.ringing.contains(target) { call.ringing.append(target) }
        for target in targets { call.ongoingRings[target] = userID }
        voice.calls[channelID] = call
        await emitCallUpdate(call)
        let messageID = call.messageID
        Task {
            try? await Task.sleep(for: .seconds(30))
            await self.stopRinging(channelID, recipients: targets, ifCall: messageID)
        }
    }

    /// `POST /channels/{id}/call/stop-ringing`: declining (your own ID) or cancelling a ring.
    func stopRinging(_ channelID: Snowflake, by userID: Snowflake, recipients: [Snowflake]) async throws {
        _ = try privateCallChannel(channelID, member: userID)
        await stopRinging(channelID, recipients: recipients, ifCall: nil)
    }

    /// `GET /channels/{id}/call`: whether the viewer can ring this channel.
    func callEligibility(_ channelID: Snowflake, for userID: Snowflake) throws -> JSON {
        let channel = try privateCallChannel(channelID, member: userID)
        let blocked = channel.recipients.contains { relationships[$0]?[userID]?.type == .blocked || relationships[userID]?[$0]?.type == .blocked }
        return .object(JSONObject([("ringable", .bool(!blocked))]))
    }

    /// CALL_CREATE for an ongoing call, as op 13 (opening the DM) returns it.
    func renderCallCreate(_ call: Call) -> JSON {
        .object(JSONObject([
            ("channel_id", call.channelID.json), ("embedded_activities", []), ("message_id", call.messageID.json),
            ("ongoing_rings", renderOngoingRings(call)), ("region", .string(call.region)),
            ("ringing", .array(call.ringing.map(\.json))),
            ("voice_states", .array(voiceStates(in: call.channelID).map { renderVoiceState($0, includeMember: false) })),
        ]))
    }

    internal func startCall(_ channelID: Snowflake, by userID: Snowflake, region: String?) async throws {
        var notice = MessageDraft()
        notice.type = 3
        notice.call = .object(JSONObject([("participants", .array([userID.json])), ("ended_timestamp", .null)]))
        let message = try await sendSystemMessage(notice, as: userID, in: channelID)
        let call = Call(channelID: channelID, messageID: message.id, region: region ?? "rotterdam", participants: [userID])
        voice.calls[channelID] = call
        await emit("CALL_CREATE", renderCallCreate(call), to: .users(Set(try channel(channelID).recipients)))
    }

    /// Someone joined the call: they stop ringing and count as a participant.
    internal func answeredRing(_ channelID: Snowflake, by userID: Snowflake) async {
        guard var call = voice.calls[channelID] else { return }
        if !call.participants.contains(userID) { call.participants.append(userID) }
        let wasRinging = call.ringing.contains(userID)
        call.ringing.removeAll { $0 == userID }
        call.ongoingRings[userID] = nil
        voice.calls[channelID] = call
        if wasRinging { await emitCallUpdate(call) }
    }

    /// The last participant left: the call message gets its end, then CALL_DELETE (the captured order).
    internal func endCall(_ channelID: Snowflake) async {
        guard let call = voice.calls.removeValue(forKey: channelID), let channel = channels[channelID] else { return }
        let ended = JSON.object(JSONObject([("participants", .array(call.participants.map(\.json))), ("ended_timestamp", World.timestamp(clock.now))]))
        if let updated = try? updateMessage(call.messageID, in: channelID, { $0.call = ended }) {
            await emit("MESSAGE_UPDATE", renderMessageEvent(updated), to: .users(Set(channel.recipients)))
        }
        await emit("CALL_DELETE", .object(JSONObject([("channel_id", channelID.json)])), to: .users(Set(channel.recipients)))
    }

    private func stopRinging(_ channelID: Snowflake, recipients: [Snowflake], ifCall messageID: Snowflake?) async {
        guard var call = voice.calls[channelID], messageID == nil || call.messageID == messageID,
              call.ringing.contains(where: recipients.contains) else { return }
        call.ringing.removeAll(where: recipients.contains)
        for recipient in recipients { call.ongoingRings[recipient] = nil }
        voice.calls[channelID] = call
        await emitCallUpdate(call)
    }

    private func privateCallChannel(_ channelID: Snowflake, member userID: Snowflake) throws -> Channel {
        let channel = try channel(channelID)
        guard channel.type.isPrivate else { throw WorldError.wrongChannelType }
        guard channel.recipients.contains(userID) else { throw WorldError.missingAccess }
        return channel
    }

    private func emitCallUpdate(_ call: Call) async {
        guard let channel = channels[call.channelID] else { return }
        await emit("CALL_UPDATE", .object(JSONObject([
            ("channel_id", call.channelID.json), ("guild_id", .null), ("message_id", call.messageID.json),
            ("ongoing_rings", renderOngoingRings(call)), ("region", .string(call.region)), ("ringing", .array(call.ringing.map(\.json))),
        ])), to: .users(Set(channel.recipients)))
    }

    private func renderOngoingRings(_ call: Call) -> JSON {
        .object(JSONObject(call.ongoingRings.sorted { $0.key < $1.key }.map { ($0.key.description, $0.value.json) }))
    }
}
