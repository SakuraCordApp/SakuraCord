public struct VoiceParticipantState: Equatable, Sendable {
    public var userID: UserID
    public var channelID: ChannelID?
    public var guildID: GuildID?
    public var sessionID: String
    public var isMuted: Bool
    public var isDeafened: Bool
    public var isSelfMuted: Bool
    public var isSelfDeafened: Bool
    public var isSuppressed: Bool
    public var isStreaming: Bool
    public var isVideoEnabled: Bool

    public init(
        userID: UserID,
        channelID: ChannelID?,
        guildID: GuildID?,
        sessionID: String,
        isMuted: Bool = false,
        isDeafened: Bool = false,
        isSelfMuted: Bool = false,
        isSelfDeafened: Bool = false,
        isSuppressed: Bool = false,
        isStreaming: Bool = false,
        isVideoEnabled: Bool = false
    ) {
        self.userID = userID
        self.channelID = channelID
        self.guildID = guildID
        self.sessionID = sessionID
        self.isMuted = isMuted
        self.isDeafened = isDeafened
        self.isSelfMuted = isSelfMuted
        self.isSelfDeafened = isSelfDeafened
        self.isSuppressed = isSuppressed
        self.isStreaming = isStreaming
        self.isVideoEnabled = isVideoEnabled
    }
}
