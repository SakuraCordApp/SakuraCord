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

    public init(userID: UserID, sessionID: String) {
        self.userID = userID
        self.sessionID = sessionID
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

    public init(
        id: ApplicationID,
        name: String,
        description: String = "",
        iconURL: URL? = nil,
        coverURL: URL? = nil,
        tags: [String] = [],
        maximumParticipants: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconURL = iconURL
        self.coverURL = coverURL
        self.tags = tags
        self.maximumParticipants = maximumParticipants
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

    public init(
        applicationID: ApplicationID,
        scopes: [String],
        state: String? = nil,
        codeChallenge: String? = nil,
        codeChallengeMethod: String? = nil,
        location: EmbeddedActivityLocation
    ) {
        self.applicationID = applicationID
        self.scopes = scopes
        self.state = state
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
        self.location = location
    }
}

/// Discord's consent details for an Activity authorization request.
public struct EmbeddedActivityAuthorizationPreview: Hashable, Sendable {
    public var applicationName: String
    /// Discord already holds a grant for these scopes; no consent is shown.
    public var isAuthorized: Bool

    public init(applicationName: String, isAuthorized: Bool) {
        self.applicationName = applicationName
        self.isAuthorized = isAuthorized
    }
}
