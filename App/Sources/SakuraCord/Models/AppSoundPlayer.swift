import AVFAudio
import Foundation
import SakuraCordModels

nonisolated enum AppSoundEffect: String, CaseIterable, Sendable {
    case callCalling = "call_calling"
    case callRinging = "call_ringing"
    case cameraOff = "camera_off"
    case cameraOn = "camera_on"
    case deafen
    case disconnect
    case message = "message1"
    case mute
    case streamEnded = "stream_ended"
    case streamStarted = "stream_started"
    case streamUserJoined = "stream_user_joined"
    case streamUserLeft = "stream_user_left"
    case undeafen
    case unmute
    case userJoin = "user_join"
    case userLeave = "user_leave"

    var resourceURL: URL? {
        Bundle.module.url(
            forResource: rawValue,
            withExtension: "mp3",
            subdirectory: "Sounds"
        )
            ?? Bundle.module.url(
                forResource: rawValue,
                withExtension: "mp3"
            )
    }
}

@MainActor
protocol AppSoundPlaying: Sendable {
    func play(_ effect: AppSoundEffect)
    func setLooping(_ effect: AppSoundEffect, active: Bool)
    func stopAll()
}

@MainActor
final class NoopAppSoundPlayer: AppSoundPlaying {
    func play(_ effect: AppSoundEffect) {}
    func setLooping(_ effect: AppSoundEffect, active: Bool) {}
    func stopAll() {}
}

@MainActor
final class MacAppSoundPlayer: AppSoundPlaying {
    private var players: [AppSoundEffect: AVAudioPlayer] = [:]

    func play(_ effect: AppSoundEffect) {
        guard let player = player(for: effect) else { return }
        player.numberOfLoops = 0
        player.currentTime = 0
        player.play()
    }

    func setLooping(_ effect: AppSoundEffect, active: Bool) {
        if active {
            guard let player = player(for: effect) else { return }
            guard !player.isPlaying || player.numberOfLoops != -1 else { return }
            player.numberOfLoops = -1
            player.currentTime = 0
            player.play()
        } else if let player = players[effect], player.numberOfLoops == -1 {
            player.stop()
            player.currentTime = 0
            player.numberOfLoops = 0
        }
    }

    func stopAll() {
        for player in players.values {
            player.stop()
            player.currentTime = 0
            player.numberOfLoops = 0
        }
    }

    private func player(for effect: AppSoundEffect) -> AVAudioPlayer? {
        if let player = players[effect] { return player }
        guard let url = effect.resourceURL,
            let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        player.prepareToPlay()
        players[effect] = player
        return player
    }
}

nonisolated enum VoiceStateSoundPolicy {
    static func effects(
        previous: VoiceParticipantState?,
        current: VoiceParticipantState,
        activeChannelID: ChannelID?,
        currentUserID: UserID?
    ) -> [AppSoundEffect] {
        guard let activeChannelID,
              current.userID != currentUserID
        else { return [] }

        let wasPresent = previous?.channelID == activeChannelID
        let isPresent = current.channelID == activeChannelID
        let wasStreaming = wasPresent && previous?.isStreaming == true
        let isStreaming = isPresent && current.isStreaming
        if wasStreaming != isStreaming {
            return [isStreaming ? .streamStarted : .streamEnded]
        }
        if !wasPresent, isPresent {
            return [.userJoin]
        }
        if wasPresent, !isPresent {
            return [.userLeave]
        }
        guard wasPresent, isPresent, let previous else { return [] }

        var effects: [AppSoundEffect] = []
        let wasDeafened = previous.isDeafened || previous.isSelfDeafened
        let isDeafened = current.isDeafened || current.isSelfDeafened
        if wasDeafened != isDeafened {
            effects.append(isDeafened ? .deafen : .undeafen)
        } else {
            let wasMuted = previous.isMuted || previous.isSelfMuted
            let isMuted = current.isMuted || current.isSelfMuted
            if wasMuted != isMuted {
                effects.append(isMuted ? .mute : .unmute)
            }
        }
        if previous.isVideoEnabled != current.isVideoEnabled {
            effects.append(current.isVideoEnabled ? .cameraOn : .cameraOff)
        }
        return effects
    }
}

nonisolated struct PrivateCallSoundState: Equatable, Sendable {
    var ringsIncoming = false
    var ringsOutgoing = false

    static func make(
        calls: some Sequence<PrivateCall>,
        currentUserID: UserID?,
        activeChannelID: ChannelID?,
        locallyStartedOutgoingChannelIDs: Set<ChannelID>
    ) -> Self {
        guard let currentUserID else { return Self() }
        var state = Self()
        for call in calls where !call.isUnavailable {
            if call.channelID != activeChannelID,
               call.ongoingRings.contains(where: { $0.recipientID == currentUserID })
            {
                state.ringsIncoming = true
            }
            if call.channelID == activeChannelID,
               call.ongoingRings.contains(where: {
                   $0.senderID == currentUserID && $0.recipientID != currentUserID
               })
            {
                state.ringsOutgoing = true
            }
        }
        if let activeChannelID,
           locallyStartedOutgoingChannelIDs.contains(activeChannelID)
        {
            state.ringsOutgoing = true
        }
        return state
    }
}
