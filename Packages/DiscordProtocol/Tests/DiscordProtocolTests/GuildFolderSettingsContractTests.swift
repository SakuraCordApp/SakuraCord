@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Suite(.serialized)
struct GuildFolderSettingsContractTests {
    @Test func `server rail edits save one guild folders subtree and roll back a rejected save`() async throws {
        GuildFolderURLProtocol.reset()
        let provider = stubbedProvider(GuildFolderURLProtocol.self)
        func field(_ number: Int, _ payload: [UInt8], wireType: Int = 2) -> [UInt8] {
            encodeProtoVarint(UInt64(number << 3 | wireType))
                + (wireType == 2 ? encodeProtoVarint(UInt64(payload.count)) : []) + payload
        }
        func fixed64(_ value: UInt64) -> [UInt8] {
            (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
        }
        func entry(_ guildIDs: [UInt64], metadata: [UInt8] = []) -> [UInt8] {
            field(1, field(1, guildIDs.flatMap(fixed64)) + metadata)
        }
        // Folder 42 also stores server 900, which this session cannot show.
        let metadata = field(2, field(1, [42], wireType: 0)) + field(3, field(1, Array(" Design ".utf8)))
            + field(4, field(1, encodeProtoVarint(0x58_65_F2), wireType: 0)) + field(9, [1])
        let positions = field(2, [100, 200, 300, 900].flatMap(fixed64))
        let unknown = field(7, [5])
        let stored = entry([100]) + entry([200, 900, 300], metadata: metadata) + positions + unknown
        let status = field(11, [0x1A, 0x00])
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya")]),
            "guilds": .array(["100", "200", "300"].map { .object(["id": .string($0), "name": .string("Server \($0)")]) }),
            "user_settings_proto": .string(Data(status + field(14, stored)).base64EncodedString())
        ]))
        let folder = GuildFolder(id: 42, name: "Design", colorHex: 0x58_65_F2, guildIDs: [GuildID(rawValue: 200), GuildID(rawValue: 300)])
        let initial: [GuildRailItem] = [.guild(GuildID(rawValue: 100)), .folder(folder)]
        #expect(await provider.cachedGuildRailItemsForTesting() == initial)

        // Two quick moves are one save: 100 joins the folder, then 300 leaves it.
        let events = await provider.eventStream()
        var moved = initial.moving([.guild(GuildID(rawValue: 100))], to: .init(container: .folder(42)))
        try await provider.updateGuildRailLayout(moved)
        moved = moved.moving([.guild(GuildID(rawValue: 300))], to: .init(container: .root))
        try await provider.updateGuildRailLayout(moved)
        #expect(await provider.cachedGuildRailItemsForTesting() == moved)
        #expect(GuildFolderURLProtocol.requests.isEmpty)
        await provider.flushGuildFoldersIfNeeded()
        await provider.flushGuildFoldersIfNeeded()

        #expect(GuildFolderURLProtocol.requests.count == 1)
        let request = try #require(GuildFolderURLProtocol.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v9/users/@me/settings-proto/1")
        #expect(request.query.isEmpty)
        #expect(request.hadAuthorization)
        #expect(request.body?.keys.sorted() == ["settings"])
        let saved = try #require((request.body?["settings"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(Array(saved) == field(14, entry([200, 100, 900], metadata: metadata) + entry([300]) + positions + unknown))
        #expect(await provider.cachedGuildRailItemsForTesting() == moved)

        // A new folder carries only its ID. Folder settings rewrite just the
        // changed name and cleared color, keeping the folder's unknown field.
        moved = moved.combining(GuildID(rawValue: 100), onto: GuildID(rawValue: 300), folderID: 7)
            .updatingFolder(42, name: "Art", colorHex: nil)
        try await provider.updateGuildRailLayout(moved)
        await provider.flushGuildFoldersIfNeeded()
        #expect(GuildFolderURLProtocol.requests.count == 2)
        let edited = try #require(
            (GuildFolderURLProtocol.requests.last?.body?["settings"] as? String).flatMap { Data(base64Encoded: $0) }
        )
        let editedMetadata = field(2, field(1, [42], wireType: 0)) + field(3, field(1, Array("Art".utf8))) + field(9, [1])
        #expect(Array(edited) == field(14, entry([200, 900], metadata: editedMetadata)
            + entry([300, 100], metadata: field(2, field(1, [7], wireType: 0))) + positions + unknown))
        #expect(await provider.cachedGuildRailItemsForTesting() == moved)

        // A rejected save restores the last layout Discord confirmed.
        GuildFolderURLProtocol.settingsStatus = 400
        try await provider.updateGuildRailLayout(initial)
        await provider.flushGuildFoldersIfNeeded()
        #expect(GuildFolderURLProtocol.requests.count == 3)
        #expect(await provider.cachedGuildRailItemsForTesting() == moved)
        await provider.disconnect()
        #expect(GuildFolderURLProtocol.requests.count == 3)
        var received: [[GuildRailItem]?] = []
        for await event in events {
            if case let .guildLayoutChanged(_, railItems) = event { received.append(railItems) }
            if case .guildLayoutSaveFailed = event { received.append(nil) }
        }
        #expect(received == [moved, nil])
    }
}

private struct CapturedGuildFolderRequest: @unchecked Sendable {
    var method: String
    var path: String
    var query: [URLQueryItem]
    var hadAuthorization: Bool
    var body: [String: Any]?
}

/// Records every request and echoes a settings save back, as Discord does.
private final class GuildFolderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [CapturedGuildFolderRequest] = []
    nonisolated(unsafe) static var settingsStatus = 200

    static func reset() {
        requests = []
        settingsStatus = 200
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.requestBody(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        Self.requests.append(CapturedGuildFolderRequest(
            method: request.httpMethod ?? "",
            path: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "",
            query: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [],
            hadAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil,
            body: body
        ))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.settingsStatus, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        let payload = try? JSONSerialization.data(withJSONObject: ["settings": body?["settings"] as? String ?? ""])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        request.bodyData
    }
}
