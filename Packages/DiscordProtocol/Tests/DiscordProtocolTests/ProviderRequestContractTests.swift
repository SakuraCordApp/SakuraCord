@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Suite(.serialized)
struct ProviderRequestContractTests {
    @Test func `pre-clear emoji requests cannot restore cleared memory or disk catalogs`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "emoji-clear-\(UUID().uuidString)"),
            session: URLSession(configuration: configuration), usesForwardSearchPeopleDiskCache: false
        )
        let guildID = GuildID(rawValue: 987_654_321_012_345_678)
        let cacheURL = try await provider.emojiCacheURL(for: guildID)
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let received = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await provider.setEmojiResponseGate {
            received.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let load = Task { try await provider.emojis(in: guildID) }
        var receivedIterator = received.stream.makeAsyncIterator()
        _ = await receivedIterator.next()
        try await provider.clearLocalSearchCache()
        release.continuation.yield(())
        _ = try await load.value
        #expect(await provider.cachedEmojis[guildID] == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(RateLimitURLProtocol.guildEmojiRequests == 1)

        // A new post-clear request may establish a new catalog normally.
        await provider.setEmojiResponseGate(nil)
        _ = try await provider.emojis(in: guildID)
        #expect(await provider.cachedEmojis[guildID] != nil)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(RateLimitURLProtocol.guildEmojiRequests == 2)
        await provider.disconnect()
    }

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

        try await provider.updateDirectMessagePin(
            channelID: channelID,
            flags: (1 << 11) | (1 << 5)
        )
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 2)
        #expect(RateLimitURLProtocol.channelNotificationMethod == "PATCH")
        #expect(
            RateLimitURLProtocol.channelNotificationPath
                == "/api/v9/users/@me/guilds/@me/settings"
        )
        overrides = RateLimitURLProtocol.channelNotificationBody?["channel_overrides"]
            as? [String: Any]
        override = overrides?["200"] as? [String: Any]
        #expect((override?["flags"] as? NSNumber)?.uint64Value == (1 << 11) | (1 << 5))
        #expect(override?["message_notifications"] == nil)

        let endTime = Date(timeIntervalSince1970: 1_785_420_000)
        try await provider.updateChannelMute(
            guildID: guildID,
            channelID: channelID,
            isMuted: true,
            until: endTime
        )
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 3)
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
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 4)
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
        #expect(RateLimitURLProtocol.channelNotificationRequestCount == 5)
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

    @Test(arguments: [false, true])
    func `reaction intents outside the working set reload before deciding whether to mutate`(reacted: Bool) async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration), installationID: "fixture"
        )
        let channelID = ChannelID(rawValue: 200)
        let messageID = MessageID(rawValue: 350)
        #expect(await provider.cachedMessages[messageID] == nil)
        try await provider.setReaction("🔥", reacted: reacted, messageID: messageID, channelID: channelID)
        #expect(RateLimitURLProtocol.messageHistoryQueryItems.count == 1)
        #expect(Set(RateLimitURLProtocol.messageHistoryQueryItems[0]) == Set(["around=350", "limit=1"]))
        #expect(RateLimitURLProtocol.reactionMethods == (reacted ? ["PUT"] : []))
        await provider.disconnect()
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

private extension DiscordRESTProvider {
    func setEmojiResponseGate(_ callback: (@Sendable () async -> Void)?) {
        emojiResponseReceivedForTesting = callback
    }
}
