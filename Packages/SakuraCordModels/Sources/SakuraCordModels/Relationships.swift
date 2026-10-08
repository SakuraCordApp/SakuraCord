import Foundation

/// Discord's account relationship types. Suggestions and game friends are
/// separate collections and are not represented here.
public enum RelationshipType: Int, Codable, Hashable, Sendable {
    case none = 0
    case friend = 1
    case blocked = 2
    case incomingRequest = 3
    case outgoingRequest = 4
    /// Inferred by Discord from shared activity; never a friendship.
    case implicit = 5
}

/// One relationship record. `user` is nil until the identity is hydrated;
/// the record keeps its identity meanwhile instead of being dropped.
public struct Relationship: Identifiable, Codable, Hashable, Sendable {
    public let id: UserID
    public var type: RelationshipType
    public var user: User?
    /// The private friend nickname, visible only to the current account.
    public var nickname: String?
    public var since: Date?
    public var isSpamRequest: Bool
    public var isUserIgnored: Bool

    public init(
        id: UserID,
        type: RelationshipType,
        user: User? = nil,
        nickname: String? = nil,
        since: Date? = nil,
        isSpamRequest: Bool = false,
        isUserIgnored: Bool = false
    ) {
        self.id = id
        self.type = type
        self.user = user
        self.nickname = nickname
        self.since = since
        self.isSpamRequest = isSpamRequest
        self.isUserIgnored = isUserIgnored
    }
}

public extension Collection<Relationship> {
    var friendUserIDs: Set<UserID> {
        Set(lazy.filter { $0.type == .friend }.map(\.id))
    }

    var nicknamesByUserID: [UserID: String] {
        Dictionary(compactMap { relationship in
            relationship.nickname.map { (relationship.id, $0) }
        }, uniquingKeysWith: { _, newer in newer })
    }
}

/// The account-wide presence of a relationship's user. Absent presence is offline.
public struct UserPresence: Codable, Hashable, Sendable {
    public var status: PresenceStatus
    public var customStatus: String?
    public var activityText: String?
    public var isListeningToMusic: Bool
    public var isMobileOnly: Bool

    public init(
        status: PresenceStatus,
        customStatus: String? = nil,
        activityText: String? = nil,
        isListeningToMusic: Bool = false,
        isMobileOnly: Bool = false
    ) {
        self.status = status
        self.customStatus = customStatus
        self.activityText = activityText
        self.isListeningToMusic = isListeningToMusic
        self.isMobileOnly = isMobileOnly
    }

    public var showsMobileIndicator: Bool {
        status.isVisibleOnline && isMobileOnly
    }
}

/// A relationship mutation Discord rejected. The message is Discord's own
/// user-facing explanation where one exists.
public enum RelationshipActionError: Error, LocalizedError, Equatable, Sendable {
    /// Accepting needs the user's confirmation that they know the requester.
    case strangerConfirmationRequired
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .strangerConfirmationRequired: "Confirm that you know this person before accepting their request."
        case .failed(let reason): reason
        }
    }
}
