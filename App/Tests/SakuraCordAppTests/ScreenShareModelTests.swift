@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `application stream lifecycle remains independent from the voice channel`() {
    let model = AppModel(launchMode: .offlineTesting)
    let key = ApplicationStreamKey(
        type: .guild,
        guildID: GuildID(rawValue: 10),
        channelID: ChannelID(rawValue: 20),
        ownerID: UserID(rawValue: 30)
    )
    let stream = ApplicationStream(key: key, region: "eu-central")

    model.consumeApplicationStreamChanged(stream)

    #expect(model.applicationStreams[key] == stream)
    #expect(model.applicationStreamStates[key] == .available)
    #expect(model.activeVoiceChannel == nil)

    model.applicationStreamStates[key] = .watching
    model.consumeApplicationStreamDeleted(
        key: key,
        unavailable: true,
        reason: "Source unavailable"
    )

    #expect(model.applicationStreams[key] == stream)
    #expect(model.applicationStreamStates[key] == .reconnecting)
    #expect(model.activeVoiceChannel == nil)

    model.consumeApplicationStreamDeleted(key: key, unavailable: false, reason: nil)

    #expect(model.applicationStreams[key] == nil)
    #expect(model.applicationStreamStates[key] == nil)
    #expect(model.activeVoiceChannel == nil)
}

@MainActor
@Test func `recoverable stream media errors do not replace successful playback with retry`() {
    let model = AppModel(launchMode: .offlineTesting)
    let key = ApplicationStreamKey(
        type: .guild,
        guildID: GuildID(rawValue: 10),
        channelID: ChannelID(rawValue: 20),
        ownerID: UserID(rawValue: 30)
    )
    model.applicationStreamStates[key] = .watching

    model.consumeApplicationStreamSessionEvent(
        .error("A recoverable packet could not be decoded."),
        key: key
    )

    #expect(model.applicationStreamStates[key] == .watching)

    model.applicationStreamStates[key] = .reconnecting
    model.consumeApplicationStreamSessionEvent(.stateChanged(.connected), key: key)

    #expect(model.applicationStreamStates[key] == .watching)
}

@MainActor
@Test func `hidden stream demand survives connection replacement`() async {
    let model = AppModel(launchMode: .offlineTesting)
    let key = ApplicationStreamKey(
        type: .guild,
        guildID: GuildID(rawValue: 10),
        channelID: ChannelID(rawValue: 20),
        ownerID: UserID(rawValue: 30)
    )
    model.applicationStreamStates[key] = .reconnecting

    await model.setApplicationStreamDemand(false, key: key)

    #expect(model.applicationStreamDemandIntents[key] == ApplicationStreamDemandIntent(
        isEnabled: false,
        pixelCount: nil
    ))

    await model.setApplicationStreamDemand(true, key: key, pixelCount: 921_600)

    #expect(model.applicationStreamDemandIntents[key] == ApplicationStreamDemandIntent(
        isEnabled: true,
        pixelCount: 921_600
    ))
}
