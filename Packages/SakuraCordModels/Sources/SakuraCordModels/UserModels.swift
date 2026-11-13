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
    /// Discord marks message-scoped webhook identities with discriminator 0000.
    /// Interaction replies from real bot users retain their normal profiles.
    public var isWebhookIdentity: Bool { isBot && discriminator == "0000" }

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
    public var allowsAdultContent: Bool?

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
        premiumType: Int = 0,
        allowsAdultContent: Bool? = nil
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
        self.allowsAdultContent = allowsAdultContent
    }

    private enum CodingKeys: String, CodingKey {
        case id, username, discriminator, displayName, avatarURL, isBot, isSystem, avatarDecorationURL, nameplate
        case primaryGuild, displayNameStyle, publicFlags, premiumType, allowsAdultContent
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
        allowsAdultContent = try container.decodeIfPresent(Bool.self, forKey: .allowsAdultContent)
    }

    public var tag: String {
        discriminator == "0" ? username : "\(username)#\(discriminator)"
    }

    /// Discord's BOT_HTTP_INTERACTIONS flag identifies bots available without
    /// a Gateway presence: https://docs.discord.com/developers/resources/user#user-flags
    public var usesHTTPInteractions: Bool {
        isBot && publicFlags & (1 << 19) != 0
    }

    /// Discord's VERIFIED_BOT flag marks an app Discord has verified.
    public var isVerifiedBot: Bool {
        isBot && publicFlags & (1 << 16) != 0
    }
}
