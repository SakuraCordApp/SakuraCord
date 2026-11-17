import Foundation

/// The expression pickers: GIFs, server emoji, standard sticker packs and soundboard sounds.
extension World {
    // MARK: GIFs

    static let gifCategories = ["hello", "lol", "love", "yes", "no", "thanks", "sleepy", "happy", "dance", "cozy", "hungry", "wow"]

    /// A GIF result. Its media is generated and served through Discord's
    /// external-media proxy host, so the picker never leaves the simulator.
    func gifResult(query: String, index: Int) -> JSON {
        let seed = "\(query.lowercased())#\(index)".hashValueStable
        let slug = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        let id = "\(slug.isEmpty ? "gif" : slug)-\(seed % 997)"
        let width = 220 + Int(seed % 5) * 20, height = 160 + Int(seed / 5 % 5) * 20
        let path = "/external/\(String(seed, radix: 36))/https/static.klipy.com/ii/\(String(format: "%016llx", seed))/\(id).gif"
        storeLazyMedia(path) { (MediaGenerator.animatedGIF(seed: seed, size: 160), "image/gif") }
        let media = JSON.string("https://images-ext-1.discordapp.net\(path)")
        return .object(JSONObject([
            ("id", .string(id)), ("title", .string("\(query.capitalized) \(index + 1)")), ("url", .string("https://klipy.com/gifs/\(id)")),
            ("src", media), ("gif_src", media), ("width", .int(width)), ("height", .int(height)), ("preview", media),
        ]))
    }

    func gifSearch(_ query: String, limit: Int) -> [JSON] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return (0 ..< min(limit, 50)).map { gifResult(query: trimmed, index: $0) }
    }

    func gifTrending() -> JSON {
        .object(JSONObject([
            ("categories", .array(Self.gifCategories.map { name in
                .object(JSONObject([("name", .string(name)), ("src", gifResult(query: name, index: 0)["src"] ?? .null)]))
            })),
            ("gifs", [gifResult(query: "trending", index: 0)]),
        ]))
    }

    // MARK: Emoji and stickers

    func guildEmojis(_ guildID: Snowflake, viewer: Snowflake) throws -> [JSON] {
        let guild = try memberGuild(guildID, of: viewer)
        let manages = guild.permissions(of: viewer, at: clock.now).contains(.manageGuildExpressions)
        // Expression managers also see who uploaded each emoji.
        return guild.emojis.map { emoji in
            guard manages, let creator = emoji.creatorID else { return renderEmoji(emoji) }
            return renderEmoji(emoji).merging(["user": renderUser(creator)])
        }
    }

    /// Discord's own stickers as one pack, whose IDs derive from its cover sticker's.
    func stickerPacks() -> JSON {
        guard let cover = standardStickers.first else { return .object(JSONObject([("sticker_packs", [])])) }
        let packID = cover.id.withWorker(2).json
        let pack = JSONObject([
            ("id", packID), ("sku_id", cover.id.withWorker(3).json),
            ("name", "Porch Pals"), ("description", "Little friends for every mood"),
            ("stickers", .array(standardStickers.enumerated().map { index, sticker in
                renderSticker(sticker, guildID: nil).merging(["pack_id": packID, "sort_value": .int(index)])
            })),
            ("cover_sticker_id", cover.id.json), ("banner_asset_id", cover.id.withWorker(4).json),
        ])
        return .object(JSONObject([("sticker_packs", [.object(pack)])]))
    }

    // MARK: Soundboard

    /// Discord's default sounds, available to everyone. IDs are small numbers, as Discord's are.
    static let defaultSounds: [(name: String, emoji: String)] = [
        ("quack", "🦆"), ("airhorn", "🔊"), ("cricket", "🦗"), ("golf clap", "⛳"), ("sad horn", "🎺"), ("ba dum tss", "🥁"),
    ]

    func defaultSoundboardSounds() -> [JSON] {
        Self.defaultSounds.enumerated().map { index, sound in
            storeSoundMedia(String(index + 1), seed: UInt64(index + 1))
            return .object(JSONObject([
                ("name", .string(sound.name)), ("sound_id", .string(String(index + 1))), ("volume", 1),
                ("emoji_id", .null), ("emoji_name", .string(sound.emoji)), ("available", true),
            ]))
        }
    }

    /// SOUNDBOARD_SOUNDS for op 31, for servers the viewer belongs to.
    func renderSoundboardSounds(guildID: Snowflake, viewer: Snowflake) -> JSON? {
        guard let guild = guilds[guildID], guild.members[viewer] != nil else { return nil }
        return .object(JSONObject([
            ("guild_id", guildID.json),
            ("soundboard_sounds", .array(guild.soundboardSounds.map { .object(renderSoundboardSound($0, in: guild)) })),
        ]))
    }

    func renderSoundboardSound(_ sound: SoundboardSound, in guild: Guild) -> JSONObject {
        storeSoundMedia(sound.id.description, seed: sound.id.rawValue)
        return JSONObject([
            ("available", true), ("emoji_id", .null), ("emoji_name", .optional(sound.emojiName)), ("guild_id", guild.id.json),
            ("name", .string(sound.name)), ("sound_id", sound.id.json), ("user_id", sound.userID?.json ?? guild.ownerID.json),
            ("volume", .double(sound.volume)),
        ])
    }

    private func storeSoundMedia(_ id: String, seed: UInt64) {
        let path = "/soundboard-sounds/\(id)"
        guard media[path] == nil, lazyMedia[path] == nil else { return }
        storeLazyMedia(path) { (Self.chirpWAV(seed: seed), "audio/wav") }
    }

    /// A short rising chirp, distinct per sound, as 16-bit mono PCM WAV.
    nonisolated static func chirpWAV(seed: UInt64, seconds: Double = 0.6, rate: Int = 22_050) -> Data {
        let count = Int(seconds * Double(rate))
        let base = 330.0 + Double(seed % 7) * 70
        var samples = Data(capacity: count * 2)
        var phase = 0.0
        for index in 0 ..< count {
            let progress = Double(index) / Double(count)
            phase += 2 * .pi * base * (1 + progress) / Double(rate)
            let value = Int16(sin(phase) * (1 - progress) * 12_000)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        return wav + samples
    }
}
