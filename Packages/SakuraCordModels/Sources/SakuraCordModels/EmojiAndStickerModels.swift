import Foundation

public struct DiscordEmoji: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var isAnimated: Bool
    public var guildID: GuildID
    public var isAvailable: Bool
    public var isManaged: Bool
    public var roleIDs: [RoleID]
    public var assetURL: URL?

    public init(
        id: String,
        name: String,
        isAnimated: Bool = false,
        guildID: GuildID,
        isAvailable: Bool = true,
        assetURL: URL? = nil,
        isManaged: Bool = false,
        roleIDs: [RoleID] = []
    ) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
        self.guildID = guildID
        self.isAvailable = isAvailable
        self.assetURL = assetURL
        self.isManaged = isManaged
        self.roleIDs = roleIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isAnimated, guildID, isAvailable, assetURL, isManaged, roleIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isAnimated = try container.decode(Bool.self, forKey: .isAnimated)
        guildID = try container.decode(GuildID.self, forKey: .guildID)
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
        assetURL = try container.decodeIfPresent(URL.self, forKey: .assetURL)
        isManaged = try container.decodeIfPresent(Bool.self, forKey: .isManaged) ?? false
        roleIDs = try container.decodeIfPresent([RoleID].self, forKey: .roleIDs) ?? []
    }

    public var messageToken: String {
        "<\(isAnimated ? "a" : ""):\(name):\(id)>"
    }

    public var reactionToken: String {
        "\(name):\(id)"
    }

    public var imageURL: URL? {
        assetURL ?? Self.imageURL(id: id, isAnimated: isAnimated)
    }

    public static func imageURL(id: String, isAnimated: Bool) -> URL? {
        DiscordCDN.emoji(id, fileExtension: "webp", query: "size=96&animated=\(isAnimated ? "true" : "false")")
    }

    public var linkedImageMarkdown: String {
        "[\(name)](https://cdn.discordapp.com/emojis/\(id).\(isAnimated ? "gif" : "webp")?size=48&animated=\(isAnimated ? "true" : "false")&name=\(name)&lossless=true)"
    }
}

public struct EmojiUserSettings: Equatable, Sendable {
    public var favoriteKeys: [String]
    public var dataVersion: UInt32?
    public var messageHistory: DiscordFrecencyHistory
    public var reactionHistory: DiscordFrecencyHistory
    public var guildAndChannelUsageScores: [String: Int]
    public var guildAndChannelUsage: [String: DiscordFrecencyUsage]
    public var guildAndChannelUsageOrder: [String]

    public init(
        favoriteKeys: [String] = [],
        dataVersion: UInt32? = nil,
        messageHistory: DiscordFrecencyHistory = .init(),
        reactionHistory: DiscordFrecencyHistory = .init(),
        guildAndChannelUsageScores: [String: Int] = [:],
        guildAndChannelUsage: [String: DiscordFrecencyUsage] = [:],
        guildAndChannelUsageOrder: [String] = []
    ) {
        self.dataVersion = dataVersion
        self.messageHistory = messageHistory
        self.reactionHistory = reactionHistory
        self.favoriteKeys = favoriteKeys
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

public struct StickerUserSettings: Equatable, Sendable {
    public var favoriteIDs: [String]
    public var frequentlyUsedIDs: [String]
    public var usageScores: [String: Int]
    public var usage: [String: DiscordFrecencyUsage]
    public var usageOrder: [String]

    public init(
        favoriteIDs: [String] = [],
        frequentlyUsedIDs: [String] = [],
        usageScores: [String: Int] = [:],
        usage: [String: DiscordFrecencyUsage] = [:],
        usageOrder: [String] = []
    ) {
        self.favoriteIDs = favoriteIDs
        self.frequentlyUsedIDs = frequentlyUsedIDs
        self.usageScores = usageScores
        self.usage = usage
        self.usageOrder = usageOrder
    }
}
