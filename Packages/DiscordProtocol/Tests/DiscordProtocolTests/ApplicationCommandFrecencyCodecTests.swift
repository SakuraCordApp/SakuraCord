import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

struct ApplicationCommandFrecencyCodecTests {
    @Test func `command frecency patch encodes field 7 the way Discord's client writes it`() {
        let history = DiscordFrecencyHistory(entries: [
            DiscordFrecencyEntry(key: "-7", totalUses: 3, recentUses: [1, 300], frecency: 2, score: 1),
            DiscordFrecencyEntry(key: "9\u{0}sub:8", totalUses: 1, recentUses: [5], frecency: -1, score: 0),
        ])

        let patch = DiscordSettingsProto.frecencyPatch(
            history,
            field: DiscordSettingsProto.applicationCommandFrecencyField,
            limit: DiscordSettingsProto.maximumApplicationCommandFrecencyEntries
        )

        // value: total_uses, packed recent_uses, frecency, score; zero fields omitted.
        let first: [UInt8] = [0x08, 3, 0x12, 3, 1, 0xAC, 0x02, 0x18, 2, 0x20, 1]
        let negativeOne: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        let second: [UInt8] = [0x08, 1, 0x12, 1, 5, 0x18] + negativeOne
        func mapEntry(_ key: String, _ value: [UInt8]) -> [UInt8] {
            let body = [0x0A, UInt8(key.utf8.count)] + Array(key.utf8) + [0x12, UInt8(value.count)] + value
            return [0x0A, UInt8(body.count)] + body
        }
        let map = mapEntry("-7", first) + mapEntry("9\u{0}sub:8", second)
        #expect(Array(patch) == [0x3A, UInt8(map.count)] + map)
        #expect(DiscordSettingsProto.frecencyHistory(from: patch, field: DiscordSettingsProto.applicationCommandFrecencyField) == history)
    }

    @Test func `command frecency save keeps the 500 most recently used entries`() {
        let entries = (0 ..< 502).map {
            DiscordFrecencyEntry(
                key: "\($0)", totalUses: 1, recentUses: [UInt64(1_000 + ($0 == 0 ? 5_000 : $0))], frecency: 1, score: 1
            )
        }

        let patch = DiscordSettingsProto.frecencyPatch(
            DiscordFrecencyHistory(entries: entries),
            field: DiscordSettingsProto.applicationCommandFrecencyField,
            limit: DiscordSettingsProto.maximumApplicationCommandFrecencyEntries
        )
        let saved = DiscordSettingsProto.frecencyHistory(
            from: patch, field: DiscordSettingsProto.applicationCommandFrecencyField
        )?.entries.map(\.key) ?? []

        #expect(saved.count == 500)
        #expect(saved.first == "0")
        #expect(!saved.contains("1") && !saved.contains("2"))
    }

    @Test func `emoji history keeps 100 recent entries and preserves unknown value bytes`() throws {
        let history = DiscordFrecencyHistory(entries: (0 ..< 102).map {
            .init(key: "emoji\($0)", totalUses: 1, recentUses: [UInt64($0 + 1)], frecency: 100, score: 100)
        })
        let patch = DiscordSettingsProto.frecencyPatch(history, field: DiscordSettingsProto.emojiFrecencyField, limit: 100)
        let saved = try #require(DiscordSettingsProto.frecencyHistory(from: patch, field: DiscordSettingsProto.emojiFrecencyField))
        #expect(saved.entries.count == 100)
        #expect(saved.entries.first?.key == "emoji101")
        #expect(saved.entries.last?.key == "emoji2")
        // Field 6 map entry "x", unknown value field 9 = 7.
        let original = Data([0x32, 9, 0x0A, 7, 0x0A, 1, 0x78, 0x12, 2, 0x48, 7])
        let updated = DiscordSettingsProto.frecencyPatch(
            .init(entries: [.init(key: "x", totalUses: 1, recentUses: [9])]),
            field: DiscordSettingsProto.emojiFrecencyField, limit: 100, preserving: original
        )
        #expect(updated.range(of: Data([0x48, 7])) != nil)
    }

    @Test func `settings without command frecency are not treated as an empty history`() {
        let field = DiscordSettingsProto.applicationCommandFrecencyField
        #expect(DiscordSettingsProto.frecencyHistory(from: Data([0x08, 0x01]), field: field) == nil)
        #expect(DiscordSettingsProto.frecencyHistory(from: Data([0x3A, 0x00]), field: field)?.entries.isEmpty == true)
    }
}
