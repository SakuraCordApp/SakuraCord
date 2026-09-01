@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension ProviderRequestContractTests {
    @Test func `guild message search matches Discord query contract`() async throws {
        let provider = messageSearchProvider()
        let page = try await provider.searchMessages(
            MessageSearchQuery(
                scope: .guild(GuildID(rawValue: 100)),
                content: "  sakura  ",
                filters: MessageSearchFilters(
                    authorIDs: [UserID(rawValue: 4)],
                    channelIDs: [ChannelID(rawValue: 200)],
                    mentionedUserIDs: [UserID(rawValue: 5)],
                    contentTypes: [.image, .video],
                    authorTypes: [.bot],
                    pinned: true,
                    minimumMessageID: MessageID(rawValue: 10),
                    maximumMessageID: MessageID(rawValue: 20)
                ),
                sort: .oldest,
                offset: 25
            )
        )

        #expect(RateLimitURLProtocol.messageSearchMethods == ["GET"])
        #expect(RateLimitURLProtocol.messageSearchPaths == [
            "/api/v9/guilds/100/messages/search",
        ])
        #expect(RateLimitURLProtocol.messageSearchQueryItems == [[
            "author_id=4", "channel_id=200", "mentions=5",
            "has=image", "has=video", "author_type=bot", "pinned=true",
            "min_id=10", "max_id=20", "content=sakura",
            "sort_by=timestamp", "sort_order=asc", "offset=25",
        ]])
        #expect(RateLimitURLProtocol.messageSearchBodies.isEmpty)
        #expect(page.totalResults == 1)
        #expect(page.results.map(\.hit.id) == [MessageID(rawValue: 351)])
        #expect(page.results.first?.hit.content == "searchable sakura message")
        #expect(page.channels.map(\.id) == [ChannelID(rawValue: 300)])
        let cachedThread = await provider.cachedChannelForTesting(
            channelID: ChannelID(rawValue: 300)
        )
        #expect(cachedThread == nil)
    }

    @Test func `direct message search uses tabs body and top level channel scope`() async throws {
        let provider = messageSearchProvider()
        let page = try await provider.searchMessages(
            MessageSearchQuery(
                scope: .directMessages,
                content: "sakura",
                filters: MessageSearchFilters(
                    authorIDs: [UserID(rawValue: 4)],
                    channelIDs: [ChannelID(rawValue: 200)],
                    contentTypes: [.file],
                    pinned: false
                ),
                sort: .mostRelevant,
                offset: 50
            )
        )

        #expect(RateLimitURLProtocol.messageSearchMethods == ["POST"])
        #expect(RateLimitURLProtocol.messageSearchPaths == [
            "/api/v9/users/@me/messages/search/tabs",
        ])
        #expect(RateLimitURLProtocol.messageSearchQueryItems == [[]])
        let body = try #require(RateLimitURLProtocol.messageSearchBodies.first)
        #expect(body["track_exact_total_hits"] as? Bool == true)
        #expect(body["channel_ids"] as? [String] == ["200"])
        let tabs = try #require(body["tabs"] as? [String: Any])
        let messages = try #require(tabs["messages"] as? [String: Any])
        #expect(messages["content"] as? String == "sakura")
        #expect(messages["author_id"] as? [String] == ["4"])
        #expect(messages["has"] as? [String] == ["file"])
        #expect(messages["pinned"] as? Bool == false)
        #expect(messages["sort_by"] as? String == "relevance")
        #expect(messages["sort_order"] as? String == "desc")
        #expect(messages["offset"] as? Int == 50)
        #expect(messages["limit"] as? Int == 25)
        #expect(page.channels.map(\.id) == [ChannelID(rawValue: 200)])
        #expect(page.serverElapsedMilliseconds == 12)
    }

    @Test func `filter only message search is valid`() async throws {
        let provider = messageSearchProvider()
        _ = try await provider.searchMessages(
            MessageSearchQuery(
                scope: .guild(GuildID(rawValue: 100)),
                filters: MessageSearchFilters(contentTypes: [.image])
            )
        )

        #expect(RateLimitURLProtocol.messageSearchQueryItems == [[
            "has=image", "sort_by=timestamp", "sort_order=desc", "offset=0",
        ]])
    }

    @Test func `message search retries indexing responses within a six request budget`() async throws {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.messageSearchStatuses = [202, 202, 200]
        let provider = makeMessageSearchProvider()

        let page = try await provider.searchMessages(
            MessageSearchQuery(
                scope: .guild(GuildID(rawValue: 100)),
                content: "sakura"
            )
        )

        #expect(page.totalResults == 1)
        #expect(RateLimitURLProtocol.messageSearchRequestCount == 3)
    }

    @Test func `message search stops after six indexing responses`() async {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.messageSearchStatuses = Array(repeating: 202, count: 6)
        let provider = makeMessageSearchProvider()

        await #expect(throws: ChatProviderError.self) {
            try await provider.searchMessages(
                MessageSearchQuery(
                    scope: .guild(GuildID(rawValue: 100)),
                    content: "sakura"
                )
            )
        }
        #expect(RateLimitURLProtocol.messageSearchRequestCount == 6)
    }

    @Test func `message search rejects empty and invalid page requests without transport`() async {
        let provider = messageSearchProvider()
        await #expect(throws: ChatProviderError.self) {
            try await provider.searchMessages(
                MessageSearchQuery(scope: .directMessages)
            )
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.searchMessages(
                MessageSearchQuery(
                    scope: .directMessages,
                    content: "sakura",
                    offset: 1
                )
            )
        }
        #expect(RateLimitURLProtocol.messageSearchRequestCount == 0)
    }

    private func messageSearchProvider() -> DiscordRESTProvider {
        RateLimitURLProtocol.reset()
        return makeMessageSearchProvider()
    }

    private func makeMessageSearchProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        return DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
    }
}
