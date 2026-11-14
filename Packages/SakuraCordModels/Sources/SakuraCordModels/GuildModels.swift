import Foundation

/// Discord guild feature names, as they appear in a guild's `features`.
public enum GuildFeature {
    public static let community = "COMMUNITY"
    public static let discoverable = "DISCOVERABLE"
    public static let forwardingDisabled = "FORWARDING_DISABLED"
    public static let guildTags = "GUILD_TAGS"
    public static let memberVerificationGateEnabled = "MEMBER_VERIFICATION_GATE_ENABLED"
    public static let memberVerificationManualApproval = "MEMBER_VERIFICATION_MANUAL_APPROVAL"
    public static let onboarding = "GUILD_ONBOARDING"
    public static let onboardingHasPrompts = "GUILD_ONBOARDING_HAS_PROMPTS"
    public static let partnered = "PARTNERED"
    public static let roleSubscriptionsEnabled = "ROLE_SUBSCRIPTIONS_ENABLED"
    public static let serverGuide = "GUILD_SERVER_GUIDE"
    public static let staff = "STAFF"
    public static let verified = "VERIFIED"
}

public struct Guild: Identifiable, Codable, Hashable, Sendable {
    public let id: GuildID
    public var name: String
    public var iconURL: URL?
    public var guideHeaderURL: URL?
    public var accentHex: UInt32
    public var unreadCount: Int
    public var mentionCount: Int
    public var isOwnedByCurrentUser: Bool?
    public var ownerID: UserID?
    public var currentUserPermissions: UInt64?
    public var rulesChannelID: ChannelID?
    public var features: Set<String>
    public var profileTag: PrimaryGuildIdentity?
    public var defaultMessageNotifications: MessageNotificationLevel
    public var isUnavailable: Bool
    public var joinedAt: Date?
    public var isAgeRestricted: Bool

    public var hasOnboarding: Bool { features.contains(GuildFeature.onboarding) }

    /// Whether `member` carries the flags that say if onboarding is complete;
    /// only a guild with onboarding needs them.
    public func isOnboardingStateKnown(for member: Member?) -> Bool {
        !hasOnboarding || member?.flags != nil
    }

    /// Discord's `EXPLICIT` (1) and `AGE_RESTRICTED` (3) guild NSFW levels.
    public static func isAgeRestricted(nsfwLevel: Int) -> Bool {
        nsfwLevel == 1 || nsfwLevel == 3
    }

    public init(
        id: GuildID, name: String, iconURL: URL? = nil, accentHex: UInt32 = 0x5865F2,
        unreadCount: Int = 0, mentionCount: Int = 0, isOwnedByCurrentUser: Bool? = nil, ownerID: UserID? = nil,
        currentUserPermissions: UInt64? = nil, rulesChannelID: ChannelID? = nil,
        features: Set<String> = [],
        guideHeaderURL: URL? = nil,
        profileTag: PrimaryGuildIdentity? = nil,
        defaultMessageNotifications: MessageNotificationLevel = .onlyMentions,
        isUnavailable: Bool = false,
        joinedAt: Date? = nil,
        isAgeRestricted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.guideHeaderURL = guideHeaderURL
        self.accentHex = accentHex
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.ownerID = ownerID
        self.currentUserPermissions = currentUserPermissions
        self.rulesChannelID = rulesChannelID
        self.features = features
        self.profileTag = profileTag
        self.defaultMessageNotifications = defaultMessageNotifications
        self.isUnavailable = isUnavailable
        self.joinedAt = joinedAt
        self.isAgeRestricted = isAgeRestricted
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconURL, accentHex, unreadCount, mentionCount, isOwnedByCurrentUser, ownerID
        case currentUserPermissions, rulesChannelID, features, profileTag, defaultMessageNotifications
        case isUnavailable, joinedAt, isAgeRestricted, guideHeaderURL
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(GuildID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        iconURL = try values.decodeIfPresent(URL.self, forKey: .iconURL)
        guideHeaderURL = try values.decodeIfPresent(URL.self, forKey: .guideHeaderURL)
        accentHex = try values.decodeIfPresent(UInt32.self, forKey: .accentHex) ?? 0x5865F2
        unreadCount = try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        mentionCount = try values.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0
        isOwnedByCurrentUser = try values.decodeIfPresent(Bool.self, forKey: .isOwnedByCurrentUser)
        ownerID = try values.decodeIfPresent(UserID.self, forKey: .ownerID)
        currentUserPermissions = try values.decodeIfPresent(UInt64.self, forKey: .currentUserPermissions)
        rulesChannelID = try values.decodeIfPresent(ChannelID.self, forKey: .rulesChannelID)
        features = try values.decodeIfPresent(Set<String>.self, forKey: .features) ?? []
        profileTag = try values.decodeIfPresent(PrimaryGuildIdentity.self, forKey: .profileTag)
        defaultMessageNotifications =
            try values.decodeIfPresent(MessageNotificationLevel.self, forKey: .defaultMessageNotifications)
                ?? .onlyMentions
        joinedAt = try values.decodeIfPresent(Date.self, forKey: .joinedAt)
        isAgeRestricted = try values.decodeIfPresent(Bool.self, forKey: .isAgeRestricted) ?? false
        isUnavailable = try values.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false
    }
}
