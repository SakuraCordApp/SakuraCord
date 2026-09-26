import Foundation

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
    public var quickSwitcherUserIDs: [UserID]
    public var messageSearchUsers: [User]
    public var messageSearchUserBoosterChannelIDs: Set<ChannelID>
    public var friendUserIDs: Set<UserID>
    public var blockedOrIgnoredUserIDs: Set<UserID>
    public var relationshipNicknamesByUserID: [UserID: String]
    public var userSearchAliasesByUserID: [UserID: [String]]
    public var quickSwitcherGuildMemberUserIDs: [GuildID: [UserID]]
    public var quickSwitcherJoinedGuildMemberUserIDs: [GuildID: [UserID]]
    public var quickSwitcherGuildMemberAliases: [GuildID: [UserID: String]]
    public var guilds: [Guild]
    public var guildRailItems: [GuildRailItem]
    public var forwardGuildStoreOrder: [GuildID]
    public var channels: [Channel]
    public var forwardChannelStoreOrder: [ChannelID]
    public var threads: [MessageThreadSummary]
    public var activeJoinedThreads: [MessageThreadSummary]
    public var members: [Member]
    public var currentMembersByGuildID: [GuildID: Member]
    public var readStates: [ChannelReadState]
    public var notificationSettings: [GuildNotificationSettings]
    public var usesNewNotifications: Bool

    public init(
        currentUser: User,
        knownUsers: [User] = [],
        quickSwitcherUserIDs: [UserID]? = nil,
        messageSearchUsers: [User]? = nil,
        messageSearchUserBoosterChannelIDs: Set<ChannelID>? = nil,
        friendUserIDs: Set<UserID> = [],
        blockedOrIgnoredUserIDs: Set<UserID> = [],
        relationshipNicknamesByUserID: [UserID: String] = [:],
        userSearchAliasesByUserID: [UserID: [String]] = [:],
        quickSwitcherGuildMemberUserIDs: [GuildID: [UserID]] = [:],
        quickSwitcherJoinedGuildMemberUserIDs: [GuildID: [UserID]] = [:],
        quickSwitcherGuildMemberAliases: [GuildID: [UserID: String]] = [:],
        guilds: [Guild],
        guildRailItems: [GuildRailItem]? = nil,
        forwardGuildStoreOrder: [GuildID]? = nil,
        channels: [Channel],
        forwardChannelStoreOrder: [ChannelID]? = nil,
        threads: [MessageThreadSummary] = [],
        activeJoinedThreads: [MessageThreadSummary] = [],
        members: [Member],
        currentMembersByGuildID: [GuildID: Member] = [:],
        readStates: [ChannelReadState] = [],
        notificationSettings: [GuildNotificationSettings] = [],
        usesNewNotifications: Bool = true
    ) {
        self.currentUser = currentUser
        self.knownUsers = knownUsers
        self.quickSwitcherUserIDs = quickSwitcherUserIDs ?? knownUsers.map(\.id)
        self.messageSearchUsers = messageSearchUsers ?? knownUsers
        self.messageSearchUserBoosterChannelIDs = messageSearchUserBoosterChannelIDs
            ?? Set(channels.lazy.filter { $0.kind == .directMessage }.map(\.id))
        self.friendUserIDs = friendUserIDs
        self.blockedOrIgnoredUserIDs = blockedOrIgnoredUserIDs
        self.relationshipNicknamesByUserID = relationshipNicknamesByUserID
        self.userSearchAliasesByUserID = userSearchAliasesByUserID
        self.quickSwitcherGuildMemberUserIDs = quickSwitcherGuildMemberUserIDs
        self.quickSwitcherJoinedGuildMemberUserIDs = quickSwitcherJoinedGuildMemberUserIDs
        self.quickSwitcherGuildMemberAliases = quickSwitcherGuildMemberAliases
        self.guilds = guilds
        self.guildRailItems = guildRailItems ?? guilds.map { .guild($0.id) }
        self.forwardGuildStoreOrder = forwardGuildStoreOrder ?? guilds.map(\.id)
        self.channels = channels
        self.forwardChannelStoreOrder = forwardChannelStoreOrder ?? channels.map(\.id)
        self.threads = threads
        self.activeJoinedThreads = activeJoinedThreads
        self.members = members
        self.currentMembersByGuildID = currentMembersByGuildID
        self.readStates = readStates
        self.notificationSettings = notificationSettings
        self.usesNewNotifications = usesNewNotifications
    }

    private enum CodingKeys: String, CodingKey {
        case currentUser, knownUsers, quickSwitcherUserIDs, messageSearchUsers
        case messageSearchUserBoosterChannelIDs, friendUserIDs
        case blockedOrIgnoredUserIDs
        case relationshipNicknamesByUserID
        case userSearchAliasesByUserID
        case quickSwitcherGuildMemberUserIDs
        case quickSwitcherJoinedGuildMemberUserIDs
        case quickSwitcherGuildMemberAliases
        case guilds, guildRailItems, forwardGuildStoreOrder
        case channels, forwardChannelStoreOrder
        case threads, activeJoinedThreads
        case members, currentMembersByGuildID, readStates
        case notificationSettings, usesNewNotifications
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentUser = try container.decode(User.self, forKey: .currentUser)
        knownUsers = try container.decodeIfPresent([User].self, forKey: .knownUsers) ?? []
        quickSwitcherUserIDs = try container.decodeIfPresent(
            [UserID].self,
            forKey: .quickSwitcherUserIDs
        ) ?? knownUsers.map(\.id)
        messageSearchUsers = try container.decodeIfPresent(
            [User].self,
            forKey: .messageSearchUsers
        ) ?? knownUsers
        let decodedSearchBoosterIDs = try container.decodeIfPresent(
            Set<ChannelID>.self, forKey: .messageSearchUserBoosterChannelIDs
        )
        messageSearchUserBoosterChannelIDs = decodedSearchBoosterIDs ?? []
        friendUserIDs = try container.decodeIfPresent(Set<UserID>.self, forKey: .friendUserIDs) ?? []
        blockedOrIgnoredUserIDs = try container.decodeIfPresent(
            Set<UserID>.self, forKey: .blockedOrIgnoredUserIDs
        ) ?? []
        relationshipNicknamesByUserID =
            try container.decodeIfPresent(
                [UserID: String].self, forKey: .relationshipNicknamesByUserID
            ) ?? [:]
        userSearchAliasesByUserID =
            try container.decodeIfPresent(
                [UserID: [String]].self, forKey: .userSearchAliasesByUserID
            ) ?? [:]
        quickSwitcherGuildMemberUserIDs =
            try container.decodeIfPresent(
                [GuildID: [UserID]].self, forKey: .quickSwitcherGuildMemberUserIDs
            ) ?? [:]
        quickSwitcherJoinedGuildMemberUserIDs =
            try container.decodeIfPresent(
                [GuildID: [UserID]].self,
                forKey: .quickSwitcherJoinedGuildMemberUserIDs
            ) ?? [:]
        quickSwitcherGuildMemberAliases =
            try container.decodeIfPresent(
                [GuildID: [UserID: String]].self,
                forKey: .quickSwitcherGuildMemberAliases
            ) ?? [:]
        guilds = try container.decode([Guild].self, forKey: .guilds)
        guildRailItems =
            try container.decodeIfPresent([GuildRailItem].self, forKey: .guildRailItems)
                ?? guilds.map { .guild($0.id) }
        forwardGuildStoreOrder =
            try container.decodeIfPresent([GuildID].self, forKey: .forwardGuildStoreOrder)
                ?? guilds.map(\.id)
        channels = try container.decode([Channel].self, forKey: .channels)
        if decodedSearchBoosterIDs == nil {
            messageSearchUserBoosterChannelIDs = Set(
                channels.lazy.filter { $0.kind == .directMessage }.map(\.id)
            )
        }
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
        currentMembersByGuildID = try container.decodeIfPresent([GuildID: Member].self, forKey: .currentMembersByGuildID) ?? [:]
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
        try container.encode(quickSwitcherUserIDs, forKey: .quickSwitcherUserIDs)
        try container.encode(messageSearchUsers, forKey: .messageSearchUsers)
        try container.encode(
            messageSearchUserBoosterChannelIDs,
            forKey: .messageSearchUserBoosterChannelIDs
        )
        try container.encode(friendUserIDs, forKey: .friendUserIDs)
        try container.encode(blockedOrIgnoredUserIDs, forKey: .blockedOrIgnoredUserIDs)
        try container.encode(
            relationshipNicknamesByUserID, forKey: .relationshipNicknamesByUserID
        )
        try container.encode(userSearchAliasesByUserID, forKey: .userSearchAliasesByUserID)
        try container.encode(
            quickSwitcherGuildMemberUserIDs,
            forKey: .quickSwitcherGuildMemberUserIDs
        )
        try container.encode(
            quickSwitcherJoinedGuildMemberUserIDs,
            forKey: .quickSwitcherJoinedGuildMemberUserIDs
        )
        try container.encode(
            quickSwitcherGuildMemberAliases,
            forKey: .quickSwitcherGuildMemberAliases
        )
        try container.encode(guilds, forKey: .guilds)
        try container.encode(guildRailItems, forKey: .guildRailItems)
        try container.encode(forwardGuildStoreOrder, forKey: .forwardGuildStoreOrder)
        try container.encode(channels, forKey: .channels)
        try container.encode(forwardChannelStoreOrder, forKey: .forwardChannelStoreOrder)
        try container.encode(threads, forKey: .threads)
        try container.encode(activeJoinedThreads, forKey: .activeJoinedThreads)
        try container.encode(members, forKey: .members)
        try container.encode(currentMembersByGuildID, forKey: .currentMembersByGuildID)
        try container.encode(readStates, forKey: .readStates)
        try container.encode(notificationSettings, forKey: .notificationSettings)
        try container.encode(usesNewNotifications, forKey: .usesNewNotifications)
    }
}
