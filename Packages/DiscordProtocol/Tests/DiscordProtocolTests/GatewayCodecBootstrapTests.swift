@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `application stream keys payloads and dispatches match current gateway`() throws {
    let key = try #require(
        ApplicationStreamKey(rawValue: "guild:100:230:300")
    )
    #expect(key.type == .guild)
    #expect(key.guildID == GuildID(rawValue: 100))
    #expect(key.channelID == ChannelID(rawValue: 230))
    #expect(key.ownerID == UserID(rawValue: 300))
    #expect(key.rawValue == "guild:100:230:300")
    #expect(ApplicationStreamKey(rawValue: "guild:100:230") == nil)
    #expect(ApplicationStreamKey(rawValue: "call::300") == nil)

    let encodedKey = try JSONEncoder().encode(key)
    #expect(String(bytes: encodedKey, encoding: .utf8) == #""guild:100:230:300""#)
    #expect(try JSONDecoder().decode(ApplicationStreamKey.self, from: encodedKey) == key)

    let create = DiscordGatewayPayloadFactory.applicationStreamCreate(
        channelID: ChannelID(rawValue: 230),
        guildID: GuildID(rawValue: 100),
        preferredRegion: nil
    )
    #expect(create["op"] as? Int == 18)
    let createData = try #require(create["d"] as? [String: Any])
    #expect(createData["type"] as? String == "guild")
    #expect(createData["guild_id"] as? String == "100")
    #expect(createData["channel_id"] as? String == "230")
    #expect(createData["preferred_region"] is NSNull)

    let delete = DiscordGatewayPayloadFactory.applicationStreamDelete(key)
    #expect(delete["op"] as? Int == 19)
    #expect((delete["d"] as? [String: Any])?["stream_key"] as? String == key.rawValue)
    let watch = DiscordGatewayPayloadFactory.applicationStreamWatch(key)
    #expect(watch["op"] as? Int == 20)
    let ping = DiscordGatewayPayloadFactory.applicationStreamPing(key)
    #expect(ping["op"] as? Int == 21)
    let pause = DiscordGatewayPayloadFactory.applicationStreamSetPaused(
        key,
        isPaused: true
    )
    #expect(pause["op"] as? Int == 22)
    #expect((pause["d"] as? [String: Any])?["paused"] as? Bool == true)

    let createDTO = try JSONDecoder().decode(
        ApplicationStreamDTO.self,
        from: Data(#"""
        {
          "stream_key":"guild:100:230:300",
          "region":"us-west",
          "viewer_ids":["400"],
          "rtc_server_id":"500",
          "rtc_channel_id":"499",
          "paused":false
        }
        """#.utf8)
    )
    let stream = try #require(createDTO.merging())
    #expect(stream.key == key)
    #expect(stream.viewerIDs == [UserID(rawValue: 400)])
    #expect(stream.rtcServerID == "500")
    #expect(stream.rtcChannelID == ChannelID(rawValue: 499))

    let updateDTO = try JSONDecoder().decode(
        ApplicationStreamDTO.self,
        from: Data(#"""
        {
          "stream_key":"guild:100:230:300",
          "paused":true
        }
        """#.utf8)
    )
    let changed = try #require(updateDTO.merging(stream))
    #expect(changed.region == "us-west")
    #expect(changed.viewerIDs == [UserID(rawValue: 400)])
    #expect(changed.isPaused)

    let server = try JSONDecoder().decode(
        ApplicationStreamServerUpdateDTO.self,
        from: Data(#"""
        {
          "stream_key":"guild:100:230:300",
          "endpoint":"stream.example.com.",
          "token":"stream-token"
        }
        """#.utf8)
    )
    #expect(server.resolvedEndpoint == "stream.example.com")
}

@Test func `temporarily unavailable stream retains allocation metadata for reconnect`() async throws {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(),
        handle: CredentialHandle(accountID: "300"),
        session: URLSession(configuration: .ephemeral),
        installationID: "server-issued-installation"
    )
    let key = try #require(ApplicationStreamKey(rawValue: "guild:100:230:300"))
    let stream = ApplicationStream(
        key: key,
        region: "us-west",
        rtcServerID: "500",
        rtcChannelID: ChannelID(rawValue: 499)
    )
    await provider.reconcileApplicationStream(stream)

    await provider.handleGatewayDispatch(
        name: "STREAM_DELETE",
        body: .object([
            "stream_key": .string(key.rawValue),
            "unavailable": .bool(true),
            "reason": .string("server_unavailable"),
        ])
    )

    #expect(await provider.applicationStreams[key] == stream)

    await provider.handleGatewayDispatch(
        name: "STREAM_DELETE",
        body: .object([
            "stream_key": .string(key.rawValue),
            "unavailable": .bool(false),
        ])
    )

    #expect(await provider.applicationStreams[key] == nil)
}

@Test func `voice server migration waits for allocation then reconnects`() throws {
    let active = VoiceConnectionInfo(
        serverID: "100",
        channelID: ChannelID(rawValue: 230),
        guildID: GuildID(rawValue: 100),
        userID: UserID(rawValue: 300),
        sessionID: "session",
        token: "old-token",
        endpoint: "old.discord.media"
    )
    let deallocation = try JSONDecoder().decode(
        VoiceServerUpdateDTO.self,
        from: Data(#"{"token":"new-token","guild_id":"100","endpoint":null}"#.utf8)
    )
    #expect(
        VoiceServerMigrationResolver.resolve(update: deallocation, activeConnection: active)
            == .waitForAllocation
    )

    let allocation = try JSONDecoder().decode(
        VoiceServerUpdateDTO.self,
        from: Data(#"{"token":"new-token","guild_id":"100","endpoint":"new.discord.media"}"#.utf8)
    )
    var expected = active
    expected.token = "new-token"
    expected.endpoint = "new.discord.media"
    #expect(
        VoiceServerMigrationResolver.resolve(update: allocation, activeConnection: active)
            == .reconnect(expected)
    )

    let duplicate = try JSONDecoder().decode(
        VoiceServerUpdateDTO.self,
        from: Data(#"{"token":"old-token","guild_id":"100","endpoint":"old.discord.media"}"#.utf8)
    )
    #expect(VoiceServerMigrationResolver.resolve(update: duplicate, activeConnection: active) == nil)

    let otherGuild = try JSONDecoder().decode(
        VoiceServerUpdateDTO.self,
        from: Data(#"{"token":"other","guild_id":"999","endpoint":"other.discord.media"}"#.utf8)
    )
    #expect(VoiceServerMigrationResolver.resolve(update: otherGuild, activeConnection: active) == nil)
}

@Test func `guild create snapshot seeds existing voice participants`() throws {
    let data = Data(#"""
    {
        "id":"100",
        "voice_states":[
            {"user_id":"200","channel_id":"300","session_id":"existing","self_mute":false,"self_deaf":false,"self_video":true},
            {"future_shape":true}
        ]
    }
    """#.utf8)
    let snapshot = try JSONDecoder().decode(GuildVoiceStateSnapshotDTO.self, from: data)
    let state = try #require(snapshot.domainVoiceStates.first)

    #expect(snapshot.domainVoiceStates.count == 1)
    #expect(state.userID == UserID(rawValue: 200))
    #expect(state.guildID == GuildID(rawValue: 100))
    #expect(state.channelID == ChannelID(rawValue: 300))
    #expect(state.isVideoEnabled)
}

@Test func `ready supplemental seeds voice participants using ready guild order`() throws {
    let data = Data(#"""
    {
        "merged_voice_states": {
            "guilds": [
                [{"user_id":"200","channel_id":"300","session_id":"existing","self_mute":false,"self_deaf":false}],
                [{"user_id":"201","channel_id":"301","guild_id":"101","session_id":"other","self_video":true}]
            ]
        }
    }
    """#.utf8)
    let states = ReadySupplementalVoiceStateResolver.resolve(
        body: try JSONDecoder().decode(JSONValue.self, from: data),
        gatewayGuildIDs: [GuildID(rawValue: 100), GuildID(rawValue: 999)]
    )

    #expect(states.first(where: { $0.userID == UserID(rawValue: 200) })?.guildID == GuildID(rawValue: 100))
    #expect(states.first(where: { $0.userID == UserID(rawValue: 201) })?.guildID == GuildID(rawValue: 101))
    #expect(states.first(where: { $0.userID == UserID(rawValue: 201) })?.isVideoEnabled == true)
}

@Test func `ready supplemental skips null guild batches and future voice states`() throws {
    let data = Data(#"""
    {
        "merged_voice_states": {
            "guilds": [
                null,
                [null,{"future_shape":true},{"user_id":"202","channel_id":"302","session_id":"valid"}]
            ]
        }
    }
    """#.utf8)
    let states = ReadySupplementalVoiceStateResolver.resolve(
        body: try JSONDecoder().decode(JSONValue.self, from: data),
        gatewayGuildIDs: [GuildID(rawValue: 100), GuildID(rawValue: 101)]
    )

    #expect(states.count == 1)
    #expect(states.first?.guildID == GuildID(rawValue: 101))
    #expect(states.first?.channelID == ChannelID(rawValue: 302))
}

@Test func `ready payload can seed embedded voice participants`() throws {
    let data = Data(#"""
    {
        "user_settings_proto":"cgA=",
        "guilds": [
            {
                "id":"100",
                "voice_states":[
                    {"user_id":"200","channel_id":"300","session_id":"existing"},
                    {"future_shape":true}
                ]
            }
        ]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    #expect(ready.userSettingsProto == "cgA=")
    let guild = try #require(ready.guilds.first)
    let participant = try #require(guild.voiceStates.first?.domain(defaultGuildID: GuildID(guild.id)))

    #expect(guild.voiceStates.count == 1)
    #expect(participant.guildID == GuildID(rawValue: 100))
    #expect(participant.channelID == ChannelID(rawValue: 300))
}

@Test func `ready thread keeps an inline member without standalone identifiers`() throws {
    let data = Data(#"""
    {
        "guilds": [
            {
                "id":"100",
                "threads":[
                    {
                        "id":"300",
                        "guild_id":"100",
                        "parent_id":"200",
                        "type":11,
                        "name":"joined thread",
                        "thread_metadata":{"archived":false},
                        "member":{"flags":1,"muted":false,"mute_config":null}
                    }
                ]
            }
        ]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    let member = try #require(ready.guilds.first?.threads.first?.member)

    #expect(member.id == nil)
    #expect(member.userID == nil)
    #expect(member.flags == 1)
    #expect(member.domain.notificationLevel == .inherit)
    #expect(member.domain.isMuted == false)
}

@Test func `ready payload preserves guild member store insertion order`() throws {
    let data = Data(#"""
    {
        "guilds": [
            {
                "id":"100",
                "members":[
                    {"user":{"id":"200","username":"first"},"roles":[]},
                    {"user":{"id":"201","username":"second"},"roles":[]},
                    {"future_shape":true}
                ]
            }
        ]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    let guild = try #require(ready.guilds.first)

    #expect(guild.members.map(\.user.username) == ["first", "second"])
}

@Test func `ready payload decodes directly from ETF value tree without JSON round trip`() throws {
    let data = Data(#"""
    {
        "guilds": [
            {
                "id":"100",
                "properties":{
                    "name":"Direct Decode",
                    "permissions":2048,
                    "rules_channel_id":"101"
                },
                "channels":[{"id":"101","name":"rules","type":0}],
                "members":[
                    {"user":{"id":"200","username":"member"},"roles":[]},
                    {"future_shape":true}
                ]
            }
        ],
        "relationships":[
            {
                "id":"201",
                "type":1,
                "nickname":"  Friend  ",
                "user":{"id":"201","username":"friend"}
            }
        ]
    }
    """#.utf8)
    let jsonReady = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    let directReady = try JSONValueDecoder().decode(GatewayReadyGuildsDTO.self, from: value)

    let jsonGuild = try #require(jsonReady.guilds.first?.domain(currentUserID: nil))
    let directGuild = try #require(directReady.guilds.first?.domain(currentUserID: nil))
    #expect(directGuild == jsonGuild)
    #expect(directReady.guilds.first?.channels.map(\.id) == ["101"])
    #expect(directReady.guilds.first?.members.map(\.user.username) == ["member"])
    #expect(directReady.relationships == jsonReady.relationships)
    #expect(directReady.users.map(\.id) == jsonReady.users.map(\.id))
}

@Test func `ready payload preserves relationship nickname and embedded legacy user`() throws {
    let data = Data(#"""
    {
        "guilds":[],
        "relationships":[
            {
                "id":"200",
                "type":1,
                "nickname":"  USERNAME THIEF!!!  ",
                "user":{
                    "id":"200",
                    "username":"legacy-bot",
                    "discriminator":"8860",
                    "global_name":"Global Name"
                }
            }
        ]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    let userDTO = try #require(ready.users.first)
    let user = try userDTO.domain()

    #expect(ready.relationships[UserID(rawValue: 200)]?.type == .friend)
    #expect(ready.relationships[UserID(rawValue: 200)]?.nickname
        == "USERNAME THIEF!!!")
    #expect(user.tag == "legacy-bot#8860")
}

@Test func `ready identifies blocked and ignored users for forwarding search`() throws {
    let data = Data(#"""
    {
        "guilds":[],
        "relationships":[
            {"id":"200","type":2,"user":{"id":"200","username":"blocked"}},
            {
                "id":"201",
                "type":3,
                "user_ignored":true,
                "user":{"id":"201","username":"ignored"}
            },
            {"id":"202","type":1,"user":{"id":"202","username":"friend"}}
        ]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)

    #expect(ready.blockedOrIgnoredUserIDs == [
        UserID(rawValue: 200), UserID(rawValue: 201),
    ])
    #expect(!ready.blockedOrIgnoredUserIDs.contains(UserID(rawValue: 202)))
}

@Test func `ready payload hydrates compressed merged member order`() throws {
    let data = Data(#"""
    {
        "users":[
            {"id":"201","username":"second"},
            {"id":"200","username":"first"}
        ],
        "guilds":[{"id":"100"}],
        "merged_members":[[
            {"user_id":"200","roles":[]},
            {"user_id":"201","roles":[]},
            {"future_shape":true}
        ]]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    let guild = try #require(ready.hydratedGuilds(using: [:]).first)

    #expect(guild.members.map(\.user.username) == ["first", "second"])
}

@Test func `ready payload hydrates current user roles from the top level user`() throws {
    let data = Data(#"""
    {
        "user":{"id":"200","username":"current"},
        "guilds":[{"id":"100"}],
        "merged_members":[[
            {"user_id":"200","roles":["300"]}
        ]]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    let guild = try #require(ready.hydratedGuilds(using: [:]).first)
    let member = try #require(guild.members.first)

    #expect(member.user.id == "200")
    #expect(member.roles == ["300"])
}

@Test func `ready read states ignore non-channel ID collisions and tolerate duplicate channels`() throws {
    let data = Data(#"""
    {
        "read_state":{
            "entries":[
                {
                    "id":"100",
                    "last_message_id":"200",
                    "mention_count":1
                },
                {
                    "id":"522681957373575168",
                    "read_state_type":2,
                    "badge_count":3
                },
                {
                    "id":"522681957373575168",
                    "read_state_type":5,
                    "badge_count":1
                },
                {
                    "id":"100",
                    "read_state_type":0,
                    "last_message_id":"201",
                    "mention_count":2,
                    "flags":3,
                    "last_viewed":4222
                }
            ]
        }
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
    let entries = ready.readState.channelEntriesByID
    let channel = try #require(entries[ChannelID(rawValue: 100)])

    #expect(entries.count == 1)
    #expect(channel.lastMessageID == "201")
    #expect(channel.mentionCount == 2)
    #expect(channel.flags == 3)
    #expect(channel.lastViewed == 4_222)
}

@Test func `guild member store updates values without moving existing members`() {
    func member(_ id: UInt64, _ name: String) -> Member {
        Member(
            user: User(id: UserID(rawValue: id), username: name, displayName: name),
            roleName: "Member",
            status: .offline
        )
    }

    var first = member(1, "first")
    first.memberListIndex = 41
    let second = member(2, "second")
    let third = member(3, "third")
    let updatedFirst = member(1, "updated-first")
    let merged = DiscordMemberStoreOrdering.merging(
        existing: [first, second], updates: [third, updatedFirst]
    )
    let search = DiscordMemberStoreOrdering.searchResults(
        in: merged, matching: [third, updatedFirst], limit: 10
    )

    #expect(merged.map(\.user.username) == ["updated-first", "second", "third"])
    #expect(merged.first?.memberListIndex == 41)
    #expect(search.map(\.user.username) == ["updated-first", "third"])
}

@Test func `message history member resolution prioritizes authors deduplicates and stays bounded`() {
    func user(_ id: UInt64) -> User {
        User(
            id: UserID(rawValue: id),
            username: "user-\(id)",
            displayName: "User \(id)"
        )
    }

    var messages = (1 ... 100).map { rawID in
        Message(
            id: MessageID(rawValue: UInt64(rawID)),
            channelID: ChannelID(rawValue: 200),
            author: user(UInt64(rawID)),
            content: ""
        )
    }
    messages[0].mentionedUsers = [user(1_000), user(1_001), user(1_002)]

    let missing = DiscordMessageMemberHydration.missingUserIDs(
        in: messages,
        cached: [UserID(rawValue: 1)],
        requested: [UserID(rawValue: 2)]
    )

    #expect(missing.count == 101)
    #expect(missing.prefix(3) == [
        UserID(rawValue: 100), UserID(rawValue: 99), UserID(rawValue: 98)
    ])
    #expect(missing.count <= DiscordMessageMemberHydration.maximumUserIDsPerHistoryPage)
    #expect(missing.contains(UserID(rawValue: 100)))
    #expect(missing.contains(UserID(rawValue: 1_000)))
    #expect(missing.contains(UserID(rawValue: 1_001)))
    #expect(missing.contains(UserID(rawValue: 1_002)))
}

@Test func `ready and guild emoji updates decode complete custom emoji catalogs`() throws {
    let readyData = Data(#"""
    {
        "guilds": [
            {
                "id":"100",
                "voice_states":[],
                "emojis":{
                    "op":"full_sync",
                    "items":[
                        {"id":"200","name":"wave","animated":true,"available":true,"managed":true,"roles":["300"]},
                        {"future_shape":true}
                    ]
                }
            }
        ]
    }
    """#.utf8)
    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: readyData)
    let guild = try #require(ready.guilds.first)
    let guildID = try #require(GuildID(guild.id))
    let collection = try #require(guild.emojis)
    guard case let .snapshot(emojis) = collection.content else {
        Issue.record("READY emoji collection should be a full snapshot")
        return
    }
    let emoji = try #require(emojis.first?.domain(guildID: guildID))

    #expect(emojis.compactMap { $0.domain(guildID: guildID) }.count == 1)
    #expect(emoji.id == "200")
    #expect(emoji.guildID == GuildID(rawValue: 100))
    #expect(emoji.isAnimated)
    #expect(emoji.isManaged)
    #expect(emoji.roleIDs == [RoleID(rawValue: 300)])
    #expect(try JSONDecoder().decode(DiscordEmoji.self, from: JSONEncoder().encode(emoji)) == emoji)
    let oldCache = Data(#"{"id":"200","name":"wave","isAnimated":true,"guildID":"100","isAvailable":true}"#.utf8)
    #expect(try !JSONDecoder().decode(DiscordEmoji.self, from: oldCache).isManaged)
    #expect(try JSONDecoder().decode(DiscordEmoji.self, from: oldCache).roleIDs.isEmpty)

    let createData = Data(#"""
    {
        "id":"100",
        "emojis":{
            "op":"update",
            "writes":[{"id":"201","name":"party","animated":false,"available":true}],
            "deletes":["200"]
        }
    }
    """#.utf8)
    let create = try JSONDecoder().decode(GatewayGuildEmojiSnapshotDTO.self, from: createData)
    let createCollection = try #require(create.emojis)
    guard case let .update(writes, deletes) = createCollection.content else {
        Issue.record("GUILD_CREATE emoji collection should preserve its delta")
        return
    }
    #expect(writes.first?.name == "party")
    #expect(deletes == ["200"])

    let updateData = Data(#"""
    {
        "guild_id":"100",
        "emojis":[{"id":"201","name":"party","animated":false,"available":true}]
    }
    """#.utf8)
    let update = try JSONDecoder().decode(GatewayGuildEmojiSnapshotDTO.self, from: updateData)
    #expect(update.id == "100")
    let updateCollection = try #require(update.emojis)
    guard case let .snapshot(updatedEmojis) = updateCollection.content else {
        Issue.record("GUILD_EMOJIS_UPDATE should remain a full snapshot")
        return
    }
    #expect(updatedEmojis.first?.name == "party")
}

@Test func `preloaded user settings update decodes gateway folder proto`() throws {
    let data = Data(#"{"settings":{"type":1,"proto":"cgA="},"partial":true}"#.utf8)
    let update = try JSONDecoder().decode(GatewayUserSettingsProtoUpdateDTO.self, from: data)

    #expect(update.settings.type == 1)
    #expect(update.settings.proto == "cgA=")
    #expect(update.partial == true)
}

@Test func `partial frecency settings replace changed fields and preserve the rest`() {
    func field(_ number: Int, payload: Data) -> Data {
        Data(encodeProtoVarint(UInt64(number << 3 | 2)))
            + Data(encodeProtoVarint(UInt64(payload.count)))
            + payload
    }
    func favorites(_ keys: [String]) -> Data {
        field(5, payload: keys.reduce(into: Data()) { payload, key in
            payload.append(field(1, payload: Data(key.utf8)))
        })
    }

    let retained = field(2, payload: Data([0x10, 0x01]))
    let current = retained + favorites(["old"])
    let patch = favorites(["new"])

    #expect(
        DiscordSettingsProto.mergingPartialFrecencySettings(
            patch,
            into: current
        ) == retained + patch
    )
}

@Test func `frecency gateway updates publish live emoji favorites`() async throws {
    func field(_ number: Int, payload: Data) -> Data {
        Data(encodeProtoVarint(UInt64(number << 3 | 2)))
            + Data(encodeProtoVarint(UInt64(payload.count)))
            + payload
    }
    func favorites(_ keys: [String]) -> Data {
        field(5, payload: keys.reduce(into: Data()) { payload, key in
            payload.append(field(1, payload: Data(key.utf8)))
        })
    }
    func dispatchBody(_ proto: Data, partial: Bool) -> JSONValue {
        .object([
            "settings": .object([
                "type": .number(2),
                "proto": .string(proto.base64EncodedString()),
            ]),
            "partial": .bool(partial),
        ])
    }

    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(),
        handle: CredentialHandle(accountID: "300"),
        session: URLSession(configuration: .ephemeral),
        installationID: "server-issued-installation"
    )
    let stream = await provider.eventStream()
    var iterator = stream.makeAsyncIterator()

    await provider.handleGatewayDispatch(
        name: "USER_SETTINGS_PROTO_UPDATE",
        body: dispatchBody(favorites(["old"]), partial: false)
    )
    guard case let .emojiUserSettingsChanged(initial)? = await iterator.next() else {
        Issue.record("Expected the initial emoji settings event")
        return
    }
    #expect(initial.favoriteKeys == ["old"])

    await provider.handleGatewayDispatch(
        name: "USER_SETTINGS_PROTO_UPDATE",
        body: dispatchBody(favorites(["new"]), partial: true)
    )
    guard case let .emojiUserSettingsChanged(updated)? = await iterator.next() else {
        Issue.record("Expected the partial emoji settings event")
        return
    }
    #expect(updated.favoriteKeys == ["new"])
    #expect(try await provider.emojiUserSettings().favoriteKeys == ["new"])
}

@Test func `lossy lists keep valid objects when discord adds partial variants`() throws {
    struct Item: Decodable, Equatable { var required: String }
    let data = Data(#"[{"required":"one"},{"new_shape":true},{"required":"two"}]"#.utf8)
    let decoded = try JSONDecoder().decode(LossyList<Item>.self, from: data)
    #expect(decoded.elements == [Item(required: "one"), Item(required: "two")])
    #expect(decoded.skippedCount == 1)
}
@Test func `role member resolver requests exact user ids without presences or nonce`() throws {
    let payload = DiscordGatewayPayloadFactory.requestMembers(
        guildID: GuildID(rawValue: 10),
        userIDs: [UserID(rawValue: 20), UserID(rawValue: 30)]
    )
    #expect(payload["op"] as? Int == 8)
    let data = try #require(payload["d"] as? [String: Any])
    #expect(data["guild_id"] as? String == "10")
    #expect(data["user_ids"] as? [String] == ["20", "30"])
    #expect(data["presences"] as? Bool == false)
    #expect(data["nonce"] == nil)
}

@Test func `role member resolver routes nonce-less chunks by guild and returned user ids`() {
    let requests = [
        DiscordPendingMemberRequestDescriptor(
            id: "first",
            guildID: GuildID(rawValue: 10),
            requestedUserIDs: Set([UserID(rawValue: 20), UserID(rawValue: 30)])
        ),
        DiscordPendingMemberRequestDescriptor(
            id: "other-guild",
            guildID: GuildID(rawValue: 11),
            requestedUserIDs: Set([UserID(rawValue: 20), UserID(rawValue: 30)])
        )
    ]

    #expect(
        DiscordMemberChunkRouting.pendingRequestID(
            guildID: GuildID(rawValue: 10),
            responseUserIDs: [UserID(rawValue: 20), UserID(rawValue: 30)],
            requests: requests
        ) == "first"
    )
    #expect(
        DiscordMemberChunkRouting.pendingRequestID(
            guildID: GuildID(rawValue: 10),
            responseUserIDs: [UserID(rawValue: 20)],
            requests: requests
        ) == "first"
    )
    #expect(
        DiscordMemberChunkRouting.pendingRequestID(
            guildID: GuildID(rawValue: 12),
            responseUserIDs: [UserID(rawValue: 20)],
            requests: requests
        ) == nil
    )
}

@Test func `member mention search requests query with official gateway shape`() throws {
    let payload = DiscordGatewayPayloadFactory.searchMembers(
        guildID: GuildID(rawValue: 10), query: "maya", limit: 10
    )
    #expect(payload["op"] as? Int == 8)
    let data = try #require(payload["d"] as? [String: Any])
    #expect(data["guild_id"] as? String == "10")
    #expect(data["query"] as? String == "maya")
    #expect(data["limit"] as? Int == 10)
    #expect(data["presences"] as? Bool == true)
    #expect(Set(data.keys) == ["guild_id", "query", "limit", "presences"])
}

@Test func `account wide member search uses current desktop payload shape`() throws {
    let payload = DiscordGatewayPayloadFactory.searchMembers(
        guildIDs: [GuildID(rawValue: 10)],
        query: "hen",
        limit: 100
    )
    #expect(payload["op"] as? Int == 8)
    let data = try #require(payload["d"] as? [String: Any])
    #expect(data["guild_id"] as? [String] == ["10"])
    #expect(data["query"] as? String == "hen")
    #expect(data["limit"] as? Int == 100)
    #expect(data["presences"] as? Bool == true)
    #expect(Set(data.keys) == ["guild_id", "query", "limit", "presences"])
}
