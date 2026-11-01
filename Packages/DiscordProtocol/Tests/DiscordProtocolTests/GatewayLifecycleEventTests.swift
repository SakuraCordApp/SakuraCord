@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Suite(.serialized)
struct GatewayLifecycleEventTests {
    private let guildID = GuildID(rawValue: 100)
    private let textChannelID = ChannelID(rawValue: 200)
    private let forumChannelID = ChannelID(rawValue: 201)
    private let voiceChannelID = ChannelID(rawValue: 202)
    private let currentUserID = UserID(rawValue: 1)

    @Test func `thread-shaped channel dispatch stays out of guild channels`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )

        let threadID = ChannelID(rawValue: 250)
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: channel(
                id: threadID.description,
                type: 11,
                name: "Loose forum post",
                parentID: forumChannelID.description
            )
        )

        #expect(await provider.cachedChannelForTesting(channelID: threadID) == nil)
        #expect(
            await provider.cachedForumPostForTesting(threadID: threadID)?.thread.parentID
                == forumChannelID
        )
    }

    @Test(arguments: [
        (#"[{"id":"1","name":"Bug"},{"id":2,"name":null},"tag"]"#, ["Bug"]),
        (#"{"unexpected":"object"}"#, []),
    ])
    func `forum keeps its channel despite malformed metadata and thread records stay out`(
        tags: String, expectedNames: [String]
    ) throws {
        let data = Data(
            #"""
            [
              {
                "id":"201","guild_id":"100","type":15,"name":"forum",
                "available_tags":\#(tags),
                "default_reaction_emoji":"🌸",
                "default_sort_order":"latest",
                "default_forum_layout":{},
                "default_tag_setting":7
              },
              {
                "id":"250","guild_id":"100","type":11,
                "name":"Loose forum post","parent_id":"201"
              }
            ]
            """#.utf8
        )
        let values = try JSONDecoder().decode([ChannelDTO].self, from: data)

        let channels = try DiscordRESTProvider.domainChannels(values, guildID: guildID)

        #expect(channels.map(\.id) == [forumChannelID])
        #expect(channels.first?.availableTags.map(\.name) == expectedNames)
        #expect(channels.first?.defaultReaction == nil)
    }

    @Test func `user and role updates keep the guild nickname and strip deleted roles`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "user": user(id: "1", username: "before", globalName: "Before"),
                "guilds": .array([]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "before", globalName: "Before"),
                "nick": .string("Guild Nick"),
                "roles": .array([.string("101")]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "USER_UPDATE",
            data: user(id: "1", username: "after", globalName: "After")
        )
        let member = await provider.cachedMembersForTesting(guildID: guildID).first
        #expect(member?.user.displayName == "Guild Nick")
        #expect(member?.globalDisplayName == "After")

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_DELETE",
            data: .object(["guild_id": .string("100"), "role_id": .string("101")])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.roleIDs.isEmpty == true)
    }

    @Test func `guild unavailable differs from leaving`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: guildCreatePayload())

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE",
            data: .object(["id": .string("100"), "unavailable": .bool(true)])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.isUnavailable == true)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.isUnavailable == false)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE",
            data: .object(["id": .string("100")])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID) == nil)
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) == nil)
    }

    @Test func `a server joined mid-session keeps the join time GUILD_CREATE carries`() async throws {
        let provider = makeProvider()
        guard case var .object(payload) = guildCreatePayload() else { return }
        payload["joined_at"] = .string("2026-10-26T15:05:52.000000+00:00")
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: .object(payload))
        let joinedAt = try #require(await provider.cachedGuildForTesting(guildID: guildID)?.joinedAt)
        #expect(joinedAt == DiscordDate.parse("2026-10-26T15:05:52.000000+00:00"))

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_UPDATE",
            data: .object(["id": .string("100"), "name": .string("Renamed")])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.joinedAt == joinedAt)
    }

    @Test func `permission scoped member lists remain isolated when revisited`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "user": user(id: "1", username: "current", globalName: "Current"),
                "guilds": .array([]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE", data: guildCreatePayload()
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(
                id: "everyone", userIDs: ["1", "2", "3"], groupCount: 3
            )
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(
                id: "restricted", userIDs: ["1"], groupCount: 1
            )
        )

        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: "restricted"
        ) == [UserID(rawValue: 1)])
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: "everyone"
        ) == [UserID(rawValue: 1), UserID(rawValue: 2), UserID(rawValue: 3)])
        #expect(await provider.memberListGroupsForTesting(
            guildID: guildID, memberListID: "restricted"
        ).map(\.count) == [1])
        #expect(await provider.memberListGroupsForTesting(
            guildID: guildID, memberListID: "everyone"
        ).map(\.count) == [3])
    }

    @Test func `INVALIDATE keeps rows and renews only the selected member list`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(
                id: memberListID, userIDs: ["1", "2", "3"], groupCount: 3, range: 0 ... 99
            )
        )
        let subscriptionSends = await socket.sentPayloadCount(opcode: 37)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE", data: memberListInvalidation(id: memberListID)
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == subscriptionSends + 1)
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ) == [UserID(rawValue: 1), UserID(rawValue: 2), UserID(rawValue: 3)])

        var otherChannel = try #require(await provider.cachedChannelForTesting(channelID: forumChannelID))
        otherChannel.memberListID = "other-list"
        await provider.seedGuildChannelForTesting(otherChannel)
        try await provider.subscribeToMemberList(guildID: guildID, channelID: forumChannelID)
        let beforeUnselectedInvalidation = await socket.sentPayloadCount(opcode: 37)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE", data: memberListInvalidation(id: memberListID)
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == beforeUnselectedInvalidation)
        try await provider.updateMemberListViewport(
            in: guildID, channelID: textChannelID, visibleRange: 0 ... 10
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == beforeUnselectedInvalidation + 1)
        await provider.disconnect()
    }

    @Test func `resumed member subscription preserves the selected channel and deep viewport`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        // Both channels share a list, so the resumed send replaces its ranges.
        try await provider.updateMemberListViewport(
            in: guildID, channelID: forumChannelID, visibleRange: 150 ... 169
        )
        let sends = await socket.sentPayloadCount(opcode: 37)

        await provider.handleGatewaySessionEvent(.stateChanged(.disconnected))
        await socket.push(gatewayMessage(
            op: 0, data: .object([:]), sequence: 2, eventName: "RESUMED"
        ))
        #expect(await eventually {
            await socket.sentPayloadCount(opcode: 37) == sends + 1
        })
        let payloads = await socket.sentPayloads
        let latest = try #require(payloads.last { data in
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (payload?["op"] as? NSNumber)?.intValue == 37
        })
        let payload = try #require(try JSONSerialization.jsonObject(with: latest) as? [String: Any])
        let body = try #require(payload["d"] as? [String: Any])
        let subscriptions = try #require(body["subscriptions"] as? [String: Any])
        let guild = try #require(subscriptions[guildID.description] as? [String: Any])
        let channels = try #require(guild["channels"] as? [String: [[Int]]])
        #expect(channels[forumChannelID.description] == [[0, 99], [100, 199]])
        await provider.disconnect()
    }

    @Test func `concurrent member subscriptions preserve the latest ranges and thread selection`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 199]
            )
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let second = Task {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 299]
            )
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
        let secondID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let thread = Task {
            try await provider.threadMembers(in: MessageThreadSummary(
                id: ChannelID(rawValue: 400), guildID: guildID,
                parentID: textChannelID, name: "Fixture Thread"
            ))
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: secondID)
        await socket.releaseHeldSend()
        try await first.value
        try await second.value
        _ = try await thread.value
        let sentPayloads = await socket.sentPayloads
        let bodies = sentPayloads.compactMap { data -> [String: Any]? in
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["op"] as? NSNumber)?.intValue == 37,
                  let body = payload["d"] as? [String: Any],
                  let subscriptions = body["subscriptions"] as? [String: Any]
            else { return nil }
            return subscriptions["100"] as? [String: Any]
        }
        let latestFull = try #require(bodies.last { $0["channels"] != nil })
        #expect((latestFull["channels"] as? [String: [[Int]]])?["200"] == [[0, 299]])
        #expect(latestFull["thread_member_lists"] as? [String] == ["400"])
        #expect(bodies.last?["thread_member_lists"] as? [String] == ["400"])
        await provider.disconnect()
    }

    @Test func `member SYNC received before subscription completion is published after commit`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        var channel = try #require(await provider.cachedChannelForTesting(channelID: forumChannelID))
        channel.memberListID = "early-sync"
        await provider.seedGuildChannelForTesting(channel)
        let events = await provider.eventStream()
        await socket.holdNextSend(opcode: 37)
        let subscription = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: forumChannelID)
        }
        await socket.waitForHeldSend()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: "early-sync", userIDs: ["2", "3"], groupCount: 2)
        )
        await socket.releaseHeldSend()
        try await subscription.value
        await provider.disconnect()
        var publishedMemberIDs: [[UserID]] = []
        for await event in events {
            if case let .membersChanged(eventGuildID, members, _) = event,
               eventGuildID == guildID {
                publishedMemberIDs.append(members.map(\.id))
            }
        }
        #expect(publishedMemberIDs.last == [UserID(rawValue: 2), UserID(rawValue: 3)])
    }

    @Test(arguments: ["INVALIDATE", "RATE_LIMITED"])
    func `member-list recovery includes the first subscription before it commits`(eventName: String) async throws {
        let fixture = try await makeMemberListProvider(subscribeInitially: false)
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID)
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3"], groupCount: 2)
        )
        let sends = await socket.sentPayloadCount(opcode: 37)
        if eventName == "INVALIDATE" {
            let invalidation = Task {
                await provider.receiveGatewayDispatchForTesting(
                    name: "GUILD_MEMBER_LIST_UPDATE", data: memberListInvalidation(id: memberListID)
                )
            }
            await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
            #expect(await provider.orderedMemberListIDsForTesting(
                guildID: guildID, memberListID: memberListID
            ) == [UserID(rawValue: 2), UserID(rawValue: 3)])
            await socket.releaseHeldSend()
            try await first.value
            await invalidation.value
        } else {
            // No guild metadata: include requested guilds even when the
            // committed subscription map is still empty.
            await provider.receiveGatewayDispatchForTesting(
                name: "RATE_LIMITED",
                data: .object(["opcode": .number(37), "retry_after": .number(60)])
            )
            let refresh = try #require(await provider.memberListsNeedingRefresh[guildID]?[memberListID])
            await socket.releaseHeldSend()
            try await first.value
            #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == refresh)
            #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
        }
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        #expect(await provider.orderedMemberListIDsForTesting(
            guildID: guildID, memberListID: memberListID
        ) == [UserID(rawValue: 2), UserID(rawValue: 3)])
        await provider.disconnect()
    }

    @Test(arguments: [true, false])
    func `role access loss discards retained member rows`(
        initiallySubscribed: Bool
    ) async throws {
        let fixture = try await makeMemberListProvider(
            subscribeInitially: initiallySubscribed
        )
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        var selectedChannel = try #require(await provider.cachedChannelForTesting(channelID: textChannelID))
        selectedChannel.permissionOverwrites = []
        selectedChannel.memberListID = memberListID
        await provider.seedGuildChannelForTesting(selectedChannel)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "role": .object([
                    "id": .string("100"), "name": .string("@everyone"),
                    "position": .number(0), "hoist": .bool(false), "permissions": .string("0"),
                ]),
            ])
        )
        #expect(await provider.isMemberListAccessible(guildID: guildID, memberListID: memberListID)
            == initiallySubscribed)
        await socket.holdNextSend(opcode: 37)
        let earlierSubscription = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID)
        }
        await socket.waitForHeldSend()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3", "4"], groupCount: 3)
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "fixture", globalName: "Fixture"),
                "roles": .array([]),
            ])
        )
        #expect(await provider.isMemberListAccessible(guildID: guildID, memberListID: memberListID) == false)
        #expect(await provider.orderedMemberListIDsForTesting(guildID: guildID, memberListID: memberListID).isEmpty)
        #expect(try await provider.members(in: guildID).isEmpty)
        await socket.releaseHeldSend()
        await #expect(throws: CancellationError.self) {
            try await earlierSubscription.value
        }
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID] == nil)
        await provider.disconnect()
    }

    @Test(arguments: [false, true])
    func `desktop guild create with numeric or nested properties adds a new guild`(nested: Bool) async {
        let provider = makeProvider()

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: nested ? desktopGuildCreatePayload() : guildCreatePayload(permissions: .number(1_024))
        )

        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Lifecycle Guild")
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.currentUserPermissions == 1_024)
        #expect(await provider.cachedGuildRailItemsForTesting() == [.guild(guildID)])
    }

    @Test func `partial desktop guild create preserves the existing catalog`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload()
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("100"),
                "data_mode": .string("partial"),
                "properties": .object([
                    "name": .string("Recovered Guild"),
                    "permissions": .number(2_048),
                ]),
            ])
        )

        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Recovered Guild")
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.currentUserPermissions == 2_048)
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) != nil)
    }

    private func makeProvider(
        session: URLSession = URLSession(configuration: .ephemeral)
    ) -> DiscordRESTProvider {
        DiscordRESTProvider(
            credentials: GatewayLifecycleCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: session
        )
    }

    private struct MemberListFixture {
        let provider: DiscordRESTProvider
        let socket: ReadyGatewaySocket
        let memberListID: String
    }

    private func makeMemberListProvider(
        subscribeInitially: Bool = true
    ) async throws -> MemberListFixture {
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(op: 10, data: .object(["heartbeat_interval": .number(60_000)])))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("invalidate-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
            ]),
            sequence: 1, eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: .init(accountID: "1"),
            session: URLSession(configuration: .ephemeral),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            installationID: "fixture"
        )
        try await provider.startGateway()
        #expect(await eventually {
            await provider.gatewayReady
        })
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE", data: guildCreatePayload()
        )
        await provider.seedPrivateChannelsForTesting([], currentUser: User(
            id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture"
        ))
        await provider.setPendingMemberGuildForTesting(guildID)
        if subscribeInitially {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 99]
            )
        }
        let channel = try #require(await provider.cachedChannelForTesting(channelID: textChannelID))
        let roles = await provider.cachedGuildRoles[guildID] ?? []
        let memberListID = DiscordMemberListIdentity.id(for: channel, guildID: guildID, roles: roles)
        return MemberListFixture(provider: provider, socket: socket, memberListID: memberListID)
    }

    private func memberListInvalidation(id: String, range: ClosedRange<Int> = 0 ... 99) -> JSONValue {
        .object([
            "guild_id": .string("100"), "id": .string(id),
            "ops": .array([.object([
                "op": .string("INVALIDATE"),
                "range": .array([.number(Double(range.lowerBound)), .number(Double(range.upperBound))]),
            ])]),
        ])
    }

    private func guildCreatePayload(
        includesUnavailable: Bool = true,
        permissions: JSONValue = .string("1024")
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string("100"), "name": .string("Lifecycle Guild"),
            "permissions": permissions,
            "channels": .array([
                channel(id: "299", type: 4, name: "Info", position: 0),
                channel(
                    id: "200", type: 0, name: "general", parentID: "299",
                    overwrites: [["id": .string("100"), "type": .number(0),
                                  "allow": .string("1024"), "deny": .string("0")]]
                ),
                channel(id: "201", type: 15, name: "forum", position: 2),
                channel(id: "202", type: 2, name: "Voice", position: 3),
            ]),
            "roles": .array([
                role(id: "100", name: "@everyone", position: 0, hoist: false),
                role(id: "101", name: "Reader", position: 2, hoist: true),
            ]),
            "members": .array([
                .object([
                    "user": user(id: "1", username: "before", globalName: "Before"),
                    "roles": .array([.string("101")]),
                ])
            ]),
            "threads": .array([]), "voice_states": .array([]), "emojis": .array([]),
        ]
        if includesUnavailable { payload["unavailable"] = .bool(false) }
        return .object(payload)
    }

    private func desktopGuildCreatePayload() -> JSONValue {
        guard case .object(var payload) = guildCreatePayload() else {
            preconditionFailure("The Guild Create fixture must remain an object.")
        }
        payload["name"] = nil
        payload["permissions"] = nil
        payload["data_mode"] = .string("full")
        payload["properties"] = .object([
            "name": .string("Lifecycle Guild"),
            "permissions": .number(1_024),
        ])
        return .object(payload)
    }

    private func channel(
        id: String, type: Int, name: String, parentID: String? = nil,
        position: Int = 1, overwrites: [[String: JSONValue]] = []
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "guild_id": .string("100"),
            "type": .number(Double(type)), "name": .string(name),
            "position": .number(Double(position)),
            "permission_overwrites": .array(overwrites.map(JSONValue.object)),
        ]
        if let parentID { value["parent_id"] = .string(parentID) }
        return .object(value)
    }

    private func role(id: String, name: String, position: Int, hoist: Bool) -> JSONValue {
        .object([
            "id": .string(id), "name": .string(name),
            "position": .number(Double(position)), "hoist": .bool(hoist),
            "permissions": .string("1024"),
        ])
    }

    private func memberListUpdate(
        id: String, userIDs: [String], groupCount: Int, range: ClosedRange<Int>? = nil
    ) -> JSONValue {
        .object([
            "guild_id": .string("100"),
            "id": .string(id),
            "groups": .array([
                .object(["id": .string("online"), "count": .number(Double(groupCount))])
            ]),
            "ops": .array([
                .object([
                    "op": .string("SYNC"),
                    "range": .array([
                        .number(Double(range?.lowerBound ?? 0)),
                        .number(Double(range?.upperBound ?? max(0, userIDs.count - 1))),
                    ]),
                    "items": .array(userIDs.map { userID in
                        .object([
                            "member": .object([
                                "user": user(
                                    id: userID,
                                    username: "member-\(userID)",
                                    globalName: "Member \(userID)"
                                ),
                                "roles": .array([]),
                            ])
                        ])
                    }),
                ])
            ]),
        ])
    }

    private func user(id: String, username: String, globalName: String) -> JSONValue {
        .object([
            "id": .string(id), "username": .string(username),
            "global_name": .string(globalName),
        ])
    }
}

private actor GatewayLifecycleCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("unused".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private final class GatewayDispatchCountingURLProtocol: URLProtocol, @unchecked Sendable {
    static let requestCount = Mutex(0)

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount.withLock { $0 += 1 }
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.dataNotAllowed)
        )
    }

    override func stopLoading() {}
}

extension GatewayLifecycleEventTests {
    @Test(arguments: ["member-list", "chunk", "thread", "supplemental", "merged-supplemental"])
    func `sparse membership hydration preserves omitted timeout and publishes explicit changes`(source: String) async throws {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "1", username: "before", globalName: "Before"), "guilds": .array([]),
        ]))
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: guildCreatePayload(includesUnavailable: false))
        let events = await provider.eventStream()
        let until = Date.now.addingTimeInterval(300).ISO8601Format()
        let expiry = try #require(DiscordDate.parse(until))

        func deliver(_ timeout: JSONValue?) async throws {
            var member: [String: JSONValue] = [
                "user": user(id: "1", username: "before", globalName: "Before"),
                "roles": .array([.string("101")]),
            ]
            member["communication_disabled_until"] = timeout
            switch source {
            case "member-list":
                await provider.receiveGatewayDispatchForTesting(name: "GUILD_MEMBER_LIST_UPDATE", data: .object([
                    "guild_id": .string("100"), "id": .string("everyone"),
                    "ops": .array([.object([
                        "op": .string("SYNC"), "range": .array([.number(0), .number(0)]),
                        "items": .array([.object(["member": .object(member)])]),
                    ])]),
                ]))
            case "chunk":
                await provider.receiveGatewayDispatchForTesting(name: "GUILD_MEMBERS_CHUNK", data: .object([
                    "guild_id": .string("100"), "members": .array([.object(member)]),
                    "chunk_index": .number(0), "chunk_count": .number(1),
                ]))
            case "thread":
                let entry = try JSONValueDecoder().decode(ThreadMemberDTO.self, from: .object([
                    "user_id": .string("1"), "member": .object(member),
                ]))
                await provider.ingestThreadMembers([entry], guildID: guildID)
            case "merged-supplemental":
                member["user"] = nil
                member["user_id"] = .string("1")
                await provider.receiveGatewayDispatchForTesting(name: "READY_SUPPLEMENTAL", data: .object([
                    "guilds": .array([.object(["id": .string("100")])]),
                    "merged_members": .array([.array([.object(member)])]),
                ]))
            default:
                await provider.receiveGatewayDispatchForTesting(name: "READY_SUPPLEMENTAL", data: .object([
                    "guilds": .array([.object(["id": .string("100"), "members": .array([.object(member)])])]),
                ]))
            }
        }

        try await deliver(.string(until))
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.communicationDisabledUntil == expiry)
        try await deliver(nil)
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.communicationDisabledUntil == expiry)
        try await deliver(.null)
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.communicationDisabledUntil == nil)
        try await deliver(.string(until))
        await provider.disconnect()
        var publishedTimeouts: [Date?] = []
        for await event in events {
            if case let .membersChanged(eventGuildID, members, _) = event,
               eventGuildID == guildID, let member = members.first(where: { $0.id == currentUserID }) {
                publishedTimeouts.append(member.communicationDisabledUntil)
            }
        }
        #expect(publishedTimeouts == [expiry, nil, expiry])
    }

    @Test func `dispatch reconciliation sends no HTTP requests`() async {
        GatewayDispatchCountingURLProtocol.requestCount.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayDispatchCountingURLProtocol.self]
        let provider = makeProvider(session: URLSession(configuration: configuration))
        let member = user(id: "2", username: "added", globalName: "Added")
        let dispatches: [(name: String, data: JSONValue)] = [
            ("READY", .object(["user": user(id: "1", username: "current", globalName: "Current"), "guilds": .array([])])),
            ("GUILD_CREATE", guildCreatePayload()),
            ("CHANNEL_CREATE", channel(id: "203", type: 0, name: "created")),
            ("CHANNEL_UPDATE", channel(id: "200", type: 0, name: "renamed")),
            ("GUILD_ROLE_CREATE", .object([
                "guild_id": .string("100"), "role": role(id: "102", name: "New", position: 1, hoist: true),
            ])),
            ("GUILD_MEMBER_ADD", .object(["guild_id": .string("100"), "user": member, "roles": .array([.string("102")])])),
            ("GUILD_MEMBER_UPDATE", .object([
                "guild_id": .string("100"), "user": member, "roles": .array([.string("101")]),
            ])),
            ("GUILD_MEMBERS_CHUNK", .object([
                "guild_id": .string("100"), "members": .array([.object(["user": member, "roles": .array([])])]),
                "chunk_index": .number(0), "chunk_count": .number(1),
            ])),
            ("GUILD_MEMBER_REMOVE", .object(["guild_id": .string("100"), "user": member])),
            ("GUILD_ROLE_DELETE", .object(["guild_id": .string("100"), "role_id": .string("102")])),
            ("USER_UPDATE", user(id: "1", username: "current", globalName: "Renamed")),
            ("GUILD_SCHEDULED_EVENT_UPDATE", .object([
                "id": .string("900"), "guild_id": .string("100"), "name": .string("Event"),
                "scheduled_start_time": .string(Date.now.addingTimeInterval(3600).ISO8601Format()), "status": .number(1),
            ])),
            ("GUILD_DELETE", .object(["id": .string("100")])),
        ]

        for dispatch in dispatches {
            await provider.receiveGatewayDispatchForTesting(name: dispatch.name, data: dispatch.data)
        }

        #expect(GatewayDispatchCountingURLProtocol.requestCount.withLock { $0 } == 0)
    }

    @Test func `timeout updates block sends locally and respect omission clear and expiry`() async throws {
        GatewayDispatchCountingURLProtocol.requestCount.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayDispatchCountingURLProtocol.self]
        let provider = makeProvider(session: URLSession(configuration: configuration))
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "1", username: "before", globalName: "Before"), "guilds": .array([]),
        ]))
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: guildCreatePayload(includesUnavailable: false))
        let until = Date.now.addingTimeInterval(300)
        var update: [String: JSONValue] = [
            "guild_id": .string("100"), "user": user(id: "1", username: "before", globalName: "Before"),
            "roles": .array([.string("101")]), "communication_disabled_until": .string(until.ISO8601Format()),
        ]
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_MEMBER_UPDATE", data: .object(update))
        let member = try #require(await provider.cachedMembersForTesting(guildID: guildID).first)
        let expiry = try #require(member.communicationDisabledUntil)
        await #expect(throws: ChatProviderError.self) {
            _ = try await provider.send(SendMessageDraft(channelID: textChannelID, content: "blocked", nonce: "timeout"))
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.requireCommunicationForRequest(path: "/channels/200/messages", method: "POST", body: nil)
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.setReaction("👍", reacted: false, messageID: .init(rawValue: 300), channelID: textChannelID)
        }
        await #expect(throws: ChatProviderError.self) {
            _ = try await provider.edit(messageID: .init(rawValue: 300), channelID: textChannelID, content: "blocked")
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.requireCommunicationForRequest(
                path: "/channels/200/messages/300", method: "PATCH", body: ["content": .string("blocked")]
            )
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.setPollAnswers([1], messageID: .init(rawValue: 300), channelID: textChannelID)
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.requireCommunicationForRequest(
                path: "/channels/200/polls/300/answers/@me", method: "PUT", body: ["answer_ids": .array([.number(1)])]
            )
        }
        // The shared voice boundary also covers deferred joins and later
        // voice-state changes, before any Gateway connection is required.
        await #expect(throws: ChatProviderError.invalidRequest("You are timed out in this server.")) {
            try await provider.updateVoiceState(
                channelID: voiceChannelID, guildID: guildID,
                selfMute: false, selfDeaf: false, selfVideo: false
            )
        }
        await #expect(throws: ChatProviderError.self) {
            try await provider.requireCommunicationForRequest(
                path: "/channels/\(voiceChannelID)/send-soundboard-sound", method: "POST", body: nil
            )
        }
        // Search results can identify an unjoined thread before any thread
        // metadata is cached. Its queued reactions must still be restricted.
        let searchThreadID = ChannelID(rawValue: 250)
        let searchMessage = Message(
            id: MessageID(rawValue: 350), channelID: searchThreadID,
            author: member.user, content: "Search result", guildID: guildID
        )
        await provider.seedMessageForTesting(searchMessage)
        await #expect(throws: ChatProviderError.self) {
            try await provider.requireCommunicationForRequest(
                path: "/channels/250/messages/350/reactions/%F0%9F%91%8D/@me", method: "PUT", body: nil
            )
        }
        #expect(GatewayDispatchCountingURLProtocol.requestCount.withLock { $0 } == 0)
        // A timeout must not block acknowledging, deleting or clearing a poll vote.
        try await provider.requireCommunicationForRequest(path: "/channels/200/messages/300/ack", method: "POST", body: nil)
        try await provider.requireCommunicationForRequest(path: "/channels/200/messages/300", method: "DELETE", body: nil)
        try await provider.requireCommunicationForRequest(
            path: "/channels/200/polls/300/answers/@me", method: "PUT", body: ["answer_ids": .array([])]
        )
        try await provider.requireGuildCommunication(in: textChannelID, now: expiry)
        // Unrelated sparse member updates must not restore communication.
        update["communication_disabled_until"] = nil
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_MEMBER_UPDATE", data: .object(update))
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.communicationDisabledUntil == expiry)
        update["communication_disabled_until"] = .null
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_MEMBER_UPDATE", data: .object(update))
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.communicationDisabledUntil == nil)
        await provider.disconnect()
    }

    @Test func `older sends preserve a newer invalidation and cooldown recovery is bounded`() async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        await socket.holdNextSend(opcode: 37)
        let first = Task {
            try await provider.subscribeToMemberList(
                guildID: guildID, channelID: textChannelID, ranges: [0 ... 199]
            )
        }
        await socket.waitForHeldSend()
        let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let invalidation = Task {
            await provider.receiveGatewayDispatchForTesting(
                name: "GUILD_MEMBER_LIST_UPDATE",
                data: memberListInvalidation(id: memberListID, range: 100 ... 199)
            )
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
        let rateLimit: JSONValue = .object([
            "opcode": .number(37), "retry_after": .number(60),
            "meta": .object(["guild_id": .string("100")]),
        ])
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: rateLimit)
        let refresh = try #require(await provider.memberListsNeedingRefresh[guildID]?[memberListID])
        await socket.releaseHeldSend()
        try await first.value
        await invalidation.value
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == refresh)
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateMemberListViewport(
                in: guildID, channelID: textChannelID, visibleRange: 500 ... 510
            )
        }
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID]?.ranges == [0 ... 199])
        let sends = await socket.sentPayloadCount(opcode: 37)
        // Advance the first cooldown, then block a normal send ahead of the
        // deferred refresh. A newer rejection arrives while it is queued.
        await provider.receiveGatewayDispatchForTesting(
            name: "RATE_LIMITED",
            data: .object(["opcode": .number(37), "retry_after": .number(0)])
        )
        await socket.holdNextSend(opcode: 37)
        let blockingSend = Task { try await provider.sendThreadMemberSubscription(guildID: guildID) }
        await socket.waitForHeldSend()
        let blockingID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let queuedRefresh = Task {
            await provider.runScheduledMemberListRefreshForTesting(guildID: guildID)
        }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: blockingID)
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: rateLimit)
        await socket.releaseHeldSend()
        try await blockingSend.value
        #expect(await queuedRefresh.value)
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
        #expect(await provider.memberListRefreshRetryAttempts[guildID]?.contains(memberListID) != true)
        #expect(await provider.memberListRefreshRetryTasks[guildID] != nil)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] != nil)
        #expect(await provider.runScheduledMemberListRefreshForTesting(guildID: guildID))
        #expect(await socket.sentPayloadCount(opcode: 37) == sends + 2)
        #expect(await provider.memberListSubscriptions[guildID]?[memberListID]?.ranges
            == [0 ... 99, 400 ... 499, 500 ... 599])
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] == nil)
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: rateLimit)
        #expect(await provider.memberListsNeedingRefresh[guildID]?[memberListID] != nil)
        #expect(await provider.memberListRefreshRetryTasks[guildID] == nil)
        await provider.disconnect()
    }

    @Test(arguments: [true, false])
    func `returning from an inaccessible viewport restores accessible member rows`(sharedList: Bool) async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let memberListID = fixture.memberListID
        let events = await provider.eventStream()
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: memberListUpdate(id: memberListID, userIDs: ["2", "3"], groupCount: 2)
        )
        let hiddenListID = sharedList ? memberListID : "hidden-list"
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object([
                "id": .string("201"), "guild_id": .string("100"), "type": .number(15),
                "name": .string("hidden"), "member_list_id": .string(hiddenListID),
                "permission_overwrites": .array([.object([
                    "id": .string("1"), "type": .number(1),
                    "allow": .string("0"), "deny": .string("1024"),
                ])]),
            ])
        )
        let sends = await socket.sentPayloadCount(opcode: 37)
        try await provider.updateMemberListViewport(
            in: guildID, channelID: forumChannelID, visibleRange: 0 ... 10
        )
        #expect(await socket.sentPayloadCount(opcode: 37) == sends)
        try await provider.updateMemberListViewport(
            in: guildID, channelID: textChannelID, visibleRange: 0 ... 10
        )
        if sharedList {
            // A hidden alias purges the shared cache. Returning must request
            // a fresh SYNC instead of relying on a native row callback.
            #expect(await socket.sentPayloadCount(opcode: 37) == sends + 1)
            await provider.receiveGatewayDispatchForTesting(
                name: "GUILD_MEMBER_LIST_UPDATE",
                data: memberListUpdate(id: memberListID, userIDs: ["2", "3"], groupCount: 2)
            )
        } else {
            #expect(await socket.sentPayloadCount(opcode: 37) == sends)
        }
        await provider.disconnect()
        var published: [[UserID]] = []
        for await event in events {
            if case let .membersChanged(eventGuildID, members, _) = event, eventGuildID == guildID {
                published.append(members.map(\.id))
            }
        }
        #expect(published.contains([]))
        #expect(published.last == [UserID(rawValue: 2), UserID(rawValue: 3)])
    }

    @Test(arguments: ["restore", "superseded", "closed"])
    func `member-only queue resets preserve a desired thread subscription`(outcome: String) async throws {
        let fixture = try await makeMemberListProvider()
        let (provider, socket) = (fixture.provider, fixture.socket)
        let thread = MessageThreadSummary(
            id: ChannelID(rawValue: 400), guildID: guildID, parentID: textChannelID, name: "Fixture Thread"
        )
        let events = await provider.eventStream()
        await socket.holdNextSend(opcode: 37)
        let viewport = Task {
            try await provider.subscribeToMemberList(guildID: guildID, channelID: textChannelID, ranges: [0 ... 199])
        }
        await socket.waitForHeldSend()
        let viewportID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
        let first = Task { try await provider.threadMembers(in: thread) }
        await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: viewportID)
        var successor: Task<[Member]?, any Error>?
        if outcome == "superseded" {
            let firstID = try #require(await provider.guildSubscriptionTaskIDs[guildID])
            successor = Task { try await provider.threadMembers(in: thread) }
            await provider.waitForNextGuildSubscriptionForTesting(guildID: guildID, after: firstID)
        }
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object([
                "id": .string("200"), "guild_id": .string("100"), "type": .number(0),
                "name": .string("general"), "member_list_id": .string("replacement-list"),
            ])
        )
        if outcome == "closed" { await provider.removeThreadMemberSubscription(thread.id) }
        await socket.releaseHeldSend()
        await #expect(throws: CancellationError.self) { try await viewport.value }
        let remainsDesired = outcome == "restore" || outcome == "superseded"
        if outcome == "restore" {
            #expect(try await first.value == nil)
        } else {
            await #expect(throws: CancellationError.self) { try await first.value }
        }
        if let successor { #expect(try await successor.value == nil) }
        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_MEMBER_LIST_UPDATE",
            data: .object([
                "guild_id": .string("100"), "thread_id": .string("400"),
                "members": .array([.object([
                    "user_id": .string("2"),
                    "member": .object(["user": user(id: "2", username: "member", globalName: "Member"),
                                       "roles": .array([])]),
                ])]),
            ])
        )
        #expect(await provider.resolvedThreadMembers(threadID: thread.id, guildID: guildID)?.map(\.id)
            == (remainsDesired ? [UserID(rawValue: 2)] : nil))
        await provider.disconnect()
        var published: [[UserID]] = []
        for await event in events {
            if case let .threadMembersChanged(eventGuildID, threadID, members) = event,
               eventGuildID == guildID, threadID == thread.id, let members {
                published.append(members.map(\.id))
            }
        }
        #expect(published.last == (remainsDesired ? [UserID(rawValue: 2)] : nil))
    }
}
