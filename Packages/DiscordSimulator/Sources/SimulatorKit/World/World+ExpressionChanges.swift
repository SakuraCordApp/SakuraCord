import Foundation

/// Someone else adding or removing a server's emoji, stickers or soundboard
/// sounds (the app has no editor for these; the control API drives them).
extension World {
    /// Adds an emoji when `name` is new, or removes the one with that name or ID.
    func changeEmoji(_ name: String, in guildID: Snowflake, by userID: Snowflake, adding: Bool) async throws {
        var guild = try guild(guildID)
        if adding {
            let emoji = Emoji(id: nextID(), name: name, creatorID: userID)
            let png = MediaGenerator.emojiPNG(seed: emoji.id.rawValue)
            for ext in ["png", "webp"] { storeMedia("/emojis/\(emoji.id).\(ext)", png, contentType: "image/png") }
            guild.emojis.append(emoji)
        } else {
            guard let index = guild.emojis.firstIndex(where: { $0.name == name || $0.id.description == name }) else {
                throw WorldError.unknown("Emoji", code: 10014)
            }
            guild.emojis.remove(at: index)
        }
        guilds[guildID] = guild
        // Each emoji carries the guild's expression version, which moves with every change.
        let version = JSON.int(Int64(clock.now.timeIntervalSince1970 * 1000))
        await emit("GUILD_EMOJIS_UPDATE", .object(JSONObject([
            ("emojis", .array(guild.emojis.map { renderEmoji($0).merging(["version": version]) })), ("guild_id", guildID.json),
        ])), to: .guild(guildID, channel: nil))
    }

    func changeSticker(_ name: String, in guildID: Snowflake, adding: Bool, tags: String = "🙂") async throws {
        var guild = try guild(guildID)
        if adding {
            let sticker = Sticker(id: nextID(), name: name, description: "", tags: tags)
            let png = MediaGenerator.stickerPNG(seed: sticker.id.rawValue)
            for ext in ["png", "webp"] { storeMedia("/stickers/\(sticker.id).\(ext)", png, contentType: "image/png") }
            guild.stickers.append(sticker)
        } else {
            guard let index = guild.stickers.firstIndex(where: { $0.name == name || $0.id.description == name }) else {
                throw WorldError.unknown("Sticker", code: 10060)
            }
            guild.stickers.remove(at: index)
        }
        guilds[guildID] = guild
        let version = JSON.int(Int64(clock.now.timeIntervalSince1970 * 1000))
        await emit("GUILD_STICKERS_UPDATE", .object(JSONObject([
            ("guild_id", guildID.json),
            ("stickers", .array(guild.stickers.map { renderSticker($0, guildID: guildID).merging(["version": version]) })),
        ])), to: .guild(guildID, channel: nil))
    }

    func addSoundboardSound(_ name: String, emoji: String?, in guildID: Snowflake, by userID: Snowflake) async throws {
        let sound = SoundboardSound(id: nextID(), name: name, emojiName: emoji, userID: userID)
        _ = try guild(guildID)
        guilds[guildID]?.soundboardSounds.append(sound)
        await emitSoundboardSound("GUILD_SOUNDBOARD_SOUND_CREATE", sound, in: guildID)
    }

    /// A member renames a sound or changes its emoji or volume. Captured: GUILD_SOUNDBOARD_SOUND_UPDATE carries the
    /// same fields as the create, `id` included.
    func updateSoundboardSound(_ name: String, in guildID: Snowflake, newName: String?, emoji: String?, volume: Double?) async throws {
        let index = try soundboardSoundIndex(name, in: guildID)
        var sound = guilds[guildID]!.soundboardSounds[index]
        if let newName { sound.name = newName }
        if let emoji { sound.emojiName = emoji }
        if let volume { sound.volume = volume }
        guilds[guildID]!.soundboardSounds[index] = sound
        await emitSoundboardSound("GUILD_SOUNDBOARD_SOUND_UPDATE", sound, in: guildID)
    }

    func removeSoundboardSound(_ name: String, in guildID: Snowflake) async throws {
        let index = try soundboardSoundIndex(name, in: guildID)
        let sound = guilds[guildID]!.soundboardSounds.remove(at: index)
        await emit("GUILD_SOUNDBOARD_SOUND_DELETE", .object(JSONObject([("guild_id", guildID.json), ("sound_id", sound.id.json)])),
                   to: .guild(guildID, channel: nil))
    }

    private func soundboardSoundIndex(_ name: String, in guildID: Snowflake) throws -> Int {
        guard let index = try guild(guildID).soundboardSounds.firstIndex(where: { $0.name == name || $0.id.description == name }) else {
            throw WorldError.unknown("Sound", code: 10097)
        }
        return index
    }

    private func emitSoundboardSound(_ event: String, _ sound: SoundboardSound, in guildID: Snowflake) async {
        var payload = renderSoundboardSound(sound, in: guilds[guildID]!)
        payload["id"] = sound.id.json
        if let userID = sound.userID { payload["user"] = renderUser(userID) }
        await emit(event, .object(payload), to: .guild(guildID, channel: nil))
    }
}
