import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct DirectMessageProviderContractTests {
    @Test func `DM history stays a read and extends the forwarding user index`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        _ = try await provider.messages(
            in: ChannelID(rawValue: 41),
            before: MessageID(rawValue: 900),
            limit: 50
        )

        #expect(await provider.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 77), UserID(rawValue: 78),
        ])

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

    @Test func `profile effects use only the current collectibles product route`() async throws {
        DirectMessageURLProtocol.reset()
        DirectMessageURLProtocol.profileHasEffect = true
        let provider = makeProvider()

        async let firstProfile = provider.profile(
            for: UserID(rawValue: 2),
            in: nil
        )
        async let secondProfile = provider.profile(
            for: UserID(rawValue: 2),
            in: nil
        )
        let (profile, duplicateProfile) = try await (firstProfile, secondProfile)

        #expect(profile.effect?.id == "900")
        #expect(profile.effect?.title == "Aurora")
        #expect(duplicateProfile == profile)
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile",
            "/api/v9/collectibles-products/900",
        ])
        #expect(DirectMessageURLProtocol.requests[1].query == [
            CapturedQueryItem(
                name: "locale",
                value: Locale.preferredLanguages.first ?? "en-US"
            )
        ])
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
                UserID(rawValue: 3), UserID(rawValue: 2),
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
            UserID(rawValue: 3), UserID(rawValue: 2),
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
        await seedPrivateChannelOrderReady(on: provider)
        #expect(
            await provider.cachedPrivateChannelsForTesting().map(\.id) == [
                ChannelID(rawValue: 43),
                ChannelID(rawValue: 41),
                ChannelID(rawValue: 42),
            ]
        )
        #expect(
            Dictionary(
                uniqueKeysWithValues: await provider.cachedPrivateChannelsForTesting()
                    .map { ($0.id, $0.position) }
            ) == [
                ChannelID(rawValue: 41): 0,
                ChannelID(rawValue: 42): 1,
                ChannelID(rawValue: 43): 2,
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
        #expect(
            await provider.cachedPrivateChannelsForTesting()
                .first(where: { $0.id == ChannelID(rawValue: 44) })?.position == 3
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
        #expect(afterSupplemental.first?.position == 4)

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

    @Test func `ready supplemental does not admit standalone hydration users`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let events = await provider.eventStream()
        let published = Task { () -> [User]? in
            for await event in events {
                if case let .knownUsersChanged(users) = event { return users }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    .object([
                        "id": .string("3"),
                        "username": .string("legacy-bot"),
                        "discriminator": .string("8860"),
                        "global_name": .string("Global Name"),
                    ]),
                    .object([
                        "id": .string("2"),
                        "username": .string("later-user"),
                        "global_name": .string("Later User"),
                    ])
                ]),
            ])
        )

        let users = try #require(await published.value)
        #expect(users.isEmpty)
        #expect(await provider.currentMessageSearchUsers().isEmpty)
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `ready supplemental admits only lazy private channel recipients in payload order`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "9", username: "hydration", globalName: "Hydration"),
                    user(id: "3", username: "third", globalName: "Third"),
                    user(id: "2", username: "second", globalName: "Second"),
                ]),
                "lazy_private_channels": .array([
                    .object([
                        "id": .string("41"),
                        "type": .number(3),
                        "recipients": .array([
                            user(id: "3", username: "third", globalName: "Third"),
                            user(id: "2", username: "second", globalName: "Second"),
                        ]),
                    ])
                ]),
            ])
        )

        #expect(await provider.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 3), UserID(rawValue: 2),
        ])
        #expect(await provider.currentMessageSearchUsers().map(\.id) == [
            UserID(rawValue: 3), UserID(rawValue: 2),
        ])
        await provider.disconnect()
    }

    @Test func `message updates an existing forwarding user without a REST lookup`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "before", globalName: "Before")
                ]),
            ])
        )
        let events = await provider.eventStream()
        let published = Task { () -> [User]? in
            for await event in events {
                if case let .knownUsersChanged(users) = event { return users }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1000"),
                "channel_id": .string("42"),
                "author": user(id: "2", username: "after", globalName: "After"),
                "content": .string("updated identity"),
                "timestamp": .string("2026-08-10T08:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )

        let users = try #require(await published.value)
        let updated = try #require(users.first { $0.id == UserID(rawValue: 2) })
        #expect(updated.username == "after")
        #expect(updated.displayName == "After")
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `message learned forwarding people survive a provider relaunch`() async throws {
        DirectMessageURLProtocol.reset()
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "forward-search-people-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        await seedForwardSearchPeopleCache(at: cacheDirectory)

        let second = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await second.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await second.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner"),
                "users": .array([
                    user(id: "3", username: "ready", globalName: "Ready User")
                ]),
            ])
        )

        #expect(await second.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 1),
            UserID(rawValue: 3),
        ])
        #expect(await second.currentQuickSwitcherUsers().map(\.id) == [
            UserID(rawValue: 1), UserID(rawValue: 3),
        ])
        let reloadedMemberships = await second.currentQuickSwitcherGuildMemberUserIDs()
        #expect(reloadedMemberships[GuildID(rawValue: 7)] == nil)
        #expect(
            await second.currentQuickSwitcherGuildMemberAliases()[GuildID(rawValue: 7)]
                == nil
        )
        #expect(
            await second.currentUserSearchAliasesByUserID()[UserID(rawValue: 2)]
                == ["Current nickname"]
        )

        await seedLiveForwardSearchUsers(on: second)

        #expect(await second.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 1),
            UserID(rawValue: 3),
            UserID(rawValue: 2),
            UserID(rawValue: 4),
        ])
        #expect(await second.currentQuickSwitcherUsers().map(\.id) == [
            UserID(rawValue: 1), UserID(rawValue: 3),
            UserID(rawValue: 2), UserID(rawValue: 4),
        ])
        let reloadedAliases = await second.currentUserSearchAliasesByUserID()
        #expect(reloadedAliases[UserID(rawValue: 2)] == [
            "Ready nickname", "Current nickname",
        ])
        #expect(
            await second.currentUserSearchAliasesByUserID()[UserID(rawValue: 4)]
                == nil
        )
        let liveMessageMemberships = await second.currentQuickSwitcherGuildMemberUserIDs()
        #expect(liveMessageMemberships[GuildID(rawValue: 6)] == [
            UserID(rawValue: 2), UserID(rawValue: 4),
        ])
        #expect(
            await second.currentQuickSwitcherGuildMemberAliases()[GuildID(rawValue: 8)]
                == [UserID(rawValue: 2): "Ready nickname"]
        )
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await second.disconnect()
    }

    @Test func `quick switcher channel store order survives Ready reconciliation`() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "quick-switcher-channel-store-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let first = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await first.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await first.reconcileQuickSwitcherChannelStoreOrder(with: [
            ChannelID(rawValue: 3), ChannelID(rawValue: 1), ChannelID(rawValue: 2),
        ])
        await first.persistQuickSwitcherChannelStoreCache()

        let second = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await second.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await second.loadQuickSwitcherChannelStoreCache()
        await second.reconcileQuickSwitcherChannelStoreOrder(with: [
            ChannelID(rawValue: 2), ChannelID(rawValue: 3),
            ChannelID(rawValue: 4), ChannelID(rawValue: 1),
        ])

        #expect(await second.cachedForwardChannelStoreOrder == [
            ChannelID(rawValue: 3), ChannelID(rawValue: 1),
            ChannelID(rawValue: 2), ChannelID(rawValue: 4),
        ])
        await first.disconnect()
        await second.disconnect()
    }

    @Test func `ready supplemental resolves recipients referenced by Ready private channels`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner"),
                "users": .array([]),
                "private_channels": .array([
                    .object([
                        "id": .string("41"),
                        "type": .number(3),
                        "name": .string(""),
                        "owner_id": .string("1"),
                        "recipient_ids": .array([.string("2")]),
                    ])
                ]),
            ])
        )
        #expect(await provider.cachedPrivateChannelsForTesting().first?.recipients.isEmpty == true)

        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "later-user", globalName: "Later User")
                ]),
            ])
        )

        let channel = try #require(await provider.cachedPrivateChannelsForTesting().first)
        #expect(channel.recipients.map(\.id) == [UserID(rawValue: 2)])
        #expect(channel.name == "Later User")
        #expect(await provider.currentMessageSearchUsers().map(\.id) == [
            UserID(rawValue: 1), UserID(rawValue: 2),
        ])
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `private recipient ordering matches Discords JavaScript snowflake sorter`() {
        let input = [
            "1000000000000000123",
            "1100000000000000456",
            "1200000000000000789",
            "1300000000000000111",
            "1400000000000000222",
        ]

        #expect(
            DiscordPrivateRecipientOrdering.sortedIDs(
                input,
                channelID: "1500000000000000123",
                channelType: 3
            ) == [
                "1300000000000000111",
                "1000000000000000123",
                "1200000000000000789",
                "1400000000000000222",
                "1100000000000000456",
            ]
        )
    }

    @Test func `ready excludes blocked and ignored users from forwarding search`() async throws {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner"),
                "relationships": .array([
                    .object([
                        "id": .string("7"),
                        "type": .number(2),
                        "user": user(id: "7", username: "blocked", globalName: "Blocked"),
                    ]),
                    .object([
                        "id": .string("8"),
                        "type": .number(3),
                        "user_ignored": .bool(true),
                        "user": user(id: "8", username: "ignored", globalName: "Ignored"),
                    ]),
                    .object([
                        "id": .string("9"),
                        "type": .number(1),
                        "user": user(id: "9", username: "friend", globalName: "Friend"),
                    ]),
                ]),
            ])
        )

        let users = await provider.currentKnownUsers()
        #expect(users.contains { $0.id == UserID(rawValue: 9) })
        #expect(!users.contains { $0.id == UserID(rawValue: 7) })
        #expect(!users.contains { $0.id == UserID(rawValue: 8) })
        let quickSwitcherUsers = await provider.currentQuickSwitcherUsers()
        #expect(quickSwitcherUsers.contains { $0.id == UserID(rawValue: 7) })
        #expect(quickSwitcherUsers.contains { $0.id == UserID(rawValue: 8) })
        #expect(quickSwitcherUsers.contains { $0.id == UserID(rawValue: 9) })
        await provider.disconnect()
    }

    @Test func `guild create members extend account wide forwarding users without REST`() async {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let events = await provider.eventStream()
        let publishedAliases = Task { () -> [UserID: [String]]? in
            for await event in events {
                if case let .userSearchAliasesChanged(aliases) = event {
                    return aliases
                }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("1"),
                "name": .string("Guild"),
                "members": .array([
                    .object([
                        "user": user(
                            id: "7",
                            username: "member-user",
                            globalName: "Member User"
                        ),
                        "nick": .string("Member nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )

        let users = await provider.currentKnownUsers()
        #expect(users.contains { $0.id == UserID(rawValue: 7) })
        let aliases = await publishedAliases.value
        #expect(aliases?[UserID(rawValue: 7)] == ["Member nickname"])
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `guild member chunks extend forwarding users without a REST lookup`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let events = await provider.eventStream()
        let published = Task { () -> [User]? in
            for await event in events {
                if case let .knownUsersChanged(users) = event { return users }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBERS_CHUNK",
            data: .object([
                "guild_id": .string("1"),
                "chunk_index": .number(0),
                "chunk_count": .number(1),
                "members": .array([
                    .object([
                        "user": user(
                            id: "8",
                            username: "chunk-user",
                            globalName: "Chunk User"
                        ),
                        "nick": .string("Chunk nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )

        let users = try #require(await published.value)
        #expect(users.contains { $0.id == UserID(rawValue: 8) })
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `member list updates do not extend forwarding user search`() async {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("1"),
                "name": .string("Guild"),
            ])
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: .object([
                "guild_id": .string("1"),
                "id": .string("everyone"),
                "ops": .array([
                    .object([
                        "op": .string("SYNC"),
                        "range": .array([.number(0), .number(0)]),
                        "items": .array([
                            .object([
                                "member": .object([
                                    "user": user(
                                        id: "10",
                                        username: "list-user",
                                        globalName: "List User"
                                    ),
                                    "nick": .string("List nickname"),
                                    "roles": .array([]),
                                ])
                            ])
                        ]),
                    ])
                ]),
            ])
        )

        #expect(!(await provider.currentKnownUsers()).contains {
            $0.id == UserID(rawValue: 10)
        })
        #expect(
            await provider.currentUserSearchAliasesByUserID()[UserID(rawValue: 10)]
                == ["List nickname"]
        )
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `empty group DM uses its owner display name like Discord`() async throws {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner Display"),
                "users": .array([]),
                "private_channels": .array([
                    .object([
                        "id": .string("41"),
                        "type": .number(3),
                        "name": .string(""),
                        "owner_id": .string("1"),
                        "recipient_ids": .array([]),
                        "last_message_id": .string("500"),
                    ])
                ]),
            ])
        )

        let channel = try #require(
            await provider.cachedPrivateChannelsForTesting().first
        )
        #expect(channel.kind == .groupDirectMessage)
        #expect(channel.name == "Owner Display's Group")
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

    @Test func `private call gateway events preserve rings participants and deletion`() async throws {
        let provider = makeProvider()
        let events = await provider.eventStream()
        let created = Task { () -> PrivateCall? in
            for await event in events {
                if case let .privateCallChanged(call) = event { return call }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "CALL_CREATE",
            data: .object([
                "channel_id": .string("41"),
                "message_id": .string("501"),
                "region": .string("rotterdam"),
                "ongoing_rings": .object([
                    "2": .string("1")
                ]),
                "voice_states": .array([
                    .object([
                        "user_id": .string("1"),
                        "channel_id": .string("41"),
                        "guild_id": .null,
                        "session_id": .string("private-session"),
                        "self_mute": .bool(false),
                        "self_deaf": .bool(false),
                    ])
                ]),
            ])
        )
        let call = try #require(await created.value)
        #expect(call.channelID == ChannelID(rawValue: 41))
        #expect(call.messageID == MessageID(rawValue: 501))
        #expect(call.region == "rotterdam")
        #expect(
            call.ongoingRings == [
                PrivateCallRing(
                    recipientID: UserID(rawValue: 2),
                    senderID: UserID(rawValue: 1)
                )
            ]
        )
        #expect(call.voiceStates?.first?.guildID == nil)
        #expect(call.voiceStates?.first?.channelID == ChannelID(rawValue: 41))

        let deleted = Task { () -> (ChannelID, Bool)? in
            for await event in events {
                if case let .privateCallDeleted(channelID, unavailable) = event {
                    return (channelID, unavailable)
                }
            }
            return nil
        }
        await provider.receiveGatewayDispatchForTesting(
            name: "CALL_DELETE",
            data: .object([
                "channel_id": .string("41"),
                "unavailable": .bool(true),
            ])
        )
        let deletion = try #require(await deleted.value)
        #expect(deletion.0 == ChannelID(rawValue: 41))
        #expect(deletion.1)
        await provider.disconnect()
    }

    @Test func `guildless voice move evicts the participant from the previous call`() async throws {
        try await assertGuildlessVoiceMoveReconciliation(
            provider: makeProvider()
        )
    }

    @Test func `private call REST paths use exact bounded bodies`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        #expect(
            try await provider.privateCallIsRingable(
                channelID: ChannelID(rawValue: 41)
            )
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "CALL_CREATE",
            data: .object([
                "channel_id": .string("41"),
                "message_id": .string("501"),
                "ongoing_rings": .object([:]),
            ])
        )
        try await provider.ringPrivateCall(
            channelID: ChannelID(rawValue: 41),
            recipients: nil
        )
        try await provider.stopRingingPrivateCall(
            channelID: ChannelID(rawValue: 41),
            recipients: [UserID(rawValue: 1)]
        )

        #expect(DirectMessageURLProtocol.requests.map(\.method) == [
            "GET", "POST", "POST",
        ])
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/channels/41/call",
            "/api/v9/channels/41/call/ring",
            "/api/v9/channels/41/call/stop-ringing",
        ])
        #expect(
            DirectMessageURLProtocol.requests[1].body?["recipients"] is NSNull
        )
        #expect(
            DirectMessageURLProtocol.requests[2].body?["recipients"] as? [String]
                == ["1"]
        )

        DirectMessageURLProtocol.ringStatus = 429
        await #expect(throws: ChatProviderError.self) {
            try await provider.ringPrivateCall(
                channelID: ChannelID(rawValue: 41),
                recipients: nil
            )
        }
        #expect(
            DirectMessageURLProtocol.requests.count {
                $0.path == "/api/v9/channels/41/call/ring"
            } == 2
        )
        await provider.disconnect()
    }

    @Test func `private call connect uses current gateway opcode`() throws {
        let payload = DiscordGatewayPayloadFactory.privateCallConnect(
            channelID: ChannelID(rawValue: 41)
        )
        #expect(payload["op"] as? Int == 13)
        let body = try #require(payload["d"] as? [String: Any])
        #expect(body["channel_id"] as? String == "41")
    }

    @Test func `private call subscriptions reset after Gateway resume`() async {
        let provider = makeProvider()
        let channelID = ChannelID(rawValue: 41)
        await provider.seedPrivateCallSubscriptionForTesting(channelID: channelID)
        #expect(await provider.hasPrivateCallSubscriptionForTesting(channelID: channelID))

        await provider.receiveGatewayDispatchForTesting(
            name: "RESUMED",
            data: .object([:])
        )

        #expect(!(await provider.hasPrivateCallSubscriptionForTesting(channelID: channelID)))
        await provider.disconnect()
    }

    private func seedPrivateChannelOrderReady(on provider: DiscordRESTProvider) async {
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
    }

    private func seedForwardSearchPeopleCache(at cacheDirectory: URL) async {
        let provider = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await provider.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("7"),
                "name": .string("Cached guild"),
                "members": .array([
                    .object([
                        "user": user(id: "2", username: "cached", globalName: "Cached User"),
                        "nick": .string("Current nickname"),
                        "roles": .array([]),
                    ]),
                    .object([
                        "user": user(id: "5", username: "live-only", globalName: "Live Only"),
                        "nick": .string("Live nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1000"),
                "channel_id": .string("42"),
                "guild_id": .string("7"),
                "author": user(id: "2", username: "cached", globalName: "Cached User"),
                "member": .object([
                    "nick": .string("Historical nickname"),
                    "roles": .array([]),
                ]),
                "content": .string("cache me"),
                "timestamp": .string("2026-08-10T08:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
        await provider.disconnect()
    }

    private func seedLiveForwardSearchUsers(on provider: DiscordRESTProvider) async {
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("8"),
                "name": .string("Ready guild"),
                "members": .array([
                    .object([
                        "user": user(id: "2", username: "cached", globalName: "Cached User"),
                        "nick": .string("Ready nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1001"),
                "channel_id": .string("43"),
                "guild_id": .string("6"),
                "author": user(id: "4", username: "later", globalName: "Later User"),
                "member": .object([
                    "nick": .string("Later nickname"),
                    "roles": .array([]),
                ]),
                "mentions": .array([
                    user(id: "2", username: "cached", globalName: "Cached User")
                ]),
                "content": .string("learn after Ready"),
                "timestamp": .string("2026-08-10T08:01:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1002"),
                "channel_id": .string("43"),
                "guild_id": .string("6"),
                "author": user(id: "2", username: "cached", globalName: "Cached User"),
                "member": .object([
                    "nick": .string("Later guild nickname"),
                    "roles": .array([]),
                ]),
                "content": .string("learn a later guild alias"),
                "timestamp": .string("2026-08-10T08:02:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
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

    private func makeProvider(
        usesForwardSearchPeopleDiskCache: Bool? = nil
    ) -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectMessageURLProtocol.self]
        return DiscordRESTProvider(
            credentials: DirectMessageCredentialStore(),
            handle: CredentialHandle(accountID: "dm-contract"),
            session: URLSession(configuration: configuration),
            usesForwardSearchPeopleDiskCache: usesForwardSearchPeopleDiskCache
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
    #expect(calls[1].voiceStates?.first?.sessionID == "private-session-b")
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

private struct CapturedDirectMessageRequest: @unchecked Sendable {
    var method: String
    var path: String
    var query: [CapturedQueryItem]
    var hadAuthorization: Bool
    var body: [String: Any]?
}

private final class DirectMessageURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    nonisolated(unsafe) static var requests:
        [CapturedDirectMessageRequest] = []
    nonisolated(unsafe) static var ringStatus = 204
    nonisolated(unsafe) static var profileHasEffect = false

    static func reset() {
        requests = []
        ringStatus = 204
        profileHasEffect = false
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
                    ) != nil,
                body: Self.requestBody(request).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
            )
        )

        let body: String
        switch request.url?.path {
        case "/api/v9/channels/41/messages":
            body = #"""
            [{
              "id":"800","channel_id":"41",
              "author":{"id":"77","username":"history-author","global_name":"History Author"},
              "content":"history","timestamp":"2026-07-29T08:00:00.000Z",
              "mentions":[{"id":"78","username":"history-mention","global_name":"History Mention"}],
              "attachments":[],"reactions":[]
            }]
            """#
        case "/api/v9/users/2/profile":
            body = Self.profileHasEffect
                ? #"""
                {
                  "user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},
                  "user_profile":{"profile_effect":{"sku_id":"900"}},
                  "mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0
                }
                """#
                : #"{"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0}"#
        case "/api/v9/collectibles-products/900":
            body = #"{"items":[{"type":1,"sku_id":"900","title":"Aurora","effects":[] }]}"#
        case "/api/v9/channels/41/call":
            body = #"{"ringable":true}"#
        default:
            body = "{}"
        }
        let status =
            request.url?.path == "/api/v9/channels/41/call/ring"
            ? Self.ringStatus : 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
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
