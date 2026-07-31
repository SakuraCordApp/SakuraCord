@testable import DiscordProtocol
import Foundation
import Testing

@Test func `retry after never truncates discords cooldown`() throws {
    let url = try #require(URL(string: "https://discord.com/api/v9/users/@me"))
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 429,
        httpVersion: "HTTP/1.1",
        headerFields: ["Retry-After": "300"]
    ))

    #expect(DiscordRESTProvider.retryAfter(from: Data("{}".utf8), response: response) >= 300.25)
}
