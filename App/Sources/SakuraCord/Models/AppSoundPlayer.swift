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
    /// Starts a one-shot preview, or stops it if it is already playing.
    /// Returns the preview's duration when it started, nil otherwise.
    func togglePreview(_ effect: AppSoundEffect) -> TimeInterval?
    func connectNotificationSounds(to preferences: NotificationPreferences)
}

extension AppSoundPlaying {
    func togglePreview(_ effect: AppSoundEffect) -> TimeInterval? { nil }
    func connectNotificationSounds(to preferences: NotificationPreferences) {}
}

@MainActor
final class NoopAppSoundPlayer: AppSoundPlaying {
    func play(_ effect: AppSoundEffect) {}
    func setLooping(_ effect: AppSoundEffect, active: Bool) {}
    func stopAll() {}
}

@MainActor
final class MacAppSoundPlayer: AppSoundPlaying {
    /// A player for a user-chosen notification sound. Holds security-scoped
    /// access to a custom file for as long as the player exists.
    private struct NotificationSlot {
        var choice: NotificationSoundLibrary.Choice
        var player: AVAudioPlayer
        var scopedURL: URL?
    }

    private var players: [AppSoundEffect: AVAudioPlayer] = [:]
    private var notificationSlots: [AppSoundEffect: NotificationSlot] = [:]
    private weak var notificationPreferences: NotificationPreferences?

    func connectNotificationSounds(to preferences: NotificationPreferences) {
        notificationPreferences = preferences
    }

    func play(_ effect: AppSoundEffect) {
        guard let player = player(for: effect) else { return }
        player.numberOfLoops = 0
        player.currentTime = 0
        player.play()
    }

    func togglePreview(_ effect: AppSoundEffect) -> TimeInterval? {
        // Never take over a ringtone that is ringing for a real call.
        if let active = existingPlayer(for: effect), active.numberOfLoops == -1 {
            return nil
        }
        guard let player = player(for: effect) else { return nil }
        if player.isPlaying {
            player.stop()
            player.currentTime = 0
            return nil
        }
        player.numberOfLoops = 0
        player.currentTime = 0
        player.play()
        return player.duration
    }

    func setLooping(_ effect: AppSoundEffect, active: Bool) {
        if active {
            guard let player = player(for: effect) else { return }
            guard !player.isPlaying || player.numberOfLoops != -1 else { return }
            player.numberOfLoops = -1
            player.currentTime = 0
            player.play()
        } else if let player = existingPlayer(for: effect), player.numberOfLoops == -1 {
            player.stop()
            player.currentTime = 0
            player.numberOfLoops = 0
        }
    }

    func stopAll() {
        for player in players.values + notificationSlots.values.map(\.player) {
            player.stop()
            player.currentTime = 0
            player.numberOfLoops = 0
        }
    }

    private func existingPlayer(for effect: AppSoundEffect) -> AVAudioPlayer? {
        notificationSlots[effect]?.player ?? players[effect]
    }

    private func player(for effect: AppSoundEffect) -> AVAudioPlayer? {
        switch effect {
        case .message:
            return notificationPlayer(for: effect, kind: .message)
        case .callRinging:
            return notificationPlayer(for: effect, kind: .call)
        default:
            break
        }
        if let player = players[effect] { return player }
        guard let url = effect.resourceURL,
            let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        player.prepareToPlay()
        players[effect] = player
        return player
    }

    private func choice(for kind: NotificationSoundKind) -> NotificationSoundLibrary.Choice {
        guard let preferences = notificationPreferences else {
            return .init(soundID: NotificationSoundLibrary.bundledID, bookmark: nil)
        }
        switch kind {
        case .message:
            return .init(soundID: preferences.messageSoundID, bookmark: preferences.messageSoundBookmark)
        case .call:
            return .init(soundID: preferences.callRingtoneID, bookmark: preferences.callRingtoneBookmark)
        }
    }

    /// Rebuilds the player only when the stored choice changes.
    private func notificationPlayer(for effect: AppSoundEffect, kind: NotificationSoundKind) -> AVAudioPlayer? {
        var choice = choice(for: kind)
        if let slot = notificationSlots[effect], slot.choice == choice { return slot.player }
        releaseNotificationSlot(effect)

        let resolution = NotificationSoundLibrary.resolve(choice, kind: kind)
        var scopedURL: URL?
        if resolution.isSecurityScoped, resolution.url.startAccessingSecurityScopedResource() {
            scopedURL = resolution.url
        }
        var player = try? AVAudioPlayer(contentsOf: resolution.url)
        if player == nil {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            player = try? AVAudioPlayer(contentsOf: NotificationSoundLibrary.defaultURL(kind: kind))
        } else if resolution.isStaleBookmark, scopedURL != nil,
                  let refreshed = try? resolution.url.bookmarkData(
                      options: .withSecurityScope,
                      includingResourceValuesForKeys: nil,
                      relativeTo: nil
                  )
        {
            choice.bookmark = refreshed
            switch kind {
            case .message: notificationPreferences?.messageSoundBookmark = refreshed
            case .call: notificationPreferences?.callRingtoneBookmark = refreshed
            }
        }
        guard let player else {
            scopedURL?.stopAccessingSecurityScopedResource()
            return nil
        }
        player.prepareToPlay()
        notificationSlots[effect] = NotificationSlot(choice: choice, player: player, scopedURL: scopedURL)
        return player
    }

    private func releaseNotificationSlot(_ effect: AppSoundEffect) {
        guard let slot = notificationSlots.removeValue(forKey: effect) else { return }
        slot.player.stop()
        slot.scopedURL?.stopAccessingSecurityScopedResource()
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
