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

/// Settings Discord can mute, optionally until a set time.
public protocol DiscordMutableSettings {
    var isMuted: Bool { get set }
    var muteConfiguration: DiscordMuteConfiguration? { get set }
}

public extension DiscordMutableSettings {
    /// Muted, by a mute that has not ended at `date`.
    func isActivelyMuted(at date: Date = .now) -> Bool {
        isMuted && (muteConfiguration?.isActive(at: date) ?? true)
    }

    /// The mute in effect at `date`, untimed when it has no end; nil when not muted.
    func activeMute(at date: Date) -> DiscordMuteConfiguration? {
        guard isMuted else { return nil }
        let mute = muteConfiguration ?? DiscordMuteConfiguration()
        return mute.isActive(at: date) ? mute : nil
    }

    /// Mutes until `endTime`, or indefinitely without one, or unmutes.
    mutating func setMuted(_ isMuted: Bool, until endTime: Date?) {
        self.isMuted = isMuted
        muteConfiguration = isMuted ? DiscordMuteConfiguration(endTime: endTime) : nil
    }
}

extension ThreadNotificationSettings: DiscordMutableSettings {}
extension ChannelNotificationOverride: DiscordMutableSettings {}
extension GuildNotificationSettings: DiscordMutableSettings {}

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
    /// The current account's `join_timestamp`. Discord orders sidebar threads
    /// by it, newest join first.
    public var joinedAt: Date?

    public init(
        flags: UInt64 = 0,
        isMuted: Bool = false,
        muteConfiguration: DiscordMuteConfiguration? = nil,
        joinedAt: Date? = nil
    ) {
        self.flags = flags
        self.isMuted = isMuted
        self.muteConfiguration = muteConfiguration
        self.joinedAt = joinedAt
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
    public static let unreadOnlyMentionsFlag: UInt64 = 1 << 9
    public static let unreadAllMessagesFlag: UInt64 = 1 << 10
    // Discord's FAVORITED bit pins a DM in the inbox (@me override) or a server
    // channel to the top of its channel list (guild override).
    public static let pinnedFlag: UInt64 = 1 << 11
    /// Shows the channel in a server that has opted out of showing all channels.
    public static let optInFlag: UInt64 = 1 << 12
    public static let newForumThreadsOffFlag: UInt64 = 1 << 13
    public static let newForumThreadsOnFlag: UInt64 = 1 << 14

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

    public var isPinned: Bool {
        flags & Self.pinnedFlag != 0
    }

    public func flags(settingPinned isPinned: Bool) -> UInt64 {
        isPinned
            ? flags | Self.pinnedFlag
            : flags & ~Self.pinnedFlag
    }
}

public struct ChannelReadState: Codable, Hashable, Sendable {
    /// Discord's `IS_MENTION_LOW_IMPORTANCE` read-state flag.
    public static let lowImportanceMentionFlag: UInt64 = 1 << 2

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
