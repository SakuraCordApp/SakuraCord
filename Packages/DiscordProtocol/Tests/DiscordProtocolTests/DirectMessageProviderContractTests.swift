import Foundation
import SakuraCordModels
import Synchronization
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct DirectMessageProviderContractTests {
    @Test func `widget game search coalesces normalized requests and retains failed query cooldown`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya")]), "guilds": .array([])
        ]))
        async let first = provider.searchProfileWidgetGames(query: "  Test_Game  ")
        async let second = provider.searchProfileWidgetGames(query: "test game")
        let results = try await (first, second)
        #expect(results.1 == results.0)
        #expect(DirectMessageURLProtocol.requests.count == 1)
        #expect(DirectMessageURLProtocol.requests.first?.query == [CapturedQueryItem(name: "q", value: "test game")])
        _ = try await provider.searchProfileWidgetGames(query: "test game")
        #expect(DirectMessageURLProtocol.requests.count == 1)
        for _ in 0 ..< 2 {
            await #expect(throws: ChatProviderError.self) { try await provider.searchProfileWidgetGames(query: "unavailable") }
        }
        #expect(DirectMessageURLProtocol.requests.count == 2)
        await provider.disconnect()
    }

    @Test func `similar games hide restricted entries and each game is read once per session`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "nsfw_allowed": .bool(false)]), "guilds": .array([])
        ]))
        #expect(try await provider.similarProfileGames(to: "21").map(\.id) == ["22"])
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/content-inventory/users/@me/similar-games/21", "/api/v9/games"
        ])
        #expect(DirectMessageURLProtocol.requests[1].query == ["22", "23", "24"].map { CapturedQueryItem(name: "game_ids", value: $0) })
        _ = try await provider.profileGameAnnouncements(gameID: "21")
        let request = try #require(DirectMessageURLProtocol.requests.last)
        #expect(request.path == "/api/v9/games/21/announcements")
        #expect(request.query == [CapturedQueryItem(name: "limit", value: "8")])
        #expect(DirectMessageURLProtocol.requests.allSatisfy { $0.method == "GET" && $0.body == nil })
        _ = try await provider.profileGameAnnouncements(gameID: "21")
        _ = try await provider.similarProfileGames(to: "21")
        #expect(DirectMessageURLProtocol.requests.count == 3)
        await provider.receiveGatewayDispatchForTesting(name: "USER_UPDATE", data: .object([
            "id": .string("2"), "username": .string("maya"), "nsfw_allowed": .bool(true)
        ]))
        #expect(try await provider.similarProfileGames(to: "21").map(\.id) == ["22", "24"])
        #expect(DirectMessageURLProtocol.requests.count == 3)
        await provider.disconnect()
    }

    @Test func `widget image upload is gated before reservation and the storage upload carries no credentials`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([])
        ]))
        await #expect(throws: ChatProviderError.self) {
            try await provider.uploadProfileWidgetImage(fileURL: file, filename: "cover.png", contentType: "image/png")
        }
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: widgetEligibleReady())
        _ = try await provider.uploadProfileWidgetImage(fileURL: file, filename: "cover.png", contentType: "image/png")
        let requests = DirectMessageURLProtocol.requests
        #expect(requests.map(\.method) == ["POST", "PUT"])
        #expect(requests.map(\.path) == ["/api/v9/users/@me/widgets/assets/upload", "/widget-image"])
        #expect(requests.map(\.hadAuthorization) == [true, false])
        await provider.disconnect()
    }

    @Test func `profile save acknowledges successful identity before metadata failure and retries only remaining changes`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
        ]))
        _ = try await provider.profileEditingSnapshot(in: .main)
        var changes = ProfileEditChanges()
        changes.identity.name = .set("Updated")
        changes.metadata.bio = .set("rejected-bio")
        let receipt = ProfileSaveReceipt(changes)
        await #expect(throws: ProfileValidationError.self) {
            try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
        }
        #expect(await receipt.stages == [.identity])
        var remaining = await receipt.changes
        #expect(!remaining.identity.hasChanges)
        #expect(remaining.metadata.bio == .set("rejected-bio"))
        remaining.metadata.bio = .set("Accepted bio")
        try await provider.saveProfileChanges(remaining, in: .main) { await receipt.accept($0) }
        #expect(await receipt.stages == [.identity, .metadata])
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile", "/api/v9/users/@me", "/api/v9/users/@me/profile", "/api/v9/users/@me/profile"
        ])
        #expect(DirectMessageURLProtocol.requests.suffix(3).allSatisfy { $0.method == "PATCH" })
        #expect(DirectMessageURLProtocol.requests.suffix(2).allSatisfy { $0.encodedPath == "/api/v9/users/%40me/profile" })
        await provider.disconnect()
    }

    @Test func `solid and pop defaults pass save validation and reconcile their distinct palettes`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([])
        ]))
        _ = try await provider.profileEditingSnapshot(in: .main)
        var changes = ProfileEditChanges()
        for invalidStyle in [
            DisplayNameStyle(colors: [0x1000000]),
            DisplayNameStyle(effectID: ProfileNameEffect.pop.rawValue),
        ] {
            changes.identity.displayNameStyle = .set(invalidStyle)
            await #expect(throws: ChatProviderError.self) {
                try await provider.saveProfileChanges(changes, in: .main) { _ in }
            }
        }
        #expect(DirectMessageURLProtocol.requests.count == 1)

        for style in [DisplayNameStyle(), DisplayNameStyle(effectID: 5, colors: [1_036_166])] {
            changes.identity.displayNameStyle = .set(style)
            let receipt = ProfileSaveReceipt(changes)
            try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
            let request = try #require(DirectMessageURLProtocol.requests.last)
            #expect(request.body?["display_name_font_id"] as? Int == style.fontID)
            #expect(request.body?["display_name_effect_id"] as? Int == style.effectID)
            #expect(request.body?["display_name_colors"] as? [UInt32] == style.colors)
            #expect(await receipt.snapshots.last??.presentation.user.displayNameStyle == style)
        }
        await provider.disconnect()
    }

    @Test func `successful but malformed profile response is acknowledged and requires a reload`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
        ]))
        _ = try await provider.profileEditingSnapshot(in: .main)
        var changes = ProfileEditChanges()
        changes.identity.name = .set("malformed-response")
        changes.metadata.bio = .set("Must not be sent")
        let receipt = ProfileSaveReceipt(changes)
        await #expect(throws: ChatProviderError.self) {
            try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
        }
        #expect(await receipt.stages == [.identity])
        #expect(await receipt.snapshots == [nil])
        let remaining = await receipt.changes
        await #expect(throws: ChatProviderError.self) {
            try await provider.saveProfileChanges(remaining, in: .main) { await receipt.accept($0) }
        }
        #expect(DirectMessageURLProtocol.requests.count == 2)
        await provider.disconnect()
    }

    @Test(arguments: [ProfileEditingScope.main, .server(GuildID(rawValue: 10))])
    func `server tag save sends one account request from either editor`(origin: ProfileEditingScope) async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
        ]))
        _ = try await provider.profileEditingSnapshot(in: origin)
        let requestCount = DirectMessageURLProtocol.requests.count
        let receipt = ProfileSaveReceipt(ProfileEditChanges(serverTag: .set(GuildID(rawValue: 99))))
        try await provider.saveProfileChanges(await receipt.changes, in: origin) { await receipt.accept($0) }
        #expect(await receipt.stages == [.serverTag])
        #expect(DirectMessageURLProtocol.requests.count == requestCount + 1)
        let request = try #require(DirectMessageURLProtocol.requests.last)
        #expect(request.method == "PUT")
        #expect(request.path == "/api/v9/users/@me/clan")
        #expect(request.body?["identity_enabled"] as? Bool == true)
        #expect(request.body?["identity_guild_id"] as? String == "99")
        await provider.disconnect()
    }

    @Test func `main profile saves from a server editor preload write metadata and widgets to the account routes`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: widgetEligibleReady())
        let scope = ProfileEditingScope.server(GuildID(rawValue: 10))
        _ = try await provider.profileEditingSnapshot(in: scope)
        let preload = try #require(DirectMessageURLProtocol.requests.first)
        #expect(preload.path == "/api/v9/users/2/profile")
        #expect(preload.query == [
            CapturedQueryItem(name: "type", value: "modal"),
            CapturedQueryItem(name: "with_mutual_guilds", value: "true"),
            CapturedQueryItem(name: "with_mutual_friends", value: "false"),
            CapturedQueryItem(name: "with_mutual_friends_count", value: "true"),
            CapturedQueryItem(name: "guild_id", value: "10"),
        ])
        // Opening the main editor from the server preload must establish a
        // saveable main baseline, including the original widget list.
        _ = try #require(try await provider.cachedProfileEditingSnapshot(in: .main))
        var changes = ProfileEditChanges(widgets: [ProfileWidget(content: .application(id: "7"))])
        changes.metadata.bio = .set("Accepted bio")
        let receipt = ProfileSaveReceipt(changes)
        try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
        #expect(await receipt.stages == [.metadata, .widgets])
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile", "/api/v9/users/@me/profile", "/api/v9/users/@me/widgets"
        ])
        await provider.disconnect()
    }

    @Test func `widget connection reads preserve repeated query keys and reconcile grants without another request`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
        ]))
        let connections = try await provider.profileWidgetConnections(applicationIDs: ["21", "22", "23", "21"])
        #expect(connections == ["21": .linked(sharesProfileData: true), "22": .linked(sharesProfileData: false), "23": .unlinked])
        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.path == "/api/v9/oauth2/tokens")
        #expect(request.query == ["21", "22", "23"].map { CapturedQueryItem(name: "application_ids", value: $0) })
        _ = try await provider.profileWidgetConnections(applicationIDs: ["23", "21"])
        #expect(DirectMessageURLProtocol.requests.count == 1)
        await provider.receiveGatewayDispatchForTesting(name: "OAUTH2_TOKEN_CREATE", data: .object([
            "id": .string("new-grant"), "application": .object(["id": .string("22")]),
            "scopes": .array([.string("sdk.social_layer_presence")])
        ]))
        #expect(try await provider.profileWidgetConnections(applicationIDs: ["22"]) == ["22": .linked(sharesProfileData: true)])
        await provider.receiveGatewayDispatchForTesting(name: "OAUTH2_TOKEN_DELETE", data: .object([
            "id": .string("old-grant"), "application_id": .string("22")
        ]))
        #expect(try await provider.profileWidgetConnections(applicationIDs: ["22"]) == ["22": .linked(sharesProfileData: true)])
        await provider.receiveGatewayDispatchForTesting(name: "OAUTH2_TOKEN_DELETE", data: .object([
            "id": .string("new-grant"), "application_id": .string("22")
        ]))
        #expect(try await provider.profileWidgetConnections(applicationIDs: ["22"]) == ["22": .unlinked])
        #expect(DirectMessageURLProtocol.requests.count == 1)
        await provider.disconnect()
    }
}

extension DirectMessageProviderContractTests {
    @Test func `DM popout profile requests and retains mutual friend list data`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        let profile = try await provider.profile(for: UserID(rawValue: 2), in: nil)

        #expect(profile.mutualFriendsCount == 1)
        #expect(profile.mutualFriends.map(\.id) == [UserID(rawValue: 3)])
        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.path == "/api/v9/users/2/profile")
        #expect(request.query == [
            CapturedQueryItem(name: "type", value: "popout"),
            CapturedQueryItem(name: "with_mutual_guilds", value: "true"),
            CapturedQueryItem(name: "with_mutual_friends", value: "true"),
            CapturedQueryItem(name: "with_mutual_friends_count", value: "true"),
        ])
    }

    @Test func `profile effects use only the current collectibles product route`() async throws {
        DirectMessageURLProtocol.reset()
        DirectMessageURLProtocol.profileHasEffect = true
        let provider = makeProvider()

        async let firstProfile = provider.profile(for: UserID(rawValue: 2), in: nil)
        async let secondProfile = provider.profile(for: UserID(rawValue: 2), in: nil)
        let (profile, duplicateProfile) = try await (firstProfile, secondProfile)

        #expect(profile.effect?.id == "900")
        #expect(duplicateProfile == profile)
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile",
            "/api/v9/collectibles-products/900",
        ])
    }

    @Test func `new and reopened private channels sort by last activity like Ready`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "users": .array([user(id: "2", username: "maya", globalName: "Maya")]),
                "private_channels": .array([
                    privateChannel(id: "41", lastMessageID: "500"),
                    privateChannel(id: "42", lastMessageID: nil),
                    privateChannel(id: "43", lastMessageID: "700"),
                ]),
            ])
        )
        #expect(await provider.cachedPrivateChannelsForTesting().map(\.id.rawValue) == [43, 41, 42])

        // A new message-less group DM leads by its own snowflake; reopened
        // DMs land by last message, not by their (newer) channel IDs.
        let created: [(id: String, lastMessageID: String?)] = [("800", nil), ("801", "600"), ("802", "10")]
        for channel in created {
            await provider.receiveGatewayDispatchForTesting(name: "CHANNEL_CREATE", data: privateChannel(id: channel.id, lastMessageID: channel.lastMessageID))
        }
        #expect(await provider.cachedPrivateChannelsForTesting().map(\.id.rawValue) == [800, 43, 801, 41, 42, 802])

        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1000"),
                "channel_id": .string("42"),
                "author": user(id: "2", username: "maya", globalName: "Maya"),
                "content": .string("most recent"),
                "timestamp": .string("2026-07-29T08:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
        #expect(await provider.cachedPrivateChannelsForTesting().map(\.id.rawValue) == [42, 800, 43, 801, 41, 802])
        await provider.disconnect()
    }

    @Test func `guildless voice move evicts the participant from the previous call`() async throws {
        try await assertGuildlessVoiceMoveReconciliation(
            provider: makeProvider()
        )
    }

    @Test func `private call ring and stop-ringing send bounded bodies and never replay a rejected ring`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "CALL_CREATE",
            data: privateCallPayload(channelID: "41", messageID: "501", voiceState: nil)
        )
        try await provider.ringPrivateCall(channelID: ChannelID(rawValue: 41), recipients: nil)
        try await provider.stopRingingPrivateCall(channelID: ChannelID(rawValue: 41), recipients: [UserID(rawValue: 1)])

        #expect(DirectMessageURLProtocol.requests.map(\.method) == ["POST", "POST"])
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/channels/41/call/ring",
            "/api/v9/channels/41/call/stop-ringing",
        ])
        #expect(DirectMessageURLProtocol.requests[0].body?["recipients"] is NSNull)
        #expect(DirectMessageURLProtocol.requests[1].body?["recipients"] as? [String] == ["1"])

        DirectMessageURLProtocol.ringStatus = 429
        await #expect(throws: ChatProviderError.self) {
            try await provider.ringPrivateCall(channelID: ChannelID(rawValue: 41), recipients: nil)
        }
        #expect(DirectMessageURLProtocol.requests.count { $0.path == "/api/v9/channels/41/call/ring" } == 2)
        await provider.disconnect()
    }

    private func widgetEligibleReady() -> JSONValue {
        .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([]),
            "apex_experiments": .object(["assignments": .object(["1": .object(["2": .object([
                "assignments": .array([.array([.number(2_369_760_879), .number(1), .number(2), .number(1)])])
            ])])])])
        ])
    }

    private func privateChannel(id: String, lastMessageID: String?) -> JSONValue {
        var values: [String: JSONValue] = [
            "id": .string(id),
            "type": .number(1),
            "recipient_ids": .array([.string("2")]),
        ]
        values["last_message_id"] = lastMessageID.map { .string($0) } ?? .null
        return .object(values)
    }

    private func user(id: String, username: String, globalName: String) -> JSONValue {
        .object([
            "id": .string(id),
            "username": .string(username),
            "global_name": .string(globalName),
            "avatar": .null,
        ])
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectMessageURLProtocol.self]
        return DiscordRESTProvider(
            credentials: DirectMessageCredentialStore(),
            handle: CredentialHandle(accountID: "dm-contract"),
            session: URLSession(configuration: configuration)
        )
    }
}

private func assertGuildlessVoiceMoveReconciliation(
    provider: DiscordRESTProvider
) async throws {
    await provider.receiveGatewayDispatchForTesting(
        name: "CALL_CREATE",
        data: privateCallPayload(
            channelID: "41",
            messageID: "501",
            voiceState: .object([
                "user_id": .string("9"),
                "channel_id": .string("41"),
                "guild_id": .null,
                "session_id": .string("private-session-a")
            ])
        )
    )
    await provider.receiveGatewayDispatchForTesting(
        name: "CALL_CREATE",
        data: privateCallPayload(
            channelID: "42",
            messageID: "502",
            voiceState: nil
        )
    )

    let events = await provider.eventStream()
    let changedCalls = Task {
        await nextPrivateCallChanges(count: 2, from: events)
    }

    await provider.receiveGatewayDispatchForTesting(
        name: "VOICE_STATE_UPDATE",
        data: .object([
            "user_id": .string("9"),
            "channel_id": .string("42"),
            "guild_id": .null,
            "session_id": .string("private-session-b"),
            "self_mute": .bool(false),
            "self_deaf": .bool(false)
        ])
    )

    let calls = await changedCalls.value
    #expect(calls.map(\.channelID) == [
        ChannelID(rawValue: 41),
        ChannelID(rawValue: 42)
    ])
    #expect(calls[0].voiceStates?.isEmpty == true)
    #expect(calls[1].voiceStates?.map(\.userID) == [UserID(rawValue: 9)])
    await provider.disconnect()
}

private func nextPrivateCallChanges(
    count: Int,
    from events: AsyncStream<ClientEvent>
) async -> [PrivateCall] {
    var calls: [PrivateCall] = []
    for await event in events {
        guard case let .privateCallChanged(call) = event else {
            continue
        }
        calls.append(call)
        if calls.count == count {
            return calls
        }
    }
    return calls
}

private func privateCallPayload(
    channelID: String,
    messageID: String,
    voiceState: JSONValue?
) -> JSONValue {
    .object([
        "channel_id": .string(channelID),
        "message_id": .string(messageID),
        "ongoing_rings": .object([:]),
        "voice_states": .array(voiceState.map { [$0] } ?? [])
    ])
}

actor DirectMessageCredentialStore: CredentialStore {
    func store(
        _ credential: Data,
        accountID: String
    ) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("dm-contract-session".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        [CredentialHandle(accountID: "dm-contract")]
    }
}

private actor ProfileSaveReceipt {
    var changes: ProfileEditChanges
    var stages: [ProfileSaveStage] = []
    var snapshots: [ProfileEditingSnapshot?] = []

    init(_ changes: ProfileEditChanges) { self.changes = changes }

    func accept(_ confirmation: ProfileSaveConfirmation) {
        changes.acknowledge(confirmation.stage)
        stages.append(confirmation.stage)
        snapshots.append(confirmation.snapshot)
    }
}

struct CapturedQueryItem: Equatable, Sendable {
    var name: String
    var value: String?
}

struct CapturedDirectMessageRequest: @unchecked Sendable {
    var method: String
    var path: String
    var encodedPath: String
    var query: [CapturedQueryItem]
    var hadAuthorization: Bool
    var body: [String: Any]?
    var receivedAt = ContinuousClock.now
}

final class DirectMessageURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    nonisolated(unsafe) static var requests:
        [CapturedDirectMessageRequest] = []
    nonisolated(unsafe) static var ringStatus = 204
    nonisolated(unsafe) static var profileHasEffect = false
    /// Replies consumed in order by settings-proto/1 requests; when empty, a
    /// PATCH echoes its settings.
    nonisolated(unsafe) static var settingsReplies: [SettingsProtocolReply] = []
    static let memberIdentityReplies = Mutex<[SettingsProtocolReply]>([])

    static func reset() {
        requests = []
        ringStatus = 204
        profileHasEffect = false
        settingsReplies = []
        memberIdentityReplies.withLock { $0 = [] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestBody = Self.requestBody(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let query = URLComponents(
            url: request.url!,
            resolvingAgainstBaseURL: false
        )?.queryItems?.map {
            CapturedQueryItem(name: $0.name, value: $0.value)
        } ?? []
        Self.requests.append(
            CapturedDirectMessageRequest(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                encodedPath: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "",
                query: query,
                hadAuthorization:
                    request.value(
                        forHTTPHeaderField: "Authorization"
                    ) != nil,
                body: requestBody
            )
        )

        var body: String
        do {
            body = try Self.responseBody(path: request.url?.path, query: query, requestBody: requestBody)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var status: Int
        var responseGate: StatusRecoveryResponseGate?
        let memberIdentityReply = request.url?.path.hasPrefix("/api/v9/guilds/") == true
            && request.url?.path.contains("/members/") == true
            && request.httpMethod == "PATCH" ? Self.memberIdentityReplies.withLock { replies in
                replies.isEmpty ? nil : replies.removeFirst()
            } : nil
        if let reply = memberIdentityReply {
            status = reply.status
            body = reply.body
            responseGate = reply.gate
        } else if request.url?.path == "/api/v9/users/@me/settings-proto/1", !Self.settingsReplies.isEmpty {
            let reply = Self.settingsReplies.removeFirst()
            status = reply.status
            body = reply.body
            responseGate = reply.gate
        } else if requestBody?["bio"] as? String == "rejected-bio" {
            status = 400
        } else if request.url?.path == "/api/v9/games/autocomplete", query.first?.value == "unavailable" {
            status = 503
        } else {
            status = request.url?.path == "/api/v9/channels/41/call/ring" ? Self.ringStatus : 200
        }
        if let gate = responseGate {
            let responseStatus = status, responseBody = body
            gate.capture { [self] in completeResponse(status: responseStatus, body: responseBody) }
            return
        }
        completeResponse(status: status, body: body)
    }

    private static func responseBody(
        path: String?,
        query: [CapturedQueryItem],
        requestBody: [String: Any]?
    ) throws -> String {
        switch path {
        case "/api/v9/oauth2/tokens":
            return #"[{"id":"grant21","application":{"id":"21"},"scopes":["application_identities.write"]},{"id":"old-grant","application":{"id":"22"},"scopes":["identify"]}]"#
        case "/api/v9/users/@me/settings-proto/1":
            return String(data: try JSONSerialization.data(withJSONObject: ["settings": requestBody?["settings"] as? String ?? ""]), encoding: .utf8)!
        case "/api/v9/users/@me/widgets/assets/upload":
            return #"{"upload_url":"https://storage.example/widget-image?signature=fixture","upload_filename":"reserved/cover.png"}"#
        case "/widget-image":
            return ""
        case "/api/v9/users/@me":
            if requestBody?["display_name_colors"] != nil {
                return requestBody?["display_name_effect_id"] as? Int == 5
                    ? #"{"id":"2","username":"maya","premium_type":2,"display_name_styles":{"font_id":11,"effect_id":5,"colors":[1036166]}}"#
                    : #"{"id":"2","username":"maya","premium_type":2,"display_name_styles":{"font_id":11,"effect_id":1,"colors":[]}}"#
            }
            return requestBody?["global_name"] as? String == "malformed-response"
                ? "{}" : #"{"id":"2","username":"maya","global_name":"Updated","avatar":null}"#
        case "/api/v9/users/@me/profile":
            return requestBody?["bio"] as? String == "rejected-bio"
                ? #"{"code":50035,"message":"Invalid Form Body","errors":{"bio":{"_errors":[{"code":"BASE_TYPE_MAX_LENGTH","message":"About Me is too long."}]}}}"#
                : #"{"bio":"Accepted bio","pronouns":"","banner":null,"theme_colors":null,"collectibles":[]}"#
        case "/api/v9/users/@me/widgets":
            return #"{"widgets":[{"id":"700","updated_at":"2026-09-05T12:00:00.000000+00:00","data":{"type":"application","application_id":"7"}}]}"#
        case "/api/v9/collectibles-products/900":
            return #"""
            {"sku_id":"900","name":"Aurora","summary":"Profile effect","type":1,"premium_type":0,
             "items":[{"type":1,"sku_id":"900","title":"Aurora",
             "thumbnailPreviewSrc":"https://cdn.discordapp.com/assets/content/aurora-preview","effects":[] }]}
            """#
        default:
            return try profileResponseBody(path: path, query: query, requestBody: requestBody)
                ?? gameResponseBody(path: path, query: query)
        }
    }

    private static func profileResponseBody(
        path: String?, query: [CapturedQueryItem], requestBody: [String: Any]?
    ) throws -> String? {
        switch path {
        case "/api/v9/users/@me/clan":
            return try serverTagResponse(requestBody)
        case "/api/v9/users/2/profile":
            return profileHasEffect
                ? #"""
                {
                  "user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},
                  "user_profile":{"profile_effect":{"sku_id":"900"}},
                  "mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0
                }
                """#
                : query.contains(where: { $0.name == "guild_id" })
                    ? #"""
                    {"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"premium_type":2,
                     "guild_member":{"nick":null,"avatar":null},"guild_member_profile":{"bio":"","pronouns":"","theme_colors":null},"widgets":[],
                     "mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0}
                    """#
                    : """
                    {"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"premium_type":2,"widgets":[],"mutual_guilds":[],
                     "mutual_friends":\(query.contains(CapturedQueryItem(name: "with_mutual_friends", value: "true")) ? #"[{"id":"3","username":"ivy","global_name":"Ivy"}]"# : "[]"),
                     "mutual_friends_count":1}
                    """
        default: return nil
        }
    }

    private static func serverTagResponse(_ requestBody: [String: Any]?) throws -> String {
        let enabled = requestBody?["identity_enabled"] as? Bool == true
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "2", "username": "maya", "global_name": "Maya", "avatar": NSNull(),
            "primary_guild": ["identity_guild_id": requestBody?["identity_guild_id"] ?? NSNull(),
                              "identity_enabled": enabled, "tag": enabled ? "TEST" as Any : NSNull()]
        ])
        return String(data: data, encoding: .utf8)!
    }

    private static func gameResponseBody(path: String?, query: [CapturedQueryItem]) -> String {
        switch path {
        case "/api/v9/content-inventory/users/@me/similar-games/21":
            return #"{"similar_games":["21","22","23","24","700136079562375258"]}"#
        case "/api/v9/games":
            return #"[{"id":"22","name":"Available","game_flags":0},{"id":"23","name":"Hidden","game_flags":1},{"id":"24","name":"Adult","content_classification":{"discord_classifications":8}}]"#
        case "/api/v9/games/21/announcements":
            return ##"""
            {"messages":[
              {"id":"800","channel_id":"41","author":{"id":"77","username":"publisher"},"content":"# Update\nNew features","timestamp":"2026-09-05T12:00:00Z"}
            ],"channel_id":"41","guild_id":"10"}
            """##
        case "/api/v9/games/autocomplete":
            return query.first?.value == "unavailable" ? #"{"message":"Unavailable"}"# : #"[{"id":"21","name":"Test Game"}]"#
        default:
            return "{}"
        }
    }

    override func stopLoading() {}

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
