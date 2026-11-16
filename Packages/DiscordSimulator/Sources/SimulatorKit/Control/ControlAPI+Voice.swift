import Foundation

/// Agent controls for simulated people in voice: join, leave, mute, camera, speaking, Go Live and soundboard sounds.
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
            if body["chatter"]?.boolValue == true { try await world.setChatters(userID, true) }
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
        case ("POST", "stream"):
            guard let state = await world.voiceState(of: userID) else { throw WorldError.invalidBody("user is not in voice") }
            try await world.createStream(userID, sessionID: state.sessionID, channelID: state.channelID, guildID: state.guildID, region: nil)
        case ("DELETE", "stream"):
            let key = await world.voiceState(of: userID).map { GoLiveStream.key(userID: userID, channelID: $0.channelID, guildID: $0.guildID) }
            await world.deleteStream(key ?? "", by: userID)
        case ("POST", "soundboard"):
            guard let channelID = await world.voiceState(of: userID)?.channelID else { throw WorldError.invalidBody("user is not in voice") }
            try await world.playSoundboardSound(body["sound_id"]?.stringValue ?? "1", in: channelID, by: userID)
        default:
            return nil
        }
        let state = await world.voiceState(of: userID)
        return .json(200, .object(JSONObject([("ok", true), ("channel_id", state?.channelID.json ?? .null)])))
    }
}
