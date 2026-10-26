import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    /// The details browser lists distinct people across normal and Super Reactions.
    /// Each kind uses the same exclusive cursor, so the merged page stays ordered.
    func reactionUsers(for emoji: String, messageID: MessageID, channelID: ChannelID, after: UserID?, limit: Int) async throws -> MessagePeoplePage {
        let limit = min(100, max(1, limit))
        let encoded = Self.reactionAPIValue(emoji).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? Self.reactionAPIValue(emoji)
        var users: [User] = []
        var hasMore = false
        for kind in [MessageReactionKind.normal, .burst] {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "type", value: String(kind.rawValue)), URLQueryItem(name: "limit", value: String(limit))]
            if let after { query.append(URLQueryItem(name: "after", value: after.description)) }
            let response: [UserDTO] = try await request(
                "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)", query: query
            )
            try Task.checkCancellation()
            users += try response.map { try $0.domain() }
            hasMore = hasMore || response.count == limit
        }
        var seen = Set<UserID>()
        let distinct = users.sorted { $0.id.rawValue < $1.id.rawValue }.filter { seen.insert($0.id).inserted }
        return MessagePeoplePage(users: Array(distinct.prefix(limit)), hasMore: hasMore || distinct.count > limit)
    }
}
