import Foundation

// Stateful world records. Field names follow Discord's wire names so the
// renderers stay a direct mapping; values are what Discord would store.

public enum PremiumType: Int, Sendable, Codable {
    case none = 0, nitroClassic = 1, nitro = 2, nitroBasic = 3
}

public struct User: Sendable {
    public var id: Snowflake
    public var username: String
    public var globalName: String?
    public var avatar: String?
    public var banner: String?
    public var bannerColor: String?
    public var accentColor: Int?
    public var bio: String = ""
    public var pronouns: String = ""
    /// Profile theme `[primary, accent]`; nil renders as null.
    public var themeColors: [Int]?
    public var bot = false
    public var system = false
    public var premiumType: PremiumType = .none
    public var premiumSince: Date?
    public var publicFlags = 0
    public var email: String?
    /// Collectibles and the server tag, wire-shaped (`avatar_decoration_data`,
    /// `collectibles`, `primary_guild`); nil renders as null.
    public var avatarDecoration: JSON?
    public var collectibles: JSON?
    public var primaryGuild: JSON?
    /// Simulator-local sign-in secret for `POST /auth/login`; never rendered.
    public var password: String?
    public var createdAt: Date { id.date }

    public init(id: Snowflake, username: String, globalName: String? = nil) {
        self.id = id
        self.username = username
        self.globalName = globalName
    }
}

public enum PresenceStatus: String, Sendable, Codable {
    case online, idle, dnd, offline, invisible
}

public struct Presence: Sendable {
    public var status: PresenceStatus = .offline
    /// Activities as Discord sends them (already wire-shaped).
    public var activities: [JSON] = []
    public var clientStatus: [String: PresenceStatus] = [:]
}

public struct Role: Sendable {
    public var id: Snowflake
    public var name: String
    public var color = 0
    public var hoist = false
    public var position = 0
    public var permissions: Permissions = []
    public var mentionable = false
    public var managed = false
    public var icon: String?
    public var unicodeEmoji: String?
    public var flags = 0
}

public struct Member: Sendable {
    public var userID: Snowflake
    public var nick: String?
    public var avatar: String?
    public var banner: String?
    public var roles: [Snowflake] = []
    public var joinedAt: Date
    public var premiumSince: Date?
    public var deaf = false
    public var mute = false
    public var pending = false
    public var flags = 0
    public var communicationDisabledUntil: Date?
    /// The per-server profile (`PATCH /guilds/{id}/profile/@me`); nil means "use the main profile".
    public var pronouns = ""
    public var bio: String?
    public var accentColor: Int?
    public var themeColors: [Int]?
}

public struct PermissionOverwrite: Sendable {
    public enum Kind: Int, Sendable { case role = 0, member = 1 }
    public var id: Snowflake
    public var kind: Kind
    public var allow: Permissions
    public var deny: Permissions
}

public enum ChannelType: Int, Sendable, Codable {
    case text = 0, dm = 1, voice = 2, groupDM = 3, category = 4, announcement = 5
    case announcementThread = 10, publicThread = 11, privateThread = 12
    case stage = 13, directory = 14, forum = 15, media = 16

    public var isThread: Bool { [.announcementThread, .publicThread, .privateThread].contains(self) }
    public var isPrivate: Bool { self == .dm || self == .groupDM }
    public var holdsMessages: Bool { ![.category, .forum, .media, .directory].contains(self) }
}

public struct ForumTag: Sendable {
    public var id: Snowflake
    public var name: String
    public var moderated = false
    public var emojiName: String?
}

public struct ThreadMetadata: Sendable {
    public var archived = false
    public var autoArchiveDuration = 4320
    public var archiveTimestamp: Date
    public var locked = false
    public var invitable = true
    public var createTimestamp: Date
}

public struct Channel: Sendable {
    public var id: Snowflake
    public var type: ChannelType
    public var guildID: Snowflake?
    public var name: String?
    public var topic: String?
    public var position = 0
    public var parentID: Snowflake?
    public var overwrites: [PermissionOverwrite] = []
    public var nsfw = false
    public var rateLimitPerUser = 0
    public var bitrate = 64000
    public var userLimit = 0
    public var recipients: [Snowflake] = []
    public var ownerID: Snowflake?
    public var icon: String?
    public var lastPinTimestamp: Date?
    public var flags = 0
    public var thread: ThreadMetadata?
    public var threadMembers: [Snowflake] = []
    /// Thread members who muted the thread.
    public var mutedThreadMembers: Set<Snowflake> = []
    public var appliedTags: [Snowflake] = []
    public var availableTags: [ForumTag] = []
    public var defaultSortOrder: Int?
    public var defaultForumLayout = 0
    /// Messages in ID order. Deleted messages are removed.
    public var messages: [Message] = []
    /// Total messages ever sent in a thread, including deleted ones.
    public var totalMessageSent = 0

    public var lastMessageID: Snowflake? { messages.last?.id }
}

public struct Emoji: Sendable {
    public var id: Snowflake
    public var name: String
    public var animated = false
    public var roles: [Snowflake] = []
    public var creatorID: Snowflake?
    public var available = true
}

/// A soundboard sound: a server's own, or one of Discord's defaults (`guildID` nil).
public struct SoundboardSound: Sendable {
    public var id: Snowflake
    public var name: String
    public var emojiName: String?
    public var volume = 1.0
    public var userID: Snowflake?
}

public struct Sticker: Sendable {
    public var id: Snowflake
    public var name: String
    public var description: String?
    public var tags: String
    /// 1 PNG, 2 APNG, 3 Lottie, 4 GIF.
    public var formatType = 1
}

public struct Guild: Sendable {
    public var id: Snowflake
    public var name: String
    public var icon: String?
    public var banner: String?
    public var splash: String?
    public var description: String?
    public var ownerID: Snowflake
    public var roles: [Role] = []
    public var members: [Snowflake: Member] = [:]
    public var memberOrder: [Snowflake] = []
    public var channelIDs: [Snowflake] = []
    public var emojis: [Emoji] = []
    public var stickers: [Sticker] = []
    public var features: [String] = []
    public var preferredLocale = "en-US"
    public var verificationLevel = 1
    public var systemChannelID: Snowflake?
    public var rulesChannelID: Snowflake?
    public var afkChannelID: Snowflake?
    /// The server tag members can wear (`tag`, badge asset hash), if the server has one.
    public var serverTag: (tag: String, badge: String)?
    public var soundboardSounds: [SoundboardSound] = []
    /// Active boosts: who boosts and since when. Count and tier derive from it.
    public var boosts: [(userID: Snowflake, since: Date)] = []
    /// Discord's member count for a server too large to hold every member; nil counts `members`.
    public var approximateMemberCount: Int?
    public var approximatePresenceCount: Int?

    public var memberCount: Int { approximateMemberCount ?? members.count }

    public var everyoneRole: Role? { roles.first { $0.id == id } }
    public var premiumSubscriptionCount: Int { boosts.count }
    /// Level thresholds as shown by the official client: 2, 7, 14 boosts.
    public var premiumTier: Int {
        switch boosts.count {
        case 14...: 3
        case 7...: 2
        case 2...: 1
        default: 0
        }
    }
}

public struct Attachment: Sendable {
    public var id: Snowflake
    public var filename: String
    public var size: Int
    public var contentType: String?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var waveform: String?
    public var description: String?
    public var spoiler = false
    public var flags = 0
    /// ThumbHash of an image, as Discord's `placeholder`.
    public var placeholder: String?
    /// Path on the CDN host, e.g. `/attachments/<channel>/<id>/<filename>`.
    public var cdnPath: String
}

public struct Reaction: Sendable {
    /// Unicode emoji, or a custom emoji's name with its ID.
    public var emojiName: String
    public var emojiID: Snowflake?
    public var animated = false
    public var users: [Snowflake] = []
    public var burstUsers: [Snowflake] = []
    public var burstColors: [String] = []

    public var key: String { Self.key(name: emojiName, id: emojiID) }

    static func key(name: String, id: Snowflake?) -> String { id.map { "\(name):\($0)" } ?? name }
}

public struct Poll: Sendable {
    public struct Answer: Sendable {
        public var id: Int
        public var text: String
        public var emoji: String?
        public var voters: [Snowflake] = []
    }

    public var question: String
    public var answers: [Answer]
    public var expiry: Date
    public var allowMultiselect = false
    public var layoutType = 1
    public var finalized = false
}

public struct MessageReference: Sendable {
    /// 0 reply, 1 forward.
    public var type = 0
    public var messageID: Snowflake?
    public var channelID: Snowflake
    public var guildID: Snowflake?
}

public struct Message: Sendable {
    public var id: Snowflake
    public var channelID: Snowflake
    public var authorID: Snowflake
    public var content: String
    public var editedAt: Date?
    public var type = 0
    public var flags = 0
    public var tts = false
    public var mentionEveryone = false
    public var mentions: [Snowflake] = []
    public var mentionRoles: [Snowflake] = []
    public var attachments: [Attachment] = []
    /// Embeds and components are stored wire-shaped.
    public var embeds: [JSON] = []
    public var components: [JSON] = []
    public var reactions: [Reaction] = []
    public var pinned = false
    /// When it was pinned; pins list and paginate by this, not by message age.
    public var pinnedAt: Date?
    public var reference: MessageReference?
    /// A forwarded message's snapshot, wire-shaped.
    public var messageSnapshots: [JSON] = []
    public var poll: Poll?
    public var stickerIDs: [Snowflake] = []
    public var nonce: String?
    public var threadID: Snowflake?
    public var webhookID: Snowflake?
    public var applicationID: Snowflake?
    public var interaction: InteractionRecord?
    /// A call message's participants and end, wire-shaped.
    public var call: JSON?

    public var timestamp: Date { id.date }
}

public enum RelationshipType: Int, Sendable {
    /// `unrelated`: someone the user ignores without any other relationship.
    case unrelated = 0, friend = 1, blocked = 2, incoming = 3, outgoing = 4
}

public struct Relationship: Sendable {
    public var userID: Snowflake
    public var type: RelationshipType
    public var nickname: String?
    public var since: Date
    /// Ignored users stay friends but their activity is hidden.
    public var ignored = false
}

public struct ReadState: Sendable {
    public var lastAckedID: Snowflake?
    public var mentionCount = 0
    public var lastPinTimestamp: Date?
    public var lastViewed: Int?
}
