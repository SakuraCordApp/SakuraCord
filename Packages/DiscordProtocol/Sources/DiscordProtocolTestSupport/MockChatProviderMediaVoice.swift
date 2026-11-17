import DiscordProtocol
import Foundation
import SakuraCordModels

public extension MockChatProvider {
    func emojis(in guildID: GuildID) async throws -> [DiscordEmoji] {
        emojisByGuild[guildID] ?? []
    }

    func emojiUserSettings() async throws -> EmojiUserSettings {
        EmojiUserSettings(
            favoriteKeys: favoriteEmojiKeys ?? [
                "custom:900000000000000201", "white_check_mark", "x", "neutral_face",
                "broken_heart", "hot_face",
                "smiling_face_with_3_hearts", "cry", "fire", "thumbsup", "sob",
            ],
            messageHistory: savedEmojiFrecency?.messages ?? .init(entries: [
                "custom:900000000000000202", "broken_heart", "white_check_mark", "neutral_face",
                "sob", "pray", "fire",
                "cry", "wilted_flower", "person_shrugging", "white_heart", "thumbsup", "x",
                "unamused", "hot_face", "pleading_face", "smiley_cat", "eyes",
            ].enumerated().map { index, key in
                DiscordFrecencyEntry(key: key.replacingOccurrences(of: "custom:", with: ""), totalUses: 30 - index, recentUses: [UInt64(Date().timeIntervalSince1970 * 1_000)])
            }),
            reactionHistory: savedEmojiFrecency?.reactions ?? .init(),
            guildAndChannelUsageScores: Dictionary(
                uniqueKeysWithValues: snapshot.channels.enumerated().map { index, channel in
                    (channel.id.description, max(1, snapshot.channels.count - index))
                }
            )
        )
    }

    func setEmojiFavorite(
        _ key: String,
        isFavorite: Bool
    ) async throws -> EmojiUserSettings {
        var settings = try await emojiUserSettings()
        settings.favoriteKeys.removeAll { $0 == key }
        if isFavorite {
            settings.favoriteKeys.append(key)
        }
        favoriteEmojiKeys = settings.favoriteKeys
        return settings
    }

    func saveEmojiFrecency(
        _ messages: DiscordFrecencyHistory, reactions: DiscordFrecencyHistory,
        favoriteKey: String?, isFavorite: Bool
    ) async throws -> EmojiUserSettings {
        savedEmojiFrecency = (messages, reactions)
        if let favoriteKey { return try await setEmojiFavorite(favoriteKey, isFavorite: isFavorite) }
        return try await emojiUserSettings()
    }

    func trendingGIFs() async throws -> [GIFSearchResult] {
        try MockChatMediaFixtures.gifs(query: "Trending")
    }

    func searchGIFs(query: String) async throws -> [GIFSearchResult] {
        try MockChatMediaFixtures.gifs(query: query.isEmpty ? "GIF" : query)
    }

    func gifPickerLanding() async throws -> GIFPickerLanding {
        let preview = try MockChatMediaFixtures.gifs(query: "Category").first?.previewURL
        return GIFPickerLanding(
            categories: [
                "hello", "lol", "love", "happy birthday", "thank you", "excited",
                "yes", "no", "sorry", "happy", "sad", "thumbs up",
            ]
                .map {
                    GIFPickerCategory(id: $0, name: $0, query: $0, previewURL: preview)
                },
            trendingPreviewURL: preview
        )
    }

    func favoriteGIFs() async throws -> [GIFSearchResult] {
        favoriteGIFValues
    }

    func setGIFFavorite(_ gif: GIFSearchResult, isFavorite: Bool) async throws
        -> [GIFSearchResult]
    {
        favoriteGIFValues.removeAll { $0.url == gif.url }
        if isFavorite {
            favoriteGIFValues.insert(gif, at: 0)
        }
        return favoriteGIFValues
    }

    func stickers(in guildID: GuildID) async throws -> [MessageSticker] {
        try [
            MessageSticker(
                id: "demo-wave", name: "Wave", description: "Offline demo sticker",
                tags: "wave,hello",
                format: .png,
                guildID: guildID,
                assetURL: MockChatMediaFixtures.gifs(query: "Sticker").first?.url
            )
        ]
    }

    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        guard snapshot.channels.contains(where: {
            $0.id == channelID
                && ($0.kind == .voice || $0.kind.isDirectMessage)
        }) else {
            throw ChatProviderError.invalidRequest("That demo voice channel is unavailable.")
        }
        voiceJoinRequests.append(VoiceJoinRequest(
            channelID: channelID,
            guildID: guildID,
            selfMute: selfMute,
            selfDeaf: selfDeaf
        ))
        let state = VoiceParticipantState(
            userID: currentUser.id,
            channelID: channelID,
            guildID: guildID,
            sessionID: "demo-session",
            isSelfMuted: selfMute,
            isSelfDeafened: selfDeaf
        )
        continuation?.yield(.voiceStateChanged(state))
        if guildID == nil {
            var call =
                privateCallsByChannel[channelID]
                ?? PrivateCall(
                    channelID: channelID,
                    messageID: MessageID(rawValue: nextMessageID),
                    region: "mock",
                    voiceStates: []
                )
            var states = call.voiceStates ?? []
            states.removeAll { $0.userID == currentUser.id }
            states.append(state)
            call.voiceStates = states
            privateCallsByChannel[channelID] = call
            continuation?.yield(.privateCallChanged(call))
        }
        return VoiceConnectionInfo(
            serverID: guildID?.description ?? channelID.description,
            channelID: channelID,
            guildID: guildID,
            userID: currentUser.id,
            sessionID: state.sessionID,
            token: "demo-token",
            endpoint: "mock.sakuracord.invalid"
        )
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        continuation?.yield(
            .voiceStateChanged(
                VoiceParticipantState(
                    userID: currentUser.id,
                    channelID: channelID,
                    guildID: guildID,
                    sessionID: "demo-session",
                    isSelfMuted: selfMute,
                    isSelfDeafened: selfDeaf,
                    isVideoEnabled: selfVideo
                )
            )
        )
        if guildID == nil {
            if let channelID, var call = privateCallsByChannel[channelID] {
                var states = call.voiceStates ?? []
                states.removeAll { $0.userID == currentUser.id }
                states.append(
                    VoiceParticipantState(
                        userID: currentUser.id,
                        channelID: channelID,
                        guildID: nil,
                        sessionID: "demo-session",
                        isSelfMuted: selfMute,
                        isSelfDeafened: selfDeaf,
                        isVideoEnabled: selfVideo
                    )
                )
                call.voiceStates = states
                privateCallsByChannel[channelID] = call
                continuation?.yield(.privateCallChanged(call))
            } else if channelID == nil {
                for (id, var call) in privateCallsByChannel {
                    call.voiceStates?.removeAll { $0.userID == currentUser.id }
                    privateCallsByChannel[id] = call
                    continuation?.yield(.privateCallChanged(call))
                }
            }
        }
    }

    func subscribeToPrivateCall(channelID: ChannelID) async throws {
        if let call = privateCallsByChannel[channelID] {
            continuation?.yield(.privateCallChanged(call))
        }
    }

    func privateCallIsRingable(channelID: ChannelID) async throws -> Bool {
        snapshot.channels.contains {
            $0.id == channelID && $0.kind == .directMessage
        }
    }

    func ringPrivateCall(channelID: ChannelID, recipients: [UserID]?) async throws {
        guard let channel = snapshot.channels.first(where: { $0.id == channelID }),
              channel.kind.isDirectMessage
        else {
            throw ChatProviderError.channelNotFound
        }
        var call =
            privateCallsByChannel[channelID]
            ?? PrivateCall(
                channelID: channelID,
                messageID: MessageID(rawValue: nextMessageID),
                region: "mock",
                voiceStates: []
            )
        let targets = recipients ?? channel.recipients.map(\.id)
        call.ongoingRings = targets
            .filter { $0 != currentUser.id }
            .map { PrivateCallRing(recipientID: $0, senderID: currentUser.id) }
        privateCallsByChannel[channelID] = call
        continuation?.yield(.privateCallChanged(call))
    }

    func stopRingingPrivateCall(channelID: ChannelID, recipients: [UserID]) async throws {
        guard var call = privateCallsByChannel[channelID] else { return }
        let targetIDs = Set(recipients)
        call.ongoingRings.removeAll { targetIDs.contains($0.recipientID) }
        privateCallsByChannel[channelID] = call
        continuation?.yield(.privateCallChanged(call))
    }

    func defaultSoundboardSounds() async throws -> [SoundboardSound] {
        [
            SoundboardSound(id: "1", name: "quack", emojiName: "🦆"),
            SoundboardSound(id: "2", name: "airhorn", emojiName: "🔊"),
            SoundboardSound(id: "3", name: "cricket", emojiName: "🦗"),
            SoundboardSound(id: "4", name: "golf clap", emojiName: "👏"),
            SoundboardSound(id: "5", name: "sad horn", emojiName: "🎺"),
            SoundboardSound(id: "7", name: "ba dum tss", emojiName: "🥁"),
        ]
    }

    func soundboardSounds(
        in guildIDs: [GuildID]
    ) async throws -> [GuildID: [SoundboardSound]] {
        Dictionary(uniqueKeysWithValues: guildIDs.map {
            ($0, soundboardSoundsByGuild[$0] ?? [])
        })
    }

    func soundboardUserSettings() async throws -> SoundboardUserSettings {
        soundboardSettings
    }

    func setSoundboardFavorite(
        _ soundID: String,
        isFavorite: Bool
    ) async throws -> SoundboardUserSettings {
        soundboardSettings.favoriteSoundIDs.removeAll { $0 == soundID }
        if isFavorite {
            soundboardSettings.favoriteSoundIDs.append(soundID)
        }
        continuation?.yield(.soundboardUserSettingsChanged(soundboardSettings))
        return soundboardSettings
    }

    func sendSoundboardSound(
        _ sound: SoundboardSound,
        in channelID: ChannelID
    ) async throws {
        soundboardSendRequests.append(SoundboardSendRequest(sound: sound, channelID: channelID))
        continuation?.yield(.voiceChannelEffect(VoiceChannelEffect(
            channelID: channelID,
            guildID: snapshot.channels.first(where: { $0.id == channelID })?.guildID,
            userID: currentUser.id,
            emoji: sound.emojiReference,
            soundID: sound.id,
            soundVolume: 1
        )))
    }

    struct VoiceJoinRequest: Equatable, Sendable {
        public var channelID: ChannelID
        public var guildID: GuildID?
        public var selfMute: Bool
        public var selfDeaf: Bool

        public init(
            channelID: ChannelID,
            guildID: GuildID?,
            selfMute: Bool,
            selfDeaf: Bool
        ) {
            self.channelID = channelID
            self.guildID = guildID
            self.selfMute = selfMute
            self.selfDeaf = selfDeaf
        }
    }

    struct SoundboardSendRequest: Equatable, Sendable {
        public var sound: SoundboardSound
        public var channelID: ChannelID
    }
}
