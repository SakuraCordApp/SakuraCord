public struct MessageSearchPage: Equatable, Sendable {
    public var messages: [Message]
    public var totalResults: Int
    public var isHistoricalIndexing: Bool

    public init(
        messages: [Message],
        totalResults: Int,
        isHistoricalIndexing: Bool = false
    ) {
        self.messages = messages
        self.totalResults = totalResults
        self.isHistoricalIndexing = isHistoricalIndexing
    }
}
