@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Suite(.serialized)
struct GroupDirectMessageEditTests {
    private let groupID = ChannelID(rawValue: 401)

    @Test func `edit group sends only changed fields in one patch and reconciles the group`() async throws {
        let provider = await makeProvider()
        let icon = ProfileImageUpload(data: Data([1, 2, 3]), mediaType: "image/png", description: "icon.png")
        let saved = try await provider.editGroupDirectMessage(groupID, changes: .init(name: .set(" Trip "), icon: .set(icon)))
        #expect(saved.name == "Trip")
        #expect(saved.iconURL?.absoluteString == "https://cdn.discordapp.com/channel-icons/401/hash.webp?size=128")
        #expect(await provider.privateChannel(id: groupID)?.name == "Trip")

        // Clearing restores the member-list title and removes the icon.
        let cleared = try await provider.editGroupDirectMessage(groupID, changes: .init(name: .clear, icon: .clear))
        #expect(cleared.name == cleared.recipients.map(\.displayName).joined(separator: ", "))
        #expect(cleared.hasExplicitName == false)
        #expect(await provider.privateChannel(id: groupID)?.iconURL == nil)

        _ = try await provider.editGroupDirectMessage(groupID, changes: .init())
        let requests = GroupEditURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "PATCH" && $0.url?.absoluteString == "https://discord.com/api/v9/channels/401" })
        #expect(GroupEditURLProtocol.bodies.withLock { $0 } == [
            .object(["name": .string("Trip"), "icon": .string("data:image/png;base64,AQID")]),
            .object(["name": .string(""), "icon": .null]),
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Context-Properties") == "eyJsb2NhdGlvbiI6Imdyb3VwIGRtIGNvbnRleHQgbWVudSJ9"
        })
        await provider.disconnect()
    }

    @Test func `edit group failures stay in the dialog without retrying or stopping the session`() async throws {
        let provider = await makeProvider()
        await #expect(throws: ProfileValidationError.self) {
            _ = try await provider.editGroupDirectMessage(groupID, changes: .init(name: .set("invalid")))
        }
        await #expect(throws: ChatProviderError.self) {
            _ = try await provider.editGroupDirectMessage(groupID, changes: .init(name: .set("forbidden")))
        }
        #expect(await !provider.requestSafetyCircuitIsOpen)
        #expect(GroupEditURLProtocol.requests.withLock { $0.count } == 2)
        #expect(await provider.privateChannel(id: groupID)?.name == "Friend Group")
        await provider.disconnect()
    }

    @Test func `edit group response cannot replace a newer group update that restored the old value`() async throws {
        let credentials = NicknameInterleavingCredentials()
        let provider = await makeProvider(credentials: credentials)
        // Another session renames the group and back before this save's response.
        await credentials.interleave {
            for name in ["Elsewhere", "Friend Group"] {
                await provider.handleGatewayDispatch(name: "CHANNEL_UPDATE", body: .object([
                    "id": .string("401"), "type": .number(3), "name": .string(name),
                ]))
            }
        }
        let saved = try await provider.editGroupDirectMessage(groupID, changes: .init(name: .set("Trip")))
        #expect(saved.name == "Trip")
        #expect(await provider.privateChannel(id: groupID)?.name == "Friend Group")
        #expect(GroupEditURLProtocol.requests.withLock { $0.count } == 1)
        await provider.disconnect()
    }

    @Test func `group updates clear an explicit null name or icon and keep absent fields`() async throws {
        let provider = await makeProvider()
        await provider.handleGatewayDispatch(name: "CHANNEL_UPDATE", body: .object([
            "id": .string("401"), "type": .number(3), "icon": .string("abc"),
        ]))
        #expect(await provider.privateChannel(id: groupID)?.name == "Friend Group")
        #expect(await provider.privateChannel(id: groupID)?.iconURL != nil)
        await provider.handleGatewayDispatch(name: "CHANNEL_UPDATE", body: .object([
            "id": .string("401"), "type": .number(3), "name": .null, "icon": .null,
        ]))
        let group = await provider.privateChannel(id: groupID)
        #expect(group?.name == "Friend, Other")
        #expect(group?.iconURL == nil)
        #expect(GroupEditURLProtocol.requests.withLock { $0.isEmpty })
        await provider.disconnect()
    }

    @Test func `leave group sends one delete with the silent flag and removes the group once`() async throws {
        let provider = await makeProvider()
        let events = await provider.eventStream()
        try await provider.leaveGroupDirectMessage(groupID, silently: true)
        #expect(await provider.privateChannel(id: groupID) == nil)
        // Discord's CHANNEL_DELETE for the leave finds nothing left to remove.
        await provider.handleGatewayDispatch(name: "CHANNEL_DELETE", body: .object([
            "id": .string("401"), "type": .number(3),
        ]))
        await provider.continuation?.finish()
        var privateLists: [[ChannelID]] = []
        for await event in events {
            if case let .channelsChanged(guildID, channels) = event, guildID == nil { privateLists.append(channels.map(\.id)) }
        }
        #expect(privateLists == [[ChannelID(rawValue: 402)]])
        let requests = GroupEditURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "DELETE")
        #expect(requests.first?.url?.absoluteString == "https://discord.com/api/v9/channels/401?silent=true")
        #expect(requests.first?.httpBody == nil && requests.first?.httpBodyStream == nil)
        await provider.disconnect()
    }

    @Test func `a rejected leave keeps the group without retrying or stopping the session`() async throws {
        let provider = await makeProvider()
        GroupEditURLProtocol.leaveStatus.withLock { $0 = 403 }
        await #expect(throws: ChatProviderError.self) {
            try await provider.leaveGroupDirectMessage(groupID, silently: false)
        }
        // A 1:1 DM is never left through this route.
        await #expect(throws: ChatProviderError.self) {
            try await provider.leaveGroupDirectMessage(ChannelID(rawValue: 402), silently: false)
        }
        #expect(await !provider.requestSafetyCircuitIsOpen)
        #expect(await provider.privateChannel(id: groupID)?.name == "Friend Group")
        let requests = GroupEditURLProtocol.requests.withLock { $0 }
        #expect(requests.map { $0.url?.absoluteString } == ["https://discord.com/api/v9/channels/401?silent=false"])
        await provider.disconnect()
    }

    @Test func `leave response cannot remove a group Discord re-added meanwhile`() async throws {
        let credentials = NicknameInterleavingCredentials()
        let provider = await makeProvider(credentials: credentials)
        // The leave lands and a member re-adds this account before the response.
        await credentials.interleave {
            await provider.handleGatewayDispatch(name: "CHANNEL_DELETE", body: .object([
                "id": .string("401"), "type": .number(3),
            ]))
            await provider.handleGatewayDispatch(name: "CHANNEL_CREATE", body: .object([
                "id": .string("401"), "type": .number(3), "name": .string("Friend Group"),
                "recipients": .array([.object(["id": .string("2"), "username": .string("friend")])]),
            ]))
        }
        try await provider.leaveGroupDirectMessage(groupID, silently: false)
        #expect(await provider.privateChannel(id: groupID)?.name == "Friend Group")
        await provider.disconnect()
    }

    private func makeProvider(credentials: any CredentialStore = TestCredentialStore()) async -> DiscordRESTProvider {
        GroupEditURLProtocol.requests.withLock { $0.removeAll() }
        GroupEditURLProtocol.bodies.withLock { $0.removeAll() }
        GroupEditURLProtocol.leaveStatus.withLock { $0 = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupEditURLProtocol.self]
        let provider = DiscordRESTProvider(credentials: credentials,
                                           handle: CredentialHandle(accountID: "group-edit"),
                                           session: URLSession(configuration: configuration))
        await provider.seedGroup()
        return provider
    }
}

private extension DiscordRESTProvider {
    func seedGroup() {
        currentUser = User(id: .init(rawValue: 1), username: "fixture", displayName: "Fixture")
        let recipients = [
            User(id: .init(rawValue: 2), username: "friend", displayName: "Friend"),
            User(id: .init(rawValue: 3), username: "other", displayName: "Other"),
        ]
        cachedChannels[nil] = [
            Channel(id: .init(rawValue: 401), guildID: nil, name: "Friend Group", kind: .groupDirectMessage,
                    recipients: recipients),
            Channel(id: .init(rawValue: 402), guildID: nil, name: "Friend", kind: .directMessage,
                    recipients: [recipients[0]]),
        ]
    }
}

private final class GroupEditURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    static let bodies = Mutex<[JSONValue]>([])
    static let leaveStatus = Mutex(200)
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        if request.httpMethod == "DELETE" {
            let status = Self.leaveStatus.withLock { $0 }
            return respond(status: status, body: status == 200
                ? #"{"id":"401","type":3,"name":"Friend Group","owner_id":"2"}"#
                : #"{"code":50013,"message":"Missing Permissions"}"#)
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard case let .object(fields)? = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return respond(status: 500, body: "{}")
        }
        Self.bodies.withLock { $0.append(.object(fields)) }
        switch fields["name"] {
        case .string("invalid"):
            return respond(status: 400, body: #"{"code":50035,"errors":{"name":{"_errors":[{"code":"BASE_TYPE_BAD_LENGTH","message":"Must be between 1 and 100 in length."}]}}}"#)
        case .string("forbidden"):
            return respond(status: 403, body: #"{"code":50013,"message":"Missing Permissions"}"#)
        default: break
        }
        let recipients: JSONValue = .array([
            .object(["id": .string("2"), "username": .string("friend"), "global_name": .string("Friend")]),
            .object(["id": .string("3"), "username": .string("other"), "global_name": .string("Other")]),
        ])
        let icon: JSONValue = if case .string = fields["icon"] { .string("hash") } else { .null }
        // Discord stores a cleared name as null.
        let name: JSONValue = fields["name"] == .string("") ? .null : fields["name"] ?? .null
        let response = JSONValue.object([
            "id": .string("401"), "type": .number(3), "name": name,
            "icon": icon, "owner_id": .string("1"), "recipients": recipients,
        ])
        respond(status: 200, body: (try? JSONEncoder().encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    private func respond(status: Int, body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
