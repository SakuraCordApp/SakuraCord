@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `json gateway codec round trips unknown events`() throws {
    let codec = JSONGatewayCodec()
    let envelope = GatewayEnvelope(op: 0, data: .object(["future": .bool(true)]), sequence: 42, eventName: "FUTURE_EVENT")
    #expect(try codec.decode(codec.encode(envelope)) == envelope)
}

@Test func `desktop ETF codec round trips Discord JSON compatible terms`() throws {
    let codec = ETFGatewayCodec()
    let envelope = GatewayEnvelope(
        op: 40,
        data: .object([
            "seq": .number(42),
            "qos": .object([
                "ver": .number(29),
                "active": .bool(true),
                "reasons": .array([.string("foregrounded")]),
                "optional": .null,
            ]),
        ])
    )
    let encoded = try codec.encode(envelope)
    #expect(encoded.first == 131)
    #expect(try codec.decode(encoded) == envelope)
}

@Test func `desktop ETF codec decodes a sanitized official erlpack fixture`() throws {
    // Packed by the clean stable desktop's native discord_erlpack module. The
    // synthetic QoS envelope contains no account or session identifiers.
    let fixture = try #require(Data(base64Encoded:
        "g3QAAAACbQAAAAJvcGEobQAAAAFkdAAAAAJtAAAAA3NlcWEHbQAAAANxb3N0AAAAA20AAAAGYWN0aXZlcwVmYWxzZW0AAAADdmVyYR1tAAAAB3JlYXNvbnNq"
    ))
    let envelope = try ETFGatewayCodec().decode(fixture)
    #expect(envelope == GatewayEnvelope(
        op: 40,
        data: .object([
            "seq": .number(7),
            "qos": .object([
                "active": .bool(false),
                "ver": .number(29),
                "reasons": .array([]),
            ]),
        ])
    ))
}

@Test func `desktop ETF string extension preserves member list byte ranges`() throws {
    var fixture = Data([131, 116, 0, 0, 0, 4])
    appendETFBinary("op", to: &fixture)
    fixture.append(contentsOf: [97, 0])
    appendETFBinary("d", to: &fixture)
    fixture.append(contentsOf: [116, 0, 0, 0, 1])
    appendETFBinary("range", to: &fixture)
    fixture.append(contentsOf: [107, 0, 2, 0, 99])
    appendETFBinary("s", to: &fixture)
    fixture.append(contentsOf: [97, 1])
    appendETFBinary("t", to: &fixture)
    appendETFBinary("GUILD_MEMBER_LIST_UPDATE", to: &fixture)

    let envelope = try ETFGatewayCodec().decode(fixture)

    #expect(envelope == GatewayEnvelope(
        op: 0,
        data: .object([
            "range": .array([.number(0), .number(99)])
        ]),
        sequence: 1,
        eventName: "GUILD_MEMBER_LIST_UPDATE"
    ))
}

@Test func `ETF collection counts are bounded by remaining encoded bytes`() {
    let declaredCount: [UInt8] = [0, 255, 255, 255]
    let malformedCollections = [
        Data([131, 105] + declaredCount), // LARGE_TUPLE_EXT
        Data([131, 108] + declaredCount), // LIST_EXT, also missing its tail
        Data([131, 116] + declaredCount), // MAP_EXT
    ]

    for fixture in malformedCollections {
        #expect(throws: GatewaySessionError.malformedPayload) {
            try ETFGatewayCodec().decode(fixture)
        }
    }
}

@Test func `desktop ETF codec preserves integer map keys exactly`() throws {
    var fixture = Data([131, 116, 0, 0, 0, 4])
    appendETFBinary("op", to: &fixture)
    fixture.append(contentsOf: [97, 0])
    appendETFBinary("d", to: &fixture)
    fixture.append(contentsOf: [116, 0, 0, 0, 2, 110, 8, 0])
    fixture.append(contentsOf: [255, 255, 255, 255, 255, 255, 255, 127])
    appendETFBinary("present", to: &fixture)
    appendETFBinary("id", to: &fixture)
    fixture.append(contentsOf: [110, 8, 0])
    fixture.append(contentsOf: [255, 255, 255, 255, 255, 255, 255, 127])
    appendETFBinary("s", to: &fixture)
    fixture.append(contentsOf: [97, 1])
    appendETFBinary("t", to: &fixture)
    appendETFBinary("READY", to: &fixture)

    let envelope = try ETFGatewayCodec().decode(fixture)
    #expect(envelope == GatewayEnvelope(
        op: 0,
        data: .object([
            "9223372036854775807": .string("present"),
            "id": .string("9223372036854775807"),
        ]),
        sequence: 1,
        eventName: "READY"
    ))
}

@Test func `desktop ETF integer guild permissions decode as a numeric field`() throws {
    var fixture = Data([131, 116, 0, 0, 0, 4])
    appendETFBinary("op", to: &fixture)
    fixture.append(contentsOf: [97, 0])
    appendETFBinary("d", to: &fixture)
    fixture.append(contentsOf: [116, 0, 0, 0, 3])
    appendETFBinary("id", to: &fixture)
    appendETFBinary("100", to: &fixture)
    appendETFBinary("name", to: &fixture)
    appendETFBinary("Numeric Permissions", to: &fixture)
    appendETFBinary("permissions", to: &fixture)
    fixture.append(contentsOf: [98, 0, 0, 4, 0])
    appendETFBinary("s", to: &fixture)
    fixture.append(contentsOf: [97, 1])
    appendETFBinary("t", to: &fixture)
    appendETFBinary("GUILD_CREATE", to: &fixture)

    let envelope = try ETFGatewayCodec().decode(fixture)

    #expect(envelope.eventName == "GUILD_CREATE")
    guard case .object(let guild) = envelope.data else {
        Issue.record("Guild Create data must remain an object")
        return
    }
    #expect(guild["permissions"] == .number(1_024))
}

private func appendETFBinary(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    data.append(109)
    var count = UInt32(bytes.count).bigEndian
    withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
    data.append(bytes)
}

@Test func `production baseline matches observed bootstrap`() {
    let baseline = DiscordProductionBaseline.august2026
    #expect(baseline.apiVersion == 9)
    #expect(baseline.webBuildNumber == 587_597)
    #expect(baseline.desktopVersion == "0.0.403")
    #expect(baseline.electronVersion == "42.7.1")
    #expect(baseline.chromiumVersion == "148.0.7778.280")
    #expect(baseline.nativeBuildNumber == 87_263)
    #expect(baseline.webGatewayEncoding == "json")
    #expect(baseline.webGatewayCompression == "zlib-stream")
    #expect(baseline.desktopGatewayEncoding == "etf")
    #expect(baseline.desktopGatewayCompression == "zstd-stream")
    #expect(baseline.defaultCapabilities == 1_734_653)
    #expect(baseline.privateChannelObfuscationCapabilities == 1_767_421)
    #expect(baseline.qosHeartbeatVersion == 29)
}

@Test func `desktop metadata matches current non-secret official request fields`() throws {
    let metadata = DiscordClientMetadata(
        locale: "en-GB",
        systemLocale: "en-US",
        acceptLanguage: "en-US,en-GB;q=0.9",
        osVersion: "27.0.0"
    )

    #expect(metadata.acceptLanguage == "en-US,en-GB;q=0.9")
    #expect(metadata.properties["client_version"] == .string("0.0.403"))
    #expect(metadata.properties["client_build_number"] == .number(587_597))
    #expect(metadata.properties["os_version"] == .string("27.0.0"))
    #expect(metadata.properties["os_sdk_version"] == .string("27"))
    #expect(metadata.properties["system_locale"] == .string("en-US"))
    #expect(metadata.properties["client_launch_id"] != nil)
    #expect(metadata.properties["launch_signature"] != nil)
    #expect(metadata.properties["client_heartbeat_session_id"] != nil)
    #expect(metadata.properties["client_event_source"] == .null)
    #expect(metadata.properties["client_app_state"] == .string("focused"))
    #expect(
        metadata.properties(clientAppState: "unfocused")["client_app_state"]
            == .string("unfocused")
    )
    #expect(metadata.properties["native_build_number"] == .number(87_263))
    #expect(metadata.userAgent.contains("discord/0.0.403"))
    #expect(metadata.userAgent.contains("Chrome/148.0.7778.280"))
    #expect(metadata.userAgent.contains("Electron/42.7.1"))

    guard case let .string(signature)? = metadata.properties["launch_signature"],
          let signatureUUID = UUID(uuidString: signature)
    else {
        Issue.record("Launch signature must be a UUID")
        return
    }
    let bytes = withUnsafeBytes(of: signatureUUID.uuid) { Array($0) }
    let requiredBits: [UInt8] = [
        0x00, 0x80, 0x10, 0x10, 0x08, 0x10, 0x08, 0x00,
        0x20, 0x81, 0x00, 0x40, 0x01, 0x00, 0x08, 0x00,
    ]
    #expect(zip(bytes, requiredBits).allSatisfy { byte, mask in byte & mask == mask })
}

@Test func `desktop gateway and REST metadata use their exact separate shapes`() throws {
    let metadata = DiscordClientMetadata(
        locale: "en-US",
        systemLocale: "en-US",
        timeZone: "Europe/Kyiv",
        acceptLanguage: "en-US",
        osVersion: "27.0.0",
        installationID: "server-issued-installation"
    )
    let gateway = metadata.gatewayProperties()
    #expect(Set(gateway.keys) == Set([
        "os", "browser", "release_channel", "client_version", "os_version",
        "os_arch", "app_arch", "system_locale", "has_client_mods",
        "client_launch_id", "browser_user_agent", "browser_version",
        "os_sdk_version", "client_build_number", "native_build_number", "client_event_source",
        "is_fast_connect", "installation_id",
    ]))
    #expect(gateway["installation_id"] == .string("server-issued-installation"))
    #expect(gateway["launch_signature"] == nil)
    #expect(gateway["client_heartbeat_session_id"] == nil)
    #expect(gateway["client_app_state"] == nil)

    var get = URLRequest(url: URL(string: "https://discord.com/api/v9/users/@me")!)
    get.httpMethod = "GET"
    try metadata.apply(to: &get, clientAppState: "unfocused")
    #expect(get.value(forHTTPHeaderField: "X-Installation-ID") == "server-issued-installation")
    #expect(get.value(forHTTPHeaderField: "X-Fingerprint") == nil)
    #expect(get.value(forHTTPHeaderField: "Origin") == nil)

    var post = URLRequest(url: URL(string: "https://discord.com/api/v9/channels/1/messages")!)
    post.httpMethod = "POST"
    try metadata.apply(to: &post)
    #expect(post.value(forHTTPHeaderField: "Origin") == "https://discord.com")
}

@Test func `client hints derive their Chromium major version from the baseline`() throws {
    var baseline = DiscordProductionBaseline.august2026
    baseline.chromiumVersion = "151.2.3456.7"
    let metadata = DiscordClientMetadata(baseline: baseline)
    var request = URLRequest(url: URL(string: "https://discord.com/api/v9/users/@me")!)

    try metadata.apply(to: &request)

    #expect(metadata.userAgent.contains("Chrome/151.2.3456.7"))
    #expect(
        request.value(forHTTPHeaderField: "Sec-CH-UA")
            == "\"Not)A;Brand\";v=\"8\", \"Chromium\";v=\"151\""
    )
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

@Test func `desktop ETF numeric guild permissions remain available after ready decoding`() throws {
    let payload = Data(
        """
        {
          "guilds": [
            {
              "id": "100",
              "name": "Numeric Permissions",
              "permissions": 1024
            }
          ]
        }
        """.utf8
    )

    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: payload)
    let guild = try #require(ready.guilds.first?.domain(currentUserID: nil))
    #expect(guild.currentUserPermissions == 1_024)
}

@Test func `desktop ready guild decodes nested properties`() throws {
    let payload = Data(
        """
        {
          "guilds": [
            {
              "id": "100",
              "data_mode": "full",
              "properties": {
                "name": "Nested Properties",
                "permissions": 2048,
                "rules_channel_id": "101"
              },
              "channels": []
            }
          ]
        }
        """.utf8
    )

    let ready = try JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: payload)
    let guild = try #require(ready.guilds.first?.domain(currentUserID: nil))
    #expect(guild.name == "Nested Properties")
    #expect(guild.currentUserPermissions == 2_048)
    #expect(guild.rulesChannelID == ChannelID(rawValue: 101))
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
            + guildAndChannelEntry(
                key: 789,
                totalUses: 9,
                recentUses: [0, 1, 2, 3, 4, 6, 7, 80, 81].map {
                    now - UInt64($0) * 86_400_000
                }
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
    #expect(settings.guildAndChannelUsageScores["456"] == nil)
    #expect(settings.guildAndChannelUsageScores["789"] == 360)
    #expect(settings.guildAndChannelUsage["123"] == DiscordFrecencyUsage(
        totalUses: 5,
        recentUses: [now, now - 1, now - 2]
    ))
    #expect(settings.guildAndChannelUsage["456"] == DiscordFrecencyUsage(
        totalUses: 2,
        recentUses: []
    ))
    #expect(settings.guildAndChannelUsageOrder == ["123", "456", "789"])
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

@Test func `member list viewport ranges retain initial block and prewarm adjacent blocks`() {
    #expect(DiscordMemberListRangePolicy.ranges(around: 0 ... 16) == [0 ... 99])
    #expect(DiscordMemberListRangePolicy.ranges(around: 94 ... 111) == [
        0 ... 99, 100 ... 199,
    ])
    #expect(DiscordMemberListRangePolicy.ranges(around: 205 ... 221) == [
        0 ... 99, 100 ... 199, 200 ... 299,
    ])
}

@Test func `member list viewport payload is bounded deduplicated and channel scoped`() throws {
    let ranges = DiscordMemberListRangePolicy.ranges(around: 10_000 ... 20_000)
    #expect(ranges.count == DiscordMemberListRangePolicy.maximumRangePairs)
    #expect(ranges.first == 0 ... 99)
    #expect(Set(ranges).count == ranges.count)

    let payload = DiscordGatewayPayloadFactory.guildSubscriptions(
        guildID: GuildID(rawValue: 100),
        channelID: ChannelID(rawValue: 200),
        ranges: [0 ... 99, 200 ... 299]
    )
    let data = try #require(payload["d"] as? [String: Any])
    let subscriptions = try #require(data["subscriptions"] as? [String: Any])
    let guild = try #require(subscriptions["100"] as? [String: Any])
    let channels = try #require(guild["channels"] as? [String: Any])
    #expect(channels["200"] as? [[Int]] == [[0, 99], [200, 299]])
}

@Test func `member list subscription cache is a five list id lru`() {
    let memberListIDs = (1 ... 6).map { "list-\($0)" }
    var retained: [String] = []
    for memberListID in memberListIDs {
        retained = DiscordMemberListRangePolicy.retainedMemberListOrder(
            selecting: memberListID,
            from: retained
        )
    }
    #expect(retained == Array(memberListIDs.suffix(5)))

    retained = DiscordMemberListRangePolicy.retainedMemberListOrder(
        selecting: memberListIDs[2],
        from: retained
    )
    #expect(retained == [
        memberListIDs[1], memberListIDs[3], memberListIDs[4],
        memberListIDs[5], memberListIDs[2],
    ])
}

@Test func `member list subscription update sends one channel per retained list id`() throws {
    let channels = (1 ... 6).map { ChannelID(rawValue: UInt64($0)) }
    let memberListIDs = (1 ... 6).map { "list-\($0)" }
    let existing = Dictionary(
        uniqueKeysWithValues: zip(memberListIDs.prefix(5), channels.prefix(5)).map {
            ($0, DiscordMemberListSubscription(channelID: $1, ranges: [0 ... 99]))
        }
    )
    let state = DiscordMemberListRangePolicy.subscriptionState(
        selecting: memberListIDs[5],
        channelID: channels[5],
        ranges: [0 ... 99, 200 ... 299],
        currentSubscriptions: existing,
        currentOrder: Array(memberListIDs.prefix(5))
    )

    #expect(state.memberListOrder == Array(memberListIDs.suffix(5)))
    #expect(state.rangesByChannel[channels[0]] == nil)
    #expect(state.rangesByChannel[channels[5]] == [0 ... 99, 200 ... 299])

    let payload = DiscordGatewayPayloadFactory.guildSubscriptions(
        guildID: GuildID(rawValue: 100),
        channelRanges: state.rangesByChannel
    )
    let data = try #require(payload["d"] as? [String: Any])
    let subscriptions = try #require(data["subscriptions"] as? [String: Any])
    let guild = try #require(subscriptions["100"] as? [String: Any])
    let payloadChannels = try #require(guild["channels"] as? [String: Any])

    #expect(payloadChannels.count == DiscordMemberListRangePolicy.maximumSubscribedMemberLists)
    #expect(payloadChannels[channels[0].description] == nil)
    #expect(payloadChannels[channels[1].description] as? [[Int]] == [[0, 99]])
    #expect(payloadChannels[channels[5].description] as? [[Int]] == [
        [0, 99], [200, 299],
    ])
}

@Test func `channels sharing a list id consume one request budget slot`() {
    let general = ChannelID(rawValue: 1)
    let anotherPublicChannel = ChannelID(rawValue: 2)
    let initial = DiscordMemberListRangePolicy.subscriptionState(
        selecting: "everyone",
        channelID: general,
        ranges: [0 ... 99],
        currentSubscriptions: [:],
        currentOrder: []
    )
    let samePermissionView = DiscordMemberListRangePolicy.subscriptionState(
        selecting: "everyone",
        channelID: anotherPublicChannel,
        ranges: [0 ... 99],
        currentSubscriptions: initial.subscriptionsByMemberListID,
        currentOrder: initial.memberListOrder
    )

    #expect(samePermissionView.memberListOrder == ["everyone"])
    #expect(samePermissionView.rangesByChannel.count == 1)
    #expect(samePermissionView.rangesByChannel[anotherPublicChannel] == [0 ... 99])
    #expect(!DiscordMemberListRangePolicy.requiresSubscriptionUpdate(
        memberListID: "everyone",
        ranges: [0 ... 99],
        currentSubscriptions: initial.subscriptionsByMemberListID
    ))
}

@Test func `member list identity follows server id and permission fallback`() throws {
    let guildID = GuildID(rawValue: 100)
    let roles = try JSONDecoder().decode(
        [GuildRoleDTO].self,
        from: Data(
            #"[{"id":"100","name":"@everyone","position":0,"hoist":false,"permissions":"1024"}]"#.utf8
        )
    )
    let publicChannel = Channel(
        id: ChannelID(rawValue: 1), guildID: guildID, name: "general"
    )
    let restrictedA = Channel(
        id: ChannelID(rawValue: 2), guildID: guildID, name: "og-members",
        permissionOverwrites: [
            ChannelPermissionOverwrite(id: "100", type: 0, deny: 1 << 10),
            ChannelPermissionOverwrite(id: "200", type: 0, allow: 1 << 10),
        ]
    )
    let restrictedB = Channel(
        id: ChannelID(rawValue: 3), guildID: guildID, name: "staff-copy",
        permissionOverwrites: restrictedA.permissionOverwrites
    )
    let serverIdentified = Channel(
        id: ChannelID(rawValue: 4), guildID: guildID, name: "server-id",
        memberListID: "provided-by-gateway"
    )

    #expect(DiscordMemberListIdentity.id(
        for: publicChannel, guildID: guildID, roles: roles
    ) == "everyone")
    let restrictedID = DiscordMemberListIdentity.id(
        for: restrictedA, guildID: guildID, roles: roles
    )
    #expect(restrictedID == "2500999677")
    #expect(restrictedID == DiscordMemberListIdentity.id(
        for: restrictedB, guildID: guildID, roles: roles
    ))
    #expect(DiscordMemberListIdentity.id(
        for: serverIdentified, guildID: guildID, roles: roles
    ) == "provided-by-gateway")

    let decodedChannel = try JSONDecoder().decode(
        ChannelDTO.self,
        from: Data(
            #"{"id":"5","guild_id":"100","name":"decoded","type":0,"member_list_id":"gateway-list"}"#.utf8
        )
    )
    #expect(try decodedChannel.domain(guildID: guildID).memberListID == "gateway-list")
}

@Test func `guild member list update retains authoritative group counts and order`() throws {
    let payloadText =
        #"{"guild_id":"100","id":"everyone","ops":[],"member_count":500,"online_count":388,"groups":["# +
        #"{"id":"20","count":1},{"id":"10","count":2},{"id":"online","count":388}]}"#
    let payload = Data(payloadText.utf8)

    let update = try JSONDecoder().decode(GuildMemberListUpdateDTO.self, from: payload)

    #expect(update.id == "everyone")
    #expect(update.memberCount == 500)
    #expect(update.onlineCount == 388)
    #expect(update.groups?.map(\.id) == ["20", "10", "online"])
    #expect(update.groups?.map(\.count) == [1, 2, 388])
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
    #expect(directReady.friendUserIDs == jsonReady.friendUserIDs)
    #expect(directReady.relationshipNicknamesByUserID == jsonReady.relationshipNicknamesByUserID)
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

    #expect(ready.friendUserIDs == [UserID(rawValue: 200)])
    #expect(ready.relationshipNicknamesByUserID[UserID(rawValue: 200)]
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
