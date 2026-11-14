/// Discord's numeric channel types.
public enum DiscordChannelType {
    public static let text = 0
    public static let directMessage = 1
    public static let voice = 2
    public static let groupDirectMessage = 3
    public static let category = 4
    public static let announcement = 5
    /// `GUILD_STORE`.
    public static let store = 6
    public static let announcementThread = 10
    public static let publicThread = 11
    public static let privateThread = 12
    public static let stageVoice = 13
    public static let forum = 15
    public static let media = 16
    public static let threads = announcementThread ... privateThread
}

public extension ChannelKindValue {
    /// The local kind for a Discord channel type. Stage channels join voice,
    /// media channels share the forum surface, and other types read as text.
    init(discordChannelType type: Int) {
        self = switch type {
        case DiscordChannelType.directMessage: .directMessage
        case DiscordChannelType.groupDirectMessage: .groupDirectMessage
        case DiscordChannelType.voice, DiscordChannelType.stageVoice: .voice
        case DiscordChannelType.announcement: .announcement
        case DiscordChannelType.forum, DiscordChannelType.media: .forum
        default: .text
        }
    }
}

public extension Channel {
    /// Discord's type for the channel's kind; nil when the kind is unknown.
    var discordChannelType: Int? {
        switch kind {
        case .text: DiscordChannelType.text
        case .directMessage: DiscordChannelType.directMessage
        case .voice: DiscordChannelType.voice
        case .groupDirectMessage: DiscordChannelType.groupDirectMessage
        case .announcement: DiscordChannelType.announcement
        case .forum: DiscordChannelType.forum
        case .unknown: nil
        }
    }
}
