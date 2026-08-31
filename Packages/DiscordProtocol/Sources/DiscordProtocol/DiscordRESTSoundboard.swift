import Foundation
import SakuraCordModels

struct PendingSoundboardRequest {
    var remainingGuildIDs: Set<GuildID>
    var soundsByGuildID: [GuildID: [SoundboardSound]]
    let continuation: CheckedContinuation<[GuildID: [SoundboardSound]], any Error>
}

struct SoundboardSoundDTO: Decodable {
    var soundID: String
    var name: String
    var volume: Double?
    var emojiID: String?
    var emojiName: String?
    var userID: String?
    var available: Bool?

    enum CodingKeys: String, CodingKey {
        case name, volume, available
        case soundID = "sound_id"
        case emojiID = "emoji_id"
        case emojiName = "emoji_name"
        case userID = "user_id"
    }

    func domain(guildID: GuildID?) -> SoundboardSound {
        SoundboardSound(
            id: soundID,
            name: name,
            volume: volume ?? 1,
            emojiID: emojiID,
            emojiName: emojiName,
            guildID: guildID,
            userID: userID.flatMap(UserID.init),
            isAvailable: available ?? true
        )
    }
}

struct GatewaySoundboardSoundsDTO: Decodable {
    var guildID: String
    var sounds: [SoundboardSoundDTO]

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case sounds = "soundboard_sounds"
    }
}

struct GatewaySoundboardSoundEventDTO: Decodable {
    var guildID: String
    var soundID: String
    var name: String
    var volume: Double?
    var emojiID: String?
    var emojiName: String?
    var userID: String?
    var available: Bool?

    enum CodingKeys: String, CodingKey {
        case name, volume, available
        case guildID = "guild_id"
        case soundID = "sound_id"
        case emojiID = "emoji_id"
        case emojiName = "emoji_name"
        case userID = "user_id"
    }

    var domain: SoundboardSound? {
        guard let guildID = GuildID(guildID) else { return nil }
        return SoundboardSoundDTO(
            soundID: soundID,
            name: name,
            volume: volume,
            emojiID: emojiID,
            emojiName: emojiName,
            userID: userID,
            available: available
        ).domain(guildID: guildID)
    }
}

struct GatewaySoundboardSoundDeleteDTO: Decodable {
    var guildID: String
    var soundID: String

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case soundID = "sound_id"
    }
}

struct VoiceChannelEffectDTO: Decodable {
    var channelID: StringOrIntegerDTO
    var guildID: StringOrIntegerDTO?
    var userID: StringOrIntegerDTO
    var soundID: StringOrIntegerDTO?
    var soundVolume: Double?

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case guildID = "guild_id"
        case userID = "user_id"
        case soundID = "sound_id"
        case soundVolume = "sound_volume"
    }

    var domain: VoiceChannelEffect? {
        guard let channelID = ChannelID(channelID.value),
              let userID = UserID(userID.value)
        else { return nil }
        return VoiceChannelEffect(
            channelID: channelID,
            guildID: guildID.flatMap { GuildID($0.value) },
            userID: userID,
            soundID: soundID?.value,
            soundVolume: soundVolume ?? 1
        )
    }
}

public extension DiscordRESTProvider {
    func defaultSoundboardSounds() async throws -> [SoundboardSound] {
        if let cachedDefaultSoundboardSounds { return cachedDefaultSoundboardSounds }
        let response: [SoundboardSoundDTO] = try await request(
            "/soundboard-default-sounds"
        )
        let sounds = response.map { $0.domain(guildID: nil) }
        cachedDefaultSoundboardSounds = sounds
        continuation?.yield(.soundboardSoundsChanged(guildID: nil, sounds: sounds))
        return sounds
    }

    func soundboardSounds(
        in guildIDs: [GuildID]
    ) async throws -> [GuildID: [SoundboardSound]] {
        let orderedGuildIDs = guildIDs.reduce(into: [GuildID]()) { result, guildID in
            if !result.contains(guildID) { result.append(guildID) }
        }
        let missing = orderedGuildIDs.filter { cachedSoundboardSounds[$0] == nil }
        guard !missing.isEmpty else {
            return Dictionary(uniqueKeysWithValues: orderedGuildIDs.map {
                ($0, cachedSoundboardSounds[$0] ?? [])
            })
        }
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to load soundboard sounds."
            )
        }

        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingSoundboardRequests[requestID] = PendingSoundboardRequest(
                    remainingGuildIDs: Set(missing),
                    soundsByGuildID: Dictionary(uniqueKeysWithValues: orderedGuildIDs.compactMap { guildID in
                        cachedSoundboardSounds[guildID].map { (guildID, $0) }
                    }),
                    continuation: continuation
                )
                soundboardRequestTimeoutTasks[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.failSoundboardRequest(
                        requestID,
                        error: ChatProviderError.invalidRequest(
                            "Discord did not return the soundboard catalog in time."
                        )
                    )
                }
                Task { [weak self] in
                    do {
                        for start in stride(from: 0, to: missing.count, by: 100) {
                            try Task.checkCancellation()
                            try await self?.sendGateway(
                                DiscordGatewayPayloadFactory.requestSoundboardSounds(
                                    guildIDs: Array(missing[start ..< min(start + 100, missing.count)])
                                )
                            )
                        }
                    } catch {
                        await self?.failSoundboardRequest(requestID, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failSoundboardRequest(requestID, error: CancellationError()) }
        }
    }

    func soundboardUserSettings() async throws -> SoundboardUserSettings {
        if let cachedSoundboardUserSettings { return cachedSoundboardUserSettings }
        let settings = DiscordSettingsProto.soundboardSettings(
            from: try await frecencySettingsProto()
        )
        cachedSoundboardUserSettings = settings
        return settings
    }

    func setSoundboardFavorite(
        _ soundID: String,
        isFavorite: Bool
    ) async throws -> SoundboardUserSettings {
        guard !isMutatingFrecencyFavorite else {
            throw ChatProviderError.invalidRequest("A favorite update is already in progress.")
        }
        isMutatingFrecencyFavorite = true
        defer { isMutatingFrecencyFavorite = false }

        let update = try DiscordSettingsProto.updatingSoundboardFavorite(
            in: try await frecencySettingsProto(),
            soundID: soundID,
            isFavorite: isFavorite
        )
        try await requestEmpty(
            "/users/@me/settings-proto/2",
            method: "PATCH",
            body: ["settings": .string(update.data.base64EncodedString())]
        )
        cachedFrecencySettingsProto = update.data
        cachedSoundboardUserSettings = update.settings
        continuation?.yield(.soundboardUserSettingsChanged(update.settings))
        return update.settings
    }

    func sendSoundboardSound(
        _ sound: SoundboardSound,
        in channelID: ChannelID
    ) async throws {
        var body: [String: JSONValue] = [
            "sound_id": .string(sound.id),
            "emoji_id": sound.emojiID.map(JSONValue.string) ?? .null,
            "emoji_name": sound.emojiName.map(JSONValue.string) ?? .null,
        ]
        if let guildID = sound.guildID {
            body["source_guild_id"] = .string(guildID.description)
        }
        try await requestEmpty(
            "/channels/\(channelID)/send-soundboard-sound",
            method: "POST",
            body: body
        )
    }
}

extension DiscordRESTProvider {
    func applySoundboardSounds(_ dto: GatewaySoundboardSoundsDTO) {
        guard let guildID = GuildID(dto.guildID) else { return }
        let sounds = dto.sounds.map { $0.domain(guildID: guildID) }
        cachedSoundboardSounds[guildID] = sounds
        continuation?.yield(.soundboardSoundsChanged(guildID: guildID, sounds: sounds))

        for requestID in Array(pendingSoundboardRequests.keys) {
            guard var request = pendingSoundboardRequests[requestID],
                  request.remainingGuildIDs.remove(guildID) != nil
            else { continue }
            request.soundsByGuildID[guildID] = sounds
            if request.remainingGuildIDs.isEmpty {
                pendingSoundboardRequests[requestID] = nil
                soundboardRequestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                request.continuation.resume(returning: request.soundsByGuildID)
            } else {
                pendingSoundboardRequests[requestID] = request
            }
        }
    }

    func upsertSoundboardSound(_ sound: SoundboardSound) {
        guard let guildID = sound.guildID,
              var sounds = cachedSoundboardSounds[guildID]
        else { return }
        sounds.removeAll { $0.id == sound.id }
        sounds.append(sound)
        cachedSoundboardSounds[guildID] = sounds
        continuation?.yield(.soundboardSoundsChanged(guildID: guildID, sounds: sounds))
    }

    func deleteSoundboardSound(guildID: GuildID, soundID: String) {
        guard var sounds = cachedSoundboardSounds[guildID] else { return }
        sounds.removeAll { $0.id == soundID }
        cachedSoundboardSounds[guildID] = sounds
        continuation?.yield(.soundboardSoundsChanged(guildID: guildID, sounds: sounds))
    }

    func failSoundboardRequest(_ requestID: UUID, error: any Error) {
        soundboardRequestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        pendingSoundboardRequests.removeValue(forKey: requestID)?.continuation.resume(
            throwing: error
        )
    }

    func cancelSoundboardRequests() {
        soundboardRequestTimeoutTasks.values.forEach { $0.cancel() }
        soundboardRequestTimeoutTasks = [:]
        let requests = pendingSoundboardRequests.values
        pendingSoundboardRequests = [:]
        for request in requests {
            request.continuation.resume(throwing: CancellationError())
        }
    }
}
