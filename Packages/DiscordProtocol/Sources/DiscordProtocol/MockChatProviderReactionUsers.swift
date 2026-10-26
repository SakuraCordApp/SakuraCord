import SakuraCordModels

public extension MockChatProvider {
    func reactionUsers(for emoji: String, messageID: MessageID, channelID: ChannelID, after: UserID?, limit: Int) async throws -> MessagePeoplePage {
        guard let message = messagesByChannel[channelID]?.first(where: { $0.id == messageID }),
              let reaction = message.reactions.first(where: { $0.id == Reaction(emoji: emoji, count: 0).id })
        else { throw ChatProviderError.messageNotFound }
        let users = (0 ..< max(0, reaction.count)).map { index -> User in
            if reaction.reactors.indices.contains(index) {
                let reactor = reaction.reactors[index]
                return User(id: reactor.id, username: "reactor\(index + 1)", displayName: reactor.displayName, avatarURL: reactor.avatarURL)
            }
            return User(id: UserID(rawValue: UInt64(100_000 + index)), username: "reactor\(index + 1)", displayName: "Reactor \(index + 1)")
        }.sorted { $0.id.rawValue < $1.id.rawValue }.filter { user in
            after.map { user.id.rawValue > $0.rawValue } ?? true
        }
        let limit = min(100, max(1, limit))
        return MessagePeoplePage(users: Array(users.prefix(limit)), hasMore: users.count > limit)
    }
}
