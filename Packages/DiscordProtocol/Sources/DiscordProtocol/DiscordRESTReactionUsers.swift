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

extension DiscordRESTProvider {
    private func messageForReaction(_ messageID: MessageID, channelID: ChannelID) async throws -> Message {
        if let message = cachedMessages[messageID] { return message }
        // A visible message can outlive the provider's bounded working set.
        let page = try await messages(in: channelID, anchoredAt: .around(messageID), limit: 1)
        guard let message = page.messages.first(where: { $0.id == messageID }) else {
            throw ChatProviderError.messageNotFound
        }
        return message
    }

    public func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID)
        async throws
    {
        let message = try await messageForReaction(messageID, channelID: channelID)
        let apiEmoji = Self.reactionAPIValue(emoji)
        let existing = message.reactions.firstIndex { Self.reactionAPIValue($0.emoji) == apiEmoji }
        let reacted = existing.map { message.reactions[$0].didCurrentUserReact } ?? false
        try await setReaction(
            emoji,
            reacted: !reacted,
            messageID: messageID,
            channelID: channelID
        )
    }

    public func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        try requireGuildCommunication(in: channelID)
        let message = try await messageForReaction(messageID, channelID: channelID)
        let apiEmoji = Self.reactionAPIValue(emoji)
        let currentReaction = message.reactions.first {
            Self.reactionAPIValue($0.emoji) == apiEmoji
        }
        guard (currentReaction?.didCurrentUserReact ?? false) != reacted else { return }
        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let method = reacted ? "PUT" : "DELETE"
        let (data, response) = try await perform(
            "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me",
            method: method, query: [], body: nil
        )
        if response.statusCode == 429 {
            throw apiDiagnostics.coalescing(ChatProviderError.rateLimited(
                retryAfter: Self.retryAfter(from: data, response: response),
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            ), with: response)
        }
        try validateEmptyResponse(data, response)
        invalidateReactionReactors(channelID: channelID, messageID: messageID, reactionID: Reaction(emoji: emoji, count: 0).id)
        guard let currentUserID = currentUser?.id,
              var updated = cachedMessages[messageID]
        else { return }
        let reactionUpdate: MessageReactionUpdate =
            reacted
            ? .add(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
            : .remove(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
        guard updated.applyReactionUpdate(reactionUpdate, currentUserID: currentUserID) else {
            return
        }
        cachedMessages[messageID] = updated
        continuation?.yield(.messageUpdated(updated))
        updateForumPostForMessage(updated)
    }

    public func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        guard reactionCount > 0 else { return [] }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let key = ReactionReactorCacheKey(
            channelID: channelID,
            messageID: messageID,
            emojiIdentity: Reaction(emoji: emoji, count: reactionCount).id,
            reactionCount: reactionCount
        )
        if let cached = cachedReactionReactors[key] {
            return cached
        }
        if let task = reactionReactorTasks[key], let loadID = reactionReactorTaskIDs[key] {
            let reactors = try await task.value
            if let cached = cachedReactionReactors[key] { return cached }
            guard reactionReactorTaskIDs[key] == loadID else { throw CancellationError() }
            return reactors
        }
        guard reactionReactorTasks.count < Self.maximumConcurrentReactionReactorReads else {
            throw ChatProviderError.invalidRequest(
                "Too many reaction details are already loading. Hover this reaction again shortly."
            )
        }

        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let loadID = UUID()
        reactionReactorTaskIDs[key] = loadID
        let task = Task { [self] in
            do {
                let users: [UserDTO] = try await request(
                "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)",
                query: [
                    URLQueryItem(name: "type", value: "0"),
                    URLQueryItem(
                        name: "limit",
                        value: String(Self.reactionReactorFetchLimit)
                    ),
                ]
            )
                #if DEBUG
                    await reactorResponseReceivedForTesting?()
                #endif
                try Task.checkCancellation()
                guard reactionReactorTaskIDs[key] == loadID else { throw CancellationError() }
                return try users.map { ReactionReactor(user: try $0.domain()) }
            } catch {
                // URLSession may report cancellation as URLError.cancelled.
                // Invalidated reads must not become a preview failure cooldown.
                try Task.checkCancellation()
                throw error
            }
        }
        reactionReactorTasks[key] = task
        do {
            let reactors = try await task.value
            guard reactionReactorTaskIDs[key] == loadID else { throw CancellationError() }
            reactionReactorTasks[key] = nil
            reactionReactorTaskIDs[key] = nil
            cacheReactionReactors(reactors, for: key)
            return reactors
        } catch {
            if reactionReactorTaskIDs[key] == loadID {
                reactionReactorTasks[key] = nil
                reactionReactorTaskIDs[key] = nil
            }
            throw error
        }
    }

    func invalidateReactionReactors(channelID: ChannelID, messageID: MessageID, reactionID: String? = nil) {
        func matches(_ key: ReactionReactorCacheKey) -> Bool {
            key.channelID == channelID && key.messageID == messageID
                && (reactionID == nil || key.emojiIdentity == reactionID)
        }
        for key in reactionReactorTasks.keys
        where matches(key) {
            reactionReactorTasks.removeValue(forKey: key)?.cancel()
            reactionReactorTaskIDs[key] = nil
        }
        cachedReactionReactors = cachedReactionReactors.filter { !matches($0.key) }
        reactionReactorCacheOrder.removeAll { matches($0) }
    }

    func cacheReactionReactors(
        _ reactors: [ReactionReactor],
        for key: ReactionReactorCacheKey
    ) {
        cachedReactionReactors[key] = reactors
        reactionReactorCacheOrder.removeAll { $0 == key }
        reactionReactorCacheOrder.append(key)
        while reactionReactorCacheOrder.count > Self.maximumReactionReactorCacheEntries {
            let evicted = reactionReactorCacheOrder.removeFirst()
            cachedReactionReactors[evicted] = nil
        }
    }

    static func reactionAPIValue(_ emoji: String) -> String {
        guard emoji.hasPrefix("<"), emoji.hasSuffix(">") else { return emoji }
        let value = emoji.dropFirst().dropLast()
        let withoutAnimationPrefix = value.hasPrefix("a:") ? value.dropFirst(2) : value.dropFirst(1)
        return String(withoutAnimationPrefix)
    }
}
