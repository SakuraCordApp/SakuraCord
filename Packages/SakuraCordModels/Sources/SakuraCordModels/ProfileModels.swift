import Foundation

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
    public var thumbnailURL: URL?
    public var reducedMotionURL: URL?
    public var animations: [ProfileEffectAnimation]

    public init(
        id: String,
        title: String? = nil,
        accessibilityLabel: String? = nil,
        staticURL: URL? = nil,
        thumbnailURL: URL? = nil,
        reducedMotionURL: URL? = nil,
        animations: [ProfileEffectAnimation] = []
    ) {
        self.id = id
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.staticURL = staticURL
        self.thumbnailURL = thumbnailURL
        self.reducedMotionURL = reducedMotionURL
        self.animations = animations
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, accessibilityLabel, staticURL, thumbnailURL, reducedMotionURL, animations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        accessibilityLabel = try container.decodeIfPresent(String.self, forKey: .accessibilityLabel)
        staticURL = try container.decodeIfPresent(URL.self, forKey: .staticURL)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
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

    /// Nil when an older profile response did not report visibility.
    public var isPrivate: Bool?
    public var user: User
    public var displayName: String
    public var avatarURL: URL?
    public var defaultAvatarURL: URL?
    public var bannerURL: URL?
    public var accentHex: UInt32?
    public var themeHexes: [UInt32]
    public var bio: String?
    public var pronouns: String?
    public var effect: ProfileEffect?
    public var frame: ProfileFrame?
    public var widgets: [ProfileWidget]?
    public var widgetResources: ProfileWidgetResources?
    public var badges: [ProfileBadge]
    public var mutualGuilds: [MutualGuild]
    public var mutualFriends: [User]
    public var mutualFriendsCount: Int
    public var roles: [GuildRole]
    public var connectedAccounts: [ConnectedAccount]
    public var premiumSince: Date?
    public var premiumGuildSince: Date?
    public var legacyUsername: String?
    public var customStatus: String?

    public init(
        user: User,
        isPrivate: Bool? = nil,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        defaultAvatarURL: URL? = nil,
        bannerURL: URL? = nil,
        accentHex: UInt32? = nil,
        themeHexes: [UInt32] = [],
        bio: String? = nil,
        pronouns: String? = nil,
        effect: ProfileEffect? = nil,
        frame: ProfileFrame? = nil,
        widgets: [ProfileWidget]? = nil,
        widgetResources: ProfileWidgetResources? = nil,
        badges: [ProfileBadge] = [],
        mutualGuilds: [MutualGuild] = [],
        mutualFriends: [User] = [],
        mutualFriendsCount: Int = 0,
        roles: [GuildRole] = [],
        connectedAccounts: [ConnectedAccount] = [],
        premiumSince: Date? = nil,
        premiumGuildSince: Date? = nil,
        legacyUsername: String? = nil,
        customStatus: String? = nil
    ) {
        self.user = user
        self.isPrivate = isPrivate
        self.displayName = displayName ?? user.displayName
        self.avatarURL = avatarURL ?? user.avatarURL
        self.defaultAvatarURL = defaultAvatarURL
        self.bannerURL = bannerURL
        self.accentHex = accentHex
        self.themeHexes = themeHexes
        self.bio = bio
        self.pronouns = pronouns
        self.effect = effect
        self.frame = frame
        self.widgets = widgets
        self.widgetResources = widgetResources
        self.badges = badges
        self.mutualGuilds = mutualGuilds
        self.mutualFriends = mutualFriends
        self.mutualFriendsCount = mutualFriendsCount
        self.roles = roles
        self.connectedAccounts = connectedAccounts
        self.premiumSince = premiumSince
        self.premiumGuildSince = premiumGuildSince
        self.legacyUsername = legacyUsername
        self.customStatus = customStatus
    }
}
