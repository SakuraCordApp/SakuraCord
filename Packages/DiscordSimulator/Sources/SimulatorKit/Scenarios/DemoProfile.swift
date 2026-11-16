import Foundation

/// Profile and expression state: the Garden's server tag, the Porch's own
/// soundboard, and the avatars Wren used before the current one.
extension DemoConverter {
    mutating func addProfileState(me: Snowflake) async throws {
        let wren = try await world.user(me)
        if let gardenID = wren.primaryGuild?["identity_guild_id"]?.stringValue.flatMap(Snowflake.init),
           let tag = wren.primaryGuild?["tag"]?.stringValue, let badge = wren.primaryGuild?["badge"]?.stringValue,
           var garden = try? await world.guild(gardenID) {
            garden.serverTag = (tag, badge)
            await world.addGuild(garden)
        }
        if let porchID = guildKeys.first(where: { $0.value == "porch" })?.key, var porch = try? await world.guild(porchID) {
            let sounds = [("doorbell", "🔔"), ("kettle's on", "🫖"), ("ribbit", "🐸"), ("drum fill", "🥁")]
            let uploaders = ["hana", "tomas", "nico", "sam"]
            for (index, sound) in sounds.enumerated() {
                let id = await world.nextID(at: world.epoch.addingTimeInterval(Double(-30 + index) * 86_400))
                porch.soundboardSounds.append(SoundboardSound(id: id, name: sound.0, emojiName: sound.1, userID: people[uploaders[index]]))
            }
            await world.addGuild(porch)
        }
        // Two earlier avatars, then the current one, so the picker lists them newest first.
        for (days, seed) in [(210, 0xA7A2), (40, 0xA7A1)] {
            let hash = builder.hash(seed: UInt64(seed))
            await world.registerAsset(hash, palette: seed % 12)
            await world.recordAvatar(hash, of: me, description: days == 40 ? "garden selfie" : nil,
                                     at: world.epoch.addingTimeInterval(Double(-days) * 86_400))
        }
        if let current = wren.avatar { await world.recordAvatar(current, of: me, description: nil, at: world.epoch.addingTimeInterval(-12 * 86_400)) }
    }
}
