@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension ProviderRequestContractTests {
    @Test func `pending login bootstraps a compressed desktop Ready larger than sixteen MiB`() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let codec = ETFGatewayCodec()
        let compressor = try GatewayTestZstdStream()
        let socket = ReadyGatewaySocket()
        await socket.push(.data(try compressor.compress(codec.encode(GatewayEnvelope(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        )))))
        await socket.push(.data(try compressor.compress(codec.encode(largeGatewayReadyEnvelope()))))
        let pending = try PendingDiscordCredential(Data("pending-fixture-credential".utf8))
        let provider = DiscordRESTProvider(
            pendingCredential: pending, session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket), gatewayCodec: codec,
            gatewayEncoding: "etf", gatewayCompression: .zstdStream,
            installationID: "fixture-installation", usesEmojiDiskCache: false
        )
        let snapshot = try await provider.bootstrap()
        #expect(snapshot.currentUser.id == UserID(rawValue: 1))
        #expect(snapshot.currentUser.username == "fixture")
        #expect(RateLimitURLProtocol.totalRequestCount == 0)
        let credential = try await provider.persistPendingCredential(to: TestCredentialStore(), accountID: "1")
        #expect(credential.accountID == "1")
        await provider.disconnect()
        await pending.discard()
    }

    @Test(arguments: [false, true])
    func `bootstrap uses gateway ready and does not burst guild channel requests`(anonymisesFileNames: Bool) async throws {
        try await BootstrapRequestScenario(anonymisesFileNames: anonymisesFileNames).run
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

    @Test(arguments: [false, true])
    func `fresh READY replaces the workspace without repeating bootstrap requests`(partialSettings: Bool) async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(op: 10, data: .object(["heartbeat_interval": .number(60_000)])))
        await socket.push(startupUnreadReadyMessage())
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration), gatewayTransport: ReadyGatewayTransport(socket: socket)
        )
        let initial = try await provider.bootstrap()
        #expect(initial.channels.count == 2)
        let requestCount = RateLimitURLProtocol.totalRequestCount
        let stream = await provider.eventStream()
        await provider.handleGatewayDispatch(name: "READY", body: .object([
            "user": .object(["id": .string("1"), "username": .string("refreshed")]),
            "guilds": .array([.object([
                "id": .string("100"), "name": .string("Refreshed guild"),
                "channels": .array([
                    .object(["id": .string("200"), "type": .number(0), "name": .string("renamed"), "last_message_id": .string("900")]),
                    .object(["id": .string("202"), "type": .number(0), "name": .string("added")]),
                ])
            ])]),
            "read_state": .object(["version": .number(62), "entries": .array([
                .object(["id": .string("200"), "last_message_id": .string("850"), "mention_count": .number(1)])
            ])]),
            "user_guild_settings": .object(["entries": .array([]), "partial": .bool(partialSettings)]),
            "notification_settings": .object(["flags": .number(16)]),
        ]))
        await provider.handleGatewayDispatch(name: "RESUMED", body: .object([:]))
        await provider.continuation?.finish()
        var replacements: [BootstrapSnapshot] = []
        for await event in stream {
            if case let .snapshotChanged(value) = event { replacements.append(value) }
        }
        #expect(replacements.count == 1)
        let refreshed = try #require(replacements.first)
        #expect(refreshed.currentUser.username == "refreshed")
        #expect(refreshed.guilds.first?.name == "Refreshed guild")
        #expect(Set(refreshed.channels.map(\.id)) == [ChannelID(rawValue: 200), ChannelID(rawValue: 202)])
        #expect(refreshed.channels.first { $0.id == ChannelID(rawValue: 200) }?.name == "renamed")
        #expect(refreshed.readStates.first?.lastAcknowledgedMessageID == MessageID(rawValue: 850))
        #expect(refreshed.readStates.first?.version == 62)
        #expect(refreshed.usesNewNotifications)
        #expect(refreshed.notificationSettings == (partialSettings ? initial.notificationSettings : []))
        #expect(try await provider.waitForInitialGatewaySnapshot().readStates.first?.version == 62)
        #expect(RateLimitURLProtocol.totalRequestCount == requestCount)
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
        let privateProfile = try await provider.profile(for: UserID(rawValue: 333_333_333_333_333_333), in: nil)
        #expect(privateProfile.isPrivate == true)
        #expect(privateProfile.user.username == "private-user")
        #expect(privateProfile.mutualFriendsCount == 1)
        #expect(privateProfile.bio == nil)

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
