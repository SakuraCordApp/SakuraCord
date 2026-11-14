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

        try await provider.updateFavorites([.remove(ChannelID(rawValue: 1_569_394_316_240_097_365))])
        await provider.favoritesSaveTask?.value
        try await provider.updateFavorites([.add(ChannelID(rawValue: 1_466_495_335_391_297_617), channelType: 1)])
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

        try await provider.updateFavorites([.setVisible(true)])
        await provider.favoritesSaveTask?.value
        try await provider.updateFavorites([.setVisible(false)])
        await provider.favoritesSaveTask?.value

        #expect(FavoritesURLProtocol.requests.map { $0.body["settings"] as? String } == ["egQaAggB", "egIaAA=="])
        #expect(await provider.favoritesSettings()?.isEnabled == false)
        await provider.disconnect()
    }

    @Test func `edits during an in-flight save coalesce into one save of the newest state`() async throws {
        FavoritesURLProtocol.reset()
        FavoritesURLProtocol.holdResponses()
        let provider = makeProvider()
        try await receiveReady(provider, settings: "CgMYnzA=")
        try await provider.updateFavorites([.setVisible(true)])
        #expect(await eventually { FavoritesURLProtocol.hasHeldResponse })
        // The official client would discard these with the first response.
        try await provider.updateFavorites([.setVisible(false)])
        try await provider.updateFavorites([.setVisible(true)])
        try await provider.updateFavorites([.setVisible(false)])
        FavoritesURLProtocol.releaseHeldResponses()
        await provider.favoritesSaveTask?.value

        #expect(FavoritesURLProtocol.requests.map { $0.body["settings"] as? String } == ["egQaAggB", "egIaAA=="])
        #expect(await provider.favoritesSettings()?.isEnabled == false)
        await provider.disconnect()
    }

    @Test func `pruning and adding at the limit send one save that never exceeds it`() async throws {
        FavoritesURLProtocol.reset()
        let provider = makeProvider()
        let stored = FavoritesSettings(entries: (1 ... 3).map {
            FavoritesSettings.Entry(id: ChannelID(rawValue: UInt64($0)), position: UInt32($0), channelType: 0)
        }, storedVisibility: true)
        let message = DiscordFavoritesProto.message(for: stored, preserving: Data())
        try await receiveReady(provider, settings: DiscordSettingsProto.protoLengthDelimitedField(
            DiscordFavoritesProto.settingsField, message
        ).base64EncodedString())

        // Channel 3 is a favourite the account can no longer see.
        try await provider.updateFavorites([.remove(ChannelID(rawValue: 3)), .add(ChannelID(rawValue: 4), channelType: 0)])
        await provider.favoritesSaveTask?.value

        let saved = FavoritesURLProtocol.requests.compactMap { request in
            (request.body["settings"] as? String).flatMap { Data(base64Encoded: $0) }
                .flatMap(DiscordFavoritesProto.message(inSettings:))
                .map(DiscordFavoritesProto.settings(from:))
        }
        #expect(saved.count == 1)
        #expect(saved.allSatisfy { $0.entries.count(where: { !$0.isCategory }) <= 3 })
        #expect(saved.first?.entries.map(\.id.rawValue) == [1, 2, 4])
        await provider.disconnect()
    }

    /// Bodies captured from the official client (web build 672800) on 13 November 2026.
    @Test func `suggestions, Thread Settings and Reset encode as the official client writes them`() throws {
        func encoded(_ edits: [FavoritesSettings.Edit], from stored: String) throws -> String {
            let storedSettings = try #require(Data(base64Encoded: stored))
            let storedMessage = try #require(DiscordFavoritesProto.message(inSettings: storedSettings))
            var settings = DiscordFavoritesProto.settings(from: storedMessage)
            edits.forEach { settings.apply($0) }
            return DiscordSettingsProto.protoLengthDelimitedField(
                DiscordFavoritesProto.settingsField, DiscordFavoritesProto.message(for: settings, preserving: storedMessage)
            ).base64EncodedString()
        }
        let channels = ChannelID(rawValue: 1_570_907_657_680_715_776)
        // Adding a suggestion files it under a new Channels category.
        #expect(try encoded([
            .createCategory(channels, name: "Channels"),
            .add(ChannelID(rawValue: 1_505_739_981_711_478_784), channelType: 0, categoryID: channels),
        ], from: "egQaAggB") == "ejsKGQkAAAAPMfzMFRIOCghDaGFubmVscxACGAEKGgkAEAQeiXblFBIPEAEYAiEAAAAPMfzMFSoAGgIIAQ==")
        // Own-category auto-add creates Auto-Added Threads in the same save.
        let threadSettings = FavoritesSettings.ThreadSettings(
            autoAddsJoinedThreads: true, removesReadThreads: true, removalDays: 7, removesFromAllThreads: true
        )
        let favorites = "emEKGgkAEAQeiXblFBIPEAEYAiEAAAAPMfzMFSoAChkJAAAADzH8zBUSDgoIQ2hhbm5lbHMQAhgBChEJHiCCaW2tsBUSBhAB"
            + "GAMqAAoRCT8QgDP5UqoVEgYQARgEKgAaAggB"
        let withThreadSettings = "epABChoJABAEHol25RQSDxABGAIhAAAADzH8zBUqAAoZCQAAAA8x/MwVEg4KCENoYW5uZWxzEAIYAQoRCR4ggmltrbAVEgYQ"
            + "ARgDKgAKEQk/EIAz+VKqFRIGEAEYBCoACiMJAABA+sT8zBUSGAoSQXV0by1BZGRlZCBUaHJlYWRzEAIYBRoCCAEgASoCCAEwBzgB"
        #expect(try encoded([
            .createCategory(ChannelID(rawValue: 1_570_908_292_987_748_352), name: "Auto-Added Threads"),
            .setThreadSettings(threadSettings),
        ], from: favorites) == withThreadSettings)
        #expect(try encoded([.reset], from: withThreadSettings) == "egA=")
    }

    /// Dismissing Suggested Channels sets DismissibleContent 807 and keeps the
    /// rest of UserContentSettings, re-encoded with its recurring states by key.
    @Test func `dismissing suggestions writes bit 807 into the complete user content`() {
        let recurring = { (key: UInt64) in
            DiscordSettingsProto.protoLengthDelimitedField(7, DiscordSettingsProto.protoVarintField(1, key))
        }
        let stored = DiscordSettingsProto.protoLengthDelimitedField(1, Data([0x01]))
            + DiscordSettingsProto.protoVarintField(6, 9) + recurring(30) + recurring(5)
        let dismissed = DiscordUserContentProto.setting(807, dismissed: true, in: stored)
        var bits = [UInt8](repeating: 0, count: 101)
        bits[0] = 0x01
        bits[100] = 0x80
        #expect(dismissed == DiscordSettingsProto.protoLengthDelimitedField(1, Data(bits))
            + DiscordSettingsProto.protoVarintField(6, 9) + recurring(5) + recurring(30))
        #expect(DiscordUserContentProto.isDismissed(807, in: dismissed))
        let restored = DiscordUserContentProto.setting(807, dismissed: false, in: dismissed)
        #expect(!DiscordUserContentProto.isDismissed(807, in: restored))
        #expect(restored.count == dismissed.count)
    }

    /// Reset made while the dismissal's save is in flight still restores
    /// Suggested Channels in its own write, as the official client's optimistic
    /// store does.
    @Test func `reset after a pending dismissal clears bit 807 in the same write`() async throws {
        FavoritesURLProtocol.reset()
        FavoritesURLProtocol.holdResponses()
        let provider = makeProvider()
        let userContent = DiscordSettingsProto.protoLengthDelimitedField(1, Data([0x01]))
        try await receiveReady(provider, settings: (
            DiscordSettingsProto.protoLengthDelimitedField(DiscordUserContentProto.settingsField, userContent)
                + DiscordSettingsProto.protoLengthDelimitedField(DiscordFavoritesProto.settingsField, Data([0x1A, 0x02, 0x08, 0x01]))
        ).base64EncodedString())
        let dismissal = Task { try await provider.setFavoritesSuggestionsDismissed(true) }
        #expect(await eventually { FavoritesURLProtocol.hasHeldResponse })
        try await provider.updateFavorites([.reset])
        FavoritesURLProtocol.releaseHeldResponses()
        try await dismissal.value
        await provider.favoritesSaveTask?.value
        #expect(FavoritesURLProtocol.requests.count == 2)

        let resetBody = try #require((FavoritesURLProtocol.requests.last?.body["settings"] as? String).flatMap { Data(base64Encoded: $0) })
        let savedContent = try #require(DiscordUserContentProto.message(inSettings: resetBody))
        #expect(!DiscordUserContentProto.isDismissed(DiscordUserContentProto.favoritesSuggestions, in: savedContent))
        #expect(DiscordFavoritesProto.message(inSettings: resetBody) == Data())
        await provider.disconnect()
    }

    /// A Reset made while a save is in flight is sent in a follow-up save even
    /// when later edits return the Favorites to the in-flight state, and is
    /// dropped with that save when it fails, so no later save sends it.
    @Test func `a Reset queued behind an in-flight save follows it or fails with it`() async throws {
        for fails in [true, false] {
            FavoritesURLProtocol.reset()
            FavoritesURLProtocol.holdResponses()
            let provider = makeProvider()
            var dismissed = [UInt8](repeating: 0, count: 101)
            dismissed[100] = 0x80
            try await receiveReady(provider, settings: (
                DiscordSettingsProto.protoLengthDelimitedField(
                    DiscordUserContentProto.settingsField, DiscordSettingsProto.protoLengthDelimitedField(1, Data(dismissed))
                ) + DiscordSettingsProto.protoLengthDelimitedField(DiscordFavoritesProto.settingsField, Data([0x1A, 0x00]))
            ).base64EncodedString())
            try await provider.updateFavorites([.setVisible(true)])
            #expect(await eventually { FavoritesURLProtocol.hasHeldResponse })
            try await provider.updateFavorites([.reset])
            try await provider.updateFavorites([.setVisible(true)])
            FavoritesURLProtocol.releaseHeldResponses(failing: fails)
            await provider.favoritesSaveTask?.value
            if fails {
                try await provider.updateFavorites([.setVisible(true)])
                await provider.favoritesSaveTask?.value
            }

            #expect(FavoritesURLProtocol.requests.count == 2)
            let lastBody = try #require((FavoritesURLProtocol.requests.last?.body["settings"] as? String).flatMap { Data(base64Encoded: $0) })
            let savedContent = DiscordUserContentProto.message(inSettings: lastBody)
            if fails {
                #expect(savedContent == nil)
                let content = try #require(await provider.userContentMessage)
                #expect(DiscordUserContentProto.isDismissed(807, in: content))
            } else {
                #expect(try !DiscordUserContentProto.isDismissed(807, in: #require(savedContent)))
            }
            await provider.disconnect()
        }
    }

    /// Dismissing suggestions while a Reset waits behind a save replaces the
    /// Reset's queued restore, so the one follow-up save sends the dismissal
    /// and nothing brings the suggestions back afterwards.
    @Test func `a dismissal made while a Reset is queued is what the follow-up save sends`() async throws {
        FavoritesURLProtocol.reset()
        FavoritesURLProtocol.holdResponses()
        let provider = makeProvider()
        var dismissed = [UInt8](repeating: 0, count: 101)
        dismissed[100] = 0x80
        try await receiveReady(provider, settings: (
            DiscordSettingsProto.protoLengthDelimitedField(
                DiscordUserContentProto.settingsField, DiscordSettingsProto.protoLengthDelimitedField(1, Data(dismissed))
            ) + DiscordSettingsProto.protoLengthDelimitedField(DiscordFavoritesProto.settingsField, Data([0x1A, 0x00]))
        ).base64EncodedString())
        try await provider.updateFavorites([.setVisible(true)])
        #expect(await eventually { FavoritesURLProtocol.hasHeldResponse })
        try await provider.updateFavorites([.reset])
        let dismissal = Task { try await provider.setFavoritesSuggestionsDismissed(true) }
        #expect(await eventually {
            await provider.userContentMessage.map { DiscordUserContentProto.isDismissed(807, in: $0) } == true
        })
        FavoritesURLProtocol.releaseHeldResponses()
        try await dismissal.value
        await provider.favoritesSaveTask?.value

        let sentContent = FavoritesURLProtocol.requests.dropFirst().compactMap { request in
            (request.body["settings"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(DiscordUserContentProto.message(inSettings:))
        }
        #expect(sentContent.count == 1)
        #expect(sentContent.allSatisfy { DiscordUserContentProto.isDismissed(807, in: $0) })
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
    /// Guards the held-response state, which URLSession's loading thread and the test share.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var holdsResponses = false
    /// Each held request's completion, which fails it when passed true.
    nonisolated(unsafe) private static var heldResponses: [(Bool) -> Void] = []

    static func reset() {
        requests = []
        lock.withLock {
            holdsResponses = false
            heldResponses = []
        }
    }

    /// Holds responses until released, so later edits arrive while a save is in flight.
    static func holdResponses() {
        lock.withLock { holdsResponses = true }
    }

    static var hasHeldResponse: Bool {
        lock.withLock { !heldResponses.isEmpty }
    }

    static func releaseHeldResponses(failing: Bool = false) {
        let held = lock.withLock {
            holdsResponses = false
            defer { heldResponses = [] }
            return heldResponses
        }
        for finish in held { finish(failing) }
    }

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
        let finish = { [self] (fails: Bool) in
            guard !fails else {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        let isHeld = Self.lock.withLock {
            if Self.holdsResponses { Self.heldResponses.append(finish) }
            return Self.holdsResponses
        }
        if !isHeld { finish(false) }
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
