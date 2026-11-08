import Foundation
import SakuraCordModels

/// Shared usage-map encoding for emoji (6), commands (7), applications (9) and reactions (13).
extension DiscordSettingsProto {
    static let applicationCommandFrecencyField = 7
    /// Launched applications, which the Activity shelf lists as Recents.
    static let applicationFrecencyField = 9
    /// Discord keeps at most this many command entries when saving.
    static let maximumApplicationCommandFrecencyEntries = 500

    static func applicationCommandFrecency(from data: Data) -> DiscordFrecencyHistory? {
        frecencyHistory(from: data, field: applicationCommandFrecencyField)
    }

    static func frecencyHistory(from data: Data, field fieldNumber: Int) -> DiscordFrecencyHistory? {
        var reader = ProtoReader(data: data)
        var payload: Data?
        var found = false
        while let field = reader.readRawField() {
            if field.field == fieldNumber, field.wireType == 2 {
                payload = field.payload
                found = true
            }
        }
        guard found else { return nil }
        return frecencyHistory(mapPayload: payload ?? Data())
    }

    static func frecencyHistory(mapPayload data: Data) -> DiscordFrecencyHistory {
        var reader = ProtoReader(data: data)
        var entries: [DiscordFrecencyEntry] = []
        var indexByKey: [String: Int] = [:]
        while let tag = reader.readTag() {
            guard tag.field == 1, tag.wireType == 2, let entryData = reader.readLengthDelimited() else {
                if !reader.skip(wireType: tag.wireType) { break }
                continue
            }
            var entryReader = ProtoReader(data: entryData)
            var key: String?
            var item = DiscordFrecencyEntry(key: "", totalUses: 0, recentUses: [], frecency: 0, score: 0)
            while let entryTag = entryReader.readTag() {
                if entryTag.field == 1, entryTag.wireType == 2, let bytes = entryReader.readLengthDelimited() {
                    key = String(bytes: bytes, encoding: .utf8)
                } else if entryTag.field == 2, entryTag.wireType == 2, let bytes = entryReader.readLengthDelimited() {
                    item = frecencyItem(from: bytes)
                } else if !entryReader.skip(wireType: entryTag.wireType) {
                    break
                }
            }
            guard let key else { continue }
            item.key = key
            // A repeated map key replaces the earlier value in place, as in JavaScript objects.
            if let index = indexByKey[key] {
                entries[index] = item
            } else {
                indexByKey[key] = entries.count
                entries.append(item)
            }
        }
        return DiscordFrecencyHistory(entries: entries)
    }

    private static func frecencyItem(from data: Data) -> DiscordFrecencyEntry {
        var reader = ProtoReader(data: data)
        var item = DiscordFrecencyEntry(key: "", totalUses: 0, recentUses: [], frecency: 0, score: 0)
        while let tag = reader.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 0):
                item.totalUses = Int(truncatingIfNeeded: UInt32(truncatingIfNeeded: reader.readVarint() ?? 0))
            case (2, 0):
                if let value = reader.readVarint() { item.recentUses.append(value) }
            case (2, 2):
                if let packed = reader.readLengthDelimited() {
                    var packedReader = ProtoReader(data: packed)
                    while let value = packedReader.readVarint() { item.recentUses.append(value) }
                }
            case (3, 0):
                item.frecency = Int32(truncatingIfNeeded: reader.readVarint() ?? 0)
            case (4, 0):
                item.score = Int32(truncatingIfNeeded: reader.readVarint() ?? 0)
            default:
                if !reader.skip(wireType: tag.wireType) { return item }
            }
        }
        return item
    }

    /// The partial settings proto carrying only field 7, as Discord's client
    /// sends it. Entries beyond the limit drop the least recently used, which
    /// also reorders by recency like Discord's serializer.
    static func applicationCommandFrecencyPatch(_ history: DiscordFrecencyHistory) -> Data {
        frecencyPatch(history, field: applicationCommandFrecencyField, limit: maximumApplicationCommandFrecencyEntries)
    }

    static func frecencyPatch(_ history: DiscordFrecencyHistory, field: Int, limit: Int, preserving current: Data = Data()) -> Data {
        var entries = history.entries
        if entries.count > limit {
            entries = stableSorted(entries) { ($0.recentUses.last ?? 0) < ($1.recentUses.last ?? 0) }
            entries.reverse()
            entries.removeLast(entries.count - limit)
        }
        if field == 6 || field == 13 {
            // Protobuf's JS writer enumerates an object: integer-index keys
            // precede other keys even after the serializer's recency pruning.
            entries = entries.enumerated().sorted { left, right in
                let leftIndex = UInt32(left.element.key).flatMap { $0 < UInt32.max && String($0) == left.element.key ? $0 : nil }
                let rightIndex = UInt32(right.element.key).flatMap { $0 < UInt32.max && String($0) == right.element.key ? $0 : nil }
                if let leftIndex, let rightIndex { return leftIndex < rightIndex }
                if leftIndex != nil { return true }
                if rightIndex != nil { return false }
                return left.offset < right.offset
            }.map(\.element)
        }
        let preserved = frecencyUnknownFields(in: current, field: field)
        var map = preserved.container
        for entry in entries {
            var value = preserved.values[entry.key] ?? Data()
            if entry.totalUses != 0 { value.append(frecencyVarintField(1, UInt64(UInt32(truncatingIfNeeded: entry.totalUses)))) }
            let recent = entry.recentUses.filter { $0 > 0 }
            if !recent.isEmpty {
                var packed = Data()
                recent.forEach { packed.append(frecencyVarint($0)) }
                value.append(frecencyLengthDelimitedField(2, packed))
            }
            if entry.frecency != 0 { value.append(frecencyVarintField(3, UInt64(bitPattern: Int64(entry.frecency)))) }
            if entry.score != 0 { value.append(frecencyVarintField(4, UInt64(bitPattern: Int64(entry.score)))) }
            var mapEntry = preserved.entries[entry.key] ?? Data()
            mapEntry.append(frecencyLengthDelimitedField(1, Data(entry.key.utf8)))
            mapEntry.append(frecencyLengthDelimitedField(2, value))
            map.append(frecencyLengthDelimitedField(1, mapEntry))
        }
        return frecencyLengthDelimitedField(field, map)
    }

    private struct FrecencyUnknownFields {
        var container = Data()
        var entries: [String: Data] = [:]
        var values: [String: Data] = [:]
    }

    /// Unknown fields survive a usage update even inside a retained map entry.
    private static func frecencyUnknownFields(in data: Data, field: Int) -> FrecencyUnknownFields {
        var root = ProtoReader(data: data)
        var result = FrecencyUnknownFields()
        while let outer = root.readRawField() {
            guard outer.field == field, let payload = outer.payload else { continue }
            var map = ProtoReader(data: payload)
            while let entry = map.readRawField() {
                guard entry.field == 1, let entryPayload = entry.payload else {
                    result.container.append(entry.raw)
                    continue
                }
                var item = ProtoReader(data: entryPayload)
                var key: String?
                var entryUnknown = Data()
                var valueUnknown = Data()
                while let part = item.readRawField() {
                    if part.field == 1, let bytes = part.payload {
                        key = String(data: bytes, encoding: .utf8)
                    } else if part.field == 2, let bytes = part.payload {
                        var value = ProtoReader(data: bytes)
                        while let component = value.readRawField() {
                            if !(1 ... 4).contains(component.field) { valueUnknown.append(component.raw) }
                        }
                    } else { entryUnknown.append(part.raw) }
                }
                if let key { result.entries[key] = entryUnknown; result.values[key] = valueUnknown }
            }
        }
        return result
    }

    private static func stableSorted(
        _ entries: [DiscordFrecencyEntry],
        by areInIncreasingOrder: (DiscordFrecencyEntry, DiscordFrecencyEntry) -> Bool
    ) -> [DiscordFrecencyEntry] {
        entries.enumerated().sorted { left, right in
            if areInIncreasingOrder(left.element, right.element) { return true }
            if areInIncreasingOrder(right.element, left.element) { return false }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func frecencyLengthDelimitedField(_ field: Int, _ value: Data) -> Data {
        var data = frecencyVarint(UInt64(field << 3 | 2))
        data.append(frecencyVarint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func frecencyVarintField(_ field: Int, _ value: UInt64) -> Data {
        var data = frecencyVarint(UInt64(field << 3))
        data.append(frecencyVarint(value))
        return data
    }

    private static func frecencyVarint(_ source: UInt64) -> Data {
        var value = source
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }
}
