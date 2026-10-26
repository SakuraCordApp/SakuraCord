public struct MessagePeoplePage: Sendable {
    public var users: [User]
    public var hasMore: Bool
    public init(users: [User], hasMore: Bool) {
        self.users = users
        self.hasMore = hasMore
    }
}
