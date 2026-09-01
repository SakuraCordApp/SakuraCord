@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

// Rate-limit coverage is kept in one sequential suite because the tests share
// deterministic URL-protocol and virtual-clock fixtures.
// swiftlint:disable file_length

@Suite(.serialized)
struct ProviderRequestContractTests {
    @Test func `REST scheduling learns server buckets without a global cadence`() async throws {
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "rate-limit-scheduler"),
            session: URLSession(configuration: .ephemeral),
            installationID: "server-issued-installation"
        )
        let route = DiscordRESTProvider.rateLimitRouteKey(
            method: "GET",
            path: "/channels/123456789012345200/messages"
        )
        #expect(route == "GET /channels/{id}/messages")
        #expect(
            DiscordRESTProvider.rateLimitMajorParameter(
                path: "/channels/200/messages"
            ) == "channels:200"
        )
        let firstMajorParameter = "channels:123456789012345200"
        let secondMajorParameter = "channels:123456789012345201"
        let firstChannelKey = "\(route) [\(firstMajorParameter)]"
        let secondChannelKey = "\(route) [\(secondMajorParameter)]"
        let response = try #require(HTTPURLResponse(
            url: URL(
                string: "https://discord.com/api/v9/channels/123456789012345200/messages"
            )!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "X-RateLimit-Bucket": "message-history",
                "X-RateLimit-Limit": "1",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset-After": "0.08",
            ]
        ))
        await provider.recordRateLimitState(
            response: response,
            routeKey: firstChannelKey,
            majorParameter: firstMajorParameter
        )

        let independentElapsed = try await ContinuousClock().measure {
            try await provider.reserveRateLimitSlot(
                routeKey: secondChannelKey
            )
        }
        #expect(independentElapsed < .milliseconds(30))

        let exhaustedElapsed = try await ContinuousClock().measure {
            try await provider.reserveRateLimitSlot(
                routeKey: firstChannelKey
            )
        }
        #expect(exhaustedElapsed >= .milliseconds(40))
        #expect(exhaustedElapsed < .seconds(1))
    }

    @Test func `concurrent first requests serialize only until their route learns a bucket`() async throws {
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "rate-limit-discovery"),
            session: URLSession(configuration: .ephemeral),
            installationID: "server-issued-installation"
        )
        let routeKey = "GET /channels/{id}/messages [channels:200]"
        let first = try await provider.reserveRateLimitSlot(routeKey: routeKey)
        #expect(first.discoveryToken != nil)

        let second = Task {
            try await provider.reserveRateLimitSlot(routeKey: routeKey)
        }
        #expect(await eventually {
            await provider.rateLimitDiscoveryWaiterCountForTesting(
                routeKey: routeKey
            ) == 1
        })

        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://discord.com/api/v9/channels/200/messages")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "X-RateLimit-Bucket": "message-history",
                "X-RateLimit-Limit": "2",
                "X-RateLimit-Remaining": "1",
                "X-RateLimit-Reset-After": "1",
            ]
        ))
        await provider.recordRateLimitState(
            response: response,
            routeKey: routeKey,
            majorParameter: "channels:200"
        )
        await provider.finishRateLimitReservation(first)

        let secondReservation = try await second.value
        #expect(secondReservation.discoveryToken == nil)
        await provider.finishRateLimitReservation(secondReservation)

        let unbucketedRouteKey = "GET /users/@me/settings-proto/1 [none]"
        let unbucketedDiscovery = try await provider.reserveRateLimitSlot(
            routeKey: unbucketedRouteKey
        )
        #expect(unbucketedDiscovery.discoveryToken != nil)
        let unbucketedResponse = try #require(HTTPURLResponse(
            url: URL(string: "https://discord.com/api/v9/users/@me/settings-proto/1")!,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ))
        await provider.recordRateLimitState(
            response: unbucketedResponse,
            routeKey: unbucketedRouteKey,
            majorParameter: "none"
        )
        await provider.finishRateLimitReservation(unbucketedDiscovery)

        let laterUnbucketedRequest = try await provider.reserveRateLimitSlot(
            routeKey: unbucketedRouteKey
        )
        #expect(laterUnbucketedRequest.discoveryToken == nil)

        let cancellationRouteKey = "GET /guilds/{id}/channels [guilds:300]"
        let cancellationDiscovery = try await provider.reserveRateLimitSlot(
            routeKey: cancellationRouteKey
        )
        let cancelledWaiter = Task {
            try await provider.reserveRateLimitSlot(
                routeKey: cancellationRouteKey
            )
        }
        #expect(await eventually {
            await provider.rateLimitDiscoveryWaiterCountForTesting(
                routeKey: cancellationRouteKey
            ) == 1
        })
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        #expect(await provider.rateLimitDiscoveryWaiterCountForTesting(
            routeKey: cancellationRouteKey
        ) == 0)
        await provider.finishRateLimitReservation(cancellationDiscovery)
    }

    @Test func `message history encodes bounded around and after anchors`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            installationID: "server-issued-installation"
        )

        _ = try await provider.messages(
            in: ChannelID(rawValue: 200),
            anchoredAt: .around(MessageID(rawValue: 350)),
            limit: 50
        )
        _ = try await provider.messages(
            in: ChannelID(rawValue: 200),
            anchoredAt: .after(MessageID(rawValue: 350)),
            limit: 20
        )

        #expect(RateLimitURLProtocol.messageHistoryQueryItems == [
            ["around=350", "limit=50"],
            ["after=350", "limit=20"],
        ])
    }

    @Test func `history reports incomplete member hydration when Gateway lookup is unavailable`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            installationID: "server-issued-installation"
        )
        await provider.seedGuildChannelForTesting(Channel(
            id: ChannelID(rawValue: 200),
            guildID: GuildID(rawValue: 100),
            name: "general"
        ))

        let page = try await provider.messages(
            in: ChannelID(rawValue: 200),
            before: nil,
            limit: 10
        )

        #expect(page.resolvedMembers.isEmpty)
        #expect(!page.hasCompleteMemberResolution)
    }

    @Test func `desktop ready lifecycle matches official opcode ordering`() async throws {
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10,
            data: .object(["heartbeat_interval": .number(60_000)])
        ))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("desktop-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
            ]),
            sequence: 12,
            eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: .ephemeral),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            usesDesktopHeartbeat: true,
            installationID: "server-issued-installation"
        )

        try await provider.startGateway()
        #expect(await eventually { await socket.sentCount == 5 })
        #expect(await socket.sentOpcodes() == [2, 4, 3, 41, 40])
        await provider.disconnect()
    }

    @Test func `authentication preparation reads and caches the credential once`() async throws {
        let credentials = TestCredentialStore()
        let provider = DiscordRESTProvider(
            credentials: credentials,
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: .ephemeral),
            installationID: "server-issued-installation"
        )

        try await provider.prepareAuthentication()
        let authorization = try await provider.authorizationToken()

        #expect(authorization == "test-session-credential-value")
        #expect(await credentials.credentialReadCount == 1)
    }

    @Test func `stored desktop session repairs missing installation identity before Gateway`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = ReadyGatewaySocket()
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            usesDesktopHeartbeat: true,
            installationID: nil
        )

        try await provider.prepareAuthentication()
        try await provider.prepareAuthentication()

        #expect(RateLimitURLProtocol.totalRequestCount == 1)
        #expect(RateLimitURLProtocol.apexInstallationRequests == 1)
        #expect(RateLimitURLProtocol.apexInstallationQuery == ["surface": "2"])
        #expect(RateLimitURLProtocol.apexInstallationMethod == "GET")
        #expect(RateLimitURLProtocol.apexInstallationHost == "discordapp.com")
        #expect(RateLimitURLProtocol.apexInstallationReferer == "https://discordapp.com/app")
        #expect(RateLimitURLProtocol.apexInstallationAuthorization == nil)
        #expect(RateLimitURLProtocol.apexInstallationHeader == nil)
        #expect(RateLimitURLProtocol.apexInstallationFingerprint == nil)
        #expect(!RateLimitURLProtocol.apexInstallationHadBody)
        let encodedProperties = try #require(
            RateLimitURLProtocol.apexInstallationSuperProperties
        )
        let propertiesData = try #require(Data(base64Encoded: encodedProperties))
        let properties = try #require(
            JSONSerialization.jsonObject(with: propertiesData) as? [String: Any]
        )
        #expect(properties["client_heartbeat_session_id"] == nil)
        #expect(properties["client_app_state"] as? String == "focused")
        let resolvedMetadata = await provider.clientMetadata
        #expect(resolvedMetadata.installationID == "server-issued-installation")
        #expect(await socket.sentCount == 0)
    }

    @Test func `pending login fails closed when Ready omits user without REST identity lookup`() async throws {
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
                "session_id": .string("pending-login-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "guilds": .array([]),
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let pending = try PendingDiscordCredential(
            Data("pending-session-credential-value".utf8)
        )
        let provider = DiscordRESTProvider(
            pendingCredential: pending,
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket)
        )

        await #expect(throws: ChatProviderError.self) {
            try await provider.bootstrap()
        }

        #expect(RateLimitURLProtocol.currentUserRequests == 0)
        #expect(RateLimitURLProtocol.totalRequestCount == 0)
        await provider.disconnect()
        await pending.discard()
    }

    @Test func `concurrent sends with one nonce use one message mutation`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let draft = SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "one intentional send",
            nonce: "one-intentional-send"
        )

        async let first = provider.send(draft)
        async let second = provider.send(draft)
        let messages = try await (first, second)

        #expect(messages.0.id == messages.1.id)
        #expect(RateLimitURLProtocol.messageRequestCount == 1)
        #expect(RateLimitURLProtocol.sentNonce == draft.nonce)
        #expect(RateLimitURLProtocol.sentEnforceNonce)
    }

    @Test func `message send rejects more than ten attachments without a request`() async {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let attachments = (0 ... SendMessageDraft.maximumAttachmentCount).map {
            URL(fileURLWithPath: "/tmp/sakuracord-over-limit-\($0)")
        }

        await #expect(throws: ChatProviderError.self) {
            try await provider.send(
                SendMessageDraft(
                    channelID: ChannelID(rawValue: 200),
                    content: "",
                    attachmentURLs: attachments
                )
            )
        }
        #expect(RateLimitURLProtocol.messageRequestCount == 0)
    }

    @Test func `message send rejects an oversized base tier attachment before reservation`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sakuracord-provider-oversized-\(UUID().uuidString).bin"
        )
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(DiscordAttachmentUploadPolicy.baseLimit + 1))
        try handle.close()

        await #expect(throws: ChatProviderError.self) {
            try await provider.send(
                SendMessageDraft(
                    channelID: ChannelID(rawValue: 200),
                    content: "",
                    attachmentURLs: [file]
                )
            )
        }
        #expect(RateLimitURLProtocol.totalRequestCount == 0)
        #expect(RateLimitURLProtocol.messageRequestCount == 0)
    }

    @Test func `acknowledgement uses exact route token body response and one mutation attempt`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: ReadyGatewaySocket())
        )

        let response = try await provider.acknowledge(
            channelID: ChannelID(rawValue: 200),
            messageID: MessageID(rawValue: 333),
            token: nil
        )
        #expect(RateLimitURLProtocol.ackRequestCount == 1)
        #expect(RateLimitURLProtocol.ackMethod == "POST")
        #expect(RateLimitURLProtocol.ackPath == "/api/v9/channels/200/messages/333/ack")
        #expect(RateLimitURLProtocol.ackBody?["token"] is NSNull)
        #expect(RateLimitURLProtocol.ackBody?.count == 1)
        #expect(response.token == "next-token")

        _ = try await provider.acknowledge(
            channelID: ChannelID(rawValue: 200),
            messageID: MessageID(rawValue: 334),
            token: response.token
        )
        #expect(RateLimitURLProtocol.ackRequestCount == 2)
        #expect(RateLimitURLProtocol.ackBody?["token"] as? String == "next-token")

        _ = try await provider.acknowledge(
            channelID: ChannelID(rawValue: 200),
            messageID: MessageID(rawValue: 332),
            token: response.token,
            manual: true,
            mentionCount: 4,
            flags: 3,
            lastViewed: 4_222
        )
        #expect(RateLimitURLProtocol.ackRequestCount == 3)
        #expect(RateLimitURLProtocol.ackMethod == "POST")
        #expect(RateLimitURLProtocol.ackPath == "/api/v9/channels/200/messages/332/ack")
        #expect(RateLimitURLProtocol.ackBody?["token"] as? String == "next-token")
        #expect(RateLimitURLProtocol.ackBody?["manual"] as? Bool == true)
        #expect((RateLimitURLProtocol.ackBody?["mention_count"] as? NSNumber)?.intValue == 4)
        #expect((RateLimitURLProtocol.ackBody?["flags"] as? NSNumber)?.uint64Value == 3)
        #expect((RateLimitURLProtocol.ackBody?["last_viewed"] as? NSNumber)?.intValue == 4_222)

        RateLimitURLProtocol.ackStatus = 429
        await #expect(throws: ChatProviderError.self) {
            try await provider.acknowledge(
                channelID: ChannelID(rawValue: 200),
                messageID: MessageID(rawValue: 335),
                token: response.token
            )
        }
        #expect(RateLimitURLProtocol.ackRequestCount == 4)
    }

    @Test func `channel notification mutations use the current partial override route once`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let guildID = GuildID(rawValue: 100)
        let channelID = ChannelID(rawValue: 200)

        try await provider.updateChannelNotificationLevel(
            guildID: guildID,
            channelID: channelID,
            level: .onlyMentions
        )
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 1)
        #expect(RateLimitURLProtocol.channelNotificationMethod == "PATCH")
        #expect(
            RateLimitURLProtocol.channelNotificationPath
                == "/api/v9/users/@me/guilds/100/settings"
        )
        var overrides =
            RateLimitURLProtocol.channelNotificationBody?["channel_overrides"]
                as? [String: Any]
        var override = overrides?["200"] as? [String: Any]
        #expect((override?["message_notifications"] as? NSNumber)?.intValue == 1)
        #expect(override?["muted"] == nil)

        let endTime = Date(timeIntervalSince1970: 1_785_420_000)
        try await provider.updateChannelMute(
            guildID: guildID,
            channelID: channelID,
            isMuted: true,
            until: endTime
        )
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 2)
        overrides =
            RateLimitURLProtocol.channelNotificationBody?["channel_overrides"]
                as? [String: Any]
        override = overrides?["200"] as? [String: Any]
        #expect(override?["muted"] as? Bool == true)
        let muteConfig = override?["mute_config"] as? [String: Any]
        #expect(muteConfig?["end_time"] as? String == "2026-07-30T14:00:00.000Z")

        try await provider.updateChannelMute(
            guildID: guildID,
            channelID: channelID,
            isMuted: false,
            until: nil
        )
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 3)
        overrides =
            RateLimitURLProtocol.channelNotificationBody?["channel_overrides"]
                as? [String: Any]
        override = overrides?["200"] as? [String: Any]
        #expect(override?["muted"] as? Bool == false)
        #expect(override?.keys.contains("mute_config") == true)
        #expect(override?["mute_config"] is NSNull)

        RateLimitURLProtocol.channelNotificationStatus = 429
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateChannelNotificationLevel(
                guildID: guildID,
                channelID: channelID,
                level: .nothing
            )
        }
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 4)
    }

    @Test func `direct message notification mutations use the private channel scope once`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let channelID = ChannelID(rawValue: 400)

        try await provider.updateChannelMute(
            guildID: nil,
            channelID: channelID,
            isMuted: true,
            until: nil
        )

        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 1)
        #expect(RateLimitURLProtocol.channelNotificationMethod == "PATCH")
        #expect(
            RateLimitURLProtocol.channelNotificationPath
                == "/api/v9/users/@me/guilds/@me/settings"
        )
        let overrides =
            RateLimitURLProtocol.channelNotificationBody?["channel_overrides"]
                as? [String: Any]
        let override = overrides?["400"] as? [String: Any]
        #expect(override?["muted"] as? Bool == true)
        #expect(override?.keys.contains("mute_config") == true)
        #expect(override?["mute_config"] is NSNull)
    }

    @Test func `forum post notification mutations use thread member settings and bounded join`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
        let joinedPostData = Data(
            """
            {
              "threads": [
                {
                  "id": "500",
                  "guild_id": "100",
                  "parent_id": "200",
                  "type": 11,
                  "name": "Joined post"
                }
              ],
              "members": [
                {
                  "id": "500",
                  "user_id": "1",
                  "flags": 3,
                  "muted": false
                }
              ],
              "has_more": false
            }
            """.utf8
        )
        let joinedPostResponse = try JSONDecoder().decode(
            ForumThreadCatalogueResponseDTO.self,
            from: joinedPostData
        )
        let joinedPost = try #require(
            joinedPostResponse.posts(fallbackGuildID: GuildID(rawValue: 100)).first
        )
        #expect(joinedPost.thread.notificationSettings?.notificationLevel == .allMessages)

        try await provider.updateForumPostNotificationLevel(
            joinedPost,
            level: .onlyMentions
        )
        #expect(RateLimitURLProtocol.threadMemberMethods == ["PATCH"])
        #expect(
            RateLimitURLProtocol.threadMemberPaths
                == ["/api/v9/channels/500/thread-members/@me/settings"]
        )
        #expect(
            (RateLimitURLProtocol.threadMemberBodies.last?["flags"] as? NSNumber)?
                .uint64Value
                == ThreadNotificationSettings.hasInteractedFlag
                    | ThreadNotificationSettings.onlyMentionsFlag
        )

        let unjoinedPost = ForumPost(
            thread: MessageThreadSummary(
                id: ChannelID(rawValue: 501),
                guildID: GuildID(rawValue: 100),
                parentID: ChannelID(rawValue: 200),
                name: "Unjoined post"
            )
        )
        let endTime = Date(timeIntervalSince1970: 1_785_420_000)
        try await provider.updateForumPostMute(
            unjoinedPost,
            isMuted: true,
            until: endTime
        )
        #expect(
            Array(RateLimitURLProtocol.threadMemberMethods.suffix(2))
                == ["POST", "PATCH"]
        )
        #expect(
            Array(RateLimitURLProtocol.threadMemberPaths.suffix(2))
                == [
                    "/api/v9/channels/501/thread-members/@me",
                    "/api/v9/channels/501/thread-members/@me/settings",
                ]
        )
        #expect(
            RateLimitURLProtocol.threadMemberJoinLocation
                == "Change Notification Settings"
        )
        #expect(RateLimitURLProtocol.threadMemberBodies.last?["muted"] as? Bool == true)
        let muteConfig =
            RateLimitURLProtocol.threadMemberBodies.last?["mute_config"]
                as? [String: Any]
        #expect(muteConfig?["end_time"] as? String == "2026-07-30T14:00:00.000Z")

        RateLimitURLProtocol.threadMemberStatus = 429
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateForumPostNotificationLevel(
                joinedPost,
                level: .nothing
            )
        }
        #expect(RateLimitURLProtocol.threadMemberMethods.count == 4)
    }

    @Test func `reaction gateway dispatches decode every documented mutation variant`() async throws {
        try await ReactionGatewayScenario().run
    }

    @Test func `external forum reaction deltas publish once and change the count once`() async
        throws
    {
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "forum-reaction-once"),
            session: .shared
        )
        let currentUser = User(
            id: UserID(rawValue: 1),
            username: "current",
            displayName: "Current"
        )
        let author = User(
            id: UserID(rawValue: 2),
            username: "author",
            displayName: "Author"
        )
        let parentID = ChannelID(rawValue: 100)
        let threadID = ChannelID(rawValue: 200)
        let messageID = MessageID(rawValue: 200)
        let forum = Channel(
            id: parentID,
            guildID: GuildID(rawValue: 300),
            name: "forum",
            kind: .forum
        )
        let starter = Message(
            id: messageID,
            channelID: threadID,
            author: author,
            content: "Starter",
            reactions: [Reaction(emoji: "❤️", count: 1)]
        )
        let post = ForumPost(
            thread: MessageThreadSummary(
                id: threadID,
                guildID: forum.guildID,
                parentID: parentID,
                name: "Post"
            ),
            firstMessage: starter
        )
        await provider.seedForumChannelForTesting(
            forum,
            posts: [post],
            currentUser: currentUser
        )
        let events = await provider.eventStream()
        let recorder = ReactionProjectionEventRecorder()
        let consumer = Task {
            for await event in events {
                await recorder.record(event)
            }
        }
        await Task.yield()

        let externalUserID = UserID(rawValue: 4)
        await provider.receiveGatewayReactionForTesting(
            .add(
                channelID: threadID,
                messageID: messageID,
                userID: externalUserID,
                emoji: "❤️",
                kind: .normal
            )
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: threadID)?
                .firstMessage?.reactions.first?.count == 2
        )
        await provider.receiveGatewayReactionForTesting(
            .remove(
                channelID: threadID,
                messageID: messageID,
                userID: externalUserID,
                emoji: "❤️",
                kind: .normal
            )
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: threadID)?
                .firstMessage?.reactions.first?.count == 1
        )
        #expect(await eventually { await recorder.reactionUpdateCount == 2 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorder.forumCataloguePublishCount == 0)
        consumer.cancel()
    }

    @Test func `application command indexes cache and each interaction uses one exact post`() async throws {
        try await ApplicationCommandScenario().run
    }

}

extension ProviderRequestContractTests {
    @Test func `bootstrap uses gateway ready and does not burst guild channel requests`() async throws {
        try await BootstrapRequestScenario().run
    }

    @Test func `bootstrap falls back when Ready only partially hydrates guilds`() async throws {
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
                "session_id": .string("partial-ready-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "user": .object([
                    "id": .string("1"),
                    "username": .string("tester"),
                    "global_name": .string("Tester"),
                    "avatar": .null,
                ]),
                "guilds": .array([
                    .object([
                        "id": .string("100"),
                        "name": .string("Gateway Guild"),
                        "icon": .null,
                    ]),
                    .object([
                        "id": .string("101")
                    ]),
                ]),
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

        let snapshot = try await provider.bootstrap()

        #expect(snapshot.currentUser.id == UserID(rawValue: 1))
        #expect(snapshot.guilds.map(\.id) == [GuildID(rawValue: 100)])
        #expect(RateLimitURLProtocol.currentUserRequests == 0)
        #expect(RateLimitURLProtocol.guildListAttempts == 2)
        await provider.disconnect()
    }

    @Test func `partial Ready retains guild layout through catalogue fallback`() async throws {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.guildListJSON = #"""
            [
            {"id":"100","name":"First response guild","icon":null},
            {"id":"101","name":"Second response guild","icon":null}
            ]
            """#
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ))
        let settings = RateLimitURLProtocol.guildFolderSettingsProto(guildIDs: [101, 100])
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("partial-ready-layout-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "user": .object([
                    "id": .string("1"),
                    "username": .string("tester"),
                    "global_name": .string("Tester"),
                    "avatar": .null,
                ]),
                "user_settings_proto": .string(settings.base64EncodedString()),
                "guilds": .array([
                    .object(["id": .string("100")]),
                    .object(["id": .string("101")]),
                ]),
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

        let snapshot = try await provider.bootstrap()

        #expect(snapshot.guilds.map(\.id) == [
            GuildID(rawValue: 101), GuildID(rawValue: 100),
        ])
        #expect(snapshot.guildRailItems == [
            .folder(GuildFolder(id: 42, name: "Work", colorHex: 0x58_65_F2, guildIDs: [
                GuildID(rawValue: 101), GuildID(rawValue: 100),
            ])),
        ])
        #expect(RateLimitURLProtocol.guildListAttempts == 2)
        #expect(RateLimitURLProtocol.settingsRequestCount == 0)
        await provider.disconnect()
    }

    @Test func `bootstrap publishes ready unread state and guild channels atomically`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ))
        await socket.push(startupUnreadReadyMessage())
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket)
        )
        let events = await provider.eventStream()
        let readyWorkspaceReplays = Task {
            await readyWorkspaceReplayEvents(untilReadyIn: events)
        }

        let snapshot = try await provider.bootstrap()
        let channel = try #require(snapshot.channels.first { $0.id == ChannelID(rawValue: 200) })
        let readState = try #require(
            snapshot.readStates.first { $0.channelID == ChannelID(rawValue: 200) }
        )
        let settings = try #require(
            snapshot.notificationSettings.first { $0.guildID == GuildID(rawValue: 100) }
        )

        #expect(channel.lastMessageID == MessageID(rawValue: 300))
        #expect(snapshot.channels.map(\.id) == [
            ChannelID(rawValue: 200), ChannelID(rawValue: 201),
        ])
        #expect(snapshot.forwardChannelStoreOrder == [
            ChannelID(rawValue: 201), ChannelID(rawValue: 200),
        ])
        #expect(readState.lastAcknowledgedMessageID == MessageID(rawValue: 250))
        #expect(readState.mentionCount == 2)
        #expect(readState.version == 61)
        #expect(settings.messageNotifications == .onlyMentions)
        #expect(!settings.isMuted)
        #expect(settings.flags == 2048)
        #expect(settings.channelOverrides.first?.flags == 1024)
        #expect(!snapshot.usesNewNotifications)
        #expect(RateLimitURLProtocol.currentUserRequests == 1)
        #expect(RateLimitURLProtocol.guildListAttempts == 2)
        #expect(RateLimitURLProtocol.guildChannelRequests == 0)
        #expect(await readyWorkspaceReplays.value.isEmpty)

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

    @Test func `unavailable profiles remain scoped and do not stop the session`() async throws {
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
        let unavailableMessage =
            "This profile is unavailable. You may no longer share a server or friendship with this user."
        for userID in [
            UserID(rawValue: 111_111_111_111_111_111),
            UserID(rawValue: 222_222_222_222_222_222),
        ] {
            await #expect(throws: ChatProviderError.invalidRequest(unavailableMessage)) {
                try await provider.profile(for: userID, in: GuildID(rawValue: 100))
            }
        }

        let message = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "still connected",
            nonce: "profile-not-found-scope-nonce"
        ))
        #expect(message.content == "still connected")
        #expect(RateLimitURLProtocol.unavailableProfileRequestCount == 2)
        #expect(RateLimitURLProtocol.messageRequestCount == 1)
        #expect(await socket.closeCodes.isEmpty)
    }
}

private func readyWorkspaceReplayEvents(
    untilReadyIn events: AsyncStream<ClientEvent>
) async -> [ClientEvent] {
    var replays: [ClientEvent] = []
    for await event in events {
        if event == .connectionChanged(.ready) {
            return replays
        }
        switch event {
        case .readStateSnapshot,
             .notificationModeChanged,
             .notificationSettingsChanged,
             .channelsChanged:
            replays.append(event)
        default:
            break
        }
    }
    return replays
}

private struct ReactionGatewayScenario {
    var run: Void {
        get async throws {
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
                "session_id": .string("reaction-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "guilds": .array([]),
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

        let created = Task { () -> Message? in
            for await event in events {
                if case let .messageCreated(message) = event { return message }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "id": .string("300"),
                "channel_id": .string("200"),
                "guild_id": .string("100"),
                "author": .object([
                    "id": .string("2"),
                    "username": .string("maya"),
                    "global_name": .string("Maya"),
                    "avatar": .null,
                ]),
                "content": .string("react here"),
                "timestamp": .string("2026-07-26T12:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ]),
            sequence: 2,
            eventName: "MESSAGE_CREATE"
        ))
        #expect(await created.value?.id == MessageID(rawValue: 300))

        let add = Task { () -> MessageReactionUpdate? in
            for await event in events {
                if case let .messageReactionUpdated(update) = event { return update }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "user_id": .string("2"),
                "channel_id": .string("200"),
                "message_id": .string("300"),
                "guild_id": .string("100"),
                "emoji": .object(["id": .null, "name": .string("🔥")]),
                "type": .number(0),
                "burst": .bool(false),
            ]),
            sequence: 3,
            eventName: "MESSAGE_REACTION_ADD"
        ))
        #expect(
            await add.value
                == .add(
                    channelID: ChannelID(rawValue: 200),
                    messageID: MessageID(rawValue: 300),
                    userID: UserID(rawValue: 2),
                    emoji: "🔥",
                    kind: .normal
                )
        )

        let currentUserAdd = Task { () -> MessageReactionUpdate? in
            for await event in events {
                if case let .messageReactionUpdated(update) = event { return update }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "user_id": .string("1"),
                "channel_id": .string("200"),
                "message_id": .string("300"),
                "emoji": .object(["id": .null, "name": .string("🔥")]),
                "type": .number(0),
                "burst": .bool(false),
            ]),
            sequence: 4,
            eventName: "MESSAGE_REACTION_ADD"
        ))
        #expect(
            await currentUserAdd.value
                == .add(
                    channelID: ChannelID(rawValue: 200),
                    messageID: MessageID(rawValue: 300),
                    userID: UserID(rawValue: 1),
                    emoji: "🔥",
                    kind: .normal
                )
        )

        let optimisticRemove = Task { () -> Message? in
            for await event in events {
                if case let .messageUpdated(message) = event, message.id == MessageID(rawValue: 300)
                {
                    return message
                }
            }
            return nil
        }
        try await provider.toggleReaction(
            "🔥",
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200)
        )
        let removed = try #require(await optimisticRemove.value)
        #expect(removed.reactions.first?.count == 1)
        #expect(removed.reactions.first?.didCurrentUserReact == false)
        #expect(RateLimitURLProtocol.reactionMethods == ["DELETE"])

        let removeEcho = Task { () -> MessageReactionUpdate? in
            for await event in events {
                if case let .messageReactionUpdated(update) = event { return update }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "user_id": .string("1"),
                "channel_id": .string("200"),
                "message_id": .string("300"),
                "emoji": .object(["id": .null, "name": .string("🔥")]),
                "type": .number(0),
                "burst": .bool(false),
            ]),
            sequence: 5,
            eventName: "MESSAGE_REACTION_REMOVE"
        ))
        #expect(
            await removeEcho.value
                == .remove(
                    channelID: ChannelID(rawValue: 200),
                    messageID: MessageID(rawValue: 300),
                    userID: UserID(rawValue: 1),
                    emoji: "🔥",
                    kind: .normal
                )
        )

        let optimisticAdd = Task { () -> Message? in
            for await event in events {
                if case let .messageUpdated(message) = event, message.id == MessageID(rawValue: 300)
                {
                    return message
                }
            }
            return nil
        }
        try await provider.toggleReaction(
            "🔥",
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200)
        )
        let readded = try #require(await optimisticAdd.value)
        #expect(readded.reactions.first?.count == 2)
        #expect(readded.reactions.first?.didCurrentUserReact == true)
        #expect(RateLimitURLProtocol.reactionMethods == ["DELETE", "PUT"])
        try await provider.setReaction(
            "🔥",
            reacted: true,
            messageID: MessageID(rawValue: 300),
            channelID: ChannelID(rawValue: 200)
        )
        #expect(RateLimitURLProtocol.reactionMethods == ["DELETE", "PUT"])

        let remove = Task { () -> MessageReactionUpdate? in
            for await event in events {
                if case let .messageReactionUpdated(update) = event { return update }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "user_id": .string("1"),
                "channel_id": .string("200"),
                "message_id": .string("300"),
                "emoji": .object([
                    "id": .string("999"),
                    "name": .string("party_blob"),
                    "animated": .bool(true),
                ]),
                "type": .number(1),
                "burst": .bool(true),
            ]),
            sequence: 6,
            eventName: "MESSAGE_REACTION_REMOVE"
        ))
        #expect(
            await remove.value
                == .remove(
                    channelID: ChannelID(rawValue: 200),
                    messageID: MessageID(rawValue: 300),
                    userID: UserID(rawValue: 1),
                    emoji: "<a:party_blob:999>",
                    kind: .burst
                )
        )

        let removeEmoji = Task { () -> MessageReactionUpdate? in
            for await event in events {
                if case let .messageReactionUpdated(update) = event { return update }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "channel_id": .string("200"),
                "message_id": .string("300"),
                "emoji": .object([
                    "id": .string("999"),
                    "name": .string("renamed_blob"),
                ]),
            ]),
            sequence: 7,
            eventName: "MESSAGE_REACTION_REMOVE_EMOJI"
        ))
        #expect(
            await removeEmoji.value
                == .removeEmoji(
                    channelID: ChannelID(rawValue: 200),
                    messageID: MessageID(rawValue: 300),
                    emoji: "<:renamed_blob:999>"
                )
        )

        let removeAll = Task { () -> MessageReactionUpdate? in
            for await event in events {
                if case let .messageReactionUpdated(update) = event { return update }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "channel_id": .string("200"),
                "message_id": .string("300"),
            ]),
            sequence: 8,
            eventName: "MESSAGE_REACTION_REMOVE_ALL"
        ))
        #expect(
            await removeAll.value
                == .removeAll(
                    channelID: ChannelID(rawValue: 200),
                    messageID: MessageID(rawValue: 300)
                )
        )

        await provider.disconnect()
        }
    }
}

private struct ApplicationCommandScenario {
    var run: Void {
        get async throws {
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

        let acknowledgementEvent = Task { () -> ChannelReadState? in
            for await event in events {
                if case let .readStateChanged(state) = event { return state }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "channel_id": .string("200"),
                "message_id": .string("333"),
                "mention_count": .number(2),
                "manual": .bool(true),
                "flags": .number(3),
                "last_viewed": .number(4_222),
                "version": .number(73)
            ]),
            sequence: 7,
            eventName: "MESSAGE_ACK"
        ))
        #expect(
            await acknowledgementEvent.value
                == ChannelReadState(
                    channelID: ChannelID(rawValue: 200),
                    lastAcknowledgedMessageID: MessageID(rawValue: 333),
                    mentionCount: 2,
                    isManual: true,
                    flags: 3,
                    lastViewed: 4_222,
                    version: 73
                )
        )
        let notificationSettingsEvent = Task { () -> GuildNotificationSettings? in
            for await event in events {
                if case let .notificationSettingsChanged(settings) = event { return settings }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "message_notifications": .number(1),
                "muted": .bool(false),
                "suppress_everyone": .bool(true),
                "suppress_roles": .bool(false),
                "notify_highlights": .number(1),
                "mute_scheduled_events": .bool(true),
                "mobile_push": .bool(false),
                "channel_overrides": .array([
                    .object([
                        "channel_id": .string("200"),
                        "message_notifications": .number(0),
                        "muted": .bool(true),
                    ])
                ]),
            ]),
            sequence: 8,
            eventName: "USER_GUILD_SETTINGS_UPDATE"
        ))
        let decodedSettings = try #require(await notificationSettingsEvent.value)
        #expect(decodedSettings.guildID == GuildID(rawValue: 100))
        #expect(decodedSettings.messageNotifications == .onlyMentions)
        #expect(decodedSettings.suppressEveryone)
        #expect(decodedSettings.notifyHighlights == .disabled)
        #expect(decodedSettings.muteScheduledEvents)
        #expect(!decodedSettings.mobilePush)
        #expect(decodedSettings.channelOverrides.first?.messageNotifications == .allMessages)
        #expect(decodedSettings.channelOverrides.first?.isMuted == true)
        let partialSettingsEvent = Task { () -> GuildNotificationSettings? in
            for await event in events {
                if case let .notificationSettingsChanged(settings) = event { return settings }
            }
            return nil
        }
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "suppress_roles": .bool(true),
            ]),
            sequence: 9,
            eventName: "USER_GUILD_SETTINGS_UPDATE"
        ))
        let mergedSettings = try #require(await partialSettingsEvent.value)
        #expect(mergedSettings.suppressEveryone)
        #expect(mergedSettings.suppressRoles)
        #expect(mergedSettings.notifyHighlights == .disabled)
        #expect(mergedSettings.muteScheduledEvents)
        #expect(!mergedSettings.mobilePush)
        #expect(mergedSettings.channelOverrides.first?.isMuted == true)
        await provider.disconnect()
        }
    }
}

private struct BootstrapRequestScenario {
    var run: Void {
        get async throws {
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
                "user": .object([
                    "id": .string("1"),
                    "username": .string("tester"),
                    "global_name": .string("Tester"),
                    "avatar": .null,
                ]),
                "guilds": .array([
                    .object([
                        "id": .string("100"),
                        "name": .string("Guild"),
                        "icon": .null,
                        "owner_id": .string("999"),
                        "permissions": .string("1024"),
                        "default_message_notifications": .number(1),
                    ])
                ]),
                "users": .array([
                    .object([
                        "id": .string("2"),
                        "username": .string("maya"),
                        "global_name": .string("Maya"),
                        "avatar": .null,
                    ])
                ]),
                "private_channels": .array([
                    .object([
                        "id": .string("401"),
                        "type": .number(1),
                        "last_message_id": .string("601"),
                        "recipient_ids": .array([.string("2")]),
                    ])
                ]),
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: credentials,
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            usesEmojiDiskCache: false
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
        #expect(snapshot.channels.map(\.id) == [ChannelID(rawValue: 401)])
        #expect(snapshot.channels.first?.name == "Maya")
        #expect(snapshot.channels.first?.recipients.map(\.id) == [
            UserID(rawValue: 2)
        ])
        #expect(snapshot.guildRailItems == [.guild(GuildID(rawValue: 100))])
        #expect(snapshot.guilds.first?.isOwnedByCurrentUser == false)
        #expect(snapshot.guilds.first?.currentUserPermissions == 1024)
        #expect(RateLimitURLProtocol.currentUserRequests == 0)
        #expect(RateLimitURLProtocol.guildListAttempts == 0)
        #expect(RateLimitURLProtocol.privateChannelListRequests == 0)
        #expect(RateLimitURLProtocol.guildChannelRequests == 0)
        #expect(RateLimitURLProtocol.settingsRequestCount == 0)
        #expect(RateLimitURLProtocol.settingsMethod == nil)

        async let firstChannels = provider.channels(in: GuildID(rawValue: 100))
        async let secondChannels = provider.channels(in: GuildID(rawValue: 100))
        let (channels, duplicateChannels) = try await (firstChannels, secondChannels)
        #expect(channels.first?.name == "general")
        #expect(duplicateChannels == channels)
        #expect(channels.first?.category == "CHAT")
        #expect(channels.first?.permissionOverwrites?.isEmpty == true)
        #expect(RateLimitURLProtocol.guildChannelRequests == 1)

        async let firstRoles = provider.roles(in: GuildID(rawValue: 100))
        async let secondRoles = provider.roles(in: GuildID(rawValue: 100))
        let (roles, duplicateRoles) = try await (firstRoles, secondRoles)
        #expect(roles.first { $0.id == RoleID(rawValue: 100) }?.permissions == 1024)
        #expect(duplicateRoles == roles)
        #expect(RateLimitURLProtocol.guildRoleRequests == 1)

        let emojiGuildID = GuildID(rawValue: 987_654_321_012_345_678)
        async let firstEmojis = provider.emojis(in: emojiGuildID)
        async let secondEmojis = provider.emojis(in: emojiGuildID)
        let (emojis, duplicateEmojis) = try await (firstEmojis, secondEmojis)
        #expect(emojis.isEmpty)
        #expect(duplicateEmojis == emojis)
        #expect(RateLimitURLProtocol.guildEmojiRequests == 1)

        async let firstEmojiSettings = provider.emojiUserSettings()
        async let secondEmojiSettings = provider.emojiUserSettings()
        let (emojiSettings, duplicateEmojiSettings) = try await (
            firstEmojiSettings, secondEmojiSettings
        )
        #expect(duplicateEmojiSettings == emojiSettings)
        #expect(RateLimitURLProtocol.emojiSettingsRequests == 1)

        let history = Task {
            try await provider.messages(in: ChannelID(rawValue: 200), before: nil, limit: 50)
        }
        #expect(await eventually { await socket.sentPayload(opcode: 8) != nil })
        let historyGatewayData = try #require(await socket.sentPayload(opcode: 8))
        let historyGatewayPayload = try #require(
            JSONSerialization.jsonObject(with: historyGatewayData) as? [String: Any]
        )
        let historyRequest = try #require(historyGatewayPayload["d"] as? [String: Any])
        #expect(historyRequest["guild_id"] as? String == "100")
        #expect(historyRequest["user_ids"] as? [String] == ["4"])
        #expect(historyRequest["presences"] as? Bool == false)
        #expect(historyRequest["nonce"] == nil)
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "members": .array([
                    .object([
                        "user": .object([
                            "id": .string("4"),
                            "username": .string("history-author"),
                            "global_name": .string("History Author"),
                            "avatar": .null
                        ]),
                        "nick": .string("Colored Author"),
                        "roles": .array([.string("101")])
                    ])
                ]),
                "chunk_index": .number(0),
                "chunk_count": .number(1)
            ]),
            sequence: 2,
            eventName: "GUILD_MEMBERS_CHUNK"
        ))
        let historyPage = try await history.value
        let historyMessage = try #require(historyPage.messages.first)
        #expect(historyMessage.guildID == GuildID(rawValue: 100))
        #expect(historyMessage.guildMember?.nickname == "Colored Author")
        #expect(historyMessage.guildMember?.roleIDs == [RoleID(rawValue: 101)])
        #expect(historyPage.resolvedMembers.map(\.id) == [UserID(rawValue: 4)])
        #expect(historyPage.hasCompleteMemberResolution)
        let historyMemberRequests = await socket.sentPayloadCount(opcode: 8)
        _ = try await provider.messages(in: ChannelID(rawValue: 200), before: nil, limit: 50)
        #expect(await socket.sentPayloadCount(opcode: 8) == historyMemberRequests)

        let memberSearch = Task {
            try await provider.searchMembers(
                in: GuildID(rawValue: 100), query: "maya", limit: 125
            )
        }
        #expect(await eventually {
            await socket.sentPayloadCount(opcode: 8) > historyMemberRequests
        })
        let gatewayData = try #require(await socket.sentPayload(opcode: 8))
        let gatewayPayload = try #require(
            JSONSerialization.jsonObject(with: gatewayData) as? [String: Any]
        )
        #expect((gatewayPayload["op"] as? NSNumber)?.intValue == 8)
        let searchData = try #require(gatewayPayload["d"] as? [String: Any])
        #expect(searchData["guild_id"] as? [String] == ["100"])
        #expect(searchData["query"] as? String == "maya")
        #expect((searchData["limit"] as? NSNumber)?.intValue == 100)
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
        #expect((await provider.currentMessageSearchUsers()).contains {
            $0.id == UserID(rawValue: 2)
        })
        let indexedQuickSwitcherMembers =
            await provider.currentQuickSwitcherGuildMemberUserIDs()
        #expect(indexedQuickSwitcherMembers[GuildID(rawValue: 100)] == [
            // GuildMemberStore retains READY insertion order, then appends
            // query-member chunks in their returned order.
            UserID(rawValue: 4), UserID(rawValue: 2), UserID(rawValue: 3),
        ])
        #expect(RateLimitURLProtocol.memberSearchRequestCount == 0)

        let memberRequestCount = await socket.sentPayloadCount(opcode: 8)
        try await provider.requestQuickSwitcherMembers(
            in: GuildID(rawValue: 100), query: "HEN", limit: 125
        )
        #expect(await socket.sentPayloadCount(opcode: 8) == memberRequestCount + 1)
        let quickSwitcherGatewayData = try #require(await socket.sentPayload(opcode: 8))
        let quickSwitcherGatewayPayload = try #require(
            JSONSerialization.jsonObject(with: quickSwitcherGatewayData) as? [String: Any]
        )
        let quickSwitcherSearch = try #require(
            quickSwitcherGatewayPayload["d"] as? [String: Any]
        )
        #expect(quickSwitcherSearch["guild_id"] as? [String] == ["100"])
        #expect(quickSwitcherSearch["query"] as? String == "hen")
        #expect((quickSwitcherSearch["limit"] as? NSNumber)?.intValue == 100)
        #expect(quickSwitcherSearch["presences"] as? Bool == true)
        #expect(Set(quickSwitcherSearch.keys) == [
            "guild_id", "query", "limit", "presences",
        ])

        await provider.updateClientAppState(isFocused: false)
        let clientAppState = await provider.clientAppStateForTesting()
        #expect(clientAppState == "unfocused")
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
        #expect(RateLimitURLProtocol.messageContextProperties == DiscordClientMetadata.messageContextHeader)
        let encodedProperties = try #require(RateLimitURLProtocol.messageSuperProperties)
        let propertiesData = try #require(Data(base64Encoded: encodedProperties))
        let properties = try #require(JSONSerialization.jsonObject(with: propertiesData) as? [String: Any])
        #expect(properties["browser"] as? String == "Discord Client")
        #expect(properties["browser_user_agent"] as? String == RateLimitURLProtocol.messageUserAgent)
        #expect((properties["client_build_number"] as? NSNumber)?.intValue == DiscordProductionBaseline.august2026.webBuildNumber)

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
        #expect(mentionBody["attachments"] == nil)
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
        let replyBody = try #require(RateLimitURLProtocol.sentMessageBody)
        let reference = try #require(
            replyBody["message_reference"] as? [String: Any]
        )
        #expect((reference["type"] as? NSNumber)?.intValue == 0)
        #expect(reference["message_id"] as? String == "299")
        #expect(reference["channel_id"] as? String == "200")
        #expect(replyBody["allowed_mentions"] == nil)

        _ = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "quiet reply",
            replyTo: MessageID(rawValue: 299),
            mentionsRepliedUser: false
        ))
        let quietReplyBody = try #require(RateLimitURLProtocol.sentMessageBody)
        let allowedMentions = try #require(
            quietReplyBody["allowed_mentions"] as? [String: Any]
        )
        #expect(allowedMentions["replied_user"] as? Bool == false)
        #expect(allowedMentions["parse"] as? [String] == [
            "users", "roles", "everyone",
        ])

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
    }
}

actor TestCredentialStore: CredentialStore {
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

struct ReadyGatewayTransport: GatewayTransport {
    let socket: ReadyGatewaySocket

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        socket
    }
}

private enum ReadyGatewayError: Error { case closed }

actor ReadyGatewaySocket: GatewaySocket {
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

    func sentPayload(opcode: Int) -> Data? {
        sentPayloads.last { data in
            guard
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { return false }
            return (object["op"] as? NSNumber)?.intValue == opcode
        }
    }

    func sentPayloadCount(opcode: Int) -> Int {
        sentPayloads.count { data in
            guard
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { return false }
            return (object["op"] as? NSNumber)?.intValue == opcode
        }
    }

    func sentOpcodes() -> [Int] {
        sentPayloads.compactMap { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (object["op"] as? NSNumber)?.intValue
        }
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

func gatewayMessage(
    op: Int,
    data: JSONValue?,
    sequence: Int? = nil,
    eventName: String? = nil
) -> GatewaySocketMessage {
    let envelope = GatewayEnvelope(
        op: op, data: data, sequence: sequence, eventName: eventName
    )
    return .text(restrictionGatewayText(envelope))
}

private func restrictionGatewayText(_ envelope: GatewayEnvelope) -> String {
    let data: Data
    do {
        data = try JSONGatewayCodec().encode(envelope)
    } catch {
        preconditionFailure("Invalid test Gateway envelope: \(error)")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        preconditionFailure("Gateway JSON encoder returned non-UTF-8 data")
    }
    return text
}

private enum RestrictionGatewayError: Error { case closed }

private struct RestrictionGatewayTransport: GatewayTransport {
    let socket: RestrictionGatewaySocket

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        socket
    }
}

private actor RestrictionGatewaySocket: GatewaySocket {
    private var queued: [GatewaySocketMessage] = [
        gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ),
        gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("restriction-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "guilds": .array([]),
            ]),
            sequence: 1,
            eventName: "READY"
        ),
    ]
    private var receiver: CheckedContinuation<GatewaySocketMessage, any Error>?
    private(set) var receiveStarted = false
    private(set) var closeCodes: [Int] = []

    func receive() async throws -> GatewaySocketMessage {
        receiveStarted = true
        if !queued.isEmpty {
            return queued.removeFirst()
        }
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

private actor ReactionProjectionEventRecorder {
    private(set) var reactionUpdateCount = 0
    private(set) var forumCataloguePublishCount = 0

    func record(_ event: ClientEvent) {
        switch event {
        case .messageReactionUpdated:
            reactionUpdateCount += 1
        case .forumPostsChanged:
            forumCataloguePublishCount += 1
        default:
            break
        }
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
