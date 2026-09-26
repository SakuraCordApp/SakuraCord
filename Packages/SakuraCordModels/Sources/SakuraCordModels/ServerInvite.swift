import Foundation

/// A validated invite key. Codes are case-sensitive; never interpolate arbitrary URLs into REST paths.
public struct ServerInviteReference: Hashable, Sendable {
    public let code: String

    public init?(_ input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let code: String
        if input.contains("/") {
            guard let url = URL(string: input.contains("://") ? input : "https://\(input)"),
                  url.scheme == "https" || url.scheme == "http",
                  url.user == nil, url.password == nil, url.port == nil else { return nil }
            let parts = url.path.split(separator: "/")
            switch url.host?.lowercased() {
            case "discord.gg":
                guard parts.count == 1 else { return nil }
                code = String(parts[0])
            case "discord.com", "discordapp.com":
                guard parts.count == 2, parts[0] == "invite" else { return nil }
                code = String(parts[1])
            default: return nil
            }
        } else {
            code = input
        }
        guard !code.isEmpty, code.utf8.count <= 128,
              code.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0)
                  || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        self.code = code
    }

    public var url: URL { URL(string: "https://discord.gg/\(code)")! }
}

public struct ServerInvite: Equatable, Sendable {
    public struct Trait: Equatable, Sendable {
        public var label: String
        public var emoji: String?
        public var emojiURL: URL?

        public init(label: String, emoji: String? = nil, emojiURL: URL? = nil) {
            self.label = label
            self.emoji = emoji
            self.emojiURL = emojiURL
        }
    }

    public var reference: ServerInviteReference
    public var guildID: GuildID
    public var channelID: ChannelID?
    public var channelType: Int?
    public var name: String
    public var iconURL: URL?
    public var inviter: User?
    public var brandColor: UInt32?
    public var description: String?
    public var traits: [Trait]
    public var memberCount: Int?
    public var onlineCount: Int?
    public var expiresAt: Date?
    public var features: Set<String>
    public var requiresSpecialAcceptance: Bool

    public init(reference: ServerInviteReference, guildID: GuildID, channelID: ChannelID? = nil,
                channelType: Int? = nil, name: String, iconURL: URL? = nil, inviter: User? = nil,
                brandColor: UInt32? = nil, description: String? = nil, traits: [Trait] = [],
                memberCount: Int? = nil, onlineCount: Int? = nil, expiresAt: Date? = nil,
                features: Set<String> = [], requiresSpecialAcceptance: Bool = false) {
        self.reference = reference
        self.guildID = guildID
        self.channelID = channelID
        self.channelType = channelType
        self.name = name
        self.iconURL = iconURL
        self.inviter = inviter
        self.brandColor = brandColor
        self.description = description
        self.traits = traits
        self.memberCount = memberCount
        self.onlineCount = onlineCount
        self.expiresAt = expiresAt
        self.features = features
        self.requiresSpecialAcceptance = requiresSpecialAcceptance
    }

    public var unsupportedJoinReason: String? {
        if features.contains("MEMBER_VERIFICATION_GATE_ENABLED") {
            return "This server requires member screening. Join it in Discord, then return to SakuraCord."
        }
        if requiresSpecialAcceptance {
            return "This invitation requires a Discord-specific joining flow. Open it in Discord to continue."
        }
        return nil
    }
}

public enum ServerInviteError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case banned
    case serverLimit
    case unsupported(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This invite is invalid or has expired. Ask for a new invite."
        case .banned: "You are banned from this server. An administrator must remove the ban before you can join."
        case .serverLimit: "You have reached Discord’s server limit. Leave a server before joining another."
        case .unsupported(let reason), .failed(let reason): reason
        }
    }
}

public struct ServerInviteAcceptance: Sendable {
    public var invite: ServerInvite
    public var requiresVerification: Bool

    public init(invite: ServerInvite, requiresVerification: Bool = false) {
        self.invite = invite
        self.requiresVerification = requiresVerification
    }
}
