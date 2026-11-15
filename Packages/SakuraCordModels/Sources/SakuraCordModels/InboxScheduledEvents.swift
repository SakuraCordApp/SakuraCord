import Foundation

public enum ScheduledEventKind: Sendable {}
public typealias ScheduledEventID = Snowflake<ScheduledEventKind>

public struct InboxScheduledEvent: Identifiable, Equatable, Sendable {
    public var id: ScheduledEventID
    public var guildID: GuildID
    public var channelID: ChannelID?
    public var creatorID: UserID?
    public var name: String
    public var description: String?
    public var location: String?
    public var startTime: Date
    public var endTime: Date?
    public var status: Int
    public var isInterested: Bool

    public init(id: ScheduledEventID, guildID: GuildID, channelID: ChannelID? = nil, creatorID: UserID? = nil,
                name: String, description: String? = nil, location: String? = nil, startTime: Date,
                endTime: Date? = nil, status: Int = 1, isInterested: Bool = false) {
        self.id = id
        self.guildID = guildID
        self.channelID = channelID
        self.creatorID = creatorID
        self.name = name
        self.description = description
        self.location = location
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.isInterested = isInterested
    }

    /// Discord's active status (2).
    public var isActive: Bool { status == 2 }
    /// The Inbox lists scheduled (1) and active events only.
    public var isScheduledOrActive: Bool { status == 1 || isActive }
}

public struct InboxEventReadState: Equatable, Sendable {
    public var lastAcknowledgedID: ScheduledEventID?
    public var latestID: ScheduledEventID?
    public var mentionCount: Int
    public var version: Int?

    public init(lastAcknowledgedID: ScheduledEventID? = nil, latestID: ScheduledEventID? = nil,
                mentionCount: Int = 0, version: Int? = nil) {
        self.lastAcknowledgedID = lastAcknowledgedID
        self.latestID = latestID
        self.mentionCount = mentionCount
        self.version = version
    }
}

public struct InboxScheduledEvents: Equatable, Sendable {
    public var events: [InboxScheduledEvent]
    public var readStates: [GuildID: InboxEventReadState]

    public init(events: [InboxScheduledEvent] = [], readStates: [GuildID: InboxEventReadState] = [:]) {
        self.events = events
        self.readStates = readStates
    }
}
