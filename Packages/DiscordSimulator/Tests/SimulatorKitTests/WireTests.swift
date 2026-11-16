import Foundation
@testable import SimulatorKit
import Testing

struct WireTests {
    /// A settings PATCH carries only the changed sections; saving one must keep the others and apply clears.
    @Test func settingsPatchMergesIntoStoredSettings() throws {
        // field 11 { field 1: 1, field 2: "a" }, field 9 { field 1: 1 }
        let stored = Data([0x5A, 0x05, 0x08, 0x01, 0x12, 0x01, 0x61, 0x4A, 0x02, 0x08, 0x01])
        // field 11 { field 1: 1 } (field 2 cleared), field 15 { field 1: 2 }
        let patch = Data([0x5A, 0x02, 0x08, 0x01, 0x7A, 0x02, 0x08, 0x02])
        let merged = try #require(ProtobufMerge.merge(stored, patch))
        #expect(merged == Data([0x4A, 0x02, 0x08, 0x01, 0x5A, 0x02, 0x08, 0x01, 0x7A, 0x02, 0x08, 0x02]))
        #expect(ProtobufMerge.merge(stored, Data([0x5A, 0x09])) == nil)
    }

    @Test func etfRoundTripsThroughDecoder() throws {
        let value: JSON = [
            "op": 0, "s": 300, "big": 4_294_967_296, "negative": -70_000, "ratio": 0.25,
            "flag": true, "none": nil, "text": "héllo ✿", "empty": [], "bytes": [1, 2, 255],
            "nested": ["list": [1, "two", ["three": 3]]],
        ]
        let (bytes, _) = ETFEncoder.encode(value, shape: nil)
        #expect(try ETFDecoder.decode(bytes) == value)
    }

    @Test func snowflakesUseSmallBigWhenCaptured() throws {
        let shape = try ShapeNode(encoded: JSON.parse("""
            {"t": "object", "etf": "map", "f": {
              "id": {"t": "snowflake", "etf": "small_big", "ketf": "atom"},
              "name": {"t": "string", "etf": "binary", "ketf": "binary"}}}
            """))
        let value: JSON = ["id": "1439012345678901234", "name": "general"]
        let (bytes, tags) = ETFEncoder.encode(value, shape: shape)

        #expect(tags["/id"] == "small_big")
        #expect(tags["/id#key"] == "atom")
        #expect(tags["/name#key"] == "binary")
        // 131, MAP_EXT arity 2, ATOM_EXT "id", SMALL_BIG_EXT with 8 digits.
        #expect(Array(bytes.prefix(13)) == [131, 116, 0, 0, 0, 2, 100, 0, 2, 0x69, 0x64, 110, 8])
        #expect(try ETFDecoder.decode(bytes) == value)

        let (_, untyped) = ETFEncoder.encode(value, shape: nil)
        #expect(untyped["/id"] == "binary")
    }

    @Test func messageCreateTagsMatchCapture() throws {
        let shapes = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/SimulatorKit/Resources/Shapes").standardized
        let node = try #require(try ShapeCatalog.load(from: shapes).gateway["MESSAGE_CREATE"])
        let frame = Self.messageCreate
        #expect(ShapeChecker.check(frame, against: node).isEmpty)

        let (bytes, tags) = ETFEncoder.encode(frame, shape: node)
        #expect(ShapeChecker.checkETF(tags, against: node) == [])
        #expect(tags["/d/id"] == "small_big")
        #expect(tags["/d/mention_roles"] == "nil")
        #expect(tags["/t"] == "atom")
        #expect(tags["/d/member/deaf#key"] == "atom")
        #expect(tags["/d/content#key"] == "binary")
        #expect(try ETFDecoder.decode(bytes) == frame)
    }

    @Test func decoderReadsOtherClientTags() throws {
        // SMALL_TUPLE {SMALL_ATOM_UTF8 ok, LARGE_BIG 2^64, FLOAT_EXT 1.5}
        var bytes: [UInt8] = [131, 104, 3, 119, 2, 0x6F, 0x6B, 111, 0, 0, 0, 9, 0] + [UInt8](repeating: 0, count: 8) + [1]
        bytes += [99] + Array("1.50000000000000000000e+00".utf8) + [UInt8](repeating: 0, count: 5)
        #expect(try ETFDecoder.decode(Data(bytes)) == ["ok", "18446744073709551616", 1.5])
    }

    @Test func zstdStreamDecodesEachMessageOnArrival() throws {
        let compressor = ZstdStreamCompressor()
        let decompressor = ZstdStreamDecompressor()
        for message in Self.messages {
            #expect(try decompressor.decompress(compressor.compress(message)) == message)
        }
    }

    @Test func zlibStreamEndsEachMessageWithSyncFlush() throws {
        let compressor = ZlibStreamCompressor()
        let decompressor = ZlibStreamDecompressor()
        for message in Self.messages {
            let compressed = compressor.compress(message)
            #expect(compressed.suffix(4) == Data([0x00, 0x00, 0xFF, 0xFF]))
            #expect(try decompressor.decompress(compressed) == message)
        }
    }

    @Test func codecFramesFollowQueryParameters() throws {
        let frame: JSON = ["t": nil, "s": nil, "op": 10, "d": ["heartbeat_interval": 41250]]

        let etf = GatewayFrameCodec(encoding: "etf", compression: "zstd-stream")
        let decompressor = ZstdStreamDecompressor()
        for _ in 0 ..< 2 {
            let encoded = etf.encode(frame, shape: nil)
            #expect(encoded.isBinary)
            #expect(try etf.decodeClientFrame(decompressor.decompress(encoded.data)) == frame)
        }

        let json = GatewayFrameCodec(encoding: "json", compression: nil)
        let text = json.encode(frame, shape: nil)
        #expect(!text.isBinary)
        #expect((String(bytes: text.data, encoding: .utf8) ?? "") == #"{"t":null,"s":null,"op":10,"d":{"heartbeat_interval":41250}}"#)
        #expect(try json.decodeClientFrame(text.data) == frame)
    }

    private static let messages = [
        Data(#"{"op":10,"d":{"heartbeat_interval":41250}}"#.utf8),
        Data(String(repeating: #"{"op":0,"t":"TYPING_START"}"#, count: 400).utf8),
        Data(#"{"op":11,"d":null}"#.utf8),
    ]

    private static let messageCreate: JSON = [
        "t": "MESSAGE_CREATE", "s": 7, "op": 0,
        "d": [
            "guild_id": "1100000000000000001",
            "attachments": [],
            "author": [
                "avatar": nil, "discriminator": "0", "global_name": "Sakura",
                "id": "1100000000000000002", "public_flags": 0, "username": "sakura",
            ],
            "channel_id": "1100000000000000003",
            "channel_type": 0,
            "components": [],
            "content": "hello",
            "edited_timestamp": nil,
            "embeds": [],
            "flags": 0,
            "id": "1439012345678901234",
            "member": [
                "avatar": nil, "banner": nil, "communication_disabled_until": nil, "deaf": false, "flags": 0, "joined_at": "2026-01-02T03:04:05.000000+00:00",
                "mute": false, "nick": nil, "pending": false, "premium_since": nil,
                "roles": ["1100000000000000004"],
            ],
            "mention_everyone": false,
            "mention_roles": [],
            "mentions": [],
            "nonce": "1439012345678901000",
            "pinned": false,
            "timestamp": "2026-11-16T00:23:41.123000+00:00",
            "tts": false,
            "type": 0,
        ],
    ]
}
