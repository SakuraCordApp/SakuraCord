import Foundation

/// Playing a soundboard sound in voice: everyone connected to the channel gets
/// VOICE_CHANNEL_EFFECT_SEND and plays the sound themselves from the CDN, as
/// captured from the official client.
public extension World {
    func playSoundboardSound(_ soundID: String, in channelID: Snowflake, by userID: Snowflake,
                             emojiID: Snowflake? = nil, emojiName: String? = nil) async throws {
        let channel = try channel(channelID)
        guard voice.states[userID]?.channelID == channelID else { throw WorldError.missingPermissions }
        if !channel.type.isPrivate { try require([.speak, .useSoundboard], userID, channel) }
        let sound: SoundboardSound
        if let index = Int(soundID), Self.defaultSounds.indices.contains(index - 1) {
            let preset = Self.defaultSounds[index - 1]
            sound = SoundboardSound(id: Snowflake(UInt64(index)), name: preset.name, emojiName: preset.emoji)
        } else if let id = Snowflake(soundID), let match = guilds(of: userID).lazy.flatMap(\.soundboardSounds).first(where: { $0.id == id }) {
            sound = match
        } else {
            throw WorldError.unknown("Sound", code: 10_097)
        }
        // Default sounds' small IDs and whole volumes go out as integers, as captured.
        let isDefault = sound.id.rawValue <= UInt64(Self.defaultSounds.count)
        let name = emojiName ?? sound.emojiName
        let emoji: JSON = emojiID != nil || name != nil
            ? .object(JSONObject([("animated", false), ("id", emojiID?.json ?? .null), ("name", .optional(name))]))
            : .null
        await emit("VOICE_CHANNEL_EFFECT_SEND", .object(JSONObject([
            ("animation_id", 0), ("animation_type", "VOICE_CHANNEL_EFFECT_ANIMATION_TYPE_BASIC"), ("channel_id", channelID.json),
            ("emoji", emoji), ("guild_id", channel.guildID?.json ?? .null), ("sound_id", isDefault ? .int(Int64(sound.id.rawValue)) : sound.id.json),
            ("sound_volume", sound.volume == sound.volume.rounded() ? .int(Int64(sound.volume)) : .double(sound.volume)), ("user_id", userID.json),
        ])), to: .users(Set(voiceStates(in: channelID).map(\.userID))))
    }
}
