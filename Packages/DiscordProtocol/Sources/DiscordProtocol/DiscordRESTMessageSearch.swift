import Foundation
import SakuraCordModels

private struct MessageSearchResponseDTO: Decodable {
    var totalResults: Int
    var messages: [[MessageDTO]]
    var doingDeepHistoricalIndex: Bool

    enum CodingKeys: String, CodingKey {
        case totalResults = "total_results"
        case messages
        case doingDeepHistoricalIndex = "doing_deep_historical_index"
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

    public func searchMessages(
        in channelID: ChannelID,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> MessageSearchPage {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ChatProviderError.invalidRequest("Enter text to search for.")
        }
        guard normalized.count <= 1_024 else {
            throw ChatProviderError.invalidRequest(
                "Message searches cannot exceed 1,024 characters."
            )
        }
        guard (1 ... 25).contains(limit), (0 ... 9_975).contains(offset) else {
            throw ChatProviderError.invalidRequest("The message search page is out of range.")
        }

        let path = "/channels/\(channelID)/messages/search"
        let searchQuery = [
            URLQueryItem(name: "content", value: normalized),
            URLQueryItem(name: "sort_by", value: "timestamp"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]

        for attempt in 0 ..< Self.maximumMessageSearchIndexingAttempts {
            try Task.checkCancellation()
            let (data, response) = try await perform(
                path,
                method: "GET",
                query: searchQuery,
                body: nil
            )
            switch response.statusCode {
            case 200:
                let payload = try JSONDecoder().decode(
                    MessageSearchResponseDTO.self,
                    from: data
                )
                let messages = try payload.messages.compactMap { group in
                    try group.first?.domain()
                }
                for message in messages {
                    cachedMessages[message.id] = message
                }
                return MessageSearchPage(
                    messages: messages,
                    totalResults: payload.totalResults,
                    isHistoricalIndexing: payload.doingDeepHistoricalIndex
                )
            case 202:
                guard attempt + 1 < Self.maximumMessageSearchIndexingAttempts else {
                    throw ChatProviderError.invalidRequest(
                        "Discord is still indexing this channel. Try the search again shortly."
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
}
