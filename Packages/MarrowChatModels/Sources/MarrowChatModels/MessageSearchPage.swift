import Foundation

public enum MessageSearchScope: Equatable, Sendable {
    case guild(GuildID)
    case directMessages

    public var guildID: GuildID? {
        guard case let .guild(guildID) = self else { return nil }
        return guildID
    }
}

public enum MessageSearchContentType: String, CaseIterable, Codable, Hashable, Sendable {
    case image
    case video
    case link
    case file
    case embed
    case sound
    case poll
    case sticker
    case forward
}

public enum MessageSearchAuthorType: String, CaseIterable, Codable, Hashable, Sendable {
    case user
    case bot
    case webhook
}

public enum MessageSearchSort: String, CaseIterable, Codable, Hashable, Sendable {
    case newest
    case oldest
    case mostRelevant

    public var sortBy: String {
        switch self {
        case .newest, .oldest:
            "timestamp"
        case .mostRelevant:
            "relevance"
        }
    }

    public var sortOrder: String {
        self == .oldest ? "asc" : "desc"
    }
}

public struct MessageSearchFilters: Equatable, Sendable {
    public var authorIDs: [UserID]
    public var channelIDs: [ChannelID]
    public var mentionedUserIDs: [UserID]
    public var contentTypes: [MessageSearchContentType]
    public var authorTypes: [MessageSearchAuthorType]
    public var pinned: Bool?
    public var minimumMessageID: MessageID?
    public var maximumMessageID: MessageID?

    public init(
        authorIDs: [UserID] = [],
        channelIDs: [ChannelID] = [],
        mentionedUserIDs: [UserID] = [],
        contentTypes: [MessageSearchContentType] = [],
        authorTypes: [MessageSearchAuthorType] = [],
        pinned: Bool? = nil,
        minimumMessageID: MessageID? = nil,
        maximumMessageID: MessageID? = nil
    ) {
        self.authorIDs = authorIDs
        self.channelIDs = channelIDs
        self.mentionedUserIDs = mentionedUserIDs
        self.contentTypes = contentTypes
        self.authorTypes = authorTypes
        self.pinned = pinned
        self.minimumMessageID = minimumMessageID
        self.maximumMessageID = maximumMessageID
    }

    public var count: Int {
        authorIDs.count
            + channelIDs.count
            + mentionedUserIDs.count
            + contentTypes.count
            + authorTypes.count
            + (pinned == nil ? 0 : 1)
            + (minimumMessageID == nil ? 0 : 1)
            + (maximumMessageID == nil ? 0 : 1)
    }

    public var isEmpty: Bool { count == 0 }
}

public struct MessageSearchQuery: Equatable, Sendable {
    public static let pageSize = 25
    public static let maximumOffset = 9_975

    public var scope: MessageSearchScope
    public var content: String
    public var filters: MessageSearchFilters
    public var sort: MessageSearchSort
    public var offset: Int

    public init(
        scope: MessageSearchScope,
        content: String = "",
        filters: MessageSearchFilters = .init(),
        sort: MessageSearchSort = .newest,
        offset: Int = 0
    ) {
        self.scope = scope
        self.content = content
        self.filters = filters
        self.sort = sort
        self.offset = offset
    }

    public var normalizedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool {
        normalizedContent.isEmpty && filters.isEmpty
    }
}

public struct MessageSearchResult: Identifiable, Equatable, Sendable {
    public var messages: [Message]
    public var hitIndex: Int

    public init(messages: [Message], hitIndex: Int) {
        self.messages = messages
        self.hitIndex = hitIndex
    }

    public var hit: Message {
        messages[hitIndex]
    }

    public var id: MessageID { hit.id }
}

public struct MessageSearchPage: Equatable, Sendable {
    public var results: [MessageSearchResult]
    public var channels: [Channel]
    public var totalResults: Int
    public var isHistoricalIndexing: Bool
    public var serverElapsedMilliseconds: Int?

    public init(
        results: [MessageSearchResult],
        channels: [Channel] = [],
        totalResults: Int,
        isHistoricalIndexing: Bool = false,
        serverElapsedMilliseconds: Int? = nil
    ) {
        self.results = results
        self.channels = channels
        self.totalResults = totalResults
        self.isHistoricalIndexing = isHistoricalIndexing
        self.serverElapsedMilliseconds = serverElapsedMilliseconds
    }

    public init(
        messages: [Message],
        channels: [Channel] = [],
        totalResults: Int,
        isHistoricalIndexing: Bool = false,
        serverElapsedMilliseconds: Int? = nil
    ) {
        self.init(
            results: messages.map {
                MessageSearchResult(messages: [$0], hitIndex: 0)
            },
            channels: channels,
            totalResults: totalResults,
            isHistoricalIndexing: isHistoricalIndexing,
            serverElapsedMilliseconds: serverElapsedMilliseconds
        )
    }

    public var messages: [Message] { results.map(\.hit) }

    public var maximumPageCount: Int {
        min(400, max(1, Int(ceil(Double(totalResults) / 25))))
    }
}

public extension Snowflake {
    static func messageSearchBoundary(at date: Date) -> Self {
        let discordEpochMilliseconds: UInt64 = 1_420_070_400_000
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
        guard milliseconds >= discordEpochMilliseconds else {
            return Self(rawValue: 0)
        }
        return Self(rawValue: (milliseconds - discordEpochMilliseconds) << 22)
    }
}
