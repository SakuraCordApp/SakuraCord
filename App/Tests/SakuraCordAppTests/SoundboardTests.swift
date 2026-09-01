import SakuraCordModels
import Testing
@testable import SakuraCord

private let allSoundboardPermissions = DiscordPermissionBits.speak
    | DiscordPermissionBits.useSoundboard
    | DiscordPermissionBits.useExternalSounds

@Test func `soundboard picker matches Discord favorite and frequent presentation`() {
    let sounds = [
        SoundboardSound(id: "2", name: "Two", isAvailable: false),
        SoundboardSound(id: "3", name: "Three"),
        SoundboardSound(id: "4", name: "Four"),
        SoundboardSound(id: "9", name: "Nine"),
        SoundboardSound(id: "700", name: "Seven Hundred"),
        SoundboardSound(id: "900", name: "Nine Hundred", isAvailable: false),
    ]
    let soundsByID = Dictionary(uniqueKeysWithValues: sounds.map { ($0.id, $0) })

    let favorites = SoundboardPickerContentPolicy.favoriteSounds(
        ids: ["900", "3", "700", "2"],
        soundsByID: soundsByID
    )
    #expect(favorites.map(\.id) == ["3", "700", "2", "900"])

    let frequent = SoundboardPickerContentPolicy.frequentlyUsedSounds(
        ids: ["9", "2", "missing", "3", "4"],
        favoriteIDs: ["9"],
        soundsByID: soundsByID
    )
    #expect(frequent.map(\.id) == ["2", "3"])
}

@Test func `soundboard route keeps defaults and same server sounds native`() {
    let guild = GuildID(rawValue: 1)
    #expect(SoundboardPlaybackPolicy.route(
        for: SoundboardSound(id: "1", name: "Default"),
        activeGuildID: guild,
        premiumType: 0,
        effectivePermissions: allSoundboardPermissions,
        voiceState: nil
    ) == .native)
    #expect(SoundboardPlaybackPolicy.route(
        for: SoundboardSound(id: "2", name: "Local", guildID: guild),
        activeGuildID: guild,
        premiumType: 0,
        effectivePermissions: allSoundboardPermissions,
        voiceState: nil
    ) == .native)
}

@Test func `cross server sound uses Nitro native route or isolated outgoing mixer`() {
    let active = GuildID(rawValue: 1)
    let sound = SoundboardSound(
        id: "2",
        name: "External",
        guildID: GuildID(rawValue: 2)
    )
    #expect(SoundboardPlaybackPolicy.route(
        for: sound,
        activeGuildID: active,
        premiumType: 2,
        effectivePermissions: allSoundboardPermissions,
        voiceState: nil
    ) == .native)
    #expect(SoundboardPlaybackPolicy.route(
        for: sound,
        activeGuildID: active,
        premiumType: 0,
        effectivePermissions: allSoundboardPermissions,
        voiceState: nil
    ) == .outgoingMixer)
}

@Test func `soundboard permissions and server voice restrictions fail closed without blocking self mute`() {
    let userID = UserID(rawValue: 9)
    let channelID = ChannelID(rawValue: 3)
    let guildID = GuildID(rawValue: 1)
    let sound = SoundboardSound(id: "1", name: "Default")
    #expect(SoundboardPlaybackPolicy.route(
        for: sound,
        activeGuildID: guildID,
        premiumType: 2,
        effectivePermissions: DiscordPermissionBits.speak,
        voiceState: nil
    ) == nil)
    let selfMuted = VoiceParticipantState(
        userID: userID,
        channelID: channelID,
        guildID: guildID,
        sessionID: "session",
        isSelfMuted: true
    )
    #expect(SoundboardPlaybackPolicy.route(
        for: sound,
        activeGuildID: guildID,
        premiumType: 0,
        effectivePermissions: allSoundboardPermissions,
        voiceState: selfMuted
    ) == .native)
    var restricted = selfMuted
    restricted.isMuted = true
    #expect(SoundboardPlaybackPolicy.route(
        for: sound,
        activeGuildID: guildID,
        premiumType: 0,
        effectivePermissions: allSoundboardPermissions,
        voiceState: restricted
    ) == nil)
    restricted.isMuted = false
    restricted.isSuppressed = true
    #expect(SoundboardPlaybackPolicy.route(
        for: sound,
        activeGuildID: guildID,
        premiumType: 0,
        effectivePermissions: allSoundboardPermissions,
        voiceState: restricted
    ) == nil)
}

@Test func `incoming sound effect resolves uncatalogued cross server audio by ID`() {
    let known = SoundboardSound(id: "1", name: "Known", volume: 0.5)
    let resolvedKnown = SoundboardEffectPlaybackPolicy.sound(
        withID: "1",
        in: [known]
    )
    #expect(resolvedKnown == known)

    let unknown = SoundboardEffectPlaybackPolicy.sound(
        withID: "900000000000000001",
        in: [known]
    )
    #expect(unknown.id == "900000000000000001")
    #expect(unknown.mediaURL?.absoluteString ==
        "https://cdn.discordapp.com/soundboard-sounds/900000000000000001")

    let effect = VoiceChannelEffect(
        channelID: ChannelID(rawValue: 3),
        guildID: GuildID(rawValue: 1),
        userID: UserID(rawValue: 9),
        soundID: unknown.id,
        soundVolume: 0.35
    )
    #expect(SoundboardEffectPlaybackPolicy.volume(for: effect) == 0.35)
}
