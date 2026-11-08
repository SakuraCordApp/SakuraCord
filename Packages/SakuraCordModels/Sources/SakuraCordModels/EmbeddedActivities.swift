import Foundation

/// Where an Activity instance runs: a guild voice channel (`gc`) or a private
/// channel (`pc`). Discord identifies it as `gc-GUILD-CHANNEL` / `pc-CHANNEL`.
public struct EmbeddedActivityLocation: Hashable, Sendable {
    public var id: String
    public var channelID: ChannelID
    public var guildID: GuildID?

    public init(id: String, channelID: ChannelID, guildID: GuildID?) {
        self.id = id
        self.channelID = channelID
        self.guildID = guildID
    }
}

public struct EmbeddedActivityParticipant: Hashable, Sendable {
    public var userID: UserID
    public var sessionID: String
    /// The nonce of the interaction that added this participant.
    public var nonce: String?

    public init(userID: UserID, sessionID: String, nonce: String? = nil) {
        self.userID = userID
        self.sessionID = sessionID
        self.nonce = nonce
    }
}

/// One running Activity, shared by everyone in it. An instance without
/// participants has ended.
public struct EmbeddedActivityInstance: Hashable, Sendable {
    public var applicationID: ApplicationID
    public var instanceID: String
    public var compositeInstanceID: String
    public var location: EmbeddedActivityLocation
    public var participants: [EmbeddedActivityParticipant]

    public init(
        applicationID: ApplicationID,
        instanceID: String,
        compositeInstanceID: String,
        location: EmbeddedActivityLocation,
        participants: [EmbeddedActivityParticipant]
    ) {
        self.applicationID = applicationID
        self.instanceID = instanceID
        self.compositeInstanceID = compositeInstanceID
        self.location = location
        self.participants = participants
    }

    /// Each account playing, once however many of its sessions take part.
    public var playerIDs: [UserID] {
        var seen = Set<UserID>()
        return participants.map(\.userID).filter { seen.insert($0).inserted }
    }
}

/// An application that can run as an Activity, as listed by the Activity shelf.
public struct EmbeddedActivityApplication: Identifiable, Hashable, Sendable {
    public var id: ApplicationID
    public var name: String
    public var description: String
    public var iconURL: URL?
    public var coverURL: URL?
    public var tags: [String]
    /// Nil when unlimited.
    public var maximumParticipants: Int?
    /// Discord marks sponsored shelf entries as promoted.
    public var isPromoted: Bool
    /// Discord asks for age confirmation before launching.
    public var requiresAgeGate: Bool
    public var hasInAppPurchases: Bool
    /// Discord opens it on its own rather than in a channel: no instance, no
    /// launch message, and the Activity asks for its grant before anything else.
    public var isContextless: Bool
    /// Position in the account's application frecency, then by name; Recents
    /// list the installed Activities in this order.
    public var recentRank: Int?

    public init(
        id: ApplicationID,
        name: String,
        description: String = "",
        iconURL: URL? = nil,
        coverURL: URL? = nil,
        tags: [String] = [],
        maximumParticipants: Int? = nil,
        isPromoted: Bool = false,
        requiresAgeGate: Bool = false,
        hasInAppPurchases: Bool = false,
        isContextless: Bool = false,
        recentRank: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconURL = iconURL
        self.coverURL = coverURL
        self.tags = tags
        self.maximumParticipants = maximumParticipants
        self.isPromoted = isPromoted
        self.requiresAgeGate = requiresAgeGate
        self.hasInAppPurchases = hasInAppPurchases
        self.isContextless = isContextless
        self.recentRank = recentRank
    }

    /// The Activity's Discord-proxied origin.
    public var activityURL: URL {
        URL(string: "https://\(id).discordsays.com/")!
    }
}

/// What an Activity asked to be authorized for, before the person consents.
public struct EmbeddedActivityAuthorizationRequest: Hashable, Sendable {
    public var applicationID: ApplicationID
    public var scopes: [String]
    public var state: String?
    public var codeChallenge: String?
    public var codeChallengeMethod: String?
    public var location: EmbeddedActivityLocation
    /// Discord's type for the channel the Activity runs in.
    public var channelType: Int

    public init(
        applicationID: ApplicationID,
        scopes: [String],
        state: String? = nil,
        codeChallenge: String? = nil,
        codeChallengeMethod: String? = nil,
        location: EmbeddedActivityLocation,
        channelType: Int
    ) {
        self.applicationID = applicationID
        self.scopes = scopes
        self.state = state
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
        self.location = location
        self.channelType = channelType
    }
}

/// Discord's consent details for an Activity authorization request.
public struct EmbeddedActivityAuthorizationPreview: Hashable, Sendable {
    public var applicationName: String
    /// Discord already holds a grant for these scopes; no consent is shown.
    public var isAuthorized: Bool
    /// Disclosures the person hasn't acknowledged, such as the developer
    /// seeing their IP address; the consent shows them until acknowledged.
    public var unacknowledgedDisclosures: [EmbeddedActivityDisclosure]

    public init(applicationName: String, isAuthorized: Bool, unacknowledgedDisclosures: [EmbeddedActivityDisclosure] = []) {
        self.applicationName = applicationName
        self.isAuthorized = isAuthorized
        self.unacknowledgedDisclosures = unacknowledgedDisclosures
    }
}

/// What an Activity's developer discloses before the person uses it.
public enum EmbeddedActivityDisclosure: Int, Hashable, Sendable {
    case ipLocation = 1
    case displaysAdvertisements = 2
}
