import Foundation
import SakuraCordModels

extension DiscordSettingsProto {
    private struct ScoredSticker {
        var id: String
        var score: Int
        var sourceIndex: Int
    }

    struct StickerSettingsUpdate {
        var data: Data
        var settings: StickerUserSettings
        var patch: Data
    }

    static func stickerSettings(
        from data: Data,
        nowMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) -> StickerUserSettings {
        var reader = ProtoReader(data: data)
        var favorites: [String] = []
        var usage: [String: DiscordFrecencyUsage] = [:]
        var usageOrder: [String] = []
        while let field = reader.readRawField() {
            guard field.wireType == 2, let payload = field.payload else { continue }
            if field.field == 3 {
                favorites = stickerIDs(fromFavoritesPayload: payload)
            } else if field.field == 4 {
                let decoded = stickerUsage(from: payload)
                usage = decoded.usage
                usageOrder = decoded.order
            }
        }

        let scored = usageOrder.enumerated().compactMap { index, id -> ScoredSticker? in
            guard let value = usage[id],
                  let score = stickerFrecency(value, nowMilliseconds: nowMilliseconds)
            else { return nil }
            return ScoredSticker(id: id, score: score, sourceIndex: index)
        }
        let ordered = scored.sorted { left, right in
            left.score == right.score
                ? left.sourceIndex < right.sourceIndex
                : left.score > right.score
        }
        return StickerUserSettings(
            favoriteIDs: favorites,
            frequentlyUsedIDs: Array(ordered.prefix(9).map(\.id)),
            usageScores: Dictionary(uniqueKeysWithValues: scored.map { ($0.id, $0.score) }),
            usage: usage,
            usageOrder: usageOrder
        )
    }

    static func updatingStickerFavorite(
        in data: Data,
        stickerID: String,
        isFavorite: Bool
    ) throws -> StickerSettingsUpdate {
        guard UInt64(stickerID) != nil else {
            throw ChatProviderError.invalidRequest("The sticker identifier is invalid.")
        }
        var favorites = stickerSettings(from: data).favoriteIDs
        favorites.removeAll { $0 == stickerID }
        if isFavorite {
            favorites.append(stickerID)
        }
        let payload = stickerFavoritesPayload(favorites)
        let updated = replacingLengthDelimitedField(3, in: data, with: payload)
        return StickerSettingsUpdate(
            data: updated,
            settings: stickerSettings(from: updated),
            patch: stickerLengthDelimitedField(3, payload)
        )
    }

    static func recordingStickerUse(
        in data: Data,
        stickerID: String,
        timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> StickerSettingsUpdate {
        guard let numericStickerID = UInt64(stickerID) else {
            throw ChatProviderError.invalidRequest("The sticker identifier is invalid.")
        }
        let currentPayload = stickerLengthDelimitedPayload(4, in: data) ?? Data()
        let payload = recordingStickerUse(
            numericStickerID,
            in: currentPayload,
            timestamp: timestamp
        )
        let updated = replacingLengthDelimitedField(4, in: data, with: payload)
        return StickerSettingsUpdate(
            data: updated,
            settings: stickerSettings(from: updated, nowMilliseconds: timestamp),
            patch: stickerLengthDelimitedField(4, payload)
        )
    }

    private static func stickerIDs(fromFavoritesPayload data: Data) -> [String] {
        var reader = ProtoReader(data: data)
        var result: [String] = []
        var seen: Set<UInt64> = []
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 1, let value = reader.readFixed64() {
                if seen.insert(value).inserted { result.append(String(value)) }
            } else if tag.field == 1, tag.wireType == 2,
                      let packed = reader.readLengthDelimited()
            {
                var packedReader = ProtoReader(data: packed)
                while let value = packedReader.readFixed64() {
                    if seen.insert(value).inserted { result.append(String(value)) }
                }
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        return result
    }

    private static func stickerFavoritesPayload(_ ids: [String]) -> Data {
        guard !ids.isEmpty else { return Data() }
        var packed = Data()
        for id in ids.compactMap(UInt64.init) {
            packed.append(stickerFixed64(id))
        }
        return stickerLengthDelimitedField(1, packed)
    }

    private static func stickerUsage(from data: Data) -> (
        usage: [String: DiscordFrecencyUsage], order: [String]
    ) {
        var reader = ProtoReader(data: data)
        var usage: [String: DiscordFrecencyUsage] = [:]
        var order: [String] = []
        while let tag = reader.readTag() {
            guard tag.field == 1, tag.wireType == 2,
                  let entry = reader.readLengthDelimited()
            else {
                if !reader.skip(wireType: tag.wireType) { break }
                continue
            }
            var entryReader = ProtoReader(data: entry)
            var id: UInt64?
            var valueData: Data?
            while let entryTag = entryReader.readTag() {
                if entryTag.field == 1, entryTag.wireType == 1 {
                    id = entryReader.readFixed64()
                } else if entryTag.field == 2, entryTag.wireType == 2 {
                    valueData = entryReader.readLengthDelimited()
                } else if !entryReader.skip(wireType: entryTag.wireType) {
                    break
                }
            }
            guard let id, let valueData, let value = stickerUsageValue(from: valueData) else {
                continue
            }
            let key = String(id)
            if usage[key] == nil { order.append(key) }
            usage[key] = value
        }
        return (usage, order)
    }

    private static func stickerUsageValue(from data: Data) -> DiscordFrecencyUsage? {
        var reader = ProtoReader(data: data)
        var totalUses = 0
        var recentUses: [UInt64] = []
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 0, let value = reader.readVarint() {
                totalUses = Int(clamping: value)
            } else if tag.field == 2, tag.wireType == 0, let value = reader.readVarint() {
                if value > 0 { recentUses.append(value) }
            } else if tag.field == 2, tag.wireType == 2,
                      let packed = reader.readLengthDelimited()
            {
                var packedReader = ProtoReader(data: packed)
                while let value = packedReader.readVarint() {
                    if value > 0 { recentUses.append(value) }
                }
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        guard totalUses > 0 || !recentUses.isEmpty else { return nil }
        return DiscordFrecencyUsage(totalUses: totalUses, recentUses: Array(recentUses.prefix(10)))
    }

    private static func stickerLengthDelimitedPayload(_ fieldNumber: Int, in data: Data) -> Data? {
        var reader = ProtoReader(data: data)
        var payload: Data?
        while let field = reader.readRawField() {
            if field.field == fieldNumber, field.wireType == 2 {
                payload = field.payload
            }
        }
        return payload
    }

    private static func recordingStickerUse(
        _ stickerID: UInt64,
        in data: Data,
        timestamp: UInt64
    ) -> Data {
        var reader = ProtoReader(data: data)
        var fields: [RawProtoField] = []
        while let field = reader.readRawField() {
            fields.append(field)
        }
        let matchingIndex = fields.indices.last { index in
            guard fields[index].field == 1,
                  fields[index].wireType == 2,
                  let payload = fields[index].payload
            else { return false }
            return stickerUsageEntry(from: payload)?.id == stickerID
        }

        var result = Data()
        for index in fields.indices {
            guard index == matchingIndex,
                  let payload = fields[index].payload,
                  let entry = stickerUsageEntry(from: payload)
            else {
                result.append(fields[index].raw)
                continue
            }
            result.append(stickerLengthDelimitedField(
                1,
                updatedStickerUsageEntry(entry, timestamp: timestamp)
            ))
        }
        if matchingIndex == nil {
            let entry = StickerUsageEntry(id: stickerID, value: nil, unknownFields: Data())
            result.append(stickerLengthDelimitedField(
                1,
                updatedStickerUsageEntry(entry, timestamp: timestamp)
            ))
        }
        return result
    }

    private struct StickerUsageEntry {
        var id: UInt64
        var value: Data?
        var unknownFields: Data
    }

    private static func stickerUsageEntry(from data: Data) -> StickerUsageEntry? {
        var reader = ProtoReader(data: data)
        var id: UInt64?
        var value: Data?
        var unknownFields = Data()
        while let field = reader.readRawField() {
            if field.field == 1, field.wireType == 1 {
                var fieldReader = ProtoReader(data: field.raw)
                guard fieldReader.readTag() != nil else { continue }
                id = fieldReader.readFixed64()
            } else if field.field == 2, field.wireType == 2 {
                value = field.payload
            } else {
                unknownFields.append(field.raw)
            }
        }
        guard let id else { return nil }
        return StickerUsageEntry(id: id, value: value, unknownFields: unknownFields)
    }

    private static func updatedStickerUsageEntry(
        _ entry: StickerUsageEntry,
        timestamp: UInt64
    ) -> Data {
        var usage = entry.value.flatMap(stickerUsageValue(from:))
            ?? DiscordFrecencyUsage(totalUses: 0, recentUses: [])
        usage.totalUses += 1
        usage.recentUses.insert(timestamp, at: 0)
        let sampled = Array(usage.recentUses.prefix(10))

        var value = stickerVarintField(1, UInt64(clamping: usage.totalUses))
        var packed = Data()
        for recentUse in sampled { packed.append(stickerVarint(recentUse)) }
        value.append(stickerLengthDelimitedField(2, packed))
        let weights = stickerWeightSum(sampled, nowMilliseconds: timestamp)
        let frecency = Int(ceil(Double(usage.totalUses) * Double(weights) / Double(sampled.count)))
        value.append(stickerVarintField(3, UInt64(clamping: frecency)))
        value.append(stickerVarintField(4, UInt64(clamping: weights)))
        if let currentValue = entry.value {
            var valueReader = ProtoReader(data: currentValue)
            while let field = valueReader.readRawField() {
                if !(1 ... 4).contains(field.field) {
                    value.append(field.raw)
                }
            }
        }

        var result = stickerFixed64Field(1, entry.id)
        result.append(stickerLengthDelimitedField(2, value))
        result.append(entry.unknownFields)
        return result
    }

    private static func stickerFrecency(
        _ usage: DiscordFrecencyUsage,
        nowMilliseconds: UInt64
    ) -> Int? {
        let sampled = Array(usage.recentUses.prefix(10))
        guard !sampled.isEmpty else { return nil }
        let weights = stickerWeightSum(sampled, nowMilliseconds: nowMilliseconds)
        return Int(ceil(Double(usage.totalUses) * Double(weights) / Double(sampled.count)))
    }

    private static func stickerWeightSum(
        _ timestamps: [UInt64],
        nowMilliseconds: UInt64
    ) -> Int {
        let millisecondsPerDay: UInt64 = 86_400_000
        return timestamps.reduce(into: 0) { result, timestamp in
            let age = timestamp >= nowMilliseconds
                ? 0
                : Int((nowMilliseconds - timestamp) / millisecondsPerDay)
            let weight = switch age {
            case ...3: 100
            case ...15: 70
            case ...30: 50
            case ...45: 30
            case ...80: 10
            default: 1
            }
            result += weight
        }
    }

    private static func stickerFixed64Field(_ field: Int, _ value: UInt64) -> Data {
        var data = stickerVarint(UInt64(field << 3 | 1))
        data.append(stickerFixed64(value))
        return data
    }

    private static func stickerFixed64(_ value: UInt64) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    private static func stickerLengthDelimitedField(_ field: Int, _ value: Data) -> Data {
        var data = stickerVarint(UInt64(field << 3 | 2))
        data.append(stickerVarint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func stickerVarintField(_ field: Int, _ value: UInt64) -> Data {
        var data = stickerVarint(UInt64(field << 3))
        data.append(stickerVarint(value))
        return data
    }

    private static func stickerVarint(_ source: UInt64) -> Data {
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
