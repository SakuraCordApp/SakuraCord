import Foundation

/// The structure of a real account with everything identifying removed: counts,
/// proportions, states and activity rates only. `ProfileExtractor` writes it
/// from captures (jittered and shuffled so no server maps back to a real one);
/// `RealisticWorld` builds a world of the same size and shape from it.
public struct AccountProfile: Codable, Sendable, Equatable {
    public var servers: [ServerProfile]
    /// The server rail in order: folders and single servers.
    public var folders: [FolderProfile]
    public var directMessages: DirectMessageProfile
    public var relationships: RelationshipProfile

    public static func bundled(_ name: String) throws -> AccountProfile {
        try JSONDecoder().decode(AccountProfile.self, from: Data(contentsOf: bundledURL(name)))
    }

    static func bundledURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Profiles") else {
            throw WorldError.invalidBody("no bundled account profile \(name)")
        }
        return url
    }
}

public struct ServerProfile: Codable, Sendable, Equatable {
    /// Channel counts by kind (`text`, `voice`, `announcement`, `forum`, `stage`, `media`)
    /// per category, in channel-list order. The first entry is the uncategorized top of the list.
    public var categories: [[String: Int]]
    public var roles: Int
    public var emojis: Int
    public var animatedEmojis: Int
    public var stickers: Int
    public var memberCount: Int
    public var boostCount: Int
    public var boostTier: Int
    public var community: Bool
    public var discoverable: Bool
    /// Channels with a permission overwrite, i.e. private or restricted.
    public var restrictedChannels: Int
    public var activeThreads: Int
    public var forumPosts: Int
    public var scheduledEvents: Int
    public var peopleInVoice: Int
    public var settings: ServerSettingsProfile
    public var readState: ServerReadStateProfile
    public var activity: ActivityProfile
}

public struct ServerSettingsProfile: Codable, Sendable, Equatable {
    public var muted = false
    public var suppressEveryone = false
    public var suppressRoles = false
    /// 0 all messages, 1 mentions only, 2 nothing, 3 server default.
    public var messageNotifications = 3
    public var hideMutedChannels = false
    public var mutedChannels = 0
    public var collapsedCategories = 0
    /// Channels whose notification level differs from the server's.
    public var notificationOverrides = 0
}

public struct ServerReadStateProfile: Codable, Sendable, Equatable {
    public var unreadChannels = 0
    /// Mention badge sizes, one per channel with mentions.
    public var mentions: [Int] = []
}

/// Live traffic rates for one server, per hour.
public struct ActivityProfile: Codable, Sendable, Equatable {
    public var messages = 0.0
    public var typing = 0.0
    public var reactions = 0.0
    public var presence = 0.0
    public var edits = 0.0
    public var deletes = 0.0
    /// How a server's messages spread over its busiest channels, largest share first.
    public var channelShares: [Double] = []
}

/// A rail entry: a folder of `servers`, or a single server (`servers` 1, never named or coloured).
public struct FolderProfile: Codable, Sendable, Equatable {
    public var servers: Int
    public var named: Bool
    public var colored: Bool
}

public struct DirectMessageProfile: Codable, Sendable, Equatable {
    public var dms: Int
    public var groupDMs: Int
    /// Recipients per group DM, excluding the account.
    public var groupSizes: [Int]
}

public struct RelationshipProfile: Codable, Sendable, Equatable {
    public var friends: Int
    public var blocked: Int
    /// Online friends by status when the account started.
    public var friendStatuses: [String: Int]
}
