import Foundation

public struct Nameplate: Codable, Hashable, Sendable {
    public var staticURL: URL?
    public var animatedURL: URL?
    public var label: String
    public var palette: String

    public init(
        staticURL: URL? = nil, animatedURL: URL? = nil, label: String = "", palette: String = "none"
    ) {
        self.staticURL = staticURL
        self.animatedURL = animatedURL
        self.label = label
        self.palette = palette
    }
}

public struct PrimaryGuildIdentity: Codable, Hashable, Sendable {
    public var guildID: GuildID?
    public var tag: String?
    public var badgeURL: URL?

    public init(guildID: GuildID? = nil, tag: String? = nil, badgeURL: URL? = nil) {
        self.guildID = guildID
        self.tag = tag
        self.badgeURL = badgeURL
    }
}

public struct DisplayNameStyle: Codable, Hashable, Sendable {
    public var fontID: Int
    public var effectID: Int
    public var colors: [UInt32]

    public init(fontID: Int = 11, effectID: Int = 1, colors: [UInt32] = []) {
        self.fontID = fontID
        self.effectID = effectID
        self.colors = colors
    }
}

public struct User: Identifiable, Codable, Hashable, Sendable {
    public let id: UserID
    public var username: String
    public var discriminator: String
    public var displayName: String
    public var avatarURL: URL?
    public var isBot: Bool
    public var isSystem: Bool
    public var avatarDecorationURL: URL?
    public var nameplate: Nameplate?
    public var primaryGuild: PrimaryGuildIdentity?
    public var displayNameStyle: DisplayNameStyle?
    public var publicFlags: UInt64
    public var premiumType: Int

    public init(
        id: UserID,
        username: String,
        discriminator: String = "0",
        displayName: String,
        avatarURL: URL? = nil,
        isBot: Bool = false,
        isSystem: Bool = false,
        avatarDecorationURL: URL? = nil,
        nameplate: Nameplate? = nil,
        primaryGuild: PrimaryGuildIdentity? = nil,
        displayNameStyle: DisplayNameStyle? = nil,
        publicFlags: UInt64 = 0,
        premiumType: Int = 0
    ) {
        self.id = id
        self.username = username
        self.discriminator = discriminator
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.isBot = isBot
        self.isSystem = isSystem
        self.avatarDecorationURL = avatarDecorationURL
        self.nameplate = nameplate
        self.primaryGuild = primaryGuild
        self.displayNameStyle = displayNameStyle
        self.publicFlags = publicFlags
        self.premiumType = premiumType
    }

    private enum CodingKeys: String, CodingKey {
        case id, username, discriminator, displayName, avatarURL, isBot, isSystem, avatarDecorationURL, nameplate
        case primaryGuild, displayNameStyle, publicFlags, premiumType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UserID.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? id.description
        discriminator = try container.decodeIfPresent(String.self, forKey: .discriminator) ?? "0"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? username
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        isBot = try container.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
        isSystem = try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        avatarDecorationURL = try container.decodeIfPresent(URL.self, forKey: .avatarDecorationURL)
        nameplate = try container.decodeIfPresent(Nameplate.self, forKey: .nameplate)
        primaryGuild = try container.decodeIfPresent(
            PrimaryGuildIdentity.self, forKey: .primaryGuild)
        displayNameStyle = try container.decodeIfPresent(
            DisplayNameStyle.self, forKey: .displayNameStyle
        )
        publicFlags = try container.decodeIfPresent(UInt64.self, forKey: .publicFlags) ?? 0
        premiumType = try container.decodeIfPresent(Int.self, forKey: .premiumType) ?? 0
    }

    public var tag: String {
        discriminator == "0" ? username : "\(username)#\(discriminator)"
    }
}

public struct Guild: Identifiable, Codable, Hashable, Sendable {
    public let id: GuildID
    public var name: String
    public var iconURL: URL?
    public var accentHex: UInt32
    public var unreadCount: Int
    public var mentionCount: Int
    public var isOwnedByCurrentUser: Bool?
    public var currentUserPermissions: UInt64?
    public var rulesChannelID: ChannelID?
    public var features: Set<String>
    public var defaultMessageNotifications: MessageNotificationLevel
    public var isUnavailable: Bool

    public init(
        id: GuildID, name: String, iconURL: URL? = nil, accentHex: UInt32 = 0x5865F2,
        unreadCount: Int = 0, mentionCount: Int = 0, isOwnedByCurrentUser: Bool? = nil,
        currentUserPermissions: UInt64? = nil, rulesChannelID: ChannelID? = nil,
        features: Set<String> = [],
        defaultMessageNotifications: MessageNotificationLevel = .onlyMentions,
        isUnavailable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.accentHex = accentHex
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.currentUserPermissions = currentUserPermissions
        self.rulesChannelID = rulesChannelID
        self.features = features
        self.defaultMessageNotifications = defaultMessageNotifications
        self.isUnavailable = isUnavailable
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconURL, accentHex, unreadCount, mentionCount, isOwnedByCurrentUser
        case currentUserPermissions, rulesChannelID, features, defaultMessageNotifications
        case isUnavailable
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(GuildID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        iconURL = try values.decodeIfPresent(URL.self, forKey: .iconURL)
        accentHex = try values.decodeIfPresent(UInt32.self, forKey: .accentHex) ?? 0x5865F2
        unreadCount = try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        mentionCount = try values.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0
        isOwnedByCurrentUser = try values.decodeIfPresent(Bool.self, forKey: .isOwnedByCurrentUser)
        currentUserPermissions = try values.decodeIfPresent(UInt64.self, forKey: .currentUserPermissions)
        rulesChannelID = try values.decodeIfPresent(ChannelID.self, forKey: .rulesChannelID)
        features = try values.decodeIfPresent(Set<String>.self, forKey: .features) ?? []
        defaultMessageNotifications =
            try values.decodeIfPresent(MessageNotificationLevel.self, forKey: .defaultMessageNotifications)
                ?? .onlyMentions
        isUnavailable = try values.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false
    }
}

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
}

public struct GuildNotificationSettings: Codable, Hashable, Sendable {
    public var guildID: GuildID?
    public var messageNotifications: MessageNotificationLevel
    public var isMuted: Bool
    public var muteConfiguration: DiscordMuteConfiguration?
    public var suppressEveryone: Bool
    public var suppressRoles: Bool
    public var flags: UInt64
    public var channelOverrides: [ChannelNotificationOverride]

    public init(
        guildID: GuildID?,
        messageNotifications: MessageNotificationLevel = .onlyMentions,
        isMuted: Bool = false,
        muteConfiguration: DiscordMuteConfiguration? = nil,
        suppressEveryone: Bool = false,
        suppressRoles: Bool = false,
        flags: UInt64 = 0,
        channelOverrides: [ChannelNotificationOverride] = []
    ) {
        self.guildID = guildID
        self.messageNotifications = messageNotifications
        self.isMuted = isMuted
        self.muteConfiguration = muteConfiguration
        self.suppressEveryone = suppressEveryone
        self.suppressRoles = suppressRoles
        self.flags = flags
        self.channelOverrides = channelOverrides
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
    public var channelID: ChannelID
    public var messageID: MessageID

    public init(channelID: ChannelID, messageID: MessageID) {
        self.channelID = channelID
        self.messageID = messageID
    }
}

public struct DiscordEmoji: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var isAnimated: Bool
    public var guildID: GuildID
    public var isAvailable: Bool
    public var assetURL: URL?

    public init(
        id: String,
        name: String,
        isAnimated: Bool = false,
        guildID: GuildID,
        isAvailable: Bool = true,
        assetURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
        self.guildID = guildID
        self.isAvailable = isAvailable
        self.assetURL = assetURL
    }

    public var messageToken: String {
        "<\(isAnimated ? "a" : ""):\(name):\(id)>"
    }

    public var reactionToken: String {
        "\(name):\(id)"
    }

    public var imageURL: URL? {
        if let assetURL {
            return assetURL
        }
        return URL(
            string:
            "https://cdn.discordapp.com/emojis/\(id).webp?size=96&animated=\(isAnimated ? "true" : "false")"
        )
    }

    public var linkedImageMarkdown: String {
        "[\(name)](https://cdn.discordapp.com/emojis/\(id).\(isAnimated ? "gif" : "webp")?size=48&animated=\(isAnimated ? "true" : "false")&name=\(name)&lossless=true)"
    }
}

public struct EmojiUserSettings: Equatable, Sendable {
    public var favoriteKeys: [String]
    public var frequentlyUsedKeys: [String]
    public var usageScores: [String: Int]
    public var guildAndChannelUsageScores: [String: Int]
    public var guildAndChannelUsage: [String: DiscordFrecencyUsage]
    public var guildAndChannelUsageOrder: [String]

    public init(
        favoriteKeys: [String] = [],
        frequentlyUsedKeys: [String] = [],
        usageScores: [String: Int] = [:],
        guildAndChannelUsageScores: [String: Int] = [:],
        guildAndChannelUsage: [String: DiscordFrecencyUsage] = [:],
        guildAndChannelUsageOrder: [String] = []
    ) {
        self.favoriteKeys = favoriteKeys
        self.frequentlyUsedKeys = frequentlyUsedKeys
        self.usageScores = usageScores
        self.guildAndChannelUsageScores = guildAndChannelUsageScores
        self.guildAndChannelUsage = guildAndChannelUsage
        self.guildAndChannelUsageOrder = guildAndChannelUsageOrder
    }
}

public struct DiscordFrecencyUsage: Codable, Equatable, Sendable {
    public var totalUses: Int
    public var recentUses: [UInt64]

    public init(totalUses: Int, recentUses: [UInt64]) {
        self.totalUses = totalUses
        self.recentUses = recentUses
    }
}

public enum ChannelKindValue: String, Codable, Hashable, Sendable {
    case text, announcement, forum, voice, directMessage, groupDirectMessage, unknown
}

public struct ForumTag: Identifiable, Codable, Hashable, Sendable {
    public let id: ForumTagID
    public var name: String
    public var isModerated: Bool
    public var emojiID: String?
    public var emojiName: String?

    public init(
        id: ForumTagID,
        name: String,
        isModerated: Bool = false,
        emojiID: String? = nil,
        emojiName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isModerated = isModerated
        self.emojiID = emojiID
        self.emojiName = emojiName
    }
}

public struct ForumDefaultReaction: Codable, Hashable, Sendable {
    public var emojiID: String?
    public var emojiName: String?

    public init(emojiID: String? = nil, emojiName: String? = nil) {
        self.emojiID = emojiID
        self.emojiName = emojiName
    }
}

public enum ForumSortOrder: Int, Codable, CaseIterable, Hashable, Sendable {
    case latestActivity = 0
    case creationDate = 1
}

public enum ForumLayout: Int, Codable, CaseIterable, Hashable, Sendable {
    case defaultLayout = 0
    case list = 1
    case gallery = 2
}

public enum ForumTagMatch: String, Codable, CaseIterable, Hashable, Sendable {
    case matchSome = "match_some"
    case matchAll = "match_all"
}

public struct ChannelPermissionOverwrite: Codable, Hashable, Sendable {
    public var id: String
    public var type: Int
    public var allow: UInt64
    public var deny: UInt64

    public init(id: String, type: Int, allow: UInt64 = 0, deny: UInt64 = 0) {
        self.id = id
        self.type = type
        self.allow = allow
        self.deny = deny
    }
}

public struct Channel: Identifiable, Codable, Hashable, Sendable {
    public let id: ChannelID
    public var guildID: GuildID?
    public var name: String
    public var hasExplicitName: Bool
    public var iconURL: URL?
    public var ownerID: UserID?
    public var topic: String?
    public var kind: ChannelKindValue
    public var category: String?
    public var categoryID: ChannelID?
    public var position: Int
    public var categoryPosition: Int
    public var unreadCount: Int
    public var mentionCount: Int
    public var isMuted: Bool
    public var recipients: [User]
    public var permissionOverwrites: [ChannelPermissionOverwrite]?
    public var memberListID: String?
    public var lastMessageID: MessageID?
    public var lastPinTimestamp: Date?
    public var flags: UInt64
    public var availableTags: [ForumTag]
    public var defaultReaction: ForumDefaultReaction?
    public var defaultSortOrder: ForumSortOrder?
    public var defaultForumLayout: ForumLayout
    public var defaultTagMatch: ForumTagMatch
    public var defaultAutoArchiveDuration: Int?
    public var defaultThreadRateLimitPerUser: Int?
    public var rateLimitPerUser: Int
    public var voiceStatus: String?
    public var voiceStartTime: Date?

    public init(
        id: ChannelID,
        guildID: GuildID?,
        name: String,
        hasExplicitName: Bool = true,
        iconURL: URL? = nil,
        ownerID: UserID? = nil,
        topic: String? = nil,
        kind: ChannelKindValue = .text,
        category: String? = nil,
        categoryID: ChannelID? = nil,
        position: Int = 0,
        categoryPosition: Int = 0,
        unreadCount: Int = 0,
        mentionCount: Int = 0,
        isMuted: Bool = false,
        recipients: [User] = [],
        permissionOverwrites: [ChannelPermissionOverwrite]? = nil,
        memberListID: String? = nil,
        lastMessageID: MessageID? = nil,
        lastPinTimestamp: Date? = nil,
        flags: UInt64 = 0,
        availableTags: [ForumTag] = [],
        defaultReaction: ForumDefaultReaction? = nil,
        defaultSortOrder: ForumSortOrder? = nil,
        defaultForumLayout: ForumLayout = .defaultLayout,
        defaultTagMatch: ForumTagMatch = .matchSome,
        defaultAutoArchiveDuration: Int? = nil,
        defaultThreadRateLimitPerUser: Int? = nil,
        rateLimitPerUser: Int = 0,
        voiceStatus: String? = nil,
        voiceStartTime: Date? = nil
    ) {
        self.id = id
        self.guildID = guildID
        self.name = name
        self.hasExplicitName = hasExplicitName
        self.iconURL = iconURL
        self.ownerID = ownerID
        self.topic = topic
        self.kind = kind
        self.category = category
        self.categoryID = categoryID
        self.position = position
        self.categoryPosition = categoryPosition
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.isMuted = isMuted
        self.recipients = recipients
        self.permissionOverwrites = permissionOverwrites
        self.memberListID = memberListID
        self.lastMessageID = lastMessageID
        self.lastPinTimestamp = lastPinTimestamp
        self.flags = flags
        self.availableTags = availableTags
        self.defaultReaction = defaultReaction
        self.defaultSortOrder = defaultSortOrder
        self.defaultForumLayout = defaultForumLayout
        self.defaultTagMatch = defaultTagMatch
        self.defaultAutoArchiveDuration = defaultAutoArchiveDuration
        self.defaultThreadRateLimitPerUser = defaultThreadRateLimitPerUser
        self.rateLimitPerUser = rateLimitPerUser
        self.voiceStatus = voiceStatus
        self.voiceStartTime = voiceStartTime
    }

    public var requiresForumTag: Bool {
        flags & (1 << 4) != 0
    }

    public var isOfficialSystemDirectMessage: Bool {
        kind == .directMessage && recipients.contains(where: \.isSystem)
    }

    private enum CodingKeys: String, CodingKey {
        case id, guildID, name, hasExplicitName, iconURL, ownerID, topic, kind, category, categoryID, position, categoryPosition
        case unreadCount, mentionCount, isMuted, recipients, permissionOverwrites, memberListID, lastMessageID, lastPinTimestamp
        case flags, availableTags, defaultReaction, defaultSortOrder, defaultForumLayout
        case defaultTagMatch, defaultAutoArchiveDuration, defaultThreadRateLimitPerUser
        case rateLimitPerUser
        case voiceStatus, voiceStartTime
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ChannelID.self, forKey: .id)
        guildID = try values.decodeIfPresent(GuildID.self, forKey: .guildID)
        name = try values.decode(String.self, forKey: .name)
        hasExplicitName = try values.decodeIfPresent(Bool.self, forKey: .hasExplicitName) ?? true
        iconURL = try values.decodeIfPresent(URL.self, forKey: .iconURL)
        ownerID = try values.decodeIfPresent(UserID.self, forKey: .ownerID)
        topic = try values.decodeIfPresent(String.self, forKey: .topic)
        kind = try values.decodeIfPresent(ChannelKindValue.self, forKey: .kind) ?? .text
        category = try values.decodeIfPresent(String.self, forKey: .category)
        categoryID = try values.decodeIfPresent(ChannelID.self, forKey: .categoryID)
        position = try values.decodeIfPresent(Int.self, forKey: .position) ?? 0
        categoryPosition = try values.decodeIfPresent(Int.self, forKey: .categoryPosition) ?? 0
        unreadCount = try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        mentionCount = try values.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        recipients = try values.decodeIfPresent([User].self, forKey: .recipients) ?? []
        permissionOverwrites = try values.decodeIfPresent(
            [ChannelPermissionOverwrite].self, forKey: .permissionOverwrites
        )
        memberListID = try values.decodeIfPresent(String.self, forKey: .memberListID)
        lastMessageID = try values.decodeIfPresent(MessageID.self, forKey: .lastMessageID)
        lastPinTimestamp = try values.decodeIfPresent(Date.self, forKey: .lastPinTimestamp)
        flags = try values.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
        availableTags = try values.decodeIfPresent([ForumTag].self, forKey: .availableTags) ?? []
        defaultReaction = try values.decodeIfPresent(
            ForumDefaultReaction.self, forKey: .defaultReaction
        )
        defaultSortOrder = try values.decodeIfPresent(
            ForumSortOrder.self, forKey: .defaultSortOrder)
        defaultForumLayout =
            try values.decodeIfPresent(
                ForumLayout.self, forKey: .defaultForumLayout
            ) ?? .defaultLayout
        defaultTagMatch =
            try values.decodeIfPresent(
                ForumTagMatch.self, forKey: .defaultTagMatch
            ) ?? .matchSome
        defaultAutoArchiveDuration = try values.decodeIfPresent(
            Int.self, forKey: .defaultAutoArchiveDuration
        )
        defaultThreadRateLimitPerUser = try values.decodeIfPresent(
            Int.self, forKey: .defaultThreadRateLimitPerUser
        )
        rateLimitPerUser = try values.decodeIfPresent(Int.self, forKey: .rateLimitPerUser) ?? 0
        voiceStatus = try values.decodeIfPresent(String.self, forKey: .voiceStatus)
        voiceStartTime = try values.decodeIfPresent(Date.self, forKey: .voiceStartTime)
    }
}

public struct ForumPost: Identifiable, Codable, Hashable, Sendable {
    public var id: ChannelID { thread.id }
    public var thread: MessageThreadSummary
    public var owner: User?
    public var firstMessage: Message?
    public var mostRecentMessage: Message?
    public var isUnread: Bool

    public init(
        thread: MessageThreadSummary,
        owner: User? = nil,
        firstMessage: Message? = nil,
        mostRecentMessage: Message? = nil,
        isUnread: Bool = false
    ) {
        self.thread = thread
        self.owner = owner
        self.firstMessage = firstMessage
        self.mostRecentMessage = mostRecentMessage
        self.isUnread = isUnread
    }

    public var replyCount: Int {
        max(0, thread.messageCount - 1)
    }

    public var reactionCount: Int {
        firstMessage?.reactions.reduce(0) { $0 + $1.count } ?? 0
    }

    public var createdAt: Date {
        thread.createdAt ?? thread.id.createdAt
    }

    public var lastActivityAt: Date {
        mostRecentMessage?.timestamp
            ?? thread.lastMessageID?.createdAt
            ?? thread.archiveTimestamp
            ?? createdAt
    }
}

public enum ForumPostScope: Hashable, Sendable {
    case active
    case search(String)
}

public struct ForumPostQuery: Hashable, Sendable {
    public var scope: ForumPostScope
    public var sortOrder: ForumSortOrder
    public var selectedTagIDs: Set<ForumTagID>
    public var tagMatch: ForumTagMatch
    public var offset: Int
    public var limit: Int

    public init(
        scope: ForumPostScope = .active,
        sortOrder: ForumSortOrder = .latestActivity,
        selectedTagIDs: Set<ForumTagID> = [],
        tagMatch: ForumTagMatch = .matchSome,
        offset: Int = 0,
        limit: Int = 10
    ) {
        self.scope = scope
        self.sortOrder = sortOrder
        self.selectedTagIDs = selectedTagIDs
        self.tagMatch = tagMatch
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

public enum ForumPostQueryPolicy {
    public static func matchesTags(
        _ post: ForumPost,
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch
    ) -> Bool {
        guard !selectedTagIDs.isEmpty else { return true }
        let appliedTagIDs = Set(post.thread.appliedTagIDs)
        return switch tagMatch {
        case .matchSome:
            !appliedTagIDs.isDisjoint(with: selectedTagIDs)
        case .matchAll:
            appliedTagIDs.isSuperset(of: selectedTagIDs)
        }
    }

    public static func areInDisplayOrder(
        _ lhs: ForumPost,
        _ rhs: ForumPost,
        sortOrder: ForumSortOrder
    ) -> Bool {
        if lhs.thread.isPinned != rhs.thread.isPinned {
            return lhs.thread.isPinned
        }
        let lhsDate = sortOrder == .latestActivity ? lhs.lastActivityAt : lhs.createdAt
        let rhsDate = sortOrder == .latestActivity ? rhs.lastActivityAt : rhs.createdAt
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.id > rhs.id
    }

    public static func filteredAndSorted(
        _ posts: [ForumPost],
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch,
        sortOrder: ForumSortOrder
    ) -> [ForumPost] {
        posts
            .filter {
                matchesTags(
                    $0,
                    selectedTagIDs: selectedTagIDs,
                    tagMatch: tagMatch
                )
            }
            .sorted {
                areInDisplayOrder($0, $1, sortOrder: sortOrder)
            }
    }
}

public struct ForumPostPage: Equatable, Sendable {
    public var posts: [ForumPost]
    public var hasMore: Bool
    public var nextOffset: Int?

    public init(posts: [ForumPost], hasMore: Bool, nextOffset: Int?) {
        self.posts = posts
        self.hasMore = hasMore
        self.nextOffset = nextOffset
    }
}

public struct ForumPostAttachment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var url: URL
    public var filename: String
    public var description: String
    public var isSpoiler: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String? = nil,
        description: String = "",
        isSpoiler: Bool = false
    ) {
        self.id = id
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.description = description
        self.isSpoiler = isSpoiler
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url
            && lhs.filename == rhs.filename
            && lhs.description == rhs.description
            && lhs.isSpoiler == rhs.isSpoiler
    }
}

public struct CreateForumPostDraft: Equatable, Sendable {
    public var channelID: ChannelID
    public var title: String
    public var content: String
    public var attachments: [ForumPostAttachment]
    public var appliedTagIDs: [ForumTagID]
    public var autoArchiveDuration: Int

    public init(
        channelID: ChannelID,
        title: String,
        content: String,
        attachments: [ForumPostAttachment] = [],
        appliedTagIDs: [ForumTagID] = [],
        autoArchiveDuration: Int = 4_320
    ) {
        self.channelID = channelID
        self.title = title
        self.content = content
        self.attachments = attachments
        self.appliedTagIDs = appliedTagIDs
        self.autoArchiveDuration = autoArchiveDuration
    }
}

public enum ForumPostMutation: Equatable, Sendable {
    case tags([ForumTagID])
    case archived(Bool)
    case locked(Bool)
    case pinned(Bool)
}

public enum PresenceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case online, idle, dnd, invisible, offline

    public var isVisibleOnline: Bool {
        self == .online || self == .idle || self == .dnd
    }
}

public struct GuildRole: Identifiable, Codable, Hashable, Sendable {
    public let id: RoleID
    public var name: String
    public var position: Int
    public var colorHex: UInt32?
    public var iconURL: URL?
    public var unicodeEmoji: String?
    public var isMentionable: Bool
    public var permissions: UInt64?

    public init(
        id: RoleID,
        name: String,
        position: Int = 0,
        colorHex: UInt32? = nil,
        iconURL: URL? = nil,
        unicodeEmoji: String? = nil,
        isMentionable: Bool = true,
        permissions: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.colorHex = colorHex
        self.iconURL = iconURL
        self.unicodeEmoji = unicodeEmoji
        self.isMentionable = isMentionable
        self.permissions = permissions
    }
}

public struct RoleMemberResult: Equatable, Sendable {
    public var members: [Member]
    public var totalCount: Int
    public var isTruncated: Bool

    public init(members: [Member], totalCount: Int, isTruncated: Bool = false) {
        self.members = members
        self.totalCount = totalCount
        self.isTruncated = isTruncated
    }
}

public struct Attachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var filename: String
    public var url: URL
    public var proxyURL: URL?
    public var mediaType: String?
    public var width: Int?
    public var height: Int?
    public var size: Int
    public var description: String?
    public var title: String?
    public var placeholder: String?
    public var placeholderVersion: Int?
    public var durationSeconds: Double?
    public var waveform: String?
    public var flags: AttachmentFlags
    public var isSpoiler: Bool
    public var isAnimated: Bool

    public var mediaKind: AttachmentMediaKind {
        let type = mediaType?.lowercased() ?? ""
        let path = filename.lowercased()
        if type == "image/gif" || path.hasSuffix(".gif") || flags.contains(.animated) {
            return .animatedImage
        }
        if type.hasPrefix("image/") {
            return .image
        }
        if type.hasPrefix("video/") {
            return .video
        }
        if type.hasPrefix("audio/") || durationSeconds != nil || waveform != nil {
            return .audio
        }
        return .file
    }

    public init(
        id: String, filename: String, url: URL, proxyURL: URL? = nil, mediaType: String? = nil,
        width: Int? = nil, height: Int? = nil, size: Int = 0, description: String? = nil,
        title: String? = nil, placeholder: String? = nil, placeholderVersion: Int? = nil,
        durationSeconds: Double? = nil, waveform: String? = nil, flags: AttachmentFlags = [],
        isSpoiler: Bool? = nil, isAnimated: Bool? = nil
    ) {
        self.id = id
        self.filename = filename
        self.url = url
        self.proxyURL = proxyURL
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.size = size
        self.description = description
        self.title = title
        self.placeholder = placeholder
        self.placeholderVersion = placeholderVersion
        self.durationSeconds = durationSeconds
        self.waveform = waveform
        self.flags = flags
        self.isSpoiler = isSpoiler ?? (filename.hasPrefix("SPOILER_") || flags.contains(.spoiler))
        self.isAnimated =
            isAnimated ?? (mediaType?.lowercased() == "image/gif" || flags.contains(.animated))
    }

    private enum CodingKeys: String, CodingKey {
        case id, filename, url, proxyURL, mediaType, width, height, size, description, title
        case placeholder, placeholderVersion, durationSeconds, waveform, flags, isSpoiler,
             isAnimated
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        filename = try values.decode(String.self, forKey: .filename)
        url = try values.decode(URL.self, forKey: .url)
        proxyURL = try values.decodeIfPresent(URL.self, forKey: .proxyURL)
        mediaType = try values.decodeIfPresent(String.self, forKey: .mediaType)
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        size = try values.decodeIfPresent(Int.self, forKey: .size) ?? 0
        description = try values.decodeIfPresent(String.self, forKey: .description)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder)
        placeholderVersion = try values.decodeIfPresent(Int.self, forKey: .placeholderVersion)
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        waveform = try values.decodeIfPresent(String.self, forKey: .waveform)
        flags = try values.decodeIfPresent(AttachmentFlags.self, forKey: .flags) ?? []
        isSpoiler =
            try values.decodeIfPresent(Bool.self, forKey: .isSpoiler)
                ?? (filename.hasPrefix("SPOILER_") || flags.contains(.spoiler))
        isAnimated =
            try values.decodeIfPresent(Bool.self, forKey: .isAnimated)
                ?? (mediaType?.lowercased() == "image/gif" || flags.contains(.animated))
    }
}

public struct ReactionReactor: Identifiable, Codable, Hashable, Sendable {
    public let id: UserID
    public var displayName: String
    public var avatarURL: URL?

    public init(id: UserID, displayName: String, avatarURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    public init(user: User) {
        self.init(id: user.id, displayName: user.displayName, avatarURL: user.avatarURL)
    }
}

public struct Reaction: Identifiable, Codable, Hashable, Sendable {
    public var id: String {
        emojiReference.id.map { "custom:\($0)" } ?? "unicode:\(emoji)"
    }

    public var emoji: String
    public var count: Int
    public var didCurrentUserReact: Bool
    public var didCurrentUserBurstReact: Bool
    public var reactors: [ReactionReactor]

    public var emojiReference: EmojiReference {
        get { EmojiReference(rawToken: emoji) }
        set { emoji = newValue.rawToken }
    }

    public init(
        emoji: String,
        count: Int,
        didCurrentUserReact: Bool = false,
        didCurrentUserBurstReact: Bool = false,
        reactors: [ReactionReactor] = []
    ) {
        self.emoji = emoji
        self.count = count
        self.didCurrentUserReact = didCurrentUserReact
        self.didCurrentUserBurstReact = didCurrentUserBurstReact
        self.reactors = reactors
    }

    private enum CodingKeys: String, CodingKey {
        case emoji, count, didCurrentUserReact, didCurrentUserBurstReact, reactors
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try values.decode(String.self, forKey: .emoji)
        count = try values.decode(Int.self, forKey: .count)
        didCurrentUserReact =
            try values.decodeIfPresent(Bool.self, forKey: .didCurrentUserReact) ?? false
        didCurrentUserBurstReact =
            try values.decodeIfPresent(Bool.self, forKey: .didCurrentUserBurstReact) ?? false
        reactors = try values.decodeIfPresent([ReactionReactor].self, forKey: .reactors) ?? []
    }
}

public enum MessageReactionKind: Int, Codable, Hashable, Sendable {
    case normal = 0
    case burst = 1
}

public enum MessageReactionUpdate: Equatable, Sendable {
    case add(
        channelID: ChannelID,
        messageID: MessageID,
        userID: UserID,
        emoji: String,
        kind: MessageReactionKind
    )
    case remove(
        channelID: ChannelID,
        messageID: MessageID,
        userID: UserID,
        emoji: String,
        kind: MessageReactionKind
    )
    case removeAll(channelID: ChannelID, messageID: MessageID)
    case removeEmoji(channelID: ChannelID, messageID: MessageID, emoji: String)

    public var channelID: ChannelID {
        switch self {
        case .add(let channelID, _, _, _, _),
             .remove(let channelID, _, _, _, _),
             .removeAll(let channelID, _),
             .removeEmoji(let channelID, _, _):
            channelID
        }
    }

    public var messageID: MessageID {
        switch self {
        case .add(_, let messageID, _, _, _),
             .remove(_, let messageID, _, _, _),
             .removeAll(_, let messageID),
             .removeEmoji(_, let messageID, _):
            messageID
        }
    }
}

public enum OutboxState: String, Codable, Hashable, Sendable {
    case confirmed, queued, uploading, sending, awaitingReconciliation, failed
}

public struct MessageReplyPreview: Codable, Hashable, Sendable {
    public var messageID: MessageID
    public var author: User
    public var guildMember: MessageGuildMember?
    public var content: String

    public init(
        messageID: MessageID,
        author: User,
        guildMember: MessageGuildMember? = nil,
        content: String
    ) {
        self.messageID = messageID
        self.author = author
        self.guildMember = guildMember
        self.content = content
    }

    public init(message: Message) {
        self.init(
            messageID: message.id,
            author: message.author,
            guildMember: message.guildMember,
            content: message.content
        )
    }
}

public struct MessageGuildMember: Codable, Hashable, Sendable {
    public var nickname: String?
    public var roleIDs: [RoleID]
    public var avatarURL: URL?

    public init(nickname: String? = nil, roleIDs: [RoleID] = [], avatarURL: URL? = nil) {
        self.nickname = nickname
        self.roleIDs = roleIDs
        self.avatarURL = avatarURL
    }

    public init(member: Member) {
        self.init(
            nickname: member.globalDisplayName == member.user.displayName
                ? nil
                : member.user.displayName,
            roleIDs: member.roleIDs.isEmpty ? member.roles.map(\.id) : member.roleIDs,
            avatarURL: member.guildAvatarURL
        )
    }

    /// Matches Paicord's partial-member merge: an update that omits member
    /// fields must not erase values already learned from an earlier payload.
    public static func merging(
        incoming: MessageGuildMember?,
        existing: MessageGuildMember?
    ) -> MessageGuildMember? {
        guard var incoming else { return existing }
        guard let existing else { return incoming }
        incoming.nickname = incoming.nickname ?? existing.nickname
        incoming.avatarURL = incoming.avatarURL ?? existing.avatarURL
        if incoming.roleIDs.isEmpty, !existing.roleIDs.isEmpty {
            incoming.roleIDs = existing.roleIDs
        }
        return incoming
    }
}

public struct MessageCall: Codable, Hashable, Sendable {
    public var participantIDs: [UserID]
    public var endedAt: Date?

    public init(participantIDs: [UserID] = [], endedAt: Date? = nil) {
        self.participantIDs = participantIDs
        self.endedAt = endedAt
    }
}

public struct Message: Identifiable, Codable, Hashable, Sendable {
    public let id: MessageID
    public var channelID: ChannelID
    public var author: User
    public var guildMember: MessageGuildMember?
    public var content: String
    public var timestamp: Date
    public var editedTimestamp: Date?
    public var replyTo: MessageID?
    public var replyPreview: MessageReplyPreview?
    public var attachments: [Attachment]
    public var reactions: [Reaction]
    public var nonce: String?
    public var outboxState: OutboxState
    public var type: DiscordMessageType
    public var flags: MessageFlags
    public var applicationID: ApplicationID?
    public var application: ApplicationCommandApplication?
    public var interactionMetadata: MessageInteractionMetadata?
    public var guildID: GuildID?
    public var embeds: [MessageEmbed]
    public var components: [MessageComponent]
    public var stickers: [MessageSticker]
    public var thread: MessageThreadSummary?
    public var mentionedUsers: [User]
    public var mentionedRoleIDs: [RoleID]
    public var mentionsEveryone: Bool
    public var call: MessageCall?
    public var hasPoll: Bool
    public var hasActivity: Bool
    public var hasSharedClientTheme: Bool
    public var hasActivityInstance: Bool
    public var messageReference: DiscordMessageReference?
    public var forwardedSnapshot: ForwardedMessageSnapshot?

    public init(
        id: MessageID,
        channelID: ChannelID,
        author: User,
        guildMember: MessageGuildMember? = nil,
        content: String,
        timestamp: Date = .now,
        editedTimestamp: Date? = nil,
        replyTo: MessageID? = nil,
        replyPreview: MessageReplyPreview? = nil,
        attachments: [Attachment] = [],
        reactions: [Reaction] = [],
        nonce: String? = nil,
        outboxState: OutboxState = .confirmed,
        type: DiscordMessageType = .default,
        flags: MessageFlags = [],
        applicationID: ApplicationID? = nil,
        application: ApplicationCommandApplication? = nil,
        interactionMetadata: MessageInteractionMetadata? = nil,
        guildID: GuildID? = nil,
        embeds: [MessageEmbed] = [],
        components: [MessageComponent] = [],
        stickers: [MessageSticker] = [],
        thread: MessageThreadSummary? = nil,
        mentionedUsers: [User] = [],
        mentionedRoleIDs: [RoleID] = [],
        mentionsEveryone: Bool = false,
        call: MessageCall? = nil,
        hasPoll: Bool = false,
        hasActivity: Bool = false,
        hasSharedClientTheme: Bool = false,
        hasActivityInstance: Bool = false,
        messageReference: DiscordMessageReference? = nil,
        forwardedSnapshot: ForwardedMessageSnapshot? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.author = author
        self.guildMember = guildMember
        self.content = content
        self.timestamp = timestamp
        self.editedTimestamp = editedTimestamp
        self.replyTo = replyTo
        self.replyPreview = replyPreview
        self.attachments = attachments
        self.reactions = reactions
        self.nonce = nonce
        self.outboxState = outboxState
        self.type = type
        self.flags = flags
        self.applicationID = applicationID
        self.application = application
        self.interactionMetadata = interactionMetadata
        self.guildID = guildID
        self.embeds = embeds
        self.components = components
        self.stickers = stickers
        self.thread = thread
        self.mentionedUsers = mentionedUsers
        self.mentionedRoleIDs = mentionedRoleIDs
        self.mentionsEveryone = mentionsEveryone
        self.call = call
        self.hasPoll = hasPoll
        self.hasActivity = hasActivity
        self.hasSharedClientTheme = hasSharedClientTheme
        self.hasActivityInstance = hasActivityInstance
        self.messageReference = messageReference
        self.forwardedSnapshot = forwardedSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case id, channelID, author, guildMember, content, timestamp, editedTimestamp, replyTo,
             replyPreview
        case attachments, reactions, nonce, outboxState, type, flags, applicationID, application
        case interactionMetadata, guildID
        case embeds, components, stickers, thread, mentionedUsers, mentionedRoleIDs, mentionsEveryone
        case call, hasPoll, hasActivity, hasSharedClientTheme, hasActivityInstance
        case messageReference, forwardedSnapshot
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(MessageID.self, forKey: .id)
        channelID = try values.decode(ChannelID.self, forKey: .channelID)
        author = try values.decode(User.self, forKey: .author)
        guildMember = try values.decodeIfPresent(MessageGuildMember.self, forKey: .guildMember)
        content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
        timestamp = try values.decodeIfPresent(Date.self, forKey: .timestamp) ?? .distantPast
        editedTimestamp = try values.decodeIfPresent(Date.self, forKey: .editedTimestamp)
        replyTo = try values.decodeIfPresent(MessageID.self, forKey: .replyTo)
        replyPreview = try values.decodeIfPresent(MessageReplyPreview.self, forKey: .replyPreview)
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        reactions = try values.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
        nonce = try values.decodeIfPresent(String.self, forKey: .nonce)
        outboxState =
            try values.decodeIfPresent(OutboxState.self, forKey: .outboxState) ?? .confirmed
        type = try values.decodeIfPresent(DiscordMessageType.self, forKey: .type) ?? .default
        flags = try values.decodeIfPresent(MessageFlags.self, forKey: .flags) ?? []
        applicationID = try values.decodeIfPresent(ApplicationID.self, forKey: .applicationID)
        application = try values.decodeIfPresent(
            ApplicationCommandApplication.self, forKey: .application
        )
        interactionMetadata = try values.decodeIfPresent(
            MessageInteractionMetadata.self, forKey: .interactionMetadata
        )
        guildID = try values.decodeIfPresent(GuildID.self, forKey: .guildID)
        embeds = try values.decodeIfPresent([MessageEmbed].self, forKey: .embeds) ?? []
        components = try values.decodeIfPresent([MessageComponent].self, forKey: .components) ?? []
        stickers = try values.decodeIfPresent([MessageSticker].self, forKey: .stickers) ?? []
        thread = try values.decodeIfPresent(MessageThreadSummary.self, forKey: .thread)
        mentionedUsers = try values.decodeIfPresent([User].self, forKey: .mentionedUsers) ?? []
        mentionedRoleIDs = try values.decodeIfPresent([RoleID].self, forKey: .mentionedRoleIDs) ?? []
        mentionsEveryone = try values.decodeIfPresent(Bool.self, forKey: .mentionsEveryone) ?? false
        call = try values.decodeIfPresent(MessageCall.self, forKey: .call)
        hasPoll = try values.decodeIfPresent(Bool.self, forKey: .hasPoll) ?? false
        hasActivity = try values.decodeIfPresent(Bool.self, forKey: .hasActivity) ?? false
        hasSharedClientTheme =
            try values.decodeIfPresent(Bool.self, forKey: .hasSharedClientTheme) ?? false
        hasActivityInstance =
            try values.decodeIfPresent(Bool.self, forKey: .hasActivityInstance) ?? false
        messageReference = try values.decodeIfPresent(
            DiscordMessageReference.self, forKey: .messageReference
        )
        forwardedSnapshot = try values.decodeIfPresent(
            ForwardedMessageSnapshot.self, forKey: .forwardedSnapshot
        )
    }

    /// Message-local portion of Discord desktop's current forwarding guard.
    /// Source-channel permission and guild gating are evaluated by `AppModel`.
    public var isForwardable: Bool {
        outboxState == .confirmed
            && type.isForwardable
            && !hasPoll
            && !hasActivity
            && !hasSharedClientTheme
            && call == nil
            && !hasActivityInstance
            && flags.subtracting(.forwardingAllowed).isEmpty
    }
}

public struct Member: Identifiable, Codable, Hashable, Sendable {
    public var id: UserID {
        user.id
    }

    public var user: User
    public var roleName: String
    public var roleID: RoleID?
    public var rolePosition: Int?
    public var isRoleCategory: Bool?
    public var status: PresenceStatus
    /// Raw guild role membership retained even when the role catalogue has not
    /// arrived yet. `roles` contains the corresponding resolved role objects.
    public var roleIDs: [RoleID]
    public var roles: [GuildRole]
    /// Raw Discord guild-member flags, including onboarding lifecycle bits.
    public var flags: UInt64
    public var guildAvatarURL: URL?
    /// The account-wide display name before `user.displayName` is replaced by
    /// a guild nickname for presentation.
    public var globalDisplayName: String?
    public var activityText: String?
    public var customStatus: String?
    /// Absolute row index in Discord's virtualized guild member list. This is
    /// absent for DMs, fallback stores, and member lookups that are not backed
    /// by a `GUILD_MEMBER_LIST_UPDATE` range.
    public var memberListIndex: Int?

    public var isOnline: Bool {
        status.isVisibleOnline
    }

    public init(
        user: User,
        roleName: String,
        isOnline: Bool,
        roleID: RoleID? = nil,
        rolePosition: Int? = nil,
        isRoleCategory: Bool? = nil,
        roleIDs: [RoleID] = [],
        roles: [GuildRole] = [],
        flags: UInt64 = 0,
        guildAvatarURL: URL? = nil,
        globalDisplayName: String? = nil,
        activityText: String? = nil,
        customStatus: String? = nil,
        memberListIndex: Int? = nil
    ) {
        self.user = user
        self.roleName = roleName
        self.roleID = roleID
        self.rolePosition = rolePosition
        self.isRoleCategory = isRoleCategory
        status = isOnline ? .online : .offline
        self.roleIDs = roleIDs
        self.roles = roles
        self.flags = flags
        self.guildAvatarURL = guildAvatarURL
        self.globalDisplayName = globalDisplayName
        self.activityText = activityText
        self.customStatus = customStatus
        self.memberListIndex = memberListIndex
    }

    public init(
        user: User,
        roleName: String,
        status: PresenceStatus,
        roleID: RoleID? = nil,
        rolePosition: Int? = nil,
        isRoleCategory: Bool? = nil,
        roleIDs: [RoleID] = [],
        roles: [GuildRole] = [],
        flags: UInt64 = 0,
        guildAvatarURL: URL? = nil,
        globalDisplayName: String? = nil,
        activityText: String? = nil,
        customStatus: String? = nil,
        memberListIndex: Int? = nil
    ) {
        self.user = user
        self.roleName = roleName
        self.roleID = roleID
        self.rolePosition = rolePosition
        self.isRoleCategory = isRoleCategory
        self.status = status
        self.roleIDs = roleIDs
        self.roles = roles
        self.flags = flags
        self.guildAvatarURL = guildAvatarURL
        self.globalDisplayName = globalDisplayName
        self.activityText = activityText
        self.customStatus = customStatus
        self.memberListIndex = memberListIndex
    }

    private enum CodingKeys: String, CodingKey {
        case user, roleName, roleID, rolePosition, isRoleCategory, status, roleIDs, roles, flags,
             guildAvatarURL,
             globalDisplayName, activityText, customStatus, memberListIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(User.self, forKey: .user)
        roleName = try container.decodeIfPresent(String.self, forKey: .roleName) ?? "Member"
        roleID = try container.decodeIfPresent(RoleID.self, forKey: .roleID)
        rolePosition = try container.decodeIfPresent(Int.self, forKey: .rolePosition)
        isRoleCategory = try container.decodeIfPresent(Bool.self, forKey: .isRoleCategory)
        status = try container.decodeIfPresent(PresenceStatus.self, forKey: .status) ?? .offline
        roleIDs = try container.decodeIfPresent([RoleID].self, forKey: .roleIDs) ?? []
        roles = try container.decodeIfPresent([GuildRole].self, forKey: .roles) ?? []
        flags = try container.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
        guildAvatarURL = try container.decodeIfPresent(URL.self, forKey: .guildAvatarURL)
        globalDisplayName = try container.decodeIfPresent(String.self, forKey: .globalDisplayName)
        activityText = try container.decodeIfPresent(String.self, forKey: .activityText)
        customStatus = try container.decodeIfPresent(String.self, forKey: .customStatus)
        memberListIndex = try container.decodeIfPresent(Int.self, forKey: .memberListIndex)
    }
}

public struct GuildMemberListGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var count: Int

    public init(id: String, count: Int) {
        self.id = id
        self.count = max(0, count)
    }
}

public struct ProfileBadge: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var description: String
    public var iconURL: URL?
    public var linkURL: URL?

    public init(id: String, description: String, iconURL: URL? = nil, linkURL: URL? = nil) {
        self.id = id
        self.description = description
        self.iconURL = iconURL
        self.linkURL = linkURL
    }
}

public struct ProfileEffect: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String?
    public var accessibilityLabel: String?
    public var staticURL: URL?
    public var reducedMotionURL: URL?
    public var animations: [ProfileEffectAnimation]

    public init(
        id: String,
        title: String? = nil,
        accessibilityLabel: String? = nil,
        staticURL: URL? = nil,
        reducedMotionURL: URL? = nil,
        animations: [ProfileEffectAnimation] = []
    ) {
        self.id = id
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.staticURL = staticURL
        self.reducedMotionURL = reducedMotionURL
        self.animations = animations
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, accessibilityLabel, staticURL, reducedMotionURL, animations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        accessibilityLabel = try container.decodeIfPresent(String.self, forKey: .accessibilityLabel)
        staticURL = try container.decodeIfPresent(URL.self, forKey: .staticURL)
        reducedMotionURL = try container.decodeIfPresent(URL.self, forKey: .reducedMotionURL)
        animations =
            try container.decodeIfPresent([ProfileEffectAnimation].self, forKey: .animations) ?? []
    }
}

public struct ProfileEffectAnimation: Identifiable, Codable, Hashable, Sendable {
    public var id: String {
        "\(sourceURL.absoluteString):\(startMilliseconds):\(zIndex)"
    }

    public var sourceURL: URL
    public var isLooping: Bool
    public var width: Int?
    public var height: Int?
    public var durationMilliseconds: Int
    public var startMilliseconds: Int
    public var loopDelayMilliseconds: Int
    public var positionX: Int
    public var positionY: Int
    public var zIndex: Int

    public init(
        sourceURL: URL,
        isLooping: Bool = true,
        width: Int? = nil,
        height: Int? = nil,
        durationMilliseconds: Int = 0,
        startMilliseconds: Int = 0,
        loopDelayMilliseconds: Int = 0,
        positionX: Int = 0,
        positionY: Int = 0,
        zIndex: Int = 0
    ) {
        self.sourceURL = sourceURL
        self.isLooping = isLooping
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
        self.startMilliseconds = startMilliseconds
        self.loopDelayMilliseconds = loopDelayMilliseconds
        self.positionX = positionX
        self.positionY = positionY
        self.zIndex = zIndex
    }
}

public struct MutualGuild: Identifiable, Codable, Hashable, Sendable {
    public let id: GuildID
    public var name: String
    public var iconURL: URL?
    public var nickname: String?

    public init(id: GuildID, name: String, iconURL: URL? = nil, nickname: String? = nil) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.nickname = nickname
    }
}

public struct ConnectedAccount: Identifiable, Codable, Hashable, Sendable {
    public var id: String {
        "\(type):\(accountID)"
    }

    public var accountID: String
    public var type: String
    public var name: String
    public var isVerified: Bool
    public var profileURL: URL?

    public init(
        accountID: String, type: String, name: String, isVerified: Bool = false,
        profileURL: URL? = nil
    ) {
        self.accountID = accountID
        self.type = type
        self.name = name
        self.isVerified = isVerified
        self.profileURL = profileURL
    }
}

public struct UserProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UserID {
        user.id
    }

    public var user: User
    public var displayName: String
    public var avatarURL: URL?
    public var bannerURL: URL?
    public var accentHex: UInt32?
    public var themeHexes: [UInt32]
    public var bio: String?
    public var pronouns: String?
    public var effect: ProfileEffect?
    public var badges: [ProfileBadge]
    public var mutualGuilds: [MutualGuild]
    public var mutualFriends: [User]
    public var mutualFriendsCount: Int
    public var roles: [GuildRole]
    public var connectedAccounts: [ConnectedAccount]
    public var premiumSince: Date?
    public var premiumGuildSince: Date?
    public var legacyUsername: String?
    public var status: PresenceStatus
    public var customStatus: String?

    public init(
        user: User,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        bannerURL: URL? = nil,
        accentHex: UInt32? = nil,
        themeHexes: [UInt32] = [],
        bio: String? = nil,
        pronouns: String? = nil,
        effect: ProfileEffect? = nil,
        badges: [ProfileBadge] = [],
        mutualGuilds: [MutualGuild] = [],
        mutualFriends: [User] = [],
        mutualFriendsCount: Int = 0,
        roles: [GuildRole] = [],
        connectedAccounts: [ConnectedAccount] = [],
        premiumSince: Date? = nil,
        premiumGuildSince: Date? = nil,
        legacyUsername: String? = nil,
        status: PresenceStatus = .offline,
        customStatus: String? = nil
    ) {
        self.user = user
        self.displayName = displayName ?? user.displayName
        self.avatarURL = avatarURL ?? user.avatarURL
        self.bannerURL = bannerURL
        self.accentHex = accentHex
        self.themeHexes = themeHexes
        self.bio = bio
        self.pronouns = pronouns
        self.effect = effect
        self.badges = badges
        self.mutualGuilds = mutualGuilds
        self.mutualFriends = mutualFriends
        self.mutualFriendsCount = mutualFriendsCount
        self.roles = roles
        self.connectedAccounts = connectedAccounts
        self.premiumSince = premiumSince
        self.premiumGuildSince = premiumGuildSince
        self.legacyUsername = legacyUsername
        self.status = status
        self.customStatus = customStatus
    }
}

public struct GuildFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: Int64
    public var name: String?
    public var colorHex: UInt32?
    public var guildIDs: [GuildID]

    public init(id: Int64, name: String? = nil, colorHex: UInt32? = nil, guildIDs: [GuildID]) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.guildIDs = guildIDs
    }
}

public enum GuildRailItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum RailIdentifier: Codable, Equatable, Hashable, Sendable {
        case guild(GuildID)
        case folder(Int64)
    }

    case guild(GuildID)
    case folder(GuildFolder)

    public var id: RailIdentifier {
        switch self {
        case .guild(let id): .guild(id)
        case .folder(let folder): .folder(folder.id)
        }
    }
}

public struct BootstrapSnapshot: Codable, Equatable, Sendable {
    public var currentUser: User
    public var knownUsers: [User]
    public var friendUserIDs: Set<UserID>
    public var relationshipNicknamesByUserID: [UserID: String]
    public var userSearchAliasesByUserID: [UserID: [String]]
    public var guilds: [Guild]
    public var guildRailItems: [GuildRailItem]
    public var channels: [Channel]
    public var forwardChannelStoreOrder: [ChannelID]
    public var threads: [MessageThreadSummary]
    public var activeJoinedThreads: [MessageThreadSummary]
    public var members: [Member]
    public var readStates: [ChannelReadState]
    public var notificationSettings: [GuildNotificationSettings]
    public var usesNewNotifications: Bool

    public init(
        currentUser: User,
        knownUsers: [User] = [],
        friendUserIDs: Set<UserID> = [],
        relationshipNicknamesByUserID: [UserID: String] = [:],
        userSearchAliasesByUserID: [UserID: [String]] = [:],
        guilds: [Guild],
        guildRailItems: [GuildRailItem]? = nil,
        channels: [Channel],
        forwardChannelStoreOrder: [ChannelID]? = nil,
        threads: [MessageThreadSummary] = [],
        activeJoinedThreads: [MessageThreadSummary] = [],
        members: [Member],
        readStates: [ChannelReadState] = [],
        notificationSettings: [GuildNotificationSettings] = [],
        usesNewNotifications: Bool = true
    ) {
        self.currentUser = currentUser
        self.knownUsers = knownUsers
        self.friendUserIDs = friendUserIDs
        self.relationshipNicknamesByUserID = relationshipNicknamesByUserID
        self.userSearchAliasesByUserID = userSearchAliasesByUserID
        self.guilds = guilds
        self.guildRailItems = guildRailItems ?? guilds.map { .guild($0.id) }
        self.channels = channels
        self.forwardChannelStoreOrder = forwardChannelStoreOrder ?? channels.map(\.id)
        self.threads = threads
        self.activeJoinedThreads = activeJoinedThreads
        self.members = members
        self.readStates = readStates
        self.notificationSettings = notificationSettings
        self.usesNewNotifications = usesNewNotifications
    }

    private enum CodingKeys: String, CodingKey {
        case currentUser, knownUsers, friendUserIDs, relationshipNicknamesByUserID
        case userSearchAliasesByUserID
        case guilds, guildRailItems, channels, forwardChannelStoreOrder
        case threads, activeJoinedThreads
        case members, readStates
        case notificationSettings, usesNewNotifications
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentUser = try container.decode(User.self, forKey: .currentUser)
        knownUsers = try container.decodeIfPresent([User].self, forKey: .knownUsers) ?? []
        friendUserIDs = try container.decodeIfPresent(Set<UserID>.self, forKey: .friendUserIDs) ?? []
        relationshipNicknamesByUserID =
            try container.decodeIfPresent(
                [UserID: String].self, forKey: .relationshipNicknamesByUserID
            ) ?? [:]
        userSearchAliasesByUserID =
            try container.decodeIfPresent(
                [UserID: [String]].self, forKey: .userSearchAliasesByUserID
            ) ?? [:]
        guilds = try container.decode([Guild].self, forKey: .guilds)
        guildRailItems =
            try container.decodeIfPresent([GuildRailItem].self, forKey: .guildRailItems)
                ?? guilds.map { .guild($0.id) }
        channels = try container.decode([Channel].self, forKey: .channels)
        forwardChannelStoreOrder =
            try container.decodeIfPresent(
                [ChannelID].self, forKey: .forwardChannelStoreOrder
            ) ?? channels.map(\.id)
        threads =
            try container.decodeIfPresent([MessageThreadSummary].self, forKey: .threads) ?? []
        activeJoinedThreads =
            try container.decodeIfPresent(
                [MessageThreadSummary].self, forKey: .activeJoinedThreads
            ) ?? []
        members = try container.decode([Member].self, forKey: .members)
        readStates = try container.decodeIfPresent([ChannelReadState].self, forKey: .readStates) ?? []
        notificationSettings =
            try container.decodeIfPresent([GuildNotificationSettings].self, forKey: .notificationSettings)
                ?? []
        usesNewNotifications =
            try container.decodeIfPresent(Bool.self, forKey: .usesNewNotifications) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentUser, forKey: .currentUser)
        try container.encode(knownUsers, forKey: .knownUsers)
        try container.encode(friendUserIDs, forKey: .friendUserIDs)
        try container.encode(
            relationshipNicknamesByUserID, forKey: .relationshipNicknamesByUserID
        )
        try container.encode(userSearchAliasesByUserID, forKey: .userSearchAliasesByUserID)
        try container.encode(guilds, forKey: .guilds)
        try container.encode(guildRailItems, forKey: .guildRailItems)
        try container.encode(channels, forKey: .channels)
        try container.encode(forwardChannelStoreOrder, forKey: .forwardChannelStoreOrder)
        try container.encode(threads, forKey: .threads)
        try container.encode(activeJoinedThreads, forKey: .activeJoinedThreads)
        try container.encode(members, forKey: .members)
        try container.encode(readStates, forKey: .readStates)
        try container.encode(notificationSettings, forKey: .notificationSettings)
        try container.encode(usesNewNotifications, forKey: .usesNewNotifications)
    }
}

public struct MessagePage: Codable, Equatable, Sendable {
    public var messages: [Message]
    public var hasMoreBefore: Bool

    public init(messages: [Message], hasMoreBefore: Bool) {
        self.messages = messages
        self.hasMoreBefore = hasMoreBefore
    }
}

public struct SendMessageDraft: Equatable, Sendable {
    public static let maximumAttachmentCount = 10

    public var channelID: ChannelID
    public var content: String
    public var replyTo: MessageID?
    public var attachments: [ForumPostAttachment]
    public var attachmentURLs: [URL] {
        get { attachments.map(\.url) }
        set { attachments = newValue.map { ForumPostAttachment(url: $0) } }
    }
    public var nonce: String
    public var stickerIDs: [String]

    public init(
        channelID: ChannelID, content: String, replyTo: MessageID? = nil,
        attachmentURLs: [URL] = [],
        attachments: [ForumPostAttachment]? = nil,
        nonce: String = ClientNonce.make(), stickerIDs: [String] = []
    ) {
        self.channelID = channelID
        self.content = content
        self.replyTo = replyTo
        self.attachments =
            attachments ?? attachmentURLs.map { ForumPostAttachment(url: $0) }
        self.nonce = nonce
        self.stickerIDs = stickerIDs
    }
}

public struct VoiceConnectionInfo: Equatable, Sendable {
    public var serverID: String
    public var channelID: ChannelID
    public var guildID: GuildID?
    public var userID: UserID
    public var sessionID: String
    public var token: String
    public var endpoint: String

    public init(
        serverID: String,
        channelID: ChannelID,
        guildID: GuildID?,
        userID: UserID,
        sessionID: String,
        token: String,
        endpoint: String
    ) {
        self.serverID = serverID
        self.channelID = channelID
        self.guildID = guildID
        self.userID = userID
        self.sessionID = sessionID
        self.token = token
        self.endpoint = endpoint
    }
}

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
