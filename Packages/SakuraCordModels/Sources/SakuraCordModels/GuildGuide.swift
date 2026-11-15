import Foundation

/// Live Server Guide configuration, separate from pre-join questions and screening.
public struct GuildGuide: Decodable, Equatable, Sendable {
    public var guildID: GuildID
    public var enabled: Bool
    public var welcomeMessage: WelcomeMessage
    public var newMemberActions: [GuildGuideChannel]
    public var resourceChannels: [GuildGuideChannel]

    public func isResourceChannel(_ channelID: ChannelID) -> Bool {
        resourceChannels.contains { $0.channelID == channelID }
    }

    public struct WelcomeMessage: Decodable, Equatable, Sendable {
        public var authorIDs: [UserID]
        public var message: String
        enum CodingKeys: String, CodingKey { case authorIDs = "author_ids", message }
    }
    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id", enabled, welcomeMessage = "welcome_message"
        case newMemberActions = "new_member_actions", resourceChannels = "resource_channels"
    }
}

public struct GuildGuideChannel: Decodable, Identifiable, Equatable, Sendable {
    public var id: ChannelID { channelID }
    public var channelID: ChannelID
    public var title: String
    public var description: String?
    public var actionType: Int?
    public var emoji: GuildOnboardingOption.Emoji?
    public var icon: String?

    public var iconURL: URL? {
        icon.flatMap { DiscordCDN.guildGuideIcon(channelID, hash: $0, isNewMemberAction: actionType != nil) }
    }
    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id", actionType = "action_type", title, description, emoji, icon
    }
}

public struct GuildGuideProgress: Decodable, Equatable, Sendable {
    public var guildID: GuildID
    public var userID: UserID
    public var channelActions: [String: Action]
    public init(guildID: GuildID, userID: UserID, channelActions: [String: Action] = [:]) {
        self.guildID = guildID
        self.userID = userID
        self.channelActions = channelActions
    }
    public struct Action: Decodable, Equatable, Sendable { public var completed: Bool }
    public func isCompleted(_ channelID: ChannelID) -> Bool { channelActions[channelID.description]?.completed == true }
    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id", userID = "user_id", channelActions = "channel_actions"
    }
}
