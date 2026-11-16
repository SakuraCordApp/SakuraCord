import Foundation

/// Incoming private calls: the ring and the call message, without voice
/// (voice and video are out of the simulator's scope). The official client
/// can't be captured receiving a call without a second person calling, so
/// CALL_CREATE follows Discord's documented payload.
public extension World {
    /// `caller` rings everyone else in the DM or group DM `channelID`.
    func ring(_ channelID: Snowflake, from caller: Snowflake) async throws {
        let channel = try channel(channelID)
        guard channel.type.isPrivate, channel.recipients.contains(caller) else {
            throw WorldError.invalidBody("calls ring from a member of a DM or group DM")
        }
        var notice = MessageDraft()
        notice.type = 3
        let message = try await sendSystemMessage(notice, as: caller, in: channelID)
        let ringing = channel.recipients.filter { $0 != caller }
        await emit("CALL_CREATE", .object(JSONObject([
            ("channel_id", channelID.json), ("message_id", message.id.json), ("region", "rotterdam"),
            ("ringing", .array(ringing.map(\.json))),
            ("voice_states", .array([.object(JSONObject([
                ("user_id", caller.json), ("channel_id", channelID.json), ("session_id", .string(nextHash())),
                ("self_mute", false), ("self_deaf", false), ("self_video", false), ("mute", false), ("deaf", false),
                ("suppress", false), ("request_to_speak_timestamp", .null),
            ]))])),
            ("embedded_activities", []),
        ])), to: .users(Set(channel.recipients)))
    }
}
