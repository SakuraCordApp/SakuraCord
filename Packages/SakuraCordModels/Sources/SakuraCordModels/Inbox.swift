import Foundation

public enum InboxTab: Int, Codable, CaseIterable, Sendable {
    case mentions = 1
    case unread = 2
    case scheduled = 7
}

public struct InboxMentionQuery: Equatable, Sendable {
    public var guildID: GuildID?
    public var includesRoles: Bool
    public var includesEveryone: Bool

    public init(guildID: GuildID? = nil, includesRoles: Bool = true, includesEveryone: Bool = true) {
        self.guildID = guildID
        self.includesRoles = includesRoles
        self.includesEveryone = includesEveryone
    }
}

public struct InboxMentionPage: Equatable, Sendable {
    public var messages: [Message]
    public var threads: [MessageThreadSummary]
    /// The server's last result, including unsupported messages skipped during decoding.
    public var nextBefore: MessageID?
    public var hasMore: Bool

    public init(messages: [Message], nextBefore: MessageID?, hasMore: Bool, threads: [MessageThreadSummary] = []) {
        self.messages = messages
        self.threads = threads
        self.nextBefore = nextBefore
        self.hasMore = hasMore
    }
}

public struct InboxSettings: Equatable, Sendable {
    public var tab: InboxTab
    public var collapsedChannelIDs: Set<ChannelID>
    public var collapsedEventGuildIDs: Set<GuildID>
    public var favoriteChannelIDs: Set<ChannelID>

    public init(tab: InboxTab = .unread, collapsedChannelIDs: Set<ChannelID> = [], favoriteChannelIDs: Set<ChannelID> = [], collapsedEventGuildIDs: Set<GuildID> = []) {
        self.collapsedEventGuildIDs = collapsedEventGuildIDs
        self.tab = tab
        self.collapsedChannelIDs = collapsedChannelIDs
        self.favoriteChannelIDs = favoriteChannelIDs
    }
}
