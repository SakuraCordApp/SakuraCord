public struct PrivateCallRing: Equatable, Hashable, Sendable {
    public var recipientID: UserID
    public var senderID: UserID

    public init(recipientID: UserID, senderID: UserID) {
        self.recipientID = recipientID
        self.senderID = senderID
    }
}

/// Discord's app-wide state for an active direct-message or group-DM call.
///
/// `voiceStates` is nil on partial CALL_UPDATE payloads. Callers should retain
/// the last complete participant snapshot until individual VOICE_STATE_UPDATE
/// events reconcile it.
public struct PrivateCall: Equatable, Sendable {
    public var channelID: ChannelID
    public var messageID: MessageID?
    public var region: String?
    public var ongoingRings: [PrivateCallRing]
    public var voiceStates: [VoiceParticipantState]?
    public var isUnavailable: Bool

    public init(
        channelID: ChannelID,
        messageID: MessageID? = nil,
        region: String? = nil,
        ongoingRings: [PrivateCallRing] = [],
        voiceStates: [VoiceParticipantState]? = nil,
        isUnavailable: Bool = false
    ) {
        self.channelID = channelID
        self.messageID = messageID
        self.region = region
        self.ongoingRings = ongoingRings
        self.voiceStates = voiceStates
        self.isUnavailable = isUnavailable
    }

    public func isRinging(_ userID: UserID) -> Bool {
        ongoingRings.contains { $0.recipientID == userID }
    }
}
