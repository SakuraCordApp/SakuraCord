import Foundation

/// Agent controls for simulated people in voice: join, leave, mute, camera and speaking.
extension ControlAPI {
    func voiceRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        guard route.first == "voice" else { return nil }
        let userID = try await resolveUser(body["user"])
        switch (request.method, route.count > 1 ? route[1] : "") {
        case ("POST", ""):
            let channelID = try await resolveChannel(body)
            var join = VoiceStateRequest(guildID: try await world.channel(channelID).guildID, channelID: channelID)
            join.selfMute = body["self_mute"]?.boolValue ?? false
            join.selfDeaf = body["self_deaf"]?.boolValue ?? false
            join.selfVideo = body["self_video"]?.boolValue ?? false
            _ = try await world.updateVoiceState(userID, sessionID: await world.nextHash(), join, simulated: true)
        case ("DELETE", ""):
            await world.leaveVoice(userID)
        case ("PATCH", ""):
            try await world.updateVoiceFlags(userID) { state in
                if let value = body["self_mute"]?.boolValue { state.selfMute = value }
                if let value = body["self_deaf"]?.boolValue { state.selfDeaf = value }
                if let value = body["self_video"]?.boolValue { state.selfVideo = value }
            }
        case ("POST", "speaking"):
            try await simulator.voice.setSpeaking(userID, body["speaking"]?.boolValue ?? true)
        default:
            return nil
        }
        let state = await world.voiceState(of: userID)
        return .json(200, .object(JSONObject([("ok", true), ("channel_id", state?.channelID.json ?? .null)])))
    }
}
