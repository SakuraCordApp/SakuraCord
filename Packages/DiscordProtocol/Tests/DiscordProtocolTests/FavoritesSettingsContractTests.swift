@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

/// Request bodies captured from the official client (web build 670026) on
/// 11 November 2026; see docs/protocol/SETTINGS.md, Favorites server.
@Suite(.serialized)
struct FavoritesSettingsContractTests {
    @Test func `favourite edits send the complete Favorites message the official client sends`() async throws {
        FavoritesURLProtocol.reset()
        let provider = makeProvider()
        // A forum, a categorised text channel, its category and a thread.
        try await receiveReady(provider, settings: "emUKEwlHEIIOUAitFRIIEAEYAyoCCA8KGgkkEID+Ny01FRIPEAEYAiEAAIDYPGHJFSoAChkJAACA2DxhyRUSDgoIQ2hhbm5lbHMQAhgBChMJVRACzNCbxxUSCBABGAQqAggLGgIIAQ==")
        let stored = try #require(await provider.favoritesSettings())
        #expect(stored.isEnabled)
        #expect(stored.sections.map { $0.entries.map(\.id.rawValue) } == [[1_561_913_785_701_240_903, 1_569_394_316_240_097_365], [1_528_177_367_078_408_228]])

        try await provider.updateFavorites(.remove(ChannelID(rawValue: 1_569_394_316_240_097_365)))
        await provider.favoritesSaveTask?.value
        try await provider.updateFavorites(.add(ChannelID(rawValue: 1_466_495_335_391_297_617), channelType: 1, categoryID: nil))
        await provider.favoritesSaveTask?.value

        #expect(FavoritesURLProtocol.requests.map(\.method) == ["PATCH", "PATCH"])
        #expect(FavoritesURLProtocol.requests.map(\.path) == Array(repeating: "/api/v9/users/@me/settings-proto/1", count: 2))
        #expect(FavoritesURLProtocol.requests.map { $0.body.keys.sorted() } == [["settings"], ["settings"]])
        #expect(FavoritesURLProtocol.requests.map { $0.body["settings"] as? String } == [
            "elAKEwlHEIIOUAitFRIIEAEYAyoCCA8KGgkkEID+Ny01FRIPEAEYAiEAAIDYPGHJFSoAChkJAACA2DxhyRUSDgoIQ2hhbm5lbHMQAhgBGgIIAQ==",
            "emUKEwlHEIIOUAitFRIIEAEYAyoCCA8KGgkkEID+Ny01FRIPEAEYAiEAAIDYPGHJFSoAChkJAACA2DxhyRUSDgoIQ2hhbm5lbHMQAhgBChMJUQDE2rwJWhQSCBABGAQqAggBGgIIAQ==",
        ])
        await provider.disconnect()
    }

    @Test func `the Favorites server toggle writes guild_visible and is off by default`() async throws {
        FavoritesURLProtocol.reset()
        let provider = makeProvider()
        try await receiveReady(provider, settings: "CgMYnzA=")
        #expect(await provider.favoritesSettings() == FavoritesSettings())
        #expect(FavoritesSettings().isEnabled == false)

        try await provider.updateFavorites(.setVisible(true))
        await provider.favoritesSaveTask?.value
        try await provider.updateFavorites(.setVisible(false))
        await provider.favoritesSaveTask?.value

        #expect(FavoritesURLProtocol.requests.map { $0.body["settings"] as? String } == ["egQaAggB", "egIaAA=="])
        #expect(await provider.favoritesSettings()?.isEnabled == false)
        await provider.disconnect()
    }

    @Test func `edits during an in-flight save coalesce into one save of the newest state`() async throws {
        FavoritesURLProtocol.reset()
        FavoritesURLProtocol.responseDelay = .milliseconds(300)
        defer { FavoritesURLProtocol.responseDelay = nil }
        let provider = makeProvider()
        try await receiveReady(provider, settings: "CgMYnzA=")
        try await provider.updateFavorites(.setVisible(true))
        try await Task.sleep(for: .milliseconds(100))
        // The official client would discard these with the first response.
        try await provider.updateFavorites(.setVisible(false))
        try await provider.updateFavorites(.setVisible(true))
        try await provider.updateFavorites(.setVisible(false))
        await provider.favoritesSaveTask?.value

        #expect(FavoritesURLProtocol.requests.map { $0.body["settings"] as? String } == ["egQaAggB", "egIaAA=="])
        #expect(await provider.favoritesSettings()?.isEnabled == false)
        await provider.disconnect()
    }

    @Test func `moving a favourite renumbers display order like the official client`() {
        var settings = FavoritesSettings(entries: [
            .init(id: ChannelID(rawValue: 1), position: 3, channelType: 15),
            .init(id: ChannelID(rawValue: 2), position: 2, parentID: ChannelID(rawValue: 10), channelType: 0),
            .init(id: ChannelID(rawValue: 10), isCategory: true, nickname: "Channels", position: 1),
            .init(id: ChannelID(rawValue: 3), position: 4, channelType: 1),
            .init(id: ChannelID(rawValue: 11), isCategory: true, nickname: "SC Test Cat", position: 5),
        ])
        settings.apply(.move(ChannelID(rawValue: 3), categoryID: ChannelID(rawValue: 11)))
        // Capture seq 674: forum 0, general 1, DM 2 under SC Test Cat; categories unchanged.
        #expect(settings.entries.map(\.position) == [0, 1, 1, 2, 5])
        #expect(settings.entries[3].parentID == ChannelID(rawValue: 11))
        #expect(settings.limitBlockingAddition(premiumType: 0) == 3)
        #expect(settings.limitBlockingAddition(premiumType: 2) == nil)
    }

    private func receiveReady(_ provider: DiscordRESTProvider, settings: String) async throws {
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya")]),
            "guilds": .array([]),
            "user_settings_proto": .string(settings),
        ]))
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FavoritesURLProtocol.self]
        return DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
    }
}

private struct CapturedFavoritesRequest: @unchecked Sendable {
    var method: String
    var path: String
    var body: [String: Any]
}

/// Records every request and echoes a settings save back, as Discord does.
private final class FavoritesURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [CapturedFavoritesRequest] = []
    nonisolated(unsafe) static var responseDelay: DispatchTimeInterval?

    static func reset() { requests = [] }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.requestBody(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        Self.requests.append(CapturedFavoritesRequest(
            method: request.httpMethod ?? "",
            path: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "",
            body: body
        ))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let payload = try? JSONSerialization.data(withJSONObject: ["settings": body["settings"] as? String ?? ""])
        let finish = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        if let delay = Self.responseDelay {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: finish)
        } else {
            finish()
        }
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
