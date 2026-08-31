import DiscordProtocol
import Foundation
import MediaPipeline
import OSLog
import SakuraCordModels

nonisolated enum SoundboardPlaybackRoute: Equatable, Sendable {
    case native
    case outgoingMixer
}

struct SoundboardPresentationState {
    var defaults: [SoundboardSound] = []
    var soundsByGuild: [GuildID: [SoundboardSound]] = [:]
    var userSettings = SoundboardUserSettings()
    var isLoading = false
    var errorMessage: String?
    var pendingNativeEchoes: [PendingNativeSoundboardEcho] = []
}

struct PendingNativeSoundboardEcho: Equatable {
    let id: UUID
    let channelID: ChannelID
    let soundID: String
    let expiresAt: Date
}

nonisolated enum SoundboardEffectPlaybackPolicy {
    static func sound(
        withID soundID: String,
        in catalog: [SoundboardSound]
    ) -> SoundboardSound {
        catalog.first(where: { $0.id == soundID })
            ?? SoundboardSound(id: soundID, name: "Soundboard sound")
    }

    static func volume(for effect: VoiceChannelEffect) -> Double {
        min(max(effect.soundVolume, 0), 2)
    }
}

nonisolated enum SoundboardPlaybackPolicy {
    static func route(
        for sound: SoundboardSound,
        activeGuildID: GuildID?,
        premiumType: Int,
        effectivePermissions: UInt64?,
        voiceState: VoiceParticipantState?
    ) -> SoundboardPlaybackRoute? {
        guard sound.isAvailable,
              let effectivePermissions,
              effectivePermissions & DiscordPermissionBits.speak != 0,
              effectivePermissions & DiscordPermissionBits.useSoundboard != 0,
              voiceState?.isMuted != true,
              voiceState?.isDeafened != true,
              voiceState?.isSelfDeafened != true,
              voiceState?.isSuppressed != true
        else { return nil }

        guard let sourceGuildID = sound.guildID,
              sourceGuildID != activeGuildID
        else { return .native }
        guard effectivePermissions & DiscordPermissionBits.useExternalSounds != 0 else {
            return nil
        }
        return premiumType == 2 ? .native : .outgoingMixer
    }
}

actor SoundboardAudioLibrary {
    static let shared = SoundboardAudioLibrary()

    private struct Entry {
        let clip: SoundboardPCMClip
        let cost: Int
    }

    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private var loads: [URL: Task<SoundboardPCMClip, any Error>] = [:]
    private let maximumCost = 64 * 1_024 * 1_024
    private var retainedCost = 0

    func clip(for sound: SoundboardSound) async throws -> SoundboardPCMClip {
        guard let url = sound.mediaURL else { throw SoundboardAudioError.invalidAudio }
        if let entry = entries[url] {
            touch(url)
            return entry.clip
        }
        if let load = loads[url] { return try await load.value }
        let load = Task<SoundboardPCMClip, any Error> {
            let data = try await SharedMediaDataLoader.shared.data(for: url)
            return try await Task.detached(priority: .userInitiated) {
                try SoundboardAudioDecoder.decode(data)
            }.value
        }
        loads[url] = load
        defer { loads[url] = nil }
        let clip = try await load.value
        let cost = clip.frameCount * MemoryLayout<Float>.stride * 2
        entries[url] = Entry(clip: clip, cost: cost)
        order.append(url)
        retainedCost += cost
        evictIfNeeded()
        return clip
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    private func evictIfNeeded() {
        while retainedCost > maximumCost, order.count > 1 {
            let url = order.removeFirst()
            if let entry = entries.removeValue(forKey: url) {
                retainedCost -= entry.cost
            }
        }
    }
}

extension AppModel {
    static let soundboardLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "Soundboard"
    )
    static let soundboardSignposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "Soundboard"
    )

    var defaultSoundboardSounds: [SoundboardSound] {
        get { soundboardState.defaults }
        set { soundboardState.defaults = newValue }
    }

    var soundboardSoundsByGuild: [GuildID: [SoundboardSound]] {
        get { soundboardState.soundsByGuild }
        set { soundboardState.soundsByGuild = newValue }
    }

    var soundboardUserSettings: SoundboardUserSettings {
        get { soundboardState.userSettings }
        set { soundboardState.userSettings = newValue }
    }

    var isLoadingSoundboard: Bool {
        get { soundboardState.isLoading }
        set { soundboardState.isLoading = newValue }
    }

    var soundboardErrorMessage: String? {
        get { soundboardState.errorMessage }
        set { soundboardState.errorMessage = newValue }
    }

    func consumeSoundboardEvent(_ event: ClientEvent) {
        switch event {
        case .soundboardUserSettingsChanged(let settings):
            soundboardUserSettings = settings
        case .soundboardSoundsChanged(let guildID, let sounds):
            if let guildID {
                soundboardSoundsByGuild[guildID] = sounds
            } else {
                defaultSoundboardSounds = sounds
            }
        case .voiceChannelEffect(let effect):
            consumeVoiceChannelEffect(effect)
        default:
            assertionFailure("Expected a soundboard event")
        }
    }

    var allSoundboardSounds: [SoundboardSound] {
        defaultSoundboardSounds + soundboardSoundsByGuild.values.flatMap { $0 }
    }

    func loadSoundboard() async {
        guard supportedCapabilities.contains(.soundboard) else { return }
        if let task = soundboardLoadTask {
            await task.value
            return
        }
        soundboardLoadGeneration &+= 1
        let generation = soundboardLoadGeneration
        isLoadingSoundboard = true
        soundboardErrorMessage = nil
        let guildIDs = Array(serverRailGuildsByID.keys)
        let provider = provider
        let task = Task { @MainActor [weak self] in
            do {
                async let defaults = provider.defaultSoundboardSounds()
                async let guilds = provider.soundboardSounds(in: guildIDs)
                async let settings = provider.soundboardUserSettings()
                let result = try await (defaults, guilds, settings)
                guard let self, self.soundboardLoadGeneration == generation else { return }
                defaultSoundboardSounds = result.0
                soundboardSoundsByGuild = result.1
                soundboardUserSettings = result.2
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.soundboardLoadGeneration == generation else { return }
                soundboardErrorMessage = error.localizedDescription
                Self.soundboardLogger.error("Catalog load failed: \(String(reflecting: error), privacy: .public)")
            }
            guard let self, self.soundboardLoadGeneration == generation else { return }
            isLoadingSoundboard = false
            soundboardLoadTask = nil
        }
        soundboardLoadTask = task
        await task.value
    }

    func retrySoundboardLoad() async {
        soundboardLoadGeneration &+= 1
        soundboardLoadTask?.cancel()
        soundboardLoadTask = nil
        await loadSoundboard()
    }

    func isFavoriteSound(_ sound: SoundboardSound) -> Bool {
        soundboardUserSettings.favoriteSoundIDs.contains(sound.id)
    }

    func toggleFavoriteSound(_ sound: SoundboardSound) async {
        let wasFavorite = isFavoriteSound(sound)
        var optimistic = soundboardUserSettings
        if wasFavorite {
            optimistic.favoriteSoundIDs.removeAll { $0 == sound.id }
        } else if !optimistic.favoriteSoundIDs.contains(sound.id) {
            optimistic.favoriteSoundIDs.append(sound.id)
        }
        soundboardUserSettings = optimistic
        do {
            soundboardUserSettings = try await provider.setSoundboardFavorite(
                sound.id,
                isFavorite: !wasFavorite
            )
        } catch {
            soundboardUserSettings = await (try? provider.soundboardUserSettings()) ?? soundboardUserSettings
            soundboardErrorMessage = error.localizedDescription
        }
    }

    func previewSound(_ sound: SoundboardSound) async {
        await performSoundboardAudio(sound, mode: .preview)
    }

    func playSound(_ sound: SoundboardSound) async {
        guard let channel = activeVoiceChannel,
              voiceSessionState == .connected,
              let session = voiceSession,
              let route = soundboardPlaybackRoute(for: sound)
        else {
            soundboardErrorMessage = "This sound can’t be played in the current voice channel."
            return
        }
        let state = Self.soundboardSignposter.beginInterval("Trigger")
        defer { Self.soundboardSignposter.endInterval("Trigger", state) }
        do {
            switch route {
            case .native:
                let echoID = registerPendingNativeEcho(
                    soundID: sound.id,
                    channelID: channel.id
                )
                let localPlayback = Task(priority: .userInitiated) { @MainActor in
                    let clip = try await SoundboardAudioLibrary.shared.clip(for: sound)
                    try await session.playSoundboardClipLocally(
                        clip,
                        volume: Float(sound.volume)
                    )
                }
                // Give optimistic local playback a head start instead of making it
                // wait for Discord to acknowledge the native soundboard request.
                await Task.yield()
                do {
                    try await provider.sendSoundboardSound(sound, in: channel.id)
                } catch {
                    cancelPendingNativeEcho(echoID)
                    _ = await localPlayback.result
                    throw error
                }
                try await localPlayback.value
                Self.soundboardLogger.info("Native soundboard send rendered locally")
            case .outgoingMixer:
                let clip = try await SoundboardAudioLibrary.shared.clip(for: sound)
                async let local: Void = session.playSoundboardClipLocally(
                    clip,
                    volume: Float(sound.volume)
                )
                let accepted = try await session.enqueueOutgoingSoundboardClip(
                    clip,
                    volume: Float(sound.volume)
                )
                try await local
                guard accepted else { throw SoundboardAudioError.decodeFailed }
            }
            soundboardErrorMessage = nil
        } catch {
            soundboardErrorMessage = error.localizedDescription
            Self.soundboardLogger.error("Playback failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    func consumeVoiceChannelEffect(_ effect: VoiceChannelEffect) {
        guard effect.channelID == activeVoiceChannel?.id,
              let soundID = effect.soundID
        else { return }
        if consumePendingNativeEcho(for: effect, soundID: soundID) {
            return
        }
        let sound = SoundboardEffectPlaybackPolicy.sound(
            withID: soundID,
            in: allSoundboardSounds
        )
        Task { @MainActor [weak self] in
            await self?.performSoundboardAudio(
                sound,
                mode: .effect(
                    volume: SoundboardEffectPlaybackPolicy.volume(for: effect)
                )
            )
        }
    }

    private enum SoundboardAudioMode {
        case preview
        case effect(volume: Double)
    }

    private func performSoundboardAudio(
        _ sound: SoundboardSound,
        mode: SoundboardAudioMode
    ) async {
        guard voiceSessionState == .connected, let session = voiceSession else {
            if case .preview = mode {
                soundboardErrorMessage = "Connect to voice before playing a sound."
            }
            return
        }
        do {
            let clip = try await SoundboardAudioLibrary.shared.clip(for: sound)
            let volume = switch mode {
            case .preview: sound.volume
            case .effect(let effectVolume): effectVolume
            }
            try await session.playSoundboardClipLocally(clip, volume: Float(volume))
            if case .preview = mode {
                soundboardErrorMessage = nil
            } else {
                Self.soundboardLogger.info("Incoming soundboard effect rendered locally")
            }
        } catch {
            if case .preview = mode {
                soundboardErrorMessage = error.localizedDescription
            }
            Self.soundboardLogger.error("Local playback failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func registerPendingNativeEcho(
        soundID: String,
        channelID: ChannelID
    ) -> UUID {
        let now = Date()
        soundboardState.pendingNativeEchoes.removeAll { $0.expiresAt <= now }
        let id = UUID()
        soundboardState.pendingNativeEchoes.append(PendingNativeSoundboardEcho(
            id: id,
            channelID: channelID,
            soundID: soundID,
            expiresAt: now.addingTimeInterval(10)
        ))
        if soundboardState.pendingNativeEchoes.count > 64 {
            soundboardState.pendingNativeEchoes.removeFirst(
                soundboardState.pendingNativeEchoes.count - 64
            )
        }
        return id
    }

    private func cancelPendingNativeEcho(_ id: UUID) {
        soundboardState.pendingNativeEchoes.removeAll { $0.id == id }
    }

    private func consumePendingNativeEcho(
        for effect: VoiceChannelEffect,
        soundID: String
    ) -> Bool {
        guard effect.userID == snapshot?.currentUser.id else { return false }
        let now = Date()
        soundboardState.pendingNativeEchoes.removeAll { $0.expiresAt <= now }
        guard let index = soundboardState.pendingNativeEchoes.firstIndex(where: {
            $0.channelID == effect.channelID && $0.soundID == soundID
        }) else { return false }
        soundboardState.pendingNativeEchoes.remove(at: index)
        return true
    }

    private func soundboardPlaybackRoute(
        for sound: SoundboardSound
    ) -> SoundboardPlaybackRoute? {
        guard let channel = activeVoiceChannel else { return nil }
        let permissions: UInt64?
        if let guildID = channel.guildID,
           let guild = serverRailGuildsByID[guildID],
           let currentUserID = snapshot?.currentUser.id
        {
            permissions = ConversationPermissionResolver.effectivePermissions(
                guild: guild,
                channel: channel,
                currentUserID: currentUserID,
                currentMember: membersByGuildID[guildID]?[currentUserID]
                    ?? membersByID[currentUserID],
                roles: guildRolesByGuildID[guildID] ?? guildRoles,
                currentRoleIDs: currentUserRoleIDsByGuild[guildID]
            )
        } else {
            permissions = .max
        }
        let currentUserID = snapshot?.currentUser.id
        return SoundboardPlaybackPolicy.route(
            for: sound,
            activeGuildID: channel.guildID,
            premiumType: snapshot?.currentUser.premiumType ?? 0,
            effectivePermissions: permissions,
            voiceState: currentUserID.flatMap { voiceStates[$0] }
        )
    }
}
