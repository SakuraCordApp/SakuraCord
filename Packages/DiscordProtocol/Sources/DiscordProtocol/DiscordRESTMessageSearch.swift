import Foundation
import SakuraCordModels

private struct GuildMessageSearchResponseDTO: Decodable {
    var totalResults: Int
    var messages: [[MessageDTO]]
    var doingDeepHistoricalIndex: Bool
    var threads: [ChannelDTO]?

    enum CodingKeys: String, CodingKey {
        case totalResults = "total_results"
        case messages
        case doingDeepHistoricalIndex = "doing_deep_historical_index"
        case threads
    }
}

private struct DirectMessageSearchResponseDTO: Decodable {
    struct TabsDTO: Decodable {
        var messages: MessagesDTO
    }

    struct MessagesDTO: Decodable {
        var messages: [[MessageDTO]]
        var channels: [ChannelDTO]
        var totalResults: Int
        var timeSpentMilliseconds: Int?

        enum CodingKeys: String, CodingKey {
            case messages, channels
            case totalResults = "total_results"
            case timeSpentMilliseconds = "time_spent_ms"
        }
    }

    var doingDeepHistoricalIndex: Bool
    var tabs: TabsDTO

    enum CodingKeys: String, CodingKey {
        case doingDeepHistoricalIndex = "doing_deep_historical_index"
        case tabs
    }
}

private struct MessageSearchIndexingDTO: Decodable {
    var retryAfter: Double?

    enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
    }
}

extension DiscordRESTProvider {
    static let maximumMessageSearchIndexingAttempts = 6
    static let defaultMessageSearchIndexingDelay: Duration = .seconds(5)

    public func searchMessages(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        try Self.validateMessageSearch(query)
        switch query.scope {
        case .guild(let guildID):
            return try await searchGuildMessages(query, guildID: guildID)
        case .directMessages:
            return try await searchDirectMessages(query)
        }
    }

    private static func validateMessageSearch(_ query: MessageSearchQuery) throws {
        guard !query.isEmpty else {
            throw ChatProviderError.invalidRequest(
                "Enter text or choose a filter to search."
            )
        }
        guard query.normalizedContent.count <= 1_024 else {
            throw ChatProviderError.invalidRequest(
                "Message searches cannot exceed 1,024 characters."
            )
        }
        guard (0 ... MessageSearchQuery.maximumOffset).contains(query.offset),
              query.offset.isMultiple(of: MessageSearchQuery.pageSize)
        else {
            throw ChatProviderError.invalidRequest(
                "The message search page is out of range."
            )
        }
    }

    private func searchGuildMessages(
        _ query: MessageSearchQuery,
        guildID: GuildID
    ) async throws -> MessageSearchPage {
        let path = "/guilds/\(guildID)/messages/search"
        let requestQuery = Self.guildSearchQuery(query)
        return try await performIndexedMessageSearch(
            path: path,
            method: "GET",
            query: requestQuery,
            body: nil
        ) { data in
            let payload = try JSONDecoder().decode(
                GuildMessageSearchResponseDTO.self,
                from: data
            )
            let results = try self.domainSearchResults(
                payload.messages,
                fallbackGuildID: guildID
            )
            let channels = try (payload.threads ?? []).map {
                try $0.domain(guildID: guildID)
            }
            self.cacheSearchChannels(channels, guildID: guildID)
            return MessageSearchPage(
                results: results,
                channels: channels,
                totalResults: payload.totalResults,
                isHistoricalIndexing: payload.doingDeepHistoricalIndex
            )
        }
    }

    private func searchDirectMessages(
        _ query: MessageSearchQuery
    ) async throws -> MessageSearchPage {
        let path = "/users/@me/messages/search/tabs"
        return try await performIndexedMessageSearch(
            path: path,
            method: "POST",
            query: [],
            body: Self.directMessageSearchBody(query)
        ) { data in
            let payload = try JSONDecoder().decode(
                DirectMessageSearchResponseDTO.self,
                from: data
            )
            let tab = payload.tabs.messages
            let results = try self.domainSearchResults(
                tab.messages,
                fallbackGuildID: nil
            )
            let channels = try tab.channels.map {
                try $0.domain(
                    guildID: nil,
                    knownUsersByID: self.cachedGatewayUsersByID
                )
            }
            self.cacheSearchChannels(channels, guildID: nil)
            return MessageSearchPage(
                results: results,
                channels: channels,
                totalResults: tab.totalResults,
                isHistoricalIndexing: payload.doingDeepHistoricalIndex,
                serverElapsedMilliseconds: tab.timeSpentMilliseconds
            )
        }
    }

    private func performIndexedMessageSearch(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: [String: JSONValue]?,
        decode: (Data) throws -> MessageSearchPage
    ) async throws -> MessageSearchPage {
        for attempt in 0 ..< Self.maximumMessageSearchIndexingAttempts {
            try Task.checkCancellation()
            let (data, response) = try await perform(
                path,
                method: method,
                query: query,
                body: body
            )
            switch response.statusCode {
            case 200:
                return try decode(data)
            case 202:
                guard attempt + 1 < Self.maximumMessageSearchIndexingAttempts else {
                    throw ChatProviderError.invalidRequest(
                        "Discord is still indexing messages. Try the search again shortly."
                    )
                }
                let bodyDelay = try? JSONDecoder().decode(
                    MessageSearchIndexingDTO.self,
                    from: data
                ).retryAfter
                let headerDelay = response.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init)
                let seconds = headerDelay ?? bodyDelay
                let delay = seconds.map { Duration.seconds(max(0, $0)) }
                    ?? Self.defaultMessageSearchIndexingDelay
                try await Task.sleep(for: delay)
            case 401:
                authorizationValue = nil
                throw ChatProviderError.unauthenticated
            default:
                throw ChatProviderError.transport(
                    status: response.statusCode,
                    requestID: response.value(forHTTPHeaderField: "x-request-id")
                )
            }
        }
        preconditionFailure("The bounded message-search loop always returns or throws.")
    }

    private func domainSearchResults(
        _ groups: [[MessageDTO]],
        fallbackGuildID: GuildID?
    ) throws -> [MessageSearchResult] {
        try groups.compactMap { group in
            guard !group.isEmpty else { return nil }
            let messages = try group.map { dto in
                var message = try dto.domain()
                message.guildID = message.guildID ?? fallbackGuildID
                cachedMessages[message.id] = message
                return message
            }
            let hitIndex = group.firstIndex { $0.hit == true } ?? 0
            return MessageSearchResult(
                messages: messages,
                hitIndex: hitIndex
            )
        }
    }

    private func cacheSearchChannels(
        _ channels: [Channel],
        guildID: GuildID?
    ) {
        guard !channels.isEmpty else { return }
        var merged = Dictionary(
            uniqueKeysWithValues: (cachedChannels[guildID] ?? []).map { ($0.id, $0) }
        )
        for channel in channels {
            merged[channel.id] = channel
        }
        cachedChannels[guildID] = Array(merged.values)
    }

    private static func guildSearchQuery(
        _ query: MessageSearchQuery
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        items.append(contentsOf: query.filters.authorIDs.map {
            URLQueryItem(name: "author_id", value: $0.description)
        })
        items.append(contentsOf: query.filters.channelIDs.map {
            URLQueryItem(name: "channel_id", value: $0.description)
        })
        items.append(contentsOf: query.filters.mentionedUserIDs.map {
            URLQueryItem(name: "mentions", value: $0.description)
        })
        items.append(contentsOf: query.filters.contentTypes.map {
            URLQueryItem(name: "has", value: $0.rawValue)
        })
        items.append(contentsOf: query.filters.authorTypes.map {
            URLQueryItem(name: "author_type", value: $0.rawValue)
        })
        if let pinned = query.filters.pinned {
            items.append(URLQueryItem(name: "pinned", value: String(pinned)))
        }
        if let minimum = query.filters.minimumMessageID {
            items.append(URLQueryItem(name: "min_id", value: minimum.description))
        }
        if let maximum = query.filters.maximumMessageID {
            items.append(URLQueryItem(name: "max_id", value: maximum.description))
        }
        if !query.normalizedContent.isEmpty {
            items.append(URLQueryItem(name: "content", value: query.normalizedContent))
        }
        items.append(URLQueryItem(name: "sort_by", value: query.sort.sortBy))
        items.append(URLQueryItem(name: "sort_order", value: query.sort.sortOrder))
        items.append(URLQueryItem(name: "offset", value: String(query.offset)))
        return items
    }

    private static func directMessageSearchBody(
        _ query: MessageSearchQuery
    ) -> [String: JSONValue] {
        var messages: [String: JSONValue] = [
            "sort_by": .string(query.sort.sortBy),
            "sort_order": .string(query.sort.sortOrder),
        ]
        if !query.filters.authorIDs.isEmpty {
            messages["author_id"] = .array(
                query.filters.authorIDs.map { .string($0.description) }
            )
        }
        if !query.filters.mentionedUserIDs.isEmpty {
            messages["mentions"] = .array(
                query.filters.mentionedUserIDs.map { .string($0.description) }
            )
        }
        if !query.filters.contentTypes.isEmpty {
            messages["has"] = .array(
                query.filters.contentTypes.map { .string($0.rawValue) }
            )
        }
        if !query.filters.authorTypes.isEmpty {
            messages["author_type"] = .array(
                query.filters.authorTypes.map { .string($0.rawValue) }
            )
        }
        if let pinned = query.filters.pinned {
            messages["pinned"] = .bool(pinned)
        }
        if let minimum = query.filters.minimumMessageID {
            messages["min_id"] = .string(minimum.description)
        }
        if let maximum = query.filters.maximumMessageID {
            messages["max_id"] = .string(maximum.description)
        }
        if !query.normalizedContent.isEmpty {
            messages["content"] = .string(query.normalizedContent)
        }
        messages["offset"] = .number(Double(query.offset))
        messages["limit"] = .number(Double(MessageSearchQuery.pageSize))

        var body: [String: JSONValue] = [
            "tabs": .object(["messages": .object(messages)]),
            "track_exact_total_hits": .bool(true),
        ]
        if !query.filters.channelIDs.isEmpty {
            body["channel_ids"] = .array(
                query.filters.channelIDs.map { .string($0.description) }
            )
        }
        return body
    }
}
