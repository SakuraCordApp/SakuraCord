import Foundation

/// People already sitting in the demo's voice channels when the app connects.
extension DemoConverter {
    func seatVoiceStates(_ seats: [DemoVoiceState], channelID: Snowflake, guildID: Snowflake) async {
        for (index, seat) in seats.enumerated() {
            guard let userID = people[seat.person] else { continue }
            var state = VoiceState(userID: userID, guildID: guildID, channelID: channelID, sessionID: await world.nextHash(),
                                   connectedAt: Int64(world.epoch.timeIntervalSince1970) - 2_400 + Int64(index) * 300)
            state.selfMute = seat.muted
            state.selfDeaf = seat.deafened
            state.selfVideo = seat.camera
            state.selfStream = seat.streaming
            state.simulated = true
            await world.seedVoiceState(state)
        }
    }
}
