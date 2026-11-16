import Foundation

/// Voice on the main Gateway: op 4 joins, moves and leaves voice; op 13 asks
/// for an ongoing private call when a DM opens; ops 18–22 run Go Live streams.
extension GatewayHub {
    func updateVoiceState(_ session: Session, _ data: JSON) async {
        do {
            guard let grant = try await world.updateVoiceState(session.userID, sessionID: session.id, VoiceStateRequest(data)) else { return }
            // Calls name their channel; guild grants carry only the guild.
            var payload = JSONObject([("endpoint", .string(grant.endpoint)), ("guild_id", grant.guildID?.json ?? .null), ("token", .string(grant.token))])
            if grant.guildID == nil { payload["channel_id"] = grant.channelID.json }
            await dispatch("VOICE_SERVER_UPDATE", .object(payload), to: session)
        } catch {
            // Discord ignores a voice state update it refuses; the client times out its join.
            log.warning("gateway", "op 4 refused: \(error)")
        }
    }

    func connectPrivateCall(_ session: Session, _ data: JSON) async {
        guard let channelID = data["channel_id"]?.stringValue.flatMap(Snowflake.init),
              let channel = await world.channels[channelID], channel.recipients.contains(session.userID),
              let call = await world.call(in: channelID) else { return }
        await dispatch("CALL_CREATE", await world.renderCallCreate(call), to: session)
    }

    /// Op 18 create, 19 delete, 20 watch, 21 ping (keep-alive, no reply), 22 pause.
    func applicationStream(_ op: Int64, _ session: Session, _ data: JSON) async {
        let key = data["stream_key"]?.stringValue ?? ""
        do {
            switch op {
            case 18:
                guard let channelID = data["channel_id"]?.stringValue.flatMap(Snowflake.init) else { return }
                try await world.createStream(session.userID, sessionID: session.id, channelID: channelID,
                                             guildID: data["guild_id"]?.stringValue.flatMap(Snowflake.init), region: data["preferred_region"]?.stringValue)
            case 19: await world.deleteStream(key, by: session.userID)
            case 20: try await world.watchStream(key, by: session.userID, sessionID: session.id)
            case 22: await world.setStreamPaused(key, by: session.userID, paused: data["paused"]?.boolValue ?? false)
            default: break
            }
        } catch {
            log.warning("gateway", "stream op \(op) refused: \(error)")
        }
    }
}
