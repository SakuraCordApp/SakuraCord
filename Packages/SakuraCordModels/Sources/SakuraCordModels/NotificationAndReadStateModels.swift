import Foundation

public enum MessageNotificationLevel: Int, Codable, Hashable, Sendable {
    case allMessages = 0
    case onlyMentions = 1
    case nothing = 2
    case inherit = 3
}

public struct DiscordMuteConfiguration: Codable, Hashable, Sendable {
    public var endTime: Date?

    public init(endTime: Date? = nil) {
        self.endTime = endTime
    }

    public func isActive(at date: Date = .now) -> Bool {
        endTime.map { $0 > date } ?? true
    }
}

public struct ThreadNotificationSettings: Codable, Hashable, Sendable {
    public static let hasInteractedFlag: UInt64 = 1 << 0
    public static let allMessagesFlag: UInt64 = 1 << 1
    public static let onlyMentionsFlag: UInt64 = 1 << 2
    public static let noMessagesFlag: UInt64 = 1 << 3
    public static let notificationFlagsMask =
        allMessagesFlag | onlyMentionsFlag | noMessagesFlag

    public var flags: UInt64
    public var isMuted: Bool
    public var muteConfiguration: DiscordMuteConfiguration?

    public init(
        flags: UInt64 = 0,
        isMuted: Bool = false,
        muteConfiguration: DiscordMuteConfiguration? = nil
    ) {
        self.flags = flags
        self.isMuted = isMuted
        self.muteConfiguration = muteConfiguration
    }

    public var notificationLevel: MessageNotificationLevel {
        if flags & Self.allMessagesFlag != 0 { return .allMessages }
        if flags & Self.onlyMentionsFlag != 0 { return .onlyMentions }
        if flags & Self.noMessagesFlag != 0 { return .nothing }
        return .inherit
    }

    public func flags(setting level: MessageNotificationLevel) -> UInt64 {
        let retained = flags & ~Self.notificationFlagsMask
        switch level {
        case .allMessages: return retained | Self.allMessagesFlag
        case .onlyMentions: return retained | Self.onlyMentionsFlag
        case .nothing: return retained | Self.noMessagesFlag
        case .inherit: return retained
        }
    }
}

public struct ChannelNotificationOverride: Codable, Hashable, Sendable {
    // Discord's FAVORITED bit on an @me channel override pins a DM in the inbox.
    public static let pinnedDirectMessageFlag: UInt64 = 1 << 11

    public var channelID: ChannelID
    public var messageNotifications: MessageNotificationLevel
    public var isMuted: Bool
    public var muteConfiguration: DiscordMuteConfiguration?
    public var flags: UInt64
    public var isCollapsed: Bool?

    public init(
        channelID: ChannelID,
        messageNotifications: MessageNotificationLevel = .inherit,
        isMuted: Bool = false,
        muteConfiguration: DiscordMuteConfiguration? = nil,
        flags: UInt64 = 0,
        isCollapsed: Bool? = nil
    ) {
        self.channelID = channelID
        self.messageNotifications = messageNotifications
        self.isMuted = isMuted
        self.muteConfiguration = muteConfiguration
        self.flags = flags
        self.isCollapsed = isCollapsed
    }

    public var isPinnedDirectMessage: Bool {
        flags & Self.pinnedDirectMessageFlag != 0
    }

    public func flags(settingPinnedDirectMessage isPinned: Bool) -> UInt64 {
        isPinned
            ? flags | Self.pinnedDirectMessageFlag
            : flags & ~Self.pinnedDirectMessageFlag
    }
}

public struct ChannelReadState: Codable, Hashable, Sendable {
    public var channelID: ChannelID
    public var lastAcknowledgedMessageID: MessageID?
    public var mentionCount: Int
    public var isManual: Bool
    public var flags: UInt64?
    public var lastViewed: Int?
    public var version: Int?

    public init(
        channelID: ChannelID,
        lastAcknowledgedMessageID: MessageID?,
        mentionCount: Int = 0,
        isManual: Bool = false,
        flags: UInt64? = nil,
        lastViewed: Int? = nil,
        version: Int? = nil
    ) {
        self.channelID = channelID
        self.lastAcknowledgedMessageID = lastAcknowledgedMessageID
        self.mentionCount = max(0, mentionCount)
        self.isManual = isManual
        self.flags = flags
        self.lastViewed = lastViewed
        self.version = version
    }
}

public struct ReadAcknowledgementResponse: Codable, Equatable, Sendable {
    public var token: String?

    public init(token: String? = nil) {
        self.token = token
    }
}

public struct BulkReadStateAcknowledgement: Codable, Equatable, Sendable {
    public var readStateType: Int
    public var channelID: ChannelID
    public var messageID: MessageID

    public init(channelID: ChannelID, messageID: MessageID, readStateType: Int = 0) {
        self.readStateType = readStateType
        self.channelID = channelID
        self.messageID = messageID
    }

    private enum CodingKeys: String, CodingKey { case channelID, messageID, readStateType }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try values.decode(ChannelID.self, forKey: .channelID)
        messageID = try values.decode(MessageID.self, forKey: .messageID)
        readStateType = try values.decodeIfPresent(Int.self, forKey: .readStateType) ?? 0
    }
}
