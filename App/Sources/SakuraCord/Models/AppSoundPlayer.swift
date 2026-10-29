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
    /// Starts a one-shot preview, or stops it if it is already playing. Only one
    /// preview plays at a time. Returns the preview's duration when it started, nil otherwise.
    func togglePreview(_ effect: AppSoundEffect) -> TimeInterval?
    func stopPreview()
}

extension AppSoundPlaying {
    func togglePreview(_ effect: AppSoundEffect) -> TimeInterval? { nil }
    func stopPreview() {}
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
        /// A player keeps reading its file with the format it opened, so a
        /// file replaced in place needs a new player. Stamped from the chosen
        /// file even when the player fell back, so a repaired file is picked up.
        var sourceURL: URL
        var sourceStamp: NotificationSoundLibrary.FileStamp?
        /// A temporary copy holding the first `playbackLimitSeconds` of a longer file.
        var trimmedURL: URL?
        /// The bookmark could not be resolved, for example while its volume
        /// is unmounted, so the slot plays Default until it resolves again.
        var awaitsBookmark: Bool
    }

    private var players: [AppSoundEffect: AVAudioPlayer] = [:]
    private var notificationSlots: [AppSoundEffect: NotificationSlot] = [:]
    private var previewEffect: AppSoundEffect?
    private var bannerExport: Task<Void, Never>?
    private let notificationPreferences: NotificationPreferences

    init(notificationPreferences: NotificationPreferences) {
        self.notificationPreferences = notificationPreferences
        syncBannerSounds()
    }

    func play(_ effect: AppSoundEffect) {
        guard let player = player(for: effect) else { return }
        player.numberOfLoops = 0
        player.currentTime = 0
        player.play()
    }

    func togglePreview(_ effect: AppSoundEffect) -> TimeInterval? {
        let wasPreviewingThis = previewEffect == effect && existingPlayer(for: effect)?.isPlaying == true
        stopPreview()
        // Never take over a ringtone that is ringing for a real call.
        if let active = existingPlayer(for: effect), active.numberOfLoops == -1 { return nil }
        guard !wasPreviewingThis, let player = player(for: effect) else { return nil }
        player.numberOfLoops = 0
        player.currentTime = 0
        player.play()
        previewEffect = effect
        return player.duration
    }

    func stopPreview() {
        defer { previewEffect = nil }
        guard let effect = previewEffect, let player = existingPlayer(for: effect),
              player.numberOfLoops != -1
        else { return }
        player.stop()
        player.currentTime = 0
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

    /// Rebuilds the player only when the stored choice or its file changes.
    private func notificationPlayer(for effect: AppSoundEffect, kind: NotificationSoundKind) -> AVAudioPlayer? {
        var choice = notificationPreferences.soundChoice(for: kind)
        if let slot = notificationSlots[effect], slot.choice == choice,
           slot.sourceStamp == NotificationSoundLibrary.FileStamp(slot.sourceURL),
           !(slot.awaitsBookmark && NotificationSoundLibrary.resolve(choice, kind: kind).isSecurityScoped)
        {
            return slot.player
        }
        releaseNotificationSlot(effect)

        let resolution = NotificationSoundLibrary.resolve(choice, kind: kind)
        var scopedURL: URL?
        if resolution.isSecurityScoped, resolution.url.startAccessingSecurityScopedResource() {
            scopedURL = resolution.url
        }
        var player = NotificationSoundLibrary.makePlayer(at: resolution.url)
        if player == nil {
            player = NotificationSoundLibrary.makePlayer(at: NotificationSoundLibrary.defaultURL(kind: kind))
        } else if resolution.isStaleBookmark, scopedURL != nil,
                  let refreshed = try? resolution.url.bookmarkData(
                      options: .withSecurityScope,
                      includingResourceValuesForKeys: nil,
                      relativeTo: nil
                  )
        {
            choice.bookmark = refreshed
            notificationPreferences.setCustomSound(
                bookmark: refreshed,
                name: notificationPreferences.soundName(for: kind),
                for: kind
            )
        }
        var trimmedURL: URL?
        if let long = player, long.duration > kind.playbackLimitSeconds {
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
            if (try? NotificationSoundLibrary.convertToLinearPCM(
                from: resolution.url,
                to: url,
                limitSeconds: kind.playbackLimitSeconds
            )) != nil,
               let trimmed = NotificationSoundLibrary.makePlayer(at: url)
            {
                player = trimmed
                trimmedURL = url
            } else {
                // Never play past the limit.
                try? FileManager.default.removeItem(at: url)
                player = NotificationSoundLibrary.makePlayer(at: NotificationSoundLibrary.defaultURL(kind: kind))
            }
        }
        guard let player else {
            scopedURL?.stopAccessingSecurityScopedResource()
            return nil
        }
        notificationSlots[effect] = NotificationSlot(
            choice: choice,
            player: player,
            scopedURL: scopedURL,
            sourceURL: resolution.url,
            sourceStamp: NotificationSoundLibrary.FileStamp(resolution.url),
            trimmedURL: trimmedURL,
            awaitsBookmark: choice.soundID == NotificationSoundLibrary.customID && !resolution.isSecurityScoped
        )
        return player
    }

    /// Follows every change to the stored choices, including Reset and
    /// Import, which only change the preferences: exports the message sound
    /// before the first banner needs it, removes the copy when it returns to
    /// Default, and switches a ringing call to the new ringtone.
    private func syncBannerSounds() {
        withObservationTracking {
            for kind in NotificationSoundKind.allCases { _ = notificationPreferences.soundChoice(for: kind) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncBannerSounds() }
        }
        let choice = notificationPreferences.soundChoice(for: .message)
        let previous = bannerExport
        // Waiting keeps a superseded export from finishing after the newer one.
        bannerExport = Task(priority: .utility) {
            await previous?.value
            _ = await BannerSoundStore.shared.soundName(for: choice)
        }
        if existingPlayer(for: .callRinging)?.numberOfLoops == -1 { setLooping(.callRinging, active: true) }
    }

    private func releaseNotificationSlot(_ effect: AppSoundEffect) {
        guard let slot = notificationSlots.removeValue(forKey: effect) else { return }
        slot.player.stop()
        slot.scopedURL?.stopAccessingSecurityScopedResource()
        if let trimmedURL = slot.trimmedURL { try? FileManager.default.removeItem(at: trimmedURL) }
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
