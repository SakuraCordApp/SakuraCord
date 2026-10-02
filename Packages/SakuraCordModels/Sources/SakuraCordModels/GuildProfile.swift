import Foundation

/// Public server information from `GET /guilds/{guild}/profile`, shown beside
/// its guide and on server tag cards.
public struct GuildProfile: Decodable, Equatable, Sendable {
    public var id: GuildID
    public var name: String
    public var description: String?
    public var iconHash: String?
    public var customBannerHash: String?
    public var memberCount: Int
    public var onlineCount: Int
    public var brandColor: UInt32?
    public var visibility: Int
    public var features: Set<String>
    public var traits: [Trait]
    public var gameApplicationIDs: [String]
    public var gameActivityScores: [String: Double]
    public var badgeHash: String?

    public struct Trait: Decodable, Equatable, Sendable {
        public var label: String
        public var emojiName: String?
        public var emojiID: String?
        enum CodingKeys: String, CodingKey { case label, emojiName = "emoji_name", emojiID = "emoji_id" }

        public var emojiURL: URL? { emojiID.flatMap { URL(string: "https://cdn.discordapp.com/emojis/\($0).webp?size=32") } }
    }

    public init(from decoder: any Decoder) throws {
        struct Activity: Decodable {
            var score: Double?
            enum CodingKeys: String, CodingKey { case score = "activity_score" }
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(GuildID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        iconHash = try values.decodeIfPresent(String.self, forKey: .iconHash)
        memberCount = try values.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        onlineCount = try values.decodeIfPresent(Int.self, forKey: .onlineCount) ?? 0
        brandColor = try values.decodeIfPresent(String.self, forKey: .brandColorPrimary)
            .flatMap { UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) }
        traits = try values.decodeIfPresent([Trait].self, forKey: .traits) ?? []
        // Card enrichment is optional: an unexpected shape must not hide the guide profile.
        customBannerHash = (try? values.decodeIfPresent(String.self, forKey: .customBannerHash)) ?? nil
        visibility = (try? values.decodeIfPresent(Int.self, forKey: .visibility)) ?? 0
        features = (try? values.decodeIfPresent(Set<String>.self, forKey: .features)) ?? []
        gameApplicationIDs = (try? values.decodeIfPresent([String].self, forKey: .gameApplicationIDs)) ?? []
        gameActivityScores = ((try? values.decodeIfPresent([String: Activity].self, forKey: .gameActivity)) ?? [:])
            .compactMapValues(\.score)
        // `badge` is a numeric preset; the CDN image uses `badge_hash`.
        badgeHash = (try? values.decodeIfPresent(String.self, forKey: .badgeHash)) ?? nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, traits, visibility, features
        case iconHash = "icon_hash", customBannerHash = "custom_banner_hash", badgeHash = "badge_hash"
        case memberCount = "member_count", onlineCount = "online_count", brandColorPrimary = "brand_color_primary"
        case gameApplicationIDs = "game_application_ids", gameActivity = "game_activity"
    }

    public var isDiscoverable: Bool { features.contains("DISCOVERABLE") }

    public var iconURL: URL? {
        iconHash.flatMap {
            URL(string: "https://cdn.discordapp.com/icons/\(id)/\($0).webp?size=128&animated=\($0.hasPrefix("a_") ? "true" : "false")")
        }
    }

    public var badgeURL: URL? {
        badgeHash.flatMap { URL(string: "https://cdn.discordapp.com/clan-badges/\(id)/\($0).png?size=32") }
    }

    /// The first-party card shows the custom banner only for discoverable servers.
    public var bannerURL: URL? {
        guard isDiscoverable, let customBannerHash else { return nil }
        return URL(string: "https://cdn.discordapp.com/discovery-splashes/\(id)/\(customBannerHash).jpg?size=512")
    }

    /// Game applications ordered by the server's reported activity, as the first-party card presents them.
    public var rankedGameApplicationIDs: [String] {
        gameApplicationIDs.enumerated().sorted {
            let lhs = gameActivityScores[$0.element] ?? 0, rhs = gameActivityScores[$1.element] ?? 0
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
    }

    /// Without an invite, the first-party card offers Join only for discoverable servers; manual-approval
    /// screening with visibility 3 (`PUBLIC_WITH_RECRUITMENT`) offers an application instead.
    public var isDirectlyJoinable: Bool {
        let appliesToJoin = visibility == 3 && features.contains("MEMBER_VERIFICATION_GATE_ENABLED")
            && features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL")
        return isDiscoverable && !appliesToJoin
    }
}

public enum GuildProfileError: Error, Equatable, Sendable {
    /// The server limits who can see its profile.
    case restricted
}
