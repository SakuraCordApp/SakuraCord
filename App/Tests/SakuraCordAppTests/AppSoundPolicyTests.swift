import SakuraCordModels
@testable import SakuraCord
import Testing

@Test func `every app sound has a nonempty packaged resource`() throws {
    for effect in AppSoundEffect.allCases {
        let url = try #require(effect.resourceURL)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        #expect((values.fileSize ?? 0) > 0, "Missing audio data for \(effect.rawValue)")
    }
}

@MainActor
final class RecordingAppSoundPlayer: AppSoundPlaying {
    private(set) var played: [AppSoundEffect] = []
    private(set) var looping: [AppSoundEffect: Bool] = [:]
    private(set) var stopAllCount = 0

    func play(_ effect: AppSoundEffect) {
        played.append(effect)
    }

    func setLooping(_ effect: AppSoundEffect, active: Bool) {
        looping[effect] = active
    }

    func stopAll() {
        stopAllCount += 1
        looping = [:]
    }
}

@Test func `voice state sound policy covers remote join leave mute deafen and camera`() {
    let channelID = ChannelID(rawValue: 100)
    let userID = UserID(rawValue: 200)
    let currentUserID = UserID(rawValue: 201)
    let joined = voiceState(userID: userID, channelID: channelID)

    #expect(
        VoiceStateSoundPolicy.effects(
            previous: nil,
            current: joined,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.userJoin]
    )

    var muted = joined
    muted.isSelfMuted = true
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: joined,
            current: muted,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.mute]
    )

    var unmuted = muted
    unmuted.isSelfMuted = false
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: muted,
            current: unmuted,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.unmute]
    )

    var deafened = joined
    deafened.isSelfMuted = true
    deafened.isSelfDeafened = true
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: joined,
            current: deafened,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.deafen]
    )

    var undeafened = deafened
    undeafened.isSelfMuted = false
    undeafened.isSelfDeafened = false
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: deafened,
            current: undeafened,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.undeafen]
    )

    var cameraOn = joined
    cameraOn.isVideoEnabled = true
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: joined,
            current: cameraOn,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.cameraOn]
    )
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: cameraOn,
            current: joined,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.cameraOff]
    )

    var left = joined
    left.channelID = nil
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: joined,
            current: left,
            activeChannelID: channelID,
            currentUserID: currentUserID
        ) == [.userLeave]
    )
}

@Test func `voice state sound policy ignores self echoes and unrelated channels`() {
    let activeChannelID = ChannelID(rawValue: 100)
    let otherChannelID = ChannelID(rawValue: 101)
    let currentUserID = UserID(rawValue: 200)
    let selfState = voiceState(
        userID: currentUserID,
        channelID: activeChannelID,
        isSelfMuted: true
    )
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: nil,
            current: selfState,
            activeChannelID: activeChannelID,
            currentUserID: currentUserID
        ).isEmpty
    )

    let remoteState = voiceState(
        userID: UserID(rawValue: 201),
        channelID: otherChannelID
    )
    #expect(
        VoiceStateSoundPolicy.effects(
            previous: nil,
            current: remoteState,
            activeChannelID: activeChannelID,
            currentUserID: currentUserID
        ).isEmpty
    )
}

@Test func `private call sound state distinguishes incoming outgoing and active calls`() {
    let currentUserID = UserID(rawValue: 1)
    let otherUserID = UserID(rawValue: 2)
    let incomingChannelID = ChannelID(rawValue: 10)
    let outgoingChannelID = ChannelID(rawValue: 11)
    let calls = [
        PrivateCall(
            channelID: incomingChannelID,
            ongoingRings: [
                PrivateCallRing(
                    recipientID: currentUserID,
                    senderID: otherUserID
                )
            ]
        ),
        PrivateCall(
            channelID: outgoingChannelID,
            ongoingRings: [
                PrivateCallRing(
                    recipientID: otherUserID,
                    senderID: currentUserID
                )
            ]
        ),
    ]

    #expect(
        PrivateCallSoundState.make(
            calls: calls,
            currentUserID: currentUserID,
            activeChannelID: outgoingChannelID,
            locallyStartedOutgoingChannelIDs: []
        ) == PrivateCallSoundState(
            ringsIncoming: true,
            ringsOutgoing: true
        )
    )
    #expect(
        PrivateCallSoundState.make(
            calls: calls,
            currentUserID: currentUserID,
            activeChannelID: incomingChannelID,
            locallyStartedOutgoingChannelIDs: []
        ) == PrivateCallSoundState()
    )
    #expect(
        PrivateCallSoundState.make(
            calls: [],
            currentUserID: currentUserID,
            activeChannelID: outgoingChannelID,
            locallyStartedOutgoingChannelIDs: [outgoingChannelID]
        ).ringsOutgoing
    )
}

private func voiceState(
    userID: UserID,
    channelID: ChannelID?,
    isSelfMuted: Bool = false
) -> VoiceParticipantState {
    VoiceParticipantState(
        userID: userID,
        channelID: channelID,
        guildID: GuildID(rawValue: 300),
        sessionID: "session-\(userID)",
        isSelfMuted: isSelfMuted
    )
}
