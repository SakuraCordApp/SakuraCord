@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension ProviderRequestContractTests {
    @Test func `message search uses the reviewed channel contract and decodes nested results`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )

        let page = try await provider.searchMessages(
            in: ChannelID(rawValue: 200),
            query: "  sakura  ",
            limit: 25,
            offset: 0
        )

        #expect(RateLimitURLProtocol.messageSearchRequestCount == 1)
        #expect(RateLimitURLProtocol.messageSearchQueries == [[
            "content": "sakura",
            "sort_by": "timestamp",
            "sort_order": "desc",
            "limit": "25",
            "offset": "0",
        ]])
        #expect(page.totalResults == 1)
        #expect(page.messages.map(\.id) == [MessageID(rawValue: 351)])
        #expect(page.messages.first?.content == "searchable sakura message")
    }

    @Test func `message search retries indexing responses within a six request budget`() async throws {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.messageSearchStatuses = [202, 202, 200]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )

        let page = try await provider.searchMessages(
            in: ChannelID(rawValue: 200),
            query: "sakura",
            limit: 25,
            offset: 0
        )

        #expect(page.totalResults == 1)
        #expect(RateLimitURLProtocol.messageSearchRequestCount == 3)
    }

    @Test func `message search stops after six indexing responses`() async {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.messageSearchStatuses = Array(repeating: 202, count: 6)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )

        await #expect(throws: ChatProviderError.self) {
            try await provider.searchMessages(
                in: ChannelID(rawValue: 200),
                query: "sakura",
                limit: 25,
                offset: 0
            )
        }
        #expect(RateLimitURLProtocol.messageSearchRequestCount == 6)
    }
}
