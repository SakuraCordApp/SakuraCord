@testable import DiscordProtocol
import Foundation
import SakuraCordModels
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

@Suite(.serialized)
struct ProviderRequestContractTests {
    @Test func `application command indexes cache and each interaction uses one exact post`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("command-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "guilds": .array([])
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket)
        )
        let events = await provider.eventStream()

        _ = try await provider.bootstrap()
        #expect(await eventually { await socket.sentCount == 1 })
        let target = ApplicationCommandIndexTarget.guild(GuildID(rawValue: 100))
        let first = try await provider.applicationCommandCatalog(for: target)
        let second = try await provider.applicationCommandCatalog(for: target)
        let userCatalog = try await provider.applicationCommandCatalog(for: .user)
        let channelTarget = ApplicationCommandIndexTarget.channel(ChannelID(rawValue: 200))
        _ = try await provider.applicationCommandCatalog(for: channelTarget)
        #expect(first == second)
        #expect(RateLimitURLProtocol.guildCommandIndexRequests == 1)
        #expect(RateLimitURLProtocol.userCommandIndexRequests == 1)
        #expect(RateLimitURLProtocol.channelCommandIndexRequests == 1)

        let versionInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["guild_id": .string("100"), "version": .string("904")]),
            sequence: 2,
            eventName: "GUILD_APPLICATION_COMMAND_INDEX_UPDATE"
        ))
        #expect(await versionInvalidation.value == target)
        _ = try await provider.applicationCommandCatalog(for: target)
        #expect(RateLimitURLProtocol.guildCommandIndexRequests == 2)

        let userInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["application_id": .string("900")]),
            sequence: 3,
            eventName: "USER_APPLICATION_UPDATE"
        ))
        #expect(await userInvalidation.value == .user)
        _ = try await provider.applicationCommandCatalog(for: .user)
        #expect(RateLimitURLProtocol.userCommandIndexRequests == 2)

        let guildInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["id": .string("100"), "unavailable": .bool(true)]),
            sequence: 4,
            eventName: "GUILD_DELETE"
        ))
        #expect(await guildInvalidation.value == target)
        _ = try await provider.applicationCommandCatalog(for: target)
        #expect(RateLimitURLProtocol.guildCommandIndexRequests == 3)

        let channelInvalidation = Task { () -> ApplicationCommandIndexTarget? in
            for await event in events {
                if case let .applicationCommandIndexInvalidated(target) = event {
                    return target
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object(["id": .string("200"), "guild_id": .string("100")]),
            sequence: 5,
            eventName: "CHANNEL_DELETE"
        ))
        #expect(await channelInvalidation.value == channelTarget)
        _ = try await provider.applicationCommandCatalog(for: channelTarget)
        #expect(RateLimitURLProtocol.channelCommandIndexRequests == 2)

        let command = try #require(first.commands.first)
        let option = try #require(command.options.first)
        let invocation = ApplicationCommandInvocation(
            command: command,
            channelID: ChannelID(rawValue: 200),
            guildID: GuildID(rawValue: 100),
            values: [
                .init(
                    optionID: option.id,
                    name: option.name,
                    type: option.type,
                    argument: .string("sakura")
                )
            ],
            nonce: "command-nonce"
        )
        try await provider.executeApplicationCommand(invocation) { _ in }
        #expect(RateLimitURLProtocol.interactionRequestCount == 1)
        let execution = try #require(RateLimitURLProtocol.interactionBodies.first)
        #expect((execution["type"] as? NSNumber)?.intValue == 2)
        #expect(execution["application_id"] as? String == "900")
        #expect(execution["channel_id"] as? String == "200")
        #expect(execution["guild_id"] as? String == "100")
        #expect(execution["session_id"] as? String == "command-session")
        #expect(execution["nonce"] as? String == "command-nonce")
        #expect(execution["analytics_location"] as? String == "slash_ui")
        let executionData = try #require(execution["data"] as? [String: Any])
        #expect(executionData["id"] as? String == "901")
        #expect(executionData["version"] as? String == "902")
        #expect(executionData["guild_id"] as? String == "100")

        let globalCommand = try #require(userCatalog.commands.first)
        let globalOption = try #require(globalCommand.options.first)
        let globalInvocation = ApplicationCommandInvocation(
            command: globalCommand,
            channelID: ChannelID(rawValue: 200),
            guildID: GuildID(rawValue: 100),
            values: [
                .init(
                    optionID: globalOption.id,
                    name: globalOption.name,
                    type: globalOption.type,
                    argument: .string("sakura")
                )
            ],
            nonce: "global-command-nonce"
        )
        try await provider.executeApplicationCommand(globalInvocation) { _ in }
        #expect(RateLimitURLProtocol.interactionRequestCount == 2)
        let globalExecution = try #require(RateLimitURLProtocol.interactionBodies.last)
        #expect(globalExecution["guild_id"] as? String == "100")
        let globalExecutionData = try #require(globalExecution["data"] as? [String: Any])
        #expect(globalExecutionData["guild_id"] == nil)

        try await provider.requestApplicationCommandAutocomplete(
            ApplicationCommandAutocompleteRequest(
                invocation: invocation,
                focusedOptionID: option.id,
                query: "sa",
                nonce: "autocomplete-nonce"
            )
        )
        #expect(RateLimitURLProtocol.interactionRequestCount == 3)
        let autocomplete = try #require(RateLimitURLProtocol.interactionBodies.last)
        #expect((autocomplete["type"] as? NSNumber)?.intValue == 4)
        #expect(autocomplete["nonce"] as? String == "autocomplete-nonce")
        #expect(autocomplete["analytics_location"] == nil)

        let modalTask = Task { () -> InteractionModal? in
            for await event in events {
                if case let .interaction(.presentModal(nonce, modal)) = event,
                   nonce == "command-nonce"
                {
                    return modal
                }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "nonce": .string("command-nonce"),
                "application_id": .string("900"),
                "channel_id": .string("200"),
                "guild_id": .string("100"),
                "custom_id": .string("feedback"),
                "title": .string("Feedback"),
                "components": .array([
                    .object([
                        "type": .number(18), "id": .number(1),
                        "label": .string("Comment"),
                        "component": .object([
                            "type": .number(4), "id": .number(2),
                            "custom_id": .string("comment"), "style": .number(2),
                            "required": .bool(true), "min_length": .number(3)
                        ])
                    ]),
                    .object([
                        "type": .number(18), "id": .number(3),
                        "label": .string("Follow up"),
                        "component": .object([
                            "type": .number(23), "id": .number(4),
                            "custom_id": .string("follow-up"), "default": .bool(false)
                        ])
                    ])
                ])
            ]),
            sequence: 6,
            eventName: "INTERACTION_MODAL_CREATE"
        ))
        let modal = try #require(await modalTask.value)
        #expect(modal.customID == "feedback")
        #expect(modal.controls.count == 2)
        try await provider.submitModal(
            ModalSubmission(
                customID: modal.customID,
                values: ["comment": ["Looks good"], "follow-up": ["true"]]
            ),
            nonce: "command-nonce"
        )
        #expect(RateLimitURLProtocol.interactionRequestCount == 4)
        let modalBody = try #require(RateLimitURLProtocol.interactionBodies.last)
        #expect((modalBody["type"] as? NSNumber)?.intValue == 5)
        let modalData = try #require(modalBody["data"] as? [String: Any])
        #expect(modalData["custom_id"] as? String == "feedback")
        let modalComponents = try #require(modalData["components"] as? [[String: Any]])
        #expect((modalComponents[0]["type"] as? NSNumber)?.intValue == 18)
        let textInput = try #require(modalComponents[0]["component"] as? [String: Any])
        #expect(textInput["value"] as? String == "Looks good")
        let checkbox = try #require(modalComponents[1]["component"] as? [String: Any])
        #expect(checkbox["value"] as? Bool == true)
        await provider.disconnect()
    }

    @Test func `bootstrap retries 429 and does not burst guild channel requests`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let credentials = TestCredentialStore()
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("request-contract-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "guilds": .array([])
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: credentials,
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket)
        )
        let events = await provider.eventStream()
        let connected = Task { () -> Bool in
            for await event in events {
                if case .connectionChanged(.ready) = event { return true }
            }
            return false
        }

        let snapshot = try await provider.bootstrap()
        #expect(await connected.value)
        #expect(snapshot.currentUser.id == UserID(rawValue: 1))
        #expect(snapshot.guilds.count == 1)
        #expect(snapshot.channels.isEmpty)
        #expect(snapshot.guildRailItems == [.guild(GuildID(rawValue: 100))])
        #expect(snapshot.guilds.first?.isOwnedByCurrentUser == false)
        #expect(snapshot.guilds.first?.currentUserPermissions == 1024)
        #expect(RateLimitURLProtocol.guildListAttempts == 2)
        #expect(RateLimitURLProtocol.guildChannelRequests == 0)
        #expect(RateLimitURLProtocol.settingsRequestCount == 0)
        #expect(RateLimitURLProtocol.settingsMethod == nil)

        let channels = try await provider.channels(in: GuildID(rawValue: 100))
        #expect(channels.first?.name == "general")
        #expect(channels.first?.category == "CHAT")
        #expect(channels.first?.permissionOverwrites?.isEmpty == true)
        #expect(RateLimitURLProtocol.guildChannelRequests == 1)

        let roles = try await provider.roles(in: GuildID(rawValue: 100))
        #expect(roles.first { $0.id == RoleID(rawValue: 100) }?.permissions == 1024)

        let memberSearch = Task {
            try await provider.searchMembers(
                in: GuildID(rawValue: 100), query: "maya", limit: 25
            )
        }
        #expect(await eventually { await socket.sentCount >= 2 })
        let gatewayData = try #require(await socket.sentPayloads.last)
        let gatewayPayload = try #require(
            JSONSerialization.jsonObject(with: gatewayData) as? [String: Any]
        )
        #expect((gatewayPayload["op"] as? NSNumber)?.intValue == 8)
        let searchData = try #require(gatewayPayload["d"] as? [String: Any])
        #expect(searchData["guild_id"] as? String == "100")
        #expect(searchData["query"] as? String == "maya")
        #expect((searchData["limit"] as? NSNumber)?.intValue == 20)
        #expect(searchData["presences"] as? Bool == true)
        #expect(Set(searchData.keys) == ["guild_id", "query", "limit", "presences"])
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "members": .array([
                    .object([
                        "user": .object([
                            "id": .string("2"),
                            "username": .string("maya"),
                            "global_name": .string("Maya"),
                            "avatar": .null
                        ]),
                        "nick": .string("Maya"),
                        "roles": .array([.string("101")])
                    ]),
                    .object([
                        "user": .object([
                            "id": .string("3"),
                            "username": .string("mayabot"),
                            "global_name": .string("Maya Bot"),
                            "avatar": .null
                        ]),
                        "nick": .string("Maya Bot"),
                        "roles": .array([.string("101")])
                    ])
                ]),
                "chunk_index": .number(0),
                "chunk_count": .number(1)
            ]),
            sequence: 2,
            eventName: "GUILD_MEMBERS_CHUNK"
        ))
        let memberMatches = try await memberSearch.value
        #expect(memberMatches.map(\.user.displayName) == ["Maya", "Maya Bot"])
        #expect(RateLimitURLProtocol.memberSearchRequestCount == 0)

        try await provider.sendTyping(in: ChannelID(rawValue: 200))
        #expect(RateLimitURLProtocol.typingRequestCount == 1)
        #expect(RateLimitURLProtocol.typingMethod == "POST")
        #expect(RateLimitURLProtocol.typingHadBody == false)
        #expect(RateLimitURLProtocol.typingSuperProperties != nil)

        let draft = SendMessageDraft(channelID: ChannelID(rawValue: 200), content: "hello")
        let sent = try await provider.send(draft)
        #expect(sent.content == "hello")
        #expect(draft.nonce.count <= 25)
        #expect(RateLimitURLProtocol.sentNonce == draft.nonce)
        #expect(RateLimitURLProtocol.sentEnforceNonce)
        #expect(RateLimitURLProtocol.sentNetworkType == "unknown")
        #expect(RateLimitURLProtocol.messageContextProperties == DiscordClientMetadata.messageContextHeader)
        let encodedProperties = try #require(RateLimitURLProtocol.messageSuperProperties)
        let propertiesData = try #require(Data(base64Encoded: encodedProperties))
        let properties = try #require(JSONSerialization.jsonObject(with: propertiesData) as? [String: Any])
        #expect(properties["browser"] as? String == "Discord Client")
        #expect(properties["browser_user_agent"] as? String == RateLimitURLProtocol.messageUserAgent)
        #expect((properties["client_build_number"] as? NSNumber)?.intValue == DiscordProductionBaseline.july2026.webBuildNumber)

        let mentionDraft = SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "hello <@2>",
            nonce: "mention-contract-nonce"
        )
        let requestsBeforeMentionSend = RateLimitURLProtocol.messageRequestCount
        _ = try await provider.send(mentionDraft)
        #expect(RateLimitURLProtocol.messageRequestCount == requestsBeforeMentionSend + 1)
        #expect(RateLimitURLProtocol.messageMethod == "POST")
        #expect(RateLimitURLProtocol.messagePath == "/api/v9/channels/200/messages")
        let mentionBody = try #require(RateLimitURLProtocol.sentMessageBody)
        #expect(Set(mentionBody.keys) == [
            "content", "nonce", "enforce_nonce", "tts", "flags", "mobile_network_type",
        ])
        #expect(mentionBody["content"] as? String == "hello <@2>")
        #expect(mentionBody["nonce"] as? String == mentionDraft.nonce)
        #expect(mentionBody["enforce_nonce"] as? Bool == true)
        #expect(mentionBody["tts"] as? Bool == false)
        #expect((mentionBody["flags"] as? NSNumber)?.intValue == 0)
        #expect(mentionBody["mobile_network_type"] as? String == "unknown")
        #expect(mentionBody["allowed_mentions"] == nil)

        let reply = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "reply",
            replyTo: MessageID(rawValue: 299)
        ))
        #expect(reply.replyTo == MessageID(rawValue: 299))
        #expect(reply.replyPreview?.author.displayName == "Original Author")
        #expect(reply.replyPreview?.content == "original message")

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("sakuracord-upload-test.txt")
        try Data("attachment".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        _ = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "with file",
            attachmentURLs: [fileURL]
        ))
        #expect(RateLimitURLProtocol.uploadHadAuthorization == false)
        #expect(RateLimitURLProtocol.sentUploadedFilename == "discord-upload-token")
        #expect(await credentials.credentialReadCount == 1)
        await provider.disconnect()
    }

    @Test func `restriction response stops every following authenticated request`() async throws {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.restrictMessageSend = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = RestrictionGatewaySocket()
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: RestrictionGatewayTransport(socket: socket)
        )

        _ = try await provider.bootstrap()
        #expect(await eventually { await socket.receiveStarted })
        _ = try await provider.channels(in: GuildID(rawValue: 100))
        await #expect(throws: ChatProviderError.self) {
            try await provider.send(SendMessageDraft(channelID: ChannelID(rawValue: 200), content: "hello"))
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.sendTyping(in: ChannelID(rawValue: 200))
        }
        #expect(RateLimitURLProtocol.messageRequestCount == 1)
        #expect(RateLimitURLProtocol.typingRequestCount == 0)
        #expect(await socket.closeCodes == [1000])
    }

    @Test func `unavailable gateway mention search does not stop message sending`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = RestrictionGatewaySocket()
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: RestrictionGatewayTransport(socket: socket)
        )

        _ = try await provider.bootstrap()
        #expect(await eventually { await socket.receiveStarted })
        await #expect(throws: ChatProviderError.self) {
            try await provider.searchMembers(in: GuildID(rawValue: 100), query: "maya", limit: 25)
        }

        let message = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "hello <@2>",
            nonce: "permission-scope-nonce"
        ))
        #expect(message.content == "hello <@2>")
        #expect(RateLimitURLProtocol.memberSearchRequestCount == 0)
        #expect(RateLimitURLProtocol.messageRequestCount == 1)
        #expect(await socket.closeCodes.isEmpty)
    }
}

private actor TestCredentialStore: CredentialStore {
    private(set) var credentialReadCount = 0

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        credentialReadCount += 1
        return Data("test-session-credential-value".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] {
        [CredentialHandle(accountID: "1")]
    }
}

private struct UnavailableGatewayTransport: GatewayTransport {
    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        throw URLError(.notConnectedToInternet)
    }
}

private struct ReadyGatewayTransport: GatewayTransport {
    let socket: ReadyGatewaySocket

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        socket
    }
}

private enum ReadyGatewayError: Error { case closed }

private actor ReadyGatewaySocket: GatewaySocket {
    private var queued: [GatewaySocketMessage] = []
    private var receiver: CheckedContinuation<GatewaySocketMessage, any Error>?
    private(set) var sentCount = 0
    private(set) var sentPayloads: [Data] = []

    func receive() async throws -> GatewaySocketMessage {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func send(_ data: Data) async throws {
        sentCount += 1
        sentPayloads.append(data)
    }

    func close(code: Int) async {
        receiver?.resume(throwing: ReadyGatewayError.closed)
        receiver = nil
    }

    func closeCode() async -> Int? { nil }

    func push(_ message: GatewaySocketMessage) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: message)
        } else {
            queued.append(message)
        }
    }
}

private func gatewayMessage(
    op: Int,
    data: JSONValue?,
    sequence: Int? = nil,
    eventName: String? = nil
) -> GatewaySocketMessage {
    let envelope = GatewayEnvelope(
        op: op, data: data, sequence: sequence, eventName: eventName
    )
    return .text(String(decoding: try! JSONGatewayCodec().encode(envelope), as: UTF8.self))
}

private enum RestrictionGatewayError: Error { case closed }

private struct RestrictionGatewayTransport: GatewayTransport {
    let socket: RestrictionGatewaySocket

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        socket
    }
}

private actor RestrictionGatewaySocket: GatewaySocket {
    private var receiver: CheckedContinuation<GatewaySocketMessage, any Error>?
    private(set) var receiveStarted = false
    private(set) var closeCodes: [Int] = []

    func receive() async throws -> GatewaySocketMessage {
        receiveStarted = true
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func send(_ data: Data) async throws {}

    func close(code: Int) async {
        closeCodes.append(code)
        receiver?.resume(throwing: RestrictionGatewayError.closed)
        receiver = nil
    }

    func closeCode() async -> Int? {
        nil
    }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0 ..< 500 {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private final class RateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var guildListAttempts = 0
    nonisolated(unsafe) static var guildChannelRequests = 0
    nonisolated(unsafe) static var sentNonce: String?
    nonisolated(unsafe) static var sentEnforceNonce = false
    nonisolated(unsafe) static var sentNetworkType: String?
    nonisolated(unsafe) static var uploadHadAuthorization = false
    nonisolated(unsafe) static var sentUploadedFilename: String?
    nonisolated(unsafe) static var typingRequestCount = 0
    nonisolated(unsafe) static var typingMethod: String?
    nonisolated(unsafe) static var typingHadBody = false
    nonisolated(unsafe) static var typingSuperProperties: String?
    nonisolated(unsafe) static var messageRequestCount = 0
    nonisolated(unsafe) static var messageMethod: String?
    nonisolated(unsafe) static var messagePath: String?
    nonisolated(unsafe) static var sentMessageBody: [String: Any]?
    nonisolated(unsafe) static var messageContextProperties: String?
    nonisolated(unsafe) static var messageSuperProperties: String?
    nonisolated(unsafe) static var messageUserAgent: String?
    nonisolated(unsafe) static var restrictMessageSend = false
    nonisolated(unsafe) static var forbidMemberSearch = false
    nonisolated(unsafe) static var unauthorizeMemberSearch = false
    nonisolated(unsafe) static var settingsRequestCount = 0
    nonisolated(unsafe) static var settingsMethod: String?
    nonisolated(unsafe) static var guildCommandIndexRequests = 0
    nonisolated(unsafe) static var channelCommandIndexRequests = 0
    nonisolated(unsafe) static var userCommandIndexRequests = 0
    nonisolated(unsafe) static var memberSearchQuery: String?
    nonisolated(unsafe) static var memberSearchLimit: String?
    nonisolated(unsafe) static var memberSearchRequestCount = 0
    nonisolated(unsafe) static var interactionRequestCount = 0
    nonisolated(unsafe) static var interactionBodies: [[String: Any]] = []

    static func reset() {
        guildListAttempts = 0
        guildChannelRequests = 0
        sentNonce = nil
        sentEnforceNonce = false
        sentNetworkType = nil
        uploadHadAuthorization = false
        sentUploadedFilename = nil
        typingRequestCount = 0
        typingMethod = nil
        typingHadBody = false
        typingSuperProperties = nil
        messageRequestCount = 0
        messageMethod = nil
        messagePath = nil
        sentMessageBody = nil
        messageContextProperties = nil
        messageSuperProperties = nil
        messageUserAgent = nil
        restrictMessageSend = false
        forbidMemberSearch = false
        unauthorizeMemberSearch = false
        settingsRequestCount = 0
        settingsMethod = nil
        guildCommandIndexRequests = 0
        channelCommandIndexRequests = 0
        userCommandIndexRequests = 0
        interactionRequestCount = 0
        interactionBodies = []
        memberSearchQuery = nil
        memberSearchLimit = nil
        memberSearchRequestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let status: Int
        let json: String
        switch path {
        case "/api/v9/users/@me":
            status = 200
            json = #"{"id":"1","username":"tester","global_name":"Tester","avatar":null}"#
        case "/api/v9/users/@me/guilds":
            Self.guildListAttempts += 1
            if Self.guildListAttempts == 1 {
                status = 429
                json = #"{"retry_after":0.01,"global":false}"#
            } else {
                status = 200
                json = #"[{"id":"100","name":"Guild","icon":null,"owner":false,"permissions":"1024"}]"#
            }
        case "/api/v9/users/@me/channels":
            status = 200
            json = "[]"
        case "/api/v9/users/@me/settings-proto/1":
            Self.settingsRequestCount += 1
            Self.settingsMethod = request.httpMethod
            status = 200
            json = #"{"settings":"\#(Self.guildFolderSettingsProto().base64EncodedString())"}"#
        case "/api/v9/guilds/100/channels":
            Self.guildChannelRequests += 1
            status = 200
            json = #"[{"id":"199","guild_id":"100","name":"CHAT","type":4,"position":1,"permission_overwrites":[]},{"id":"200","guild_id":"100","name":"general","topic":null,"type":0,"parent_id":"199","position":2,"permission_overwrites":[]}]"#
        case "/api/v9/guilds/100/roles":
            status = 200
            json = #"[{"id":"100","name":"@everyone","position":0,"hoist":false,"color":0,"permissions":"1024"},{"id":"101","name":"Design","position":2,"hoist":true,"color":5793266,"permissions":"0"}]"#
        case "/api/v9/guilds/100/members/search":
            Self.memberSearchRequestCount += 1
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            Self.memberSearchQuery = items?.first(where: { $0.name == "query" })?.value
            Self.memberSearchLimit = items?.first(where: { $0.name == "limit" })?.value
            if Self.unauthorizeMemberSearch {
                status = 401
                json = #"{"code":40001,"message":"Unauthorized"}"#
            } else if Self.forbidMemberSearch {
                status = 403
                json = #"{"code":50001,"message":"Missing Access"}"#
            } else {
                status = 200
                json = #"[{"member":{"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"nick":"Maya","roles":["101"]}}]"#
            }
        case "/api/v9/guilds/100/application-command-index":
            Self.guildCommandIndexRequests += 1
            status = 200
            json = Self.commandIndexJSON(guildID: "100")
        case "/api/v9/channels/200/application-command-index":
            Self.channelCommandIndexRequests += 1
            status = 200
            json = Self.commandIndexJSON(guildID: nil)
        case "/api/v9/users/@me/application-command-index":
            Self.userCommandIndexRequests += 1
            status = 200
            json = Self.commandIndexJSON(guildID: nil)
        case "/api/v9/interactions":
            Self.interactionRequestCount += 1
            if let body = Self.requestBody(request),
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                Self.interactionBodies.append(object)
            }
            status = 204
            json = ""
        case "/api/v9/channels/200/attachments":
            status = 200
            json = #"{"attachments":[{"id":0,"upload_url":"https://upload.example/test","upload_filename":"discord-upload-token"}]}"#
        case "/api/v9/channels/200/typing":
            Self.typingRequestCount += 1
            Self.typingMethod = request.httpMethod
            Self.typingHadBody = Self.requestBody(request)?.isEmpty == false
            Self.typingSuperProperties = request.value(forHTTPHeaderField: "X-Super-Properties")
            status = 204
            json = ""
        case "/test":
            Self.uploadHadAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
            status = 200
            json = "{}"
        case "/api/v9/channels/200/messages":
            Self.messageRequestCount += 1
            Self.messageMethod = request.httpMethod
            Self.messagePath = path
            Self.messageContextProperties = request.value(forHTTPHeaderField: "X-Context-Properties")
            Self.messageSuperProperties = request.value(forHTTPHeaderField: "X-Super-Properties")
            Self.messageUserAgent = request.value(forHTTPHeaderField: "User-Agent")
            let body = Self.requestBody(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Self.sentMessageBody = body
            Self.sentNonce = body?["nonce"] as? String
            Self.sentEnforceNonce = body?["enforce_nonce"] as? Bool == true
            Self.sentNetworkType = body?["mobile_network_type"] as? String
            Self.sentUploadedFilename = ((body?["attachments"] as? [[String: Any]])?.first)?["uploaded_filename"] as? String
            if Self.restrictMessageSend {
                status = 400
                json = #"{"code":40004,"message":"Send messages has been temporarily disabled."}"#
            } else if (body?["message_reference"] as? [String: Any])?["message_id"] != nil {
                status = 200
                json = #"{"id":"301","channel_id":"200","author":{"id":"1","username":"tester","global_name":"Tester","avatar":null},"content":"reply","timestamp":"2026-07-11T20:01:00.000Z","edited_timestamp":null,"message_reference":{"message_id":"299"},"referenced_message":{"id":"299","author":{"id":"2","username":"original","global_name":"Original Author","avatar":null},"content":"original message"},"attachments":[],"reactions":[]}"#
            } else {
                status = 200
                let content = (body?["content"] as? String) ?? ""
                let encodedContent = String(data: try! JSONSerialization.data(
                    withJSONObject: content,
                    options: [.fragmentsAllowed]
                ), encoding: .utf8)!
                json = #"{"id":"300","channel_id":"200","author":{"id":"1","username":"tester","global_name":"Tester","avatar":null},"content":\#(encodedContent),"timestamp":"2026-07-11T20:00:00.000Z","edited_timestamp":null,"attachments":[],"reactions":[]}"#
            }
        default:
            status = 404
            json = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func guildFolderSettingsProto() -> Data {
        func field(_ number: Int, payload: [UInt8]) -> [UInt8] {
            encodeProtoVarint(UInt64(number << 3 | 2)) + encodeProtoVarint(UInt64(payload.count)) + payload
        }
        let fixedGuildID = (0 ..< 8).map {
            UInt8(truncatingIfNeeded: UInt64(100) >> UInt64($0 * 8))
        }
        let guildIDs = field(1, payload: fixedGuildID)
        let folderID = field(2, payload: encodeProtoVarint(1 << 3) + encodeProtoVarint(42))
        let name = field(3, payload: field(1, payload: Array("Work".utf8)))
        let color = field(4, payload: encodeProtoVarint(1 << 3) + encodeProtoVarint(0x58_65_F2))
        return Data(field(14, payload: field(1, payload: guildIDs + folderID + name + color)))
    }

    private static func commandIndexJSON(guildID: String?) -> String {
        let guild = guildID.map { ",\"guild_id\":\"\($0)\"" } ?? ""
        return "{\"version\":\"903\",\"applications\":[{\"id\":\"900\",\"name\":\"Utility\"}],\"application_commands\":[{\"id\":\"901\",\"application_id\":\"900\"\(guild),\"version\":\"902\",\"type\":1,\"name\":\"search\",\"description\":\"Search\",\"contexts\":[0,1,2],\"options\":[{\"type\":3,\"name\":\"query\",\"description\":\"Query\",\"required\":true,\"autocomplete\":true}]}]}"
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }
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
