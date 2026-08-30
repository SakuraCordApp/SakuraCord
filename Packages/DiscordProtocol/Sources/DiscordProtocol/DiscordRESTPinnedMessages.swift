import Foundation
import SakuraCordModels

private struct PinnedMessageDTO: Decodable {
    var pinnedAt: String
    var message: MessageDTO

    enum CodingKeys: String, CodingKey {
        case pinnedAt = "pinned_at"
        case message
    }
}

private struct PinnedMessagePageDTO: Decodable {
    var items: LossyList<PinnedMessageDTO>
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

public extension DiscordRESTProvider {
    func pinnedMessages(
        in channelID: ChannelID,
        before: Date?,
        limit: Int
    ) async throws -> PinnedMessagePage {
        var query = [URLQueryItem(
            name: "limit",
            value: String(min(max(limit, 1), 50))
        )]
        if let before {
            query.append(URLQueryItem(
                name: "before",
                value: DiscordDate.format(before)
            ))
        }
        let payload: PinnedMessagePageDTO = try await request(
            "/channels/\(channelID)/messages/pins",
            query: query
        )
        var items = payload.items.elements.compactMap { dto -> PinnedMessage? in
            guard let pinnedAt = DiscordDate.parse(dto.pinnedAt),
                  var message = try? dto.message.domain()
            else { return nil }
            message.isPinned = true
            if let existing = cachedMessages[message.id] {
                message.guildMember = MessageGuildMember.merging(
                    incoming: message.guildMember,
                    existing: existing.guildMember
                )
            }
            cachedMessages[message.id] = message
            return PinnedMessage(pinnedAt: pinnedAt, message: message)
        }
        items.sort { lhs, rhs in
            if lhs.pinnedAt != rhs.pinnedAt { return lhs.pinnedAt > rhs.pinnedAt }
            return lhs.message.id > rhs.message.id
        }
        return PinnedMessagePage(items: items, hasMore: payload.hasMore)
    }

    func setMessagePinned(
        _ isPinned: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        let path = "/channels/\(channelID)/messages/pins/\(messageID)"
        try await requestEmpty(path, method: isPinned ? "PUT" : "DELETE")
        if var message = cachedMessages[messageID] {
            message.isPinned = isPinned
            cachedMessages[messageID] = message
        }
    }
}
