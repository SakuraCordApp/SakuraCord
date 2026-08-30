import Foundation

public struct PinnedMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: MessageID { message.id }
    public var pinnedAt: Date
    public var message: Message

    public init(pinnedAt: Date, message: Message) {
        self.pinnedAt = pinnedAt
        self.message = message
    }
}

public struct PinnedMessagePage: Codable, Equatable, Sendable {
    public var items: [PinnedMessage]
    public var hasMore: Bool

    public init(items: [PinnedMessage], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }

    public var nextBefore: Date? {
        hasMore ? items.last?.pinnedAt : nil
    }
}
