@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Suite(.serialized)
struct NicknameCommandTests {
    @Test func `nickname set and reset are single scoped mutations and reconcile the member`() async throws {
        let provider = await makeProvider()
        let guildID = GuildID(rawValue: 100)
        #expect(try await provider.setNickname("Research", in: guildID) == "Research")
        #expect(await provider.cachedMembers[guildID]?.first?.guildNickname == "Research")
        #expect(try await provider.setNickname("", in: guildID) == nil)
        #expect(await provider.cachedMembers[guildID]?.first?.guildNickname == nil)
        let requests = NicknameURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "PATCH" && $0.url?.absoluteString == "https://discord.com/api/v9/guilds/100/members/%40me/nick" })
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }

    @Test func `nickname validation and permission failures do not stop the session or retry`() async throws {
        let provider = await makeProvider()
        for value in ["invalid", "forbidden"] {
            await #expect(throws: (any Error).self) {
                _ = try await provider.setNickname(value, in: .init(rawValue: 100))
            }
            #expect(await !provider.requestSafetyCircuitIsOpen)
        }
        #expect(NicknameURLProtocol.requests.withLock { $0.count } == 2)
        #expect(try await provider.setNickname("Recovered", in: .init(rawValue: 100)) == "Recovered")
        await provider.disconnect()
    }

    @Test func `moderator nickname changes use the member route once and reconcile that member`() async throws {
        let provider = await makeProvider()
        let guildID = GuildID(rawValue: 100)
        let memberID = UserID(rawValue: 2)
        #expect(try await provider.setMemberNickname("Moderated", for: memberID, in: guildID) == "Moderated")
        #expect(await provider.cachedMembers[guildID]?.first { $0.id == memberID }?.guildNickname == "Moderated")
        #expect(try await provider.setMemberNickname("", for: memberID, in: guildID) == nil)
        #expect(await provider.cachedMembers[guildID]?.first { $0.id == memberID }?.guildNickname == nil)
        await #expect(throws: (any Error).self) {
            _ = try await provider.setMemberNickname("forbidden", for: memberID, in: guildID)
        }
        #expect(await !provider.requestSafetyCircuitIsOpen)
        let requests = NicknameURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.httpMethod == "PATCH" && $0.url?.absoluteString == "https://discord.com/api/v9/guilds/100/members/2" })
        await provider.disconnect()
    }

    @Test func `friend nicknames are one relationship patch and follow relationship events`() async throws {
        let provider = await makeProvider()
        let friendID = UserID(rawValue: 2)
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: relationship(type: 1, nickname: nil))
        #expect(await provider.cachedFriendUserIDs.contains(friendID))
        #expect(try await provider.setFriendNickname("Bestie", for: friendID) == "Bestie")
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == "Bestie")
        #expect(try await provider.setFriendNickname("  ", for: friendID) == nil)
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == nil)
        let requests = NicknameURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "PATCH" && $0.url?.absoluteString == "https://discord.com/api/v9/users/@me/relationships/2" })
        #expect(NicknameURLProtocol.bodies.withLock { $0 } == [
            .object(["nickname": .string("Bestie")]), .object(["nickname": .null]),
        ])
        // Rejected friend nicknames stay in the dialog instead of stopping the session.
        await #expect(throws: ProfileValidationError.self) { _ = try await provider.setFriendNickname("invalid", for: friendID) }
        await #expect(throws: (any Error).self) { _ = try await provider.setFriendNickname("stranger", for: friendID) }
        #expect(await !provider.requestSafetyCircuitIsOpen)

        // Another session renames. Like Discord's RelationshipStore, an add
        // without a nickname keeps it, while an update without one clears it.
        await provider.seedFriendDirectMessage()
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_UPDATE", body: relationship(type: 1, nickname: .string("Elsewhere")))
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == "Elsewhere")
        #expect(await provider.cachedChannels[nil]?.map(\.name) == ["Elsewhere", "Friend Group"])
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: relationship(type: 1, nickname: nil))
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == "Elsewhere")
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_UPDATE", body: relationship(type: 1, nickname: nil))
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == nil)
        #expect(await provider.cachedChannels[nil]?.map(\.name) == ["Friend", "Friend Group"])
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_UPDATE", body: relationship(type: 1, nickname: .string("Again")))
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_REMOVE", body: relationship(type: 1, nickname: nil))
        #expect(await !provider.cachedFriendUserIDs.contains(friendID))
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == nil)
        #expect(await provider.cachedChannels[nil]?.map(\.name) == ["Friend", "Friend Group"])
        await provider.disconnect()
    }

    @Test(arguments: ["2", "3"], ["RELATIONSHIP_UPDATE", "RELATIONSHIP_REMOVE"])
    func `friend nickname saves ignore unrelated events and preserve newer target state`(
        updatedUser: String, eventName: String
    ) async throws {
        let credentials = NicknameInterleavingCredentials()
        let provider = await makeProvider(credentials: credentials)
        let friendID = UserID(rawValue: 2)
        await provider.seedFriendDirectMessage()
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_ADD", body: relationship(type: 1, nickname: .string("Old")))
        let event = relationship(userID: updatedUser, type: 1, nickname: .string("Newer"))
        await credentials.interleave {
            await provider.handleGatewayDispatch(name: eventName, body: event)
        }
        #expect(try await provider.setFriendNickname("Saved", for: friendID) == "Saved")
        let expected: String? = updatedUser == "3" ? "Saved" : eventName == "RELATIONSHIP_REMOVE" ? nil : "Newer"
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == expected)
        #expect(await provider.cachedFriendUserIDs.contains(friendID) == (expected != nil))
        #expect(await provider.cachedChannels[nil]?.map(\.name) == [expected ?? "Friend", "Friend Group"])
        #expect(NicknameURLProtocol.requests.withLock { $0.count } == 1)
        await provider.disconnect()
    }

    @Test func `friend nickname response cannot replace fresh READY state`() async throws {
        let credentials = NicknameInterleavingCredentials()
        let provider = await makeProvider(credentials: credentials)
        func ready(_ nickname: String) -> JSONValue {
            .object([
                "user": .object(["id": .string("1"), "username": .string("fixture")]),
                "relationships": .array([relationship(type: 1, nickname: .string(nickname))]),
            ])
        }
        await provider.handleGatewayDispatch(name: "READY", body: ready("Old"))
        let replacement = ready("Reconnected")
        await credentials.interleave {
            await provider.handleGatewayDispatch(name: "READY", body: replacement)
        }
        let friendID = UserID(rawValue: 2)
        #expect(try await provider.setFriendNickname("Saved", for: friendID) == "Saved")
        #expect(await provider.cachedRelationshipNicknamesByUserID[friendID] == "Reconnected")
        #expect(NicknameURLProtocol.requests.withLock { $0.count } == 1)
        await provider.disconnect()
    }

    @Test(arguments: ["100", "101"], ["1", "2"])
    func `nickname responses ignore other guild revisions and preserve newer target guild updates`(
        updatedGuild: String, targetUser: String
    ) async throws {
        let credentials = NicknameInterleavingCredentials()
        let provider = await makeProvider(credentials: credentials)
        let guildID = GuildID(rawValue: 100)
        let memberID = try #require(UserID(targetUser))
        let event = JSONValue.object([
            "guild_id": .string(updatedGuild), "nick": .string("Newer"), "roles": .array([]),
            "user": .object(["id": .string(targetUser), "username": .string("fixture")]),
        ])
        // Credential loading suspends the save after its revision is captured,
        // before the mocked PATCH completes. No timing or real networking needed.
        await credentials.interleave {
            await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: event)
        }
        #expect(try await provider.setMemberNickname("Saved", for: memberID, in: guildID) == "Saved")
        let expected = updatedGuild == "100" ? "Newer" : "Saved"
        #expect(await provider.cachedMembers[guildID]?.first { $0.id == memberID }?.guildNickname == expected)
        if updatedGuild == "101" {
            #expect(await provider.cachedMembers[GuildID(rawValue: 101)]?.first { $0.id == memberID }?.guildNickname == "Newer")
        }
        #expect(NicknameURLProtocol.requests.withLock { $0.count } == 1)
        await provider.disconnect()
    }

    @Test func `friend nicknames keep explicit group names and the empty group fallback`() async throws {
        let provider = await makeProvider()
        await provider.seedFriendDirectMessage()
        // An icon-only update must not turn the named group into a recipient title.
        await provider.handleGatewayDispatch(name: "CHANNEL_UPDATE", body: .object([
            "id": .string("401"), "type": .number(3), "icon": .string("abc"),
        ]))
        await provider.handleGatewayDispatch(name: "RELATIONSHIP_UPDATE", body: relationship(type: 1, nickname: .string("Bestie")))
        #expect(await provider.cachedChannels[nil]?.map(\.name) == ["Bestie", "Friend Group"])
        // When the only other member leaves an unnamed group, its title falls back.
        await provider.handleGatewayDispatch(name: "CHANNEL_RECIPIENT_ADD", body: .object([
            "channel_id": .string("400"), "user": .object(["id": .string("3"), "username": .string("other")]),
        ]))
        for userID in ["2", "3"] {
            await provider.handleGatewayDispatch(name: "CHANNEL_RECIPIENT_REMOVE", body: .object([
                "channel_id": .string("400"), "user": .object(["id": .string(userID), "username": .string("gone")]),
            ]))
        }
        #expect(await provider.cachedChannels[nil]?.first { $0.id.rawValue == 400 }?.name == "Group Direct Message")
        await provider.disconnect()
    }

    @Test func `member timeouts hydrate on READY and distinguish omitted updates from reset`() async throws {
        let provider = await makeProvider()
        let guildID = GuildID(rawValue: 100)
        let expiry = "2030-01-01T00:00:00.000Z"
        let user = JSONValue.object(["id": .string("1"), "username": .string("fixture")])
        let merged = try JSONValueDecoder().decode(ReadyMergedMemberDTO.self, from: .object([
            "user_id": .string("1"), "roles": .array([]), "communication_disabled_until": .string(expiry),
        ]))
        let dto = try #require(merged.hydrated(using: ["1": JSONValueDecoder().decode(UserDTO.self, from: user)]))
        #expect(try dto.domain(currentUserID: nil, currentStatus: .offline).communicationDisabledUntil == DiscordDate.parse(expiry))

        var fields: [String: JSONValue] = [
            "guild_id": .string("100"), "user": user, "roles": .array([]),
            "flags": .number(128), "pending": .bool(true), "communication_disabled_until": .string(expiry),
        ]
        await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: .object(fields))
        #expect(await provider.cachedMembers[guildID]?.first?.communicationDisabledUntil == DiscordDate.parse(expiry))
        #expect(await provider.cachedMembers[guildID]?.first?.flags == 128)
        #expect(await provider.cachedMembers[guildID]?.first?.isPending == true)
        fields.removeValue(forKey: "communication_disabled_until")
        fields["nick"] = .string("New name")
        await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: .object(fields))
        #expect(await provider.cachedMembers[guildID]?.first?.communicationDisabledUntil == DiscordDate.parse(expiry))
        fields["communication_disabled_until"] = .null
        await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: .object(fields))
        #expect(await provider.cachedMembers[guildID]?.first?.communicationDisabledUntil == nil)
        #expect(NicknameURLProtocol.requests.withLock { $0.isEmpty })
        await provider.disconnect()
    }

    private func relationship(userID: String = "2", type: Int, nickname: JSONValue?) -> JSONValue {
        var body: [String: JSONValue] = ["id": .string(userID), "type": .number(Double(type))]
        if let nickname { body["nickname"] = nickname }
        return .object(body)
    }

    private func makeProvider(credentials: any CredentialStore = TestCredentialStore()) async -> DiscordRESTProvider {
        NicknameURLProtocol.requests.withLock { $0.removeAll() }
        NicknameURLProtocol.bodies.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NicknameURLProtocol.self]
        let provider = DiscordRESTProvider(credentials: credentials,
                                           handle: CredentialHandle(accountID: "nickname-command"),
                                           session: URLSession(configuration: configuration))
        await provider.seedNicknameCommand()
        return provider
    }
}

/// Runs Gateway events after a mutation starts and before its request is sent.
actor NicknameInterleavingCredentials: CredentialStore {
    private let base = TestCredentialStore()
    private var action: (@Sendable () async -> Void)?

    func interleave(_ action: @escaping @Sendable () async -> Void) { self.action = action }
    func credential(for handle: CredentialHandle) async throws -> Data {
        let pending = action
        action = nil
        await pending?()
        return try await base.credential(for: handle)
    }
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        try await base.store(credential, accountID: accountID)
    }
    func remove(_ handle: CredentialHandle) async throws { try await base.remove(handle) }
    func handles() async throws -> [CredentialHandle] { try await base.handles() }
}

private extension DiscordRESTProvider {
    func seedNicknameCommand() {
        currentUser = User(id: .init(rawValue: 1), username: "fixture", displayName: "Fixture")
    }

    /// An unnamed DM takes its title from the friend; a named group keeps its own.
    func seedFriendDirectMessage() {
        let friend = User(id: .init(rawValue: 2), username: "friend", displayName: "Friend")
        cachedChannels[nil] = [
            Channel(id: .init(rawValue: 400), guildID: nil, name: "Friend", hasExplicitName: false,
                    kind: .directMessage, recipients: [friend]),
            Channel(id: .init(rawValue: 401), guildID: nil, name: "Friend Group", kind: .groupDirectMessage,
                    recipients: [friend]),
        ]
    }
}

private final class NicknameURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    static let bodies = Mutex<[JSONValue]>([])
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let body: Data
        if let data = request.httpBody { body = data } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = Data() }
        if let value = try? JSONDecoder().decode(JSONValue.self, from: body) {
            Self.bodies.withLock { $0.append(value) }
        }
        if request.url?.path.contains("/relationships/") == true {
            switch (try? JSONDecoder().decode([String: String].self, from: body))?["nickname"] {
            case "invalid":
                respond(status: 400, body: #"{"code":50035,"errors":{"nickname":{"_errors":[{"code":"BASE_TYPE_BAD_LENGTH","message":"Must be 32 or fewer in length."}]}}}"#)
            case "stranger":
                respond(status: 400, body: #"{"code":80004,"message":"No users with DiscordTag exist"}"#)
            default:
                respond(status: 204, body: "")
            }
            return
        }
        let userID = request.url?.lastPathComponent == "nick" ? "1" : request.url?.lastPathComponent ?? "1"
        let nickname = (try? JSONDecoder().decode([String: String].self, from: body))?["nick"]
        let status = nickname == "invalid" ? 400 : nickname == "forbidden" ? 403 : nickname == nil ? 500 : 200
        let responseBody: String
        if status == 400 {
            responseBody = #"{"code":50035,"errors":{"nick":{"_errors":[{"code":"INVALID","message":"Invalid nickname"}]}}}"#
        } else if status == 403 {
            responseBody = #"{"code":50013,"message":"Missing Permissions"}"#
        } else {
            let nick = nickname.flatMap { $0.isEmpty ? nil : $0 }.map(JSONValue.string) ?? .null
            let response = JSONValue.object(["user": .object(["id": .string(userID), "username": .string("fixture")]),
                                             "nick": nick, "roles": .array([])])
            responseBody = (try? JSONEncoder().encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        respond(status: status, body: responseBody)
    }

    private func respond(status: Int, body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
