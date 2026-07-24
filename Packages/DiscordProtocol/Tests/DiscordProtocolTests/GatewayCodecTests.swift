@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `json gateway codec round trips unknown events`() throws {
    let codec = JSONGatewayCodec()
    let envelope = GatewayEnvelope(op: 0, data: .object(["future": .bool(true)]), sequence: 42, eventName: "FUTURE_EVENT")
    #expect(try codec.decode(codec.encode(envelope)) == envelope)
}

@Test func `production baseline matches observed bootstrap`() {
    let baseline = DiscordProductionBaseline.july2026
    #expect(baseline.apiVersion == 9)
    #expect(baseline.webBuildNumber == 579_073)
    #expect(baseline.desktopVersion == "0.0.401")
    #expect(baseline.webGatewayEncoding == "json")
    #expect(baseline.webGatewayCompression == "zlib-stream")
    #expect(baseline.desktopGatewayEncoding == "etf")
    #expect(baseline.desktopGatewayCompression == "zstd-stream")
    #expect(baseline.defaultCapabilities == 1_734_653)
}

@Test func `ready guild decodes the designated community rules channel`() throws {
    let payload = Data(
        """
        {
          "guilds": [
            {
              "id": "100",
              "rules_channel_id": "101",
              "channels": [
                {"id": "101", "name": "read-me-first", "type": 0},
                {"id": "102", "name": "rules", "type": 0}
              ]
            }
          ]
        }
        """.utf8
    )

    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: payload)
    let guild = try #require(ready.guilds.first)
    #expect(guild.rulesChannelID == "101")
    #expect(guild.channels.map(\.id) == ["101", "102"])
}

@Test func `settings proto preserves discord guild folder order`() {
    func fixed64(_ value: UInt64) -> [UInt8] {
        (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
    func folder(_ ids: [UInt64]) -> [UInt8] {
        let packed = ids.flatMap(fixed64)
        return [0x0A, UInt8(packed.count)] + packed
    }
    let firstFolder = folder([300, 100])
    let standalone = folder([200])
    let guildFolders = [0x0A, UInt8(firstFolder.count)] + firstFolder
        + [0x0A, UInt8(standalone.count)] + standalone
    let topLevel = Data([0x72, UInt8(guildFolders.count)] + guildFolders)

    #expect(DiscordSettingsProto.guildOrder(from: topLevel) == [
        GuildID(rawValue: 300), GuildID(rawValue: 100), GuildID(rawValue: 200)
    ])
}

@Test func `settings proto keeps folder order when positions contain an unlisted guild`() {
    func fixed64(_ value: UInt64) -> [UInt8] {
        (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
    func folder(_ ids: [UInt64]) -> [UInt8] {
        let packed = ids.flatMap(fixed64)
        return [0x0A, UInt8(packed.count)] + packed
    }

    let folderPayload = folder([300, 100, 200])
    let completePositions = [400, 300, 100, 200].flatMap(fixed64)
    let guildFolders = [0x0A, UInt8(folderPayload.count)] + folderPayload
        + [0x12, UInt8(completePositions.count)] + completePositions
    let topLevel = Data([0x72, UInt8(guildFolders.count)] + guildFolders)

    #expect(DiscordSettingsProto.guildOrder(from: topLevel) == [
        GuildID(rawValue: 300), GuildID(rawValue: 100), GuildID(rawValue: 200)
    ])
}

@Test func `settings proto decodes full guild folder metadata`() throws {
    func field(_ number: Int, payload: [UInt8]) -> [UInt8] {
        encodeProtoVarint(UInt64(number << 3 | 2)) + encodeProtoVarint(UInt64(payload.count)) + payload
    }
    func fixed64(_ value: UInt64) -> [UInt8] {
        (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }

    let guildIDs = field(1, payload: [300, 100].flatMap(fixed64))
    let folderID = field(2, payload: encodeProtoVarint(1 << 3) + encodeProtoVarint(42))
    let name = field(3, payload: field(1, payload: Array("Design".utf8)))
    let color = field(4, payload: encodeProtoVarint(1 << 3) + encodeProtoVarint(0x58_65_F2))
    let folder = field(1, payload: guildIDs + folderID + name + color)
    let topLevel = Data(field(14, payload: folder))

    let layout = try #require(DiscordSettingsProto.guildLayout(from: topLevel))
    let decoded = try #require(layout.folders.first)
    #expect(decoded.guildIDs == [GuildID(rawValue: 300), GuildID(rawValue: 100)])
    #expect(decoded.id == 42)
    #expect(decoded.name == "Design")
    #expect(decoded.colorHex == 0x58_65_F2)
}

@Test func `guild folder layout keeps unlisted guilds above expandable folders`() throws {
    let stored = Guild(id: GuildID(rawValue: 100), name: "Stored")
    let folderChild = Guild(id: GuildID(rawValue: 200), name: "Folder child")
    let unlisted = Guild(id: GuildID(rawValue: 400), name: "Unlisted")
    let layout = DiscordGuildLayout(
        folders: [DiscordGuildLayout.Folder(
            guildIDs: [stored.id, folderChild.id],
            id: 42,
            name: "Design",
            colorHex: 0x58_65_F2
        )],
        guildPositions: []
    )

    let result = DiscordRESTProvider.applyingGuildLayout(
        layout,
        to: [stored, unlisted, folderChild]
    )
    #expect(result.guilds.map(\.id) == [unlisted.id, stored.id, folderChild.id])
    #expect(result.railItems.first == .guild(unlisted.id))
    let folder = try #require(result.railItems.last)
    #expect(folder == .folder(GuildFolder(
        id: 42,
        name: "Design",
        colorHex: 0x58_65_F2,
        guildIDs: [stored.id, folderChild.id]
    )))
}

@Test func `emoji settings preserve favorites and separate message frecency from reactions`() {
    func field(_ number: Int, payload: [UInt8]) -> [UInt8] {
        encodeProtoVarint(UInt64(number << 3 | 2)) + encodeProtoVarint(UInt64(payload.count)) + payload
    }
    func stringField(_ number: Int, _ value: String) -> [UInt8] {
        field(number, payload: Array(value.utf8))
    }
    func frecencyEntry(key: String, totalUses: UInt64, recentUses: [UInt64]) -> [UInt8] {
        let item = encodeProtoVarint(UInt64(1 << 3)) + encodeProtoVarint(totalUses)
            + field(2, payload: recentUses.flatMap(encodeProtoVarint))
            // Discord recomputes from recent uses and ignores these stale fields.
            + encodeProtoVarint(UInt64(4 << 3)) + encodeProtoVarint(1)
        return field(1, payload: stringField(1, key) + field(2, payload: item))
    }
    func fixed64Field(_ number: Int, _ value: UInt64) -> [UInt8] {
        var bytes = encodeProtoVarint(UInt64(number << 3 | 1))
        bytes.append(contentsOf: (0 ..< 8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) })
        return bytes
    }
    func guildAndChannelEntry(
        key: UInt64,
        totalUses: UInt64,
        recentUses: [UInt64],
        storedFrecency: UInt64 = 0
    ) -> [UInt8] {
        let item = encodeProtoVarint(UInt64(1 << 3)) + encodeProtoVarint(totalUses)
            + field(2, payload: recentUses.flatMap(encodeProtoVarint))
            + (storedFrecency == 0
                ? []
                : encodeProtoVarint(UInt64(3 << 3)) + encodeProtoVarint(storedFrecency))
        return field(1, payload: fixed64Field(1, key) + field(2, payload: item))
    }

    let now: UInt64 = 1_800_000_000_000

    let favorites = field(
        5,
        payload: stringField(1, "22")
            + stringField(1, "white_heart")
            + stringField(1, "11")
    )
    let messageFrecency = field(
        6,
        payload: frecencyEntry(
            key: "white_heart",
            totalUses: 1,
            recentUses: [now - 20 * 86_400_000]
        )
            + frecencyEntry(key: "22", totalUses: 5, recentUses: [now, now - 1, now - 2])
            + frecencyEntry(key: "11", totalUses: 4, recentUses: [now, now - 1])
    )
    let reactionFrecency = field(
        13,
        payload: frecencyEntry(key: "reaction_only", totalUses: 20, recentUses: [now])
    )
    let guildAndChannelFrecency = field(
        12,
        payload: guildAndChannelEntry(
            key: 123,
            totalUses: 5,
            recentUses: [now, now - 1, now - 2]
        )
            + guildAndChannelEntry(
                key: 456,
                totalUses: 2,
                recentUses: [],
                storedFrecency: 9
            )
    )

    let settings = DiscordSettingsProto.emojiSettings(
        from: Data(favorites + messageFrecency + guildAndChannelFrecency + reactionFrecency),
        nowMilliseconds: now
    )
    #expect(settings.favoriteKeys == ["22", "white_heart", "11"])
    #expect(settings.frequentlyUsedKeys == ["22", "11", "white_heart"])
    #expect(settings.usageScores["22"] == 300)
    #expect(settings.usageScores["white_heart"] == 50)
    #expect(settings.usageScores["reaction_only"] == nil)
    #expect(settings.guildAndChannelUsageScores["123"] == 500)
    #expect(settings.guildAndChannelUsageScores["456"] == 9)
}

@Test func `emoji settings cap frequently used to two picker rows`() {
    func field(_ number: Int, payload: [UInt8]) -> [UInt8] {
        encodeProtoVarint(UInt64(number << 3 | 2)) + encodeProtoVarint(UInt64(payload.count)) + payload
    }
    let now: UInt64 = 1_800_000_000_000
    let entries = (0 ..< 19).flatMap { index -> [UInt8] in
        let key = Array("e\(index)".utf8)
        let item = encodeProtoVarint(UInt64(1 << 3)) + encodeProtoVarint(UInt64(19 - index))
            + field(2, payload: encodeProtoVarint(now))
        let entry = field(1, payload: key) + field(2, payload: item)
        return field(1, payload: entry)
    }
    let settings = DiscordSettingsProto.emojiSettings(
        from: Data(field(6, payload: entries)),
        nowMilliseconds: now
    )
    #expect(settings.frequentlyUsedKeys.count == 18)
    #expect(settings.frequentlyUsedKeys.first == "e0")
    #expect(settings.frequentlyUsedKeys.last == "e17")
}

@Test func `guilds missing from settings appear above the stored sequence`() {
    let stored = Guild(id: GuildID(rawValue: 100), name: "Stored")
    let newlyCreated = Guild(id: GuildID(rawValue: 400), name: "Testing Server 2")
    let olderUnlisted = Guild(id: GuildID(rawValue: 300), name: "Older unlisted")

    #expect(DiscordRESTProvider.applyingGuildOrder(
        [stored.id], to: [stored, olderUnlisted, newlyCreated]
    ).map(\.id) == [
        newlyCreated.id, olderUnlisted.id, stored.id
    ])
}

@Test func `guild member subscription matches current discord bulk shape`() throws {
    let payload = DiscordGatewayPayloadFactory.guildSubscriptions(
        guildID: GuildID(rawValue: 100),
        channelID: ChannelID(rawValue: 200)
    )
    #expect(payload["op"] as? Int == 37)
    let data = try #require(payload["d"] as? [String: Any])
    let subscriptions = try #require(data["subscriptions"] as? [String: Any])
    let guild = try #require(subscriptions["100"] as? [String: Any])
    #expect(guild["typing"] as? Bool == true)
    #expect(guild["activities"] as? Bool == true)
    #expect(guild["threads"] as? Bool == true)
    let channels = try #require(guild["channels"] as? [String: Any])
    #expect(channels["200"] as? [[Int]] == [[0, 99]])
}

@Test func `voice state update uses gateway opcode four and explicit null to leave`() throws {
    let join = DiscordGatewayPayloadFactory.voiceStateUpdate(
        guildID: GuildID(rawValue: 100),
        channelID: ChannelID(rawValue: 230),
        selfMute: true,
        selfDeaf: false
    )
    #expect(join["op"] as? Int == 4)
    let joinData = try #require(join["d"] as? [String: Any])
    #expect(joinData["guild_id"] as? String == "100")
    #expect(joinData["channel_id"] as? String == "230")
    #expect(joinData["self_mute"] as? Bool == true)
    #expect(joinData["self_video"] as? Bool == false)
    #expect(joinData["self_stream"] as? Bool == false)

    let camera = DiscordGatewayPayloadFactory.voiceStateUpdate(
        guildID: GuildID(rawValue: 100),
        channelID: ChannelID(rawValue: 230),
        selfMute: false,
        selfDeaf: false,
        selfVideo: true
    )
    let cameraData = try #require(camera["d"] as? [String: Any])
    #expect(cameraData["self_video"] as? Bool == true)

    let leave = DiscordGatewayPayloadFactory.voiceStateUpdate(
        guildID: GuildID(rawValue: 100),
        channelID: nil,
        selfMute: false,
        selfDeaf: false
    )
    let leaveData = try #require(leave["d"] as? [String: Any])
    #expect(leaveData["channel_id"] is NSNull)
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

@Test func `ready supplemental seeds voice participants using ready guild order`() {
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
        data: data,
        gatewayGuildIDs: [GuildID(rawValue: 100), GuildID(rawValue: 999)]
    )

    #expect(states.first(where: { $0.userID == UserID(rawValue: 200) })?.guildID == GuildID(rawValue: 100))
    #expect(states.first(where: { $0.userID == UserID(rawValue: 201) })?.guildID == GuildID(rawValue: 101))
    #expect(states.first(where: { $0.userID == UserID(rawValue: 201) })?.isVideoEnabled == true)
}

@Test func `ready supplemental skips null guild batches and future voice states`() {
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
        data: data,
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
                    "mention_count":2
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
}

@Test func `guild member store updates values without moving existing members`() {
    func member(_ id: UInt64, _ name: String) -> Member {
        Member(
            user: User(id: UserID(rawValue: id), username: name, displayName: name),
            roleName: "Member",
            status: .offline
        )
    }

    let first = member(1, "first")
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
    #expect(search.map(\.user.username) == ["updated-first", "third"])
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
                        {"id":"200","name":"wave","animated":true,"available":true},
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

@Test func `lossy lists keep valid objects when discord adds partial variants`() throws {
    struct Item: Decodable, Equatable { var required: String }
    let data = Data(#"[{"required":"one"},{"new_shape":true},{"required":"two"}]"#.utf8)
    let decoded = try JSONDecoder().decode(LossyList<Item>.self, from: data)
    #expect(decoded.elements == [Item(required: "one"), Item(required: "two")])
    #expect(decoded.skippedCount == 1)
}
@Test func `role member resolver requests exact user ids without presences`() throws {
    let payload = DiscordGatewayPayloadFactory.requestMembers(
        guildID: GuildID(rawValue: 10),
        userIDs: [UserID(rawValue: 20), UserID(rawValue: 30)],
        nonce: "role-members"
    )
    #expect(payload["op"] as? Int == 8)
    let data = try #require(payload["d"] as? [String: Any])
    #expect(data["guild_id"] as? String == "10")
    #expect(data["user_ids"] as? [String] == ["20", "30"])
    #expect(data["presences"] as? Bool == false)
    #expect(data["nonce"] as? String == "role-members")
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
