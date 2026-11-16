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
        guard case var .object(payload) = renderSoundboardSounds(guildID: guildID, viewer: guilds[guildID]!.ownerID)?["soundboard_sounds"]?
            .arrayValue?.last else { return }
        payload["id"] = sound.id.json
        payload["user"] = renderUser(userID)
        await emit("GUILD_SOUNDBOARD_SOUND_CREATE", .object(payload), to: .guild(guildID, channel: nil))
    }

    func removeSoundboardSound(_ name: String, in guildID: Snowflake) async throws {
        guard let sound = try guild(guildID).soundboardSounds.first(where: { $0.name == name || $0.id.description == name }) else {
            throw WorldError.unknown("Sound", code: 10097)
        }
        guilds[guildID]?.soundboardSounds.removeAll { $0.id == sound.id }
        await emit("GUILD_SOUNDBOARD_SOUND_DELETE", .object(JSONObject([("guild_id", guildID.json), ("sound_id", sound.id.json)])),
                   to: .guild(guildID, channel: nil))
    }
}
