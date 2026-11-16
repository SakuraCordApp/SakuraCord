import Foundation

/// Chatty simulated people take turns talking while someone real listens, so
/// a voice channel sounds lived-in: a few seconds each, with short pauses.
extension VoiceGateway {
    func updateConversation(in channelID: Snowflake, present: [VoiceState]) {
        let chatty = present.contains { $0.simulated && $0.chatters && !$0.selfMute }
        guard chatty, hasListeners(in: channelID) else {
            conversations.removeValue(forKey: channelID)?.cancel()
            return
        }
        guard conversations[channelID] == nil else { return }
        conversations[channelID] = Task { [weak self] in
            var random = SeededRandom(seed: channelID.rawValue).fork("conversation")
            var previous: Snowflake?
            while !Task.isCancelled, let self {
                let speakers = await self.world.mediaParticipants(in: channelID).filter { $0.simulated && $0.chatters && !$0.selfMute }.map(\.userID)
                guard !speakers.isEmpty else { return }
                let choices = speakers.count > 1 ? speakers.filter { $0 != previous } : speakers
                let speaker = choices[Int(random.next() % UInt64(choices.count))]
                previous = speaker
                try? await self.setSpeaking(speaker, true)
                try? await Task.sleep(for: .milliseconds(1_500 + Int(random.next() % 4_500)))
                try? await self.setSpeaking(speaker, false)
                try? await Task.sleep(for: .milliseconds(400 + Int(random.next() % 1_600)))
            }
        }
    }
}
