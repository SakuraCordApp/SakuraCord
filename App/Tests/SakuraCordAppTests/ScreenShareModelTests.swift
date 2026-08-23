@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `only remote streams in connected one-to-one calls are automatically watched`() {
    let model = AppModel(launchMode: .offlineTesting)
    let currentUser = User(
        id: UserID(rawValue: 10),
        username: "current",
        displayName: "Current User"
    )
    let recipient = User(
        id: UserID(rawValue: 20),
        username: "recipient",
        displayName: "Recipient"
    )
    let directMessage = Channel(
        id: ChannelID(rawValue: 30),
        guildID: nil,
        name: "Recipient",
        kind: .directMessage,
        recipients: [recipient]
    )
    let remoteKey = ApplicationStreamKey(
        type: .call,
        guildID: nil,
        channelID: directMessage.id,
        ownerID: recipient.id
    )
    let localKey = ApplicationStreamKey(
        type: .call,
        guildID: nil,
        channelID: directMessage.id,
        ownerID: currentUser.id
    )

    model.snapshot = BootstrapSnapshot(
        currentUser: currentUser,
        guilds: [],
        channels: [directMessage],
        members: []
    )
    model.activeVoiceChannel = directMessage
    model.voiceSessionState = .connected
    model.voiceStates[recipient.id] = VoiceParticipantState(
        userID: recipient.id,
        channelID: directMessage.id,
        guildID: nil,
        sessionID: "recipient-session",
        isStreaming: true
    )

    #expect(model.shouldAutomaticallyWatchApplicationStream(remoteKey))
    #expect(!model.shouldAutomaticallyWatchApplicationStream(localKey))
    #expect(model.applicationStreamKeys(in: directMessage) == [remoteKey])

    model.manuallyStoppedApplicationStreamKeys.insert(remoteKey)
    #expect(!model.shouldAutomaticallyWatchApplicationStream(remoteKey))

    model.reconcileApplicationStreamWatchSuppression(for: VoiceParticipantState(
        userID: recipient.id,
        channelID: directMessage.id,
        guildID: nil,
        sessionID: "recipient-session",
        isStreaming: false
    ))
    #expect(model.shouldAutomaticallyWatchApplicationStream(remoteKey))

    var groupMessage = directMessage
    groupMessage.kind = .groupDirectMessage
    model.activeVoiceChannel = groupMessage

    #expect(!model.shouldAutomaticallyWatchApplicationStream(remoteKey))
}

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

@MainActor
@Test func `screen share sound policy prioritizes stream lifecycle`() {
    let channelID = ChannelID(rawValue: 20)
    let remoteUserID = UserID(rawValue: 30)
    let currentUserID = UserID(rawValue: 40)
    let connected = VoiceParticipantState(
        userID: remoteUserID,
        channelID: channelID,
        guildID: GuildID(rawValue: 10),
        sessionID: "remote-session"
    )
    var streaming = connected
    streaming.isStreaming = true

    #expect(VoiceStateSoundPolicy.effects(
        previous: connected,
        current: streaming,
        activeChannelID: channelID,
        currentUserID: currentUserID
    ) == [.streamStarted])
    #expect(VoiceStateSoundPolicy.effects(
        previous: streaming,
        current: connected,
        activeChannelID: channelID,
        currentUserID: currentUserID
    ) == [.streamEnded])

    var departed = streaming
    departed.channelID = nil
    #expect(VoiceStateSoundPolicy.effects(
        previous: streaming,
        current: departed,
        activeChannelID: channelID,
        currentUserID: currentUserID
    ) == [.streamEnded])
    #expect(VoiceStateSoundPolicy.effects(
        previous: connected,
        current: streaming,
        activeChannelID: channelID,
        currentUserID: remoteUserID
    ).isEmpty)
}

@MainActor
@Test func `single active screen share announces viewer count changes`() {
    let sounds = RecordingAppSoundPlayer()
    let model = AppModel(launchMode: .offlineTesting, soundPlayer: sounds)
    let channel = Channel(
        id: ChannelID(rawValue: 20),
        guildID: GuildID(rawValue: 10),
        name: "Voice",
        kind: .voice
    )
    let key = ApplicationStreamKey(
        type: .guild,
        guildID: channel.guildID,
        channelID: channel.id,
        ownerID: UserID(rawValue: 30)
    )
    model.activeVoiceChannel = channel

    model.consumeApplicationStreamChanged(ApplicationStream(key: key))
    #expect(sounds.played.isEmpty)

    model.consumeApplicationStreamChanged(ApplicationStream(
        key: key,
        viewerIDs: [UserID(rawValue: 40)]
    ))
    #expect(sounds.played == [.streamUserJoined])

    model.consumeApplicationStreamChanged(ApplicationStream(key: key))
    #expect(sounds.played == [.streamUserJoined, .streamUserLeft])
}
