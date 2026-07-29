import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct DirectMessageProviderContractTests {
    @Test func `DM history matches Paicord query ordering and stays a read`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        _ = try await provider.messages(
            in: ChannelID(rawValue: 41),
            before: MessageID(rawValue: 900),
            limit: 50
        )

        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/channels/41/messages")
        #expect(request.query == [
            CapturedQueryItem(name: "before", value: "900"),
            CapturedQueryItem(name: "limit", value: "50"),
        ])
        #expect(request.hadAuthorization)
    }

    @Test func `DM profile matches Paicord mutual profile query`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        let profile = try await provider.profile(
            for: UserID(rawValue: 2),
            in: nil
        )

        #expect(profile.user.id == UserID(rawValue: 2))
        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/users/2/profile")
        #expect(request.query == [
            CapturedQueryItem(name: "with_mutual_guilds", value: "true"),
            CapturedQueryItem(name: "with_mutual_friends", value: "true"),
            CapturedQueryItem(
                name: "with_mutual_friends_count",
                value: "true"
            ),
        ])
        #expect(request.hadAuthorization)
    }

    @Test func `private channel gateway events reconcile recipients and deletion`() async throws {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_CREATE",
            data: .object([
                "id": .string("41"),
                "type": .number(3),
                "name": .string("Design crew"),
                "owner_id": .string("1"),
                "recipients": .array([
                    .object([
                        "id": .string("2"),
                        "username": .string("maya"),
                        "global_name": .string("Maya"),
                    ])
                ]),
            ])
        )
        #expect(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            )?.ownerID == UserID(rawValue: 1)
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_RECIPIENT_ADD",
            data: .object([
                "channel_id": .string("41"),
                "user": .object([
                    "id": .string("3"),
                    "username": .string("theo"),
                    "global_name": .string("Theo"),
                ]),
            ])
        )
        #expect(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            )?.recipients.map(\.id) == [
                UserID(rawValue: 2), UserID(rawValue: 3),
            ]
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object([
                "id": .string("41"),
                "type": .number(3),
                "name": .string("Renamed remotely"),
            ])
        )
        let remotelyRenamed = try #require(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            )
        )
        #expect(remotelyRenamed.name == "Renamed remotely")
        #expect(remotelyRenamed.recipients.map(\.id) == [
            UserID(rawValue: 2), UserID(rawValue: 3),
        ])
        #expect(remotelyRenamed.ownerID == UserID(rawValue: 1))

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_DELETE",
            data: .object(["id": .string("41")])
        )
        #expect(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            ) == nil
        )
        await provider.disconnect()
    }

    @Test func `private channel order matches Paicord Ready and message reconciliation`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "maya", globalName: "Maya")
                ]),
                "private_channels": .array([
                    privateChannel(id: "41", lastMessageID: "500"),
                    privateChannel(id: "42", lastMessageID: nil),
                    privateChannel(id: "43", lastMessageID: "700"),
                ]),
            ])
        )
        #expect(
            await provider.cachedPrivateChannelsForTesting().map(\.id) == [
                ChannelID(rawValue: 43),
                ChannelID(rawValue: 41),
                ChannelID(rawValue: 42),
            ]
        )
        #expect(
            await provider.cachedPrivateChannelsForTesting().allSatisfy {
                $0.name == "Maya"
                    && $0.recipients.map(\.id) == [UserID(rawValue: 2)]
            }
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_CREATE",
            data: privateChannel(id: "44", lastMessageID: nil)
        )
        #expect(
            await provider.cachedPrivateChannelsForTesting().map(\.id) == [
                ChannelID(rawValue: 43),
                ChannelID(rawValue: 41),
                ChannelID(rawValue: 42),
                ChannelID(rawValue: 44),
            ]
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "3", username: "theo", globalName: "Theo")
                ]),
                "lazy_private_channels": .array([
                    privateChannel(
                        id: "45",
                        lastMessageID: "900",
                        recipientID: "3"
                    )
                ]),
            ])
        )
        let afterSupplemental = await provider.cachedPrivateChannelsForTesting()
        #expect(afterSupplemental.map(\.id) == [
            ChannelID(rawValue: 45),
            ChannelID(rawValue: 43),
            ChannelID(rawValue: 41),
            ChannelID(rawValue: 44),
            ChannelID(rawValue: 42),
        ])
        #expect(
            afterSupplemental.first?.recipients.map(\.id)
                == [UserID(rawValue: 3)]
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1000"),
                "channel_id": .string("42"),
                "author": .object([
                    "id": .string("2"),
                    "username": .string("maya"),
                    "global_name": .string("Maya"),
                    "avatar": .null,
                ]),
                "content": .string("most recent"),
                "timestamp": .string("2026-07-29T08:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
        let reordered = await provider.cachedPrivateChannelsForTesting()
        #expect(reordered.map(\.id) == [
            ChannelID(rawValue: 42),
            ChannelID(rawValue: 45),
            ChannelID(rawValue: 43),
            ChannelID(rawValue: 41),
            ChannelID(rawValue: 44),
        ])
        #expect(reordered.first?.lastMessageID == MessageID(rawValue: 1000))
        await provider.disconnect()
    }

    @Test func `official Discord system recipient marker survives Ready hydration`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(
                        id: "2",
                        username: "discord",
                        globalName: "Discord",
                        system: true
                    )
                ]),
                "private_channels": .array([
                    privateChannel(id: "41", lastMessageID: "500")
                ]),
            ])
        )

        #expect(
            await provider.cachedPrivateChannelsForTesting()
                .first?.recipients.first?.isSystem == true
        )
        await provider.disconnect()
    }

    @Test func `DM presence and custom status follow prioritized Ready and guildless updates without REST`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "maya", globalName: "Maya")
                ]),
                "private_channels": .array([
                    privateChannel(id: "41", lastMessageID: "500")
                ]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "merged_presences": .object([
                    "guilds": .array([]),
                    "friends": .array([
                        .object([
                            "user_id": .string("2"),
                            "status": .string("idle"),
                            "activities": .array([
                                .object([
                                    "type": .number(4),
                                    "state": .string("Shipping tiny details"),
                                ])
                            ]),
                        ])
                    ]),
                ]),
            ])
        )

        var member = try #require(await provider.members(in: nil).first)
        #expect(member.user.displayName == "Maya")
        #expect(member.status == .idle)
        #expect(member.customStatus == "Shipping tiny details")

        await provider.receiveGatewayDispatchForTesting(
            name: "PRESENCE_UPDATE",
            data: .object([
                "user": .object(["id": .string("2")]),
                "status": .string("online"),
                "activities": .array([]),
            ])
        )
        member = try #require(await provider.members(in: nil).first)
        #expect(member.status == .online)
        #expect(member.customStatus == nil)
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    private func privateChannel(
        id: String,
        lastMessageID: String?,
        recipientID: String = "2"
    ) -> JSONValue {
        var values: [String: JSONValue] = [
            "id": .string(id),
            "type": .number(1),
            "recipient_ids": .array([.string(recipientID)]),
        ]
        values["last_message_id"] = lastMessageID.map { .string($0) } ?? .null
        return .object(values)
    }

    private func user(
        id: String,
        username: String,
        globalName: String,
        system: Bool = false
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "username": .string(username),
            "global_name": .string(globalName),
            "avatar": .null,
            "system": .bool(system),
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

private actor DirectMessageCredentialStore: CredentialStore {
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

private struct CapturedQueryItem: Equatable, Sendable {
    var name: String
    var value: String?
}

private struct CapturedDirectMessageRequest: Sendable {
    var method: String
    var path: String
    var query: [CapturedQueryItem]
    var hadAuthorization: Bool
}

private final class DirectMessageURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    nonisolated(unsafe) static var requests:
        [CapturedDirectMessageRequest] = []

    static func reset() {
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
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
                query: query,
                hadAuthorization:
                    request.value(
                        forHTTPHeaderField: "Authorization"
                    ) != nil
            )
        )

        let body: String
        switch request.url?.path {
        case "/api/v9/channels/41/messages":
            body = "[]"
        case "/api/v9/users/2/profile":
            body =
                #"{"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0}"#
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
