import Foundation
import SakuraCordModels

struct ProfileCacheKey: Hashable {
    var userID: UserID
    var guildID: GuildID?
}

struct UserSettingsProtoDTO: Decodable {
    var settings: String
}

struct DiscordGuildLayout: Equatable {
    struct Folder: Equatable {
        var guildIDs: [GuildID]
        var id: Int64?
        var name: String?
        var colorHex: UInt32?
    }

    var folders: [Folder]
    var guildPositions: [GuildID]
}

enum DiscordSettingsProto {
    private struct FrequentEmojiEntry {
        let key: String
        let frecency: Int
        let order: Int
    }

    static func guildOrder(from data: Data) -> [GuildID]? {
        guard let layout = guildLayout(from: data) else { return nil }
        let folderOrder = layout.folders.flatMap(\.guildIDs)
        return folderOrder.isEmpty ? layout.guildPositions : folderOrder
    }

    static func guildLayout(from data: Data) -> DiscordGuildLayout? {
        var topLevel = ProtoReader(data: data)
        while let tag = topLevel.readTag() {
            if tag.field == 14, tag.wireType == 2, let guildFolders = topLevel.readLengthDelimited() {
                return layout(fromGuildFolders: guildFolders)
            }
            guard topLevel.skip(wireType: tag.wireType) else { return nil }
        }
        return nil
    }

    static func emojiSettings(
        from data: Data,
        nowMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) -> EmojiUserSettings {
        var reader = ProtoReader(data: data)
        var favorites: [String] = []
        var favoriteSet: Set<String> = []
        var frequentEntries: [FrequentEmojiEntry] = []
        var scores: [String: Int] = [:]
        var guildAndChannelScores: [String: Int] = [:]
        var guildAndChannelUsage: [String: DiscordFrecencyUsage] = [:]
        var guildAndChannelUsageOrder: [String] = []
        while let tag = reader.readTag() {
            guard tag.wireType == 2, let payload = reader.readLengthDelimited() else {
                if !reader.skip(wireType: tag.wireType) {
                    break
                }
                continue
            }
            if tag.field == 5 {
                for key in strings(fromRepeatedStringField: 1, data: payload)
                    where favoriteSet.insert(key).inserted {
                    favorites.append(key)
                }
            } else if tag.field == 6 {
                for entry in stringFrecencyEntries(
                    from: payload,
                    nowMilliseconds: nowMilliseconds
                ) {
                    scores[entry.key] = max(scores[entry.key, default: 0], entry.score)
                    frequentEntries.append(FrequentEmojiEntry(
                        key: entry.key,
                        frecency: entry.frecency,
                        order: frequentEntries.count
                    ))
                }
            } else if tag.field == 12 {
                let decoded = guildAndChannelFrecency(
                    from: payload,
                    nowMilliseconds: nowMilliseconds
                )
                for (key, score) in decoded.scores {
                    guildAndChannelScores[key] = max(guildAndChannelScores[key, default: 0], score)
                }
                guildAndChannelUsage.merge(decoded.usage) { _, newer in newer }
                for key in decoded.order where !guildAndChannelUsageOrder.contains(key) {
                    guildAndChannelUsageOrder.append(key)
                }
            }
        }
        var seenFrequent: Set<String> = []
        let frequentlyUsed =
            frequentEntries
                .sorted { left, right in
                    left.frecency == right.frecency
                        ? left.order < right.order
                        : left.frecency > right.frecency
                }
                .compactMap { entry in
                    seenFrequent.insert(entry.key).inserted ? entry.key : nil
                }
                .prefix(18)
        return EmojiUserSettings(
            favoriteKeys: favorites,
            frequentlyUsedKeys: Array(frequentlyUsed),
            usageScores: scores,
            guildAndChannelUsageScores: guildAndChannelScores,
            guildAndChannelUsage: guildAndChannelUsage,
            guildAndChannelUsageOrder: guildAndChannelUsageOrder
        )
    }

    static func gifFavorites(from data: Data) -> [GIFSearchResult] {
        decodedGIFFavoriteContainer(from: data).favorites
            .enumerated()
            .sorted { left, right in
                left.element.order == right.element.order
                    ? left.offset < right.offset
                    : left.element.order > right.element.order
            }
            .compactMap { $0.element.domain }
    }

    static func updatingGIFFavorite(
        in data: Data,
        gif: GIFSearchResult,
        isFavorite: Bool
    ) throws -> (data: Data, favorites: [GIFSearchResult]) {
        var container = decodedGIFFavoriteContainer(from: data)
        let key = gif.url.absoluteString
        container.favorites.removeAll { $0.key == key }
        if isFavorite {
            let order = (container.favorites.map(\.order).max() ?? 0) + 1
            let source = gif.previewURL ?? gif.mediaURL ?? gif.url
            container.favorites.append(
                StoredGIFFavorite(
                    key: key,
                    format: DiscordGIFFavoriteMediaPolicy.persistedFormat(
                        for: source,
                        declaredKind: source == gif.mediaURL
                            ? gif.mediaKind
                            : nil
                    ),
                    src: source.absoluteString,
                    width: UInt64(clamping: max(0, gif.width ?? 0)),
                    height: UInt64(clamping: max(0, gif.height ?? 0)),
                    order: order
                )
            )
            if container.favorites.count > 2 {
                container.hideTooltip = true
            }
        }

        let favoritePayload = encodedGIFFavoriteContainer(container)
        guard favoritePayload.count <= 762_880 else {
            throw ChatProviderError.invalidRequest(
                "Discord's GIF favorites storage limit has been reached."
            )
        }
        let updated = replacingLengthDelimitedField(
            2,
            in: data,
            with: favoritePayload
        )
        return (updated, gifFavorites(from: updated))
    }

    private struct StoredGIFFavorite {
        var key: String
        var format: UInt64
        var src: String
        var width: UInt64
        var height: UInt64
        var order: UInt64

        var domain: GIFSearchResult? {
            guard let url = normalizedURL(key),
                  let source = normalizedURL(src)
            else { return nil }
            let preview = DiscordGIFFavoriteMediaPolicy.previewURL(for: source)
            let mediaKind: GIFMediaKind? = switch format {
            case 1: .image
            case 2: .video
            default: nil
            }
            return GIFSearchResult(
                id: key,
                title: "Favorite GIF",
                url: url,
                previewURL: preview,
                width: Int(clamping: width),
                height: Int(clamping: height),
                mediaURL: source,
                mediaKind: mediaKind
            )
        }
    }

    private struct StoredGIFFavoriteContainer {
        var favorites: [StoredGIFFavorite] = []
        var hideTooltip = false
    }

    private static func decodedGIFFavoriteContainer(
        from data: Data
    ) -> StoredGIFFavoriteContainer {
        var topLevel = ProtoReader(data: data)
        while let field = topLevel.readRawField() {
            guard field.field == 2, field.wireType == 2, let payload = field.payload else {
                continue
            }
            return decodedGIFFavoriteContainerPayload(payload)
        }
        return StoredGIFFavoriteContainer()
    }

    private static func decodedGIFFavoriteContainerPayload(
        _ data: Data
    ) -> StoredGIFFavoriteContainer {
        var container = StoredGIFFavoriteContainer()
        var reader = ProtoReader(data: data)
        while let field = reader.readRawField() {
            if field.field == 1, field.wireType == 2, let payload = field.payload,
               let favorite = decodedGIFFavoriteMapEntry(payload)
            {
                container.favorites.append(favorite)
            } else if field.field == 2, field.wireType == 0 {
                container.hideTooltip = field.varint != 0
            }
        }
        return container
    }

    private static func decodedGIFFavoriteMapEntry(_ data: Data) -> StoredGIFFavorite? {
        var reader = ProtoReader(data: data)
        var key: String?
        var favoriteData: Data?
        while let field = reader.readRawField() {
            if field.field == 1, field.wireType == 2, let payload = field.payload {
                key = String(data: payload, encoding: .utf8)
            } else if field.field == 2, field.wireType == 2 {
                favoriteData = field.payload
            }
        }
        guard let key, let favoriteData else { return nil }
        var favorite = StoredGIFFavorite(
            key: key,
            format: 0,
            src: "",
            width: 0,
            height: 0,
            order: 0
        )
        var favoriteReader = ProtoReader(data: favoriteData)
        while let field = favoriteReader.readRawField() {
            switch (field.field, field.wireType) {
            case (1, 0): favorite.format = field.varint ?? 0
            case (2, 2):
                favorite.src = field.payload.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            case (3, 0): favorite.width = field.varint ?? 0
            case (4, 0): favorite.height = field.varint ?? 0
            case (5, 0): favorite.order = field.varint ?? 0
            default: break
            }
        }
        return favorite.src.isEmpty ? nil : favorite
    }

    private static func encodedGIFFavoriteContainer(
        _ container: StoredGIFFavoriteContainer
    ) -> Data {
        var data = Data()
        for favorite in container.favorites {
            var value = Data()
            value.append(protoVarintField(1, favorite.format))
            value.append(protoStringField(2, favorite.src))
            value.append(protoVarintField(3, favorite.width))
            value.append(protoVarintField(4, favorite.height))
            value.append(protoVarintField(5, favorite.order))

            var mapEntry = Data()
            mapEntry.append(protoStringField(1, favorite.key))
            mapEntry.append(protoLengthDelimitedField(2, value))
            data.append(protoLengthDelimitedField(1, mapEntry))
        }
        if container.hideTooltip {
            data.append(protoVarintField(2, 1))
        }
        return data
    }

    private static func replacingLengthDelimitedField(
        _ fieldNumber: Int,
        in data: Data,
        with payload: Data
    ) -> Data {
        var reader = ProtoReader(data: data)
        var result = Data()
        var replaced = false
        while let field = reader.readRawField() {
            if field.field == fieldNumber, field.wireType == 2 {
                if !replaced {
                    result.append(protoLengthDelimitedField(fieldNumber, payload))
                    replaced = true
                }
            } else {
                result.append(field.raw)
            }
        }
        if !replaced {
            result.append(protoLengthDelimitedField(fieldNumber, payload))
        }
        return result
    }

    private static func protoStringField(_ field: Int, _ value: String) -> Data {
        protoLengthDelimitedField(field, Data(value.utf8))
    }

    private static func protoLengthDelimitedField(_ field: Int, _ value: Data) -> Data {
        var data = protoVarint(UInt64(field << 3 | 2))
        data.append(protoVarint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func protoVarintField(_ field: Int, _ value: UInt64) -> Data {
        var data = protoVarint(UInt64(field << 3))
        data.append(protoVarint(value))
        return data
    }

    private static func protoVarint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
        return data
    }

    private static func normalizedURL(_ value: String) -> URL? {
        URL(string: value.hasPrefix("//") ? "https:\(value)" : value)
    }

    private struct GuildAndChannelFrecencyResult {
        var scores: [String: Int]
        var usage: [String: DiscordFrecencyUsage]
        var order: [String]
    }

    private static func guildAndChannelFrecency(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> GuildAndChannelFrecencyResult {
        var reader = ProtoReader(data: data)
        var scores: [String: Int] = [:]
        var usage: [String: DiscordFrecencyUsage] = [:]
        var order: [String] = []
        while let tag = reader.readTag() {
            guard tag.field == 1, tag.wireType == 2,
                  let mapEntry = reader.readLengthDelimited()
            else {
                if !reader.skip(wireType: tag.wireType) { break }
                continue
            }
            var entryReader = ProtoReader(data: mapEntry)
            var key: UInt64?
            var item: Data?
            while let entryTag = entryReader.readTag() {
                if entryTag.field == 1, entryTag.wireType == 1 {
                    key = entryReader.readFixed64()
                } else if entryTag.field == 2, entryTag.wireType == 2 {
                    item = entryReader.readLengthDelimited()
                } else if !entryReader.skip(wireType: entryTag.wireType) {
                    break
                }
            }
            if let key, let item,
               let decoded = decodedGuildAndChannelUsage(from: item)
            {
                let stringKey = String(key)
                if usage[stringKey] == nil { order.append(stringKey) }
                usage[stringKey] = decoded
                if let score = computedGuildAndChannelFrecency(
                    decoded,
                    nowMilliseconds: nowMilliseconds
                ) {
                    scores[stringKey] = score
                }
            }
        }
        return GuildAndChannelFrecencyResult(scores: scores, usage: usage, order: order)
    }

    private static func decodedGuildAndChannelUsage(
        from data: Data
    ) -> DiscordFrecencyUsage? {
        var reader = ProtoReader(data: data)
        var totalUses = 0
        var recentUses: [UInt64] = []
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 0, let value = reader.readVarint() {
                totalUses = Int(clamping: value)
            } else if tag.field == 2, tag.wireType == 0, let value = reader.readVarint() {
                if value > 0 { recentUses.append(value) }
            } else if tag.field == 2, tag.wireType == 2,
                      let packedUses = reader.readLengthDelimited()
            {
                var packedReader = ProtoReader(data: packedUses)
                while let value = packedReader.readVarint() {
                    if value > 0 { recentUses.append(value) }
                }
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        guard totalUses > 0 || !recentUses.isEmpty else { return nil }
        return DiscordFrecencyUsage(totalUses: totalUses, recentUses: recentUses)
    }

    private static func computedGuildAndChannelFrecency(
        _ usage: DiscordFrecencyUsage,
        nowMilliseconds: UInt64
    ) -> Int? {
        let sampledUses = usage.recentUses.prefix(10)
        // Discord's current FrecencyStore replaces the persisted frecency with
        // -1 and resets score to zero before recomputing. Entries without a
        // retained recent-use sample are therefore removed even when the proto
        // still carries stale values in fields 3 and 4.
        guard !sampledUses.isEmpty else { return nil }
        let millisecondsPerDay: UInt64 = 86_400_000
        let recencyScore = sampledUses.reduce(into: 0) { result, timestamp in
            let ageDays =
                timestamp >= nowMilliseconds
                    ? 0
                    : Int((nowMilliseconds - timestamp) / millisecondsPerDay)
            let weight =
                switch ageDays {
                case 0: 100
                case 1: 70
                case 2 ... 3: 50
                case 4 ... 6: 30
                default: 10
                }
            result += weight
        }
        guard recencyScore > 0 else { return nil }
        let computed = ceil(
            Double(usage.totalUses) * Double(recencyScore) / Double(sampledUses.count)
        )
        let recomputed = computed >= Double(Int.max) ? Int.max : Int(computed)
        return recomputed
    }

    private static func strings(fromRepeatedStringField field: Int, data: Data) -> [String] {
        var reader = ProtoReader(data: data)
        var values: [String] = []
        while let tag = reader.readTag() {
            if tag.field == field, tag.wireType == 2,
               let value = reader.readLengthDelimited().flatMap({
                   String(data: $0, encoding: .utf8)
               })
            {
                values.append(value)
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        return values
    }

    private struct FrecencyEntry {
        var key: String
        var score: Int
        var frecency: Int
    }

    private static func stringFrecencyEntries(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> [FrecencyEntry] {
        var reader = ProtoReader(data: data)
        var result: [FrecencyEntry] = []
        while let tag = reader.readTag() {
            guard tag.field == 1, tag.wireType == 2, let entry = reader.readLengthDelimited() else {
                if !reader.skip(wireType: tag.wireType) {
                    break
                }
                continue
            }
            var entryReader = ProtoReader(data: entry)
            var key: String?
            var frecency: (score: Int, frecency: Int)?
            while let entryTag = entryReader.readTag() {
                if entryTag.field == 1, entryTag.wireType == 2 {
                    key = entryReader.readLengthDelimited().flatMap {
                        String(data: $0, encoding: .utf8)
                    }
                } else if entryTag.field == 2, entryTag.wireType == 2,
                          let item = entryReader.readLengthDelimited()
                {
                    frecency = computedFrecency(
                        from: item,
                        nowMilliseconds: nowMilliseconds
                    )
                } else if !entryReader.skip(wireType: entryTag.wireType) {
                    break
                }
            }
            if let key, let frecency {
                result.append(
                    FrecencyEntry(
                        key: key,
                        score: frecency.score,
                        frecency: frecency.frecency
                    ))
            }
        }
        return result
    }

    private static var frecencyComputation:
        (Data, UInt64) -> (score: Int, frecency: Int)?
    {
        { data, nowMilliseconds in
        var reader = ProtoReader(data: data)
        var totalUses = 0
        var recentUses: [UInt64] = []
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 0, let value = reader.readVarint() {
                totalUses = Int(clamping: value)
            } else if tag.field == 2, tag.wireType == 0, let value = reader.readVarint() {
                if value > 0 { recentUses.append(value) }
            } else if tag.field == 2, tag.wireType == 2,
                      let packedUses = reader.readLengthDelimited()
            {
                var packedReader = ProtoReader(data: packedUses)
                while let value = packedReader.readVarint() {
                    if value > 0 { recentUses.append(value) }
                }
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        let sampledUses = recentUses.prefix(10)
        guard !sampledUses.isEmpty else { return nil }
        let millisecondsPerDay: UInt64 = 86_400_000
        let score = sampledUses.reduce(into: 0) { result, timestamp in
            let ageDays =
                timestamp >= nowMilliseconds
                    ? 0
                    : Int((nowMilliseconds - timestamp) / millisecondsPerDay)
            let weight =
                switch ageDays {
                case ...3: 100
                case ...15: 70
                case ...30: 50
                case ...45: 30
                case ...80: 10
                default: 1
                }
            result += weight
        }
        guard score > 0 else { return nil }
        let computedFrecency = ceil(
            Double(totalUses) * Double(score) / Double(sampledUses.count)
        )
        let frecency =
            computedFrecency >= Double(Int.max)
                ? Int.max
                : Int(computedFrecency)
        return (score, frecency)
        }
    }

    private static func computedFrecency(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> (score: Int, frecency: Int)? {
        frecencyComputation(data, nowMilliseconds)
    }

    private static func layout(fromGuildFolders data: Data) -> DiscordGuildLayout {
        var reader = ProtoReader(data: data)
        var folders: [DiscordGuildLayout.Folder] = []
        var legacyOrder: [GuildID] = []
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 2, let folderData = reader.readLengthDelimited() {
                folders.append(folder(from: folderData))
            } else if tag.field == 2 {
                legacyOrder.append(
                    contentsOf: readFixed64Values(wireType: tag.wireType, reader: &reader))
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        return DiscordGuildLayout(folders: folders, guildPositions: legacyOrder)
    }

    private static func folder(from data: Data) -> DiscordGuildLayout.Folder {
        var reader = ProtoReader(data: data)
        var guildIDs: [GuildID] = []
        var id: Int64?
        var name: String?
        var colorHex: UInt32?
        while let tag = reader.readTag() {
            if tag.field == 1 {
                guildIDs.append(
                    contentsOf: readFixed64Values(wireType: tag.wireType, reader: &reader))
            } else if tag.wireType == 2, let wrapper = reader.readLengthDelimited() {
                switch tag.field {
                case 2:
                    id = wrappedVarint(from: wrapper).map { Int64(bitPattern: $0) }
                case 3:
                    name = wrappedString(from: wrapper)?.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if name?.isEmpty == true { name = nil }
                case 4:
                    colorHex = wrappedVarint(from: wrapper).flatMap { UInt32(exactly: $0) }
                default:
                    break
                }
            } else if !reader.skip(wireType: tag.wireType) {
                break
            }
        }
        return DiscordGuildLayout.Folder(
            guildIDs: guildIDs,
            id: id,
            name: name,
            colorHex: colorHex
        )
    }

    private static func wrappedVarint(from data: Data) -> UInt64? {
        var reader = ProtoReader(data: data)
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 0 {
                return reader.readVarint()
            }
            guard reader.skip(wireType: tag.wireType) else { return nil }
        }
        return nil
    }

    private static func wrappedString(from data: Data) -> String? {
        var reader = ProtoReader(data: data)
        while let tag = reader.readTag() {
            if tag.field == 1, tag.wireType == 2 {
                return reader.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) }
            }
            guard reader.skip(wireType: tag.wireType) else { return nil }
        }
        return nil
    }

    private static func readFixed64Values(wireType: Int, reader: inout ProtoReader) -> [GuildID] {
        if wireType == 1, let value = reader.readFixed64() {
            return [GuildID(rawValue: value)]
        }
        if wireType == 2, let packed = reader.readLengthDelimited() {
            var packedReader = ProtoReader(data: packed)
            var values: [GuildID] = []
            while let value = packedReader.readFixed64() {
                values.append(GuildID(rawValue: value))
            }
            return values
        }
        _ = reader.skip(wireType: wireType)
        return []
    }
}

struct ProtoReader {
    var data: Data
    var index = 0

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let value = readVarint() else { return nil }
        return (Int(value >> 3), Int(value & 0x07))
    }

    mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count, shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }
        return nil
    }

    mutating func readFixed64() -> UInt64? {
        guard index + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for offset in 0 ..< 8 {
            value |= UInt64(data[index + offset]) << UInt64(offset * 8)
        }
        index += 8
        return value
    }

    mutating func readLengthDelimited() -> Data? {
        guard let rawLength = readVarint(), rawLength <= UInt64(Int.max) else { return nil }
        let length = Int(rawLength)
        guard index + length <= data.count else { return nil }
        defer { index += length }
        return Data(data[index ..< (index + length)])
    }

    mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0: return readVarint() != nil
        case 1:
            guard index + 8 <= data.count else { return false }
            index += 8
            return true
        case 2: return readLengthDelimited() != nil
        case 5:
            guard index + 4 <= data.count else { return false }
            index += 4
            return true
        default: return false
        }
    }

    mutating func readRawField() -> RawProtoField? {
        let start = index
        guard let tag = readTag() else { return nil }
        var payload: Data?
        var varint: UInt64?
        switch tag.wireType {
        case 0:
            varint = readVarint()
            guard varint != nil else { return nil }
        case 1:
            guard index + 8 <= data.count else { return nil }
            index += 8
        case 2:
            payload = readLengthDelimited()
            guard payload != nil else { return nil }
        case 5:
            guard index + 4 <= data.count else { return nil }
            index += 4
        default:
            return nil
        }
        return RawProtoField(
            field: tag.field,
            wireType: tag.wireType,
            payload: payload,
            varint: varint,
            raw: Data(data[start ..< index])
        )
    }
}

struct RawProtoField {
    var field: Int
    var wireType: Int
    var payload: Data?
    var varint: UInt64?
    var raw: Data
}

struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skippedCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                try elements.append(container.decode(Element.self))
            } catch {
                skippedCount += 1
                _ = try? container.decode(JSONValue.self)
            }
        }
    }
}

extension LossyList: Sendable where Element: Sendable {}

struct LossyValue<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

struct UserNameplateAssetsDTO: Decodable {
    var staticImageURL: String?
    var animatedImageURL: String?
    var videoURL: String?

    enum CodingKeys: String, CodingKey {
        case staticImageURL = "static_image_url"
        case animatedImageURL = "animated_image_url"
        case videoURL = "video_url"
    }
}

struct UserNameplateDTO: Decodable {
    var skuID: String?
    var asset: String?
    var label: String?
    var palette: String?
    var assets: UserNameplateAssetsDTO?

    enum CodingKeys: String, CodingKey {
        case skuID = "sku_id"
        case asset, label, palette, assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skuID = try? container.decode(String.self, forKey: .skuID)
        if skuID == nil, let numericSKU = try? container.decode(UInt64.self, forKey: .skuID) {
            skuID = numericSKU.description
        }
        asset = try container.decodeIfPresent(String.self, forKey: .asset)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        palette = try container.decodeIfPresent(String.self, forKey: .palette)
        assets = try container.decodeIfPresent(UserNameplateAssetsDTO.self, forKey: .assets)
    }
}

struct UserCollectiblesDTO: Decodable {
    var nameplate: UserNameplateDTO?
}

struct UserDTO: Decodable {
    struct AvatarDecorationDTO: Decodable { var asset: String? }

    struct PrimaryGuildDTO: Decodable {
        var identityGuildID: String?
        var identityEnabled: Bool?
        var tag: String?
        var badge: String?
        enum CodingKeys: String, CodingKey {
            case identityGuildID = "identity_guild_id"
            case identityEnabled = "identity_enabled"
            case tag, badge
        }
    }

    struct DisplayNameStyleDTO: Decodable {
        var fontID: Int?
        var effectID: Int?
        var colors: [UInt32]?
        enum CodingKeys: String, CodingKey {
            case fontID = "font_id"
            case effectID = "effect_id"
            case colors
        }
    }

    var id: String
    var username: String?
    var discriminator: String?
    var globalName: String?
    var avatar: String?
    var bot: Bool?
    var system: Bool?
    var banner: String?
    var accentColor: UInt32?
    var bio: String?
    var publicFlags: UInt64?
    var premiumType: Int?
    var avatarDecorationData: AvatarDecorationDTO?
    var collectibles: UserCollectiblesDTO?
    var primaryGuild: PrimaryGuildDTO?
    var displayNameStyles: DisplayNameStyleDTO?
    enum CodingKeys: String, CodingKey {
        case id, username, discriminator
        case globalName = "global_name"
        case avatar, bot, system, banner
        case accentColor = "accent_color"
        case bio
        case publicFlags = "public_flags"
        case premiumType = "premium_type"
        case avatarDecorationData = "avatar_decoration_data"
        case collectibles
        case primaryGuild = "primary_guild"
        case displayNameStyles = "display_name_styles"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Identity is the only required user-store field. Discord frequently
        // evolves optional profile cosmetics independently; a type change in
        // one of those fields must not make LossyList discard the entire user
        // from READY/READY_SUPPLEMENTAL and account-wide search.
        id = try container.decode(String.self, forKey: .id)
        username = try? container.decode(String.self, forKey: .username)
        discriminator = try? container.decode(String.self, forKey: .discriminator)
        globalName = try? container.decode(String.self, forKey: .globalName)
        avatar = try? container.decode(String.self, forKey: .avatar)
        bot = try? container.decode(Bool.self, forKey: .bot)
        system = try? container.decode(Bool.self, forKey: .system)
        banner = try? container.decode(String.self, forKey: .banner)
        accentColor = try? container.decode(UInt32.self, forKey: .accentColor)
        bio = try? container.decode(String.self, forKey: .bio)
        publicFlags = try? container.decode(UInt64.self, forKey: .publicFlags)
        premiumType = try? container.decode(Int.self, forKey: .premiumType)
        avatarDecorationData = try? container.decode(
            AvatarDecorationDTO.self,
            forKey: .avatarDecorationData
        )
        collectibles = try? container.decode(UserCollectiblesDTO.self, forKey: .collectibles)
        primaryGuild = try? container.decode(PrimaryGuildDTO.self, forKey: .primaryGuild)
        displayNameStyles = try? container.decode(
            DisplayNameStyleDTO.self,
            forKey: .displayNameStyles
        )
    }

    func domain() throws -> User {
        guard let id = UserID(id) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid user identifier.")
        }
        let avatarURL = avatar.flatMap { hash in
            URL(
                string:
                "https://cdn.discordapp.com/avatars/\(id)/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
            )
        }
        let decorationURL = avatarDecorationData?.asset.flatMap {
            URL(string: "https://cdn.discordapp.com/avatar-decoration-presets/\($0).png?size=160")
        }
        let nameplate = collectibles?.nameplate.flatMap { value -> Nameplate? in
            let legacyPath = value.asset?.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            let officialBase = value.skuID.map {
                "https://cdn.discordapp.com/media/v1/collectibles-shop/\($0)"
            }
            let staticURL = officialBase.flatMap { URL(string: "\($0)/static") }
                ?? value.assets?.staticImageURL.flatMap(URL.init)
                ?? legacyPath.flatMap {
                    URL(string: "https://cdn.discordapp.com/assets/collectibles/\($0)/static.png")
                }
            let animatedURL = officialBase.flatMap { URL(string: "\($0)/animated") }
                ?? value.assets?.animatedImageURL.flatMap(URL.init)
                ?? legacyPath.flatMap {
                    URL(string: "https://cdn.discordapp.com/assets/collectibles/\($0)/img.png")
                }
            guard staticURL != nil || animatedURL != nil else { return nil }
            return Nameplate(
                staticURL: staticURL,
                animatedURL: animatedURL,
                label: value.label ?? "",
                palette: value.palette ?? "none"
            )
        }
        let guildIdentity: PrimaryGuildIdentity? = primaryGuild.flatMap { value in
            guard value.identityEnabled != false else { return nil }
            let guildID = value.identityGuildID.flatMap(GuildID.init)
            let badgeURL = guildID.flatMap { guildID in
                value.badge.flatMap {
                    URL(
                        string:
                        "https://cdn.discordapp.com/guild-tag-badges/\(guildID)/\($0).png?size=32"
                    )
                }
            }
            return PrimaryGuildIdentity(guildID: guildID, tag: value.tag, badgeURL: badgeURL)
        }
        let nameStyle = displayNameStyles.map {
            DisplayNameStyle(
                fontID: $0.fontID ?? 11, effectID: $0.effectID ?? 1, colors: $0.colors ?? [])
        }
        return User(
            id: id,
            username: username ?? id.description,
            discriminator: discriminator ?? "0",
            displayName: globalName ?? username ?? id.description,
            avatarURL: avatarURL,
            isBot: bot ?? false,
            isSystem: system ?? false,
            avatarDecorationURL: decorationURL,
            nameplate: nameplate,
            primaryGuild: guildIdentity,
            displayNameStyle: nameStyle,
            publicFlags: publicFlags ?? 0,
            premiumType: premiumType ?? 0
        )
    }
}

struct ProfileMetadataDTO: Decodable {
    struct EffectDTO: Decodable {
        var id: String?
        var skuID: String?
        var resolvedID: String? {
            id ?? skuID
        }

        enum CodingKeys: String, CodingKey {
            case id
            case skuID = "sku_id"
        }
    }

    var bio: String?
    var pronouns: String?
    var banner: String?
    var accentColor: UInt32?
    var themeColors: [UInt32]?
    var profileEffect: EffectDTO?
    enum CodingKeys: String, CodingKey {
        case bio, pronouns, banner
        case accentColor = "accent_color"
        case themeColors = "theme_colors"
        case profileEffect = "profile_effect"
    }
}

struct ProfileBadgeDTO: Decodable {
    var id: String
    var description: String?
    var icon: String?
    var link: String?

    var domain: ProfileBadge {
        ProfileBadge(
            id: id,
            description: description ?? id,
            iconURL: icon.flatMap {
                URL(string: "https://cdn.discordapp.com/badge-icons/\($0).png")
            },
            linkURL: link.flatMap(URL.init)
        )
    }
}

struct MutualGuildDTO: Decodable {
    var id: String
    var nick: String?
}

struct ConnectedAccountDTO: Decodable {
    var id: String?
    var type: String
    var name: String?
    var verified: Bool?

    var domain: ConnectedAccount {
        let accountID = id ?? name ?? type
        let displayName = name ?? type.localizedCapitalized
        return ConnectedAccount(
            accountID: accountID,
            type: type,
            name: displayName,
            isVerified: verified ?? false,
            profileURL: Self.profileURL(type: type, accountID: accountID, name: displayName)
        )
    }

    private static var profileURLResolution: (String, String, String) -> URL? {
        { type, accountID, name in
        let encodedID =
            accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? accountID
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let value: String? =
            switch type.lowercased() {
            case "domain": name.contains("://") ? name : "https://\(name)"
            case "github": "https://github.com/\(encodedName)"
            case "instagram": "https://www.instagram.com/\(encodedName)"
            case "reddit": "https://www.reddit.com/user/\(encodedName)"
            case "roblox": "https://www.roblox.com/users/\(encodedID)/profile"
            case "spotify": "https://open.spotify.com/user/\(encodedID)"
            case "steam": "https://steamcommunity.com/profiles/\(encodedID)"
            case "tiktok": "https://www.tiktok.com/@\(encodedName)"
            case "twitch": "https://www.twitch.tv/\(encodedName)"
            case "twitter", "x": "https://x.com/\(encodedName)"
            case "youtube": "https://www.youtube.com/channel/\(encodedID)"
            case "facebook": "https://www.facebook.com/\(encodedID)"
            case "bluesky": "https://bsky.app/profile/\(encodedName)"
            case "mastodon": name.hasPrefix("@") ? nil : "https://mastodon.social/@\(encodedName)"
            case "soundcloud": "https://soundcloud.com/\(encodedName)"
            default: serviceHomeURL(type: type)
            }
        return value.flatMap(URL.init)
        }
    }

    private static func profileURL(type: String, accountID: String, name: String) -> URL? {
        profileURLResolution(type, accountID, name)
    }

    private static func serviceHomeURL(type: String) -> String? {
        switch type.lowercased() {
        case "amazon-music": "https://music.amazon.com"
        case "battlenet": "https://battle.net"
        case "bungie": "https://www.bungie.net"
        case "crunchyroll": "https://www.crunchyroll.com"
        case "ebay": "https://www.ebay.com"
        case "epicgames": "https://www.epicgames.com"
        case "leagueoflegends": "https://www.leagueoflegends.com"
        case "paypal": "https://www.paypal.com"
        case "playstation", "playstation-stg": "https://www.playstation.com"
        case "riotgames": "https://www.riotgames.com"
        case "xbox": "https://www.xbox.com"
        default: nil
        }
    }
}

struct ProfileGuildMemberDTO: Decodable {
    var nick: String?
    var roles: [String]?
    var avatar: String?
    var banner: String?
    var bio: String?
}

struct ProfileEffectConfigDTO: Decodable, Sendable {
    struct AnimationDTO: Decodable, Sendable {
        struct SourceDTO: Decodable, Sendable { var src: String? }

        var src: String?
        var loop: Bool?
        var height: Int?
        var width: Int?
        var duration: Int?
        var start: Int?
        var loopDelay: Int?
        var position: ProfileEffectPositionDTO?
        var zIndex: Int?
        var randomizedSources: LossyList<SourceDTO>?

        var domain: ProfileEffectAnimation? {
            let source = randomizedSources?.elements.compactMap(\.src).first ?? src
            guard let source, let sourceURL = URL(string: source) else { return nil }
            return ProfileEffectAnimation(
                sourceURL: sourceURL,
                isLooping: loop ?? true,
                width: width,
                height: height,
                durationMilliseconds: duration ?? 0,
                startMilliseconds: start ?? 0,
                loopDelayMilliseconds: loopDelay ?? 0,
                positionX: position?.horizontal ?? 0,
                positionY: position?.vertical ?? 0,
                zIndex: zIndex ?? 0
            )
        }
    }

    var type: Int?
    var id: String?
    var skuID: String?
    var title: String?
    var accessibilityLabel: String?
    var reducedMotionSrc: String?
    var staticFrameSrc: String?
    var effects: LossyList<AnimationDTO>?
    enum CodingKeys: String, CodingKey {
        case type, id
        case skuID = "sku_id"
        case title, accessibilityLabel, reducedMotionSrc, staticFrameSrc, effects
    }

    var domain: ProfileEffect {
        ProfileEffect(
            id: id ?? skuID ?? "unknown-effect",
            title: title,
            accessibilityLabel: accessibilityLabel,
            staticURL: staticFrameSrc.flatMap(URL.init),
            reducedMotionURL: reducedMotionSrc.flatMap(URL.init),
            animations: (effects?.elements ?? []).compactMap(\.domain).sorted {
                $0.zIndex < $1.zIndex
            }
        )
    }
}

struct ProfileEffectPositionDTO: Decodable, Sendable {
    var horizontal: Int?
    var vertical: Int?

    private enum CodingKeys: String, CodingKey {
        case horizontal = "x"
        case vertical = "y"
    }
}

struct CollectibleProductDTO: Decodable, Sendable {
    var items: LossyList<ProfileEffectConfigDTO>?
}

struct UserProfileDTO: Decodable {
    var user: UserDTO
    var userProfile: ProfileMetadataDTO?
    var guildMember: ProfileGuildMemberDTO?
    var guildMemberProfile: ProfileMetadataDTO?
    var badges: LossyList<ProfileBadgeDTO>?
    var guildBadges: LossyList<ProfileBadgeDTO>?
    var mutualGuilds: LossyList<MutualGuildDTO>?
    var mutualFriends: LossyList<UserDTO>?
    var mutualFriendsCount: Int?
    var connectedAccounts: LossyList<ConnectedAccountDTO>?
    var premiumSince: String?
    var premiumGuildSince: String?
    var legacyUsername: String?
    enum CodingKeys: String, CodingKey {
        case user
        case userProfile = "user_profile"
        case guildMember = "guild_member"
        case guildMemberProfile = "guild_member_profile"
        case badges
        case guildBadges = "guild_badges"
        case mutualGuilds = "mutual_guilds"
        case mutualFriends = "mutual_friends"
        case mutualFriendsCount = "mutual_friends_count"
        case connectedAccounts = "connected_accounts"
        case premiumSince = "premium_since"
        case premiumGuildSince = "premium_guild_since"
        case legacyUsername = "legacy_username"
    }

    func domain(
        guildID: GuildID?,
        guilds: [GuildID: Guild],
        guildRoles: [GuildRoleDTO],
        effectConfig: ProfileEffectConfigDTO?
    ) throws -> UserProfile {
        var domainUser = try user.domain()
        let displayName =
            guildMember?.nick.flatMap { $0.isEmpty ? nil : $0 } ?? domainUser.displayName
        let guildAvatarURL = guildID.flatMap { guildID in
            guildMember?.avatar.flatMap { hash in
                URL(
                    string:
                    "https://cdn.discordapp.com/guilds/\(guildID)/users/\(domainUser.id)/avatars/\(hash).webp?size=256&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                )
            }
        }
        let avatarURL = guildAvatarURL ?? domainUser.avatarURL
        domainUser.displayName = displayName
        domainUser.avatarURL = avatarURL

        let globalMetadata = userProfile
        let guildMetadata = guildMemberProfile
        let bannerHash =
            guildMetadata?.banner ?? guildMember?.banner ?? globalMetadata?.banner ?? user.banner
        let usesGuildBanner =
            guildID != nil && (guildMetadata?.banner != nil || guildMember?.banner != nil)
        let bannerURL: URL? = bannerHash.flatMap { hash in
            if usesGuildBanner, let guildID {
                return URL(
                    string:
                    "https://cdn.discordapp.com/guilds/\(guildID)/users/\(domainUser.id)/banners/\(hash).webp?size=600&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
                )
            }
            return URL(
                string:
                "https://cdn.discordapp.com/banners/\(domainUser.id)/\(hash).webp?size=600&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
            )
        }

        let roleIDs = Set(guildMember?.roles ?? [])
        let roles =
            guildRoles
                .filter { roleIDs.contains($0.id) }
                .sorted { $0.position > $1.position }
                .compactMap(\.domain)
        let mutualServers = (mutualGuilds?.elements ?? []).compactMap { value -> MutualGuild? in
            guard let id = GuildID(value.id), let guild = guilds[id] else { return nil }
            return MutualGuild(
                id: id, name: guild.name, iconURL: guild.iconURL, nickname: value.nick)
        }
        let friends = (mutualFriends?.elements ?? []).compactMap { try? $0.domain() }
        let allBadges = (badges?.elements ?? []) + (guildBadges?.elements ?? [])
        var seenBadgeIDs = Set<String>()
        let uniqueBadges = allBadges.map(\.domain).filter { seenBadgeIDs.insert($0.id).inserted }
        let effectID =
            guildMetadata?.profileEffect?.resolvedID ?? globalMetadata?.profileEffect?.resolvedID
        let effect = effectConfig?.domain ?? effectID.map { ProfileEffect(id: $0) }

        return UserProfile(
            user: domainUser,
            displayName: displayName,
            avatarURL: avatarURL,
            bannerURL: bannerURL,
            accentHex: guildMetadata?.accentColor ?? globalMetadata?.accentColor
                ?? user.accentColor,
            themeHexes: guildMetadata?.themeColors ?? globalMetadata?.themeColors ?? [],
            bio: Self.firstNonEmpty(
                guildMetadata?.bio, guildMember?.bio, globalMetadata?.bio, user.bio),
            pronouns: Self.firstNonEmpty(guildMetadata?.pronouns, globalMetadata?.pronouns),
            effect: effect,
            badges: uniqueBadges,
            mutualGuilds: mutualServers,
            mutualFriends: friends,
            mutualFriendsCount: mutualFriendsCount ?? friends.count,
            roles: roles,
            connectedAccounts: (connectedAccounts?.elements ?? []).map(\.domain),
            premiumSince: premiumSince.flatMap(DiscordDate.parse),
            premiumGuildSince: premiumGuildSince.flatMap(DiscordDate.parse),
            legacyUsername: legacyUsername
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }.first
    }
}

struct ThreadMemberDTO: Decodable {
    struct MuteConfigDTO: Decodable {
        var endTime: String?

        enum CodingKeys: String, CodingKey {
            case endTime = "end_time"
        }
    }

    // Discord omits both identifiers when a thread member is embedded in a
    // channel object from READY/GUILD_CREATE. They are present on standalone
    // thread-member events and list responses.
    var id: String?
    var userID: String?
    var flags: UInt64?
    var muted: Bool?
    var muteConfig: MuteConfigDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case flags, muted
        case muteConfig = "mute_config"
    }

    var domain: ThreadNotificationSettings {
        ThreadNotificationSettings(
            flags: flags ?? 0,
            isMuted: muted ?? false,
            muteConfiguration: muteConfig.map {
                DiscordMuteConfiguration(
                    endTime: $0.endTime.flatMap(DiscordDate.parse)
                )
            }
        )
    }
}

struct GuildDTO: Decodable {
    var id: String
    var name: String
    var icon: String?
    var owner: Bool?
    var permissions: String?
    var rulesChannelID: String?
    var features: Set<String>?
    var defaultMessageNotifications: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, owner, permissions, features
        case rulesChannelID = "rules_channel_id"
        case defaultMessageNotifications = "default_message_notifications"
    }

    func domain() throws -> Guild {
        guard let id = GuildID(id) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid guild identifier.")
        }
        let iconURL = icon.flatMap { hash in
            URL(
                string:
                "https://cdn.discordapp.com/icons/\(id)/\(hash).webp?size=128&animated=\(hash.hasPrefix("a_") ? "true" : "false")"
            )
        }
        return Guild(
            id: id,
            name: name,
            iconURL: iconURL,
            isOwnedByCurrentUser: owner,
            currentUserPermissions: permissions.flatMap(UInt64.init),
            rulesChannelID: rulesChannelID.flatMap(ChannelID.init),
            features: features ?? [],
            defaultMessageNotifications:
                defaultMessageNotifications.flatMap(MessageNotificationLevel.init(rawValue:))
                ?? .onlyMentions
        )
    }
}

struct ChannelDTO: Decodable {
    struct PermissionOverwriteDTO: Decodable {
        var id: String
        var type: Int
        var allow: String
        var deny: String

        var domain: ChannelPermissionOverwrite {
            ChannelPermissionOverwrite(
                id: id,
                type: type,
                allow: UInt64(allow) ?? 0,
                deny: UInt64(deny) ?? 0
            )
        }
    }

    struct ForumTagDTO: Decodable {
        var id: String
        var name: String
        var moderated: Bool?
        var emojiID: String?
        var emojiName: String?

        enum CodingKeys: String, CodingKey {
            case id, name, moderated
            case emojiID = "emoji_id"
            case emojiName = "emoji_name"
        }

        var domain: ForumTag? {
            guard let id = ForumTagID(id) else { return nil }
            return ForumTag(
                id: id, name: name, isModerated: moderated ?? false,
                emojiID: emojiID, emojiName: emojiName
            )
        }
    }

    struct DefaultReactionDTO: Decodable {
        var emojiID: String?
        var emojiName: String?

        enum CodingKeys: String, CodingKey {
            case emojiID = "emoji_id"
            case emojiName = "emoji_name"
        }
    }

    struct ThreadMetadataDTO: Decodable {
        var archived: Bool?
        var locked: Bool?
        var archiveTimestamp: String?
        var createTimestamp: String?
        var autoArchiveDuration: Int?

        enum CodingKeys: String, CodingKey {
            case archived, locked
            case archiveTimestamp = "archive_timestamp"
            case createTimestamp = "create_timestamp"
            case autoArchiveDuration = "auto_archive_duration"
        }
    }

    var id: String
    var guildID: String?
    var name: String?
    var icon: String?
    var topic: String?
    var type: Int
    var parentID: String?
    var position: Int?
    var recipients: [UserDTO]?
    var recipientIDs: [String]?
    var permissionOverwrites: [PermissionOverwriteDTO]?
    var memberListID: String?
    var lastMessageID: String?
    var lastPinTimestamp: String?
    var ownerID: String?
    var owner: LossyValue<UserDTO>?
    var messageCount: Int?
    var memberCount: Int?
    var totalMessageSent: Int?
    var threadMetadata: ThreadMetadataDTO?
    var appliedTags: [String]?
    var flags: UInt64?
    var member: ThreadMemberDTO?
    var availableTags: [ForumTagDTO]?
    var defaultReactionEmoji: DefaultReactionDTO?
    var defaultSortOrder: Int?
    var defaultForumLayout: Int?
    var defaultTagSetting: String?
    var defaultAutoArchiveDuration: Int?
    var defaultThreadRateLimitPerUser: Int?
    var rateLimitPerUser: Int?
    var status: String?
    var voiceStartTime: DiscordTimestampDTO?
    var message: MessageDTO?
    enum CodingKeys: String, CodingKey {
        case id
        case guildID = "guild_id"
        case name, icon, topic, type
        case parentID = "parent_id"
        case position, recipients
        case recipientIDs = "recipient_ids"
        case permissionOverwrites = "permission_overwrites"
        case memberListID = "member_list_id"
        case lastMessageID = "last_message_id"
        case lastPinTimestamp = "last_pin_timestamp"
        case ownerID = "owner_id"
        case owner, flags, member, message
        case messageCount = "message_count"
        case memberCount = "member_count"
        case totalMessageSent = "total_message_sent"
        case threadMetadata = "thread_metadata"
        case appliedTags = "applied_tags"
        case availableTags = "available_tags"
        case defaultReactionEmoji = "default_reaction_emoji"
        case defaultSortOrder = "default_sort_order"
        case defaultForumLayout = "default_forum_layout"
        case defaultTagSetting = "default_tag_setting"
        case defaultAutoArchiveDuration = "default_auto_archive_duration"
        case defaultThreadRateLimitPerUser = "default_thread_rate_limit_per_user"
        case rateLimitPerUser = "rate_limit_per_user"
        case status
        case voiceStartTime = "voice_start_time"
    }

    func domain(
        guildID fallbackGuildID: GuildID?,
        categoryName: String? = nil,
        categoryPosition: Int = 0,
        knownUsersByID: [String: UserDTO] = [:]
    ) throws -> Channel {
        let channelIDString = id
        guard let id = ChannelID(id) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid channel identifier.")
        }
        let guild = guildID.flatMap(GuildID.init) ?? fallbackGuildID
        let unresolvedRecipientDTOs =
            recipients
            ?? recipientIDs?.compactMap { knownUsersByID[$0] }
            ?? []
        let recipientDTOs = DiscordPrivateRecipientOrdering.sortedUsers(
            unresolvedRecipientDTOs,
            channelID: channelIDString,
            channelType: type
        )
        let users = try recipientDTOs.map { try $0.domain() }
        let kind: ChannelKindValue =
            switch type {
            case 1: .directMessage
            case 3: .groupDirectMessage
            case 2, 13: .voice
            case 5: .announcement
            // Media channels (16) share the forum-style surface locally. The
            // distinction is not yet rendered separately, but retaining them
            // as non-text destinations is required for forwarding eligibility.
            case 15, 16: .forum
            default: .text
            }
        let explicitName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientName = users.map(\.displayName).joined(separator: ", ")
        let ownerGroupName = ownerID
            .flatMap { knownUsersByID[$0] }
            .flatMap { try? $0.domain().displayName }
            .map { "\($0)'s Group" }
        let resolvedName: String
        if let explicitName, !explicitName.isEmpty {
            resolvedName = explicitName
        } else if !recipientName.isEmpty {
            resolvedName = recipientName
        } else if type == 3, let ownerGroupName {
            resolvedName = ownerGroupName
        } else {
            resolvedName = type == 3 ? "Group Direct Message" : "Direct Message"
        }
        let iconURL = icon.flatMap { hash in
            URL(
                string:
                    "https://cdn.discordapp.com/channel-icons/\(id)/\(hash).webp?size=128"
            )
        }
        return Channel(
            id: id,
            guildID: guild,
            name: resolvedName,
            hasExplicitName: explicitName?.isEmpty == false,
            iconURL: iconURL,
            ownerID: ownerID.flatMap(UserID.init),
            topic: topic,
            kind: kind,
            category: categoryName,
            categoryID: parentID.flatMap(ChannelID.init),
            position: position ?? 0,
            categoryPosition: categoryPosition,
            recipients: users,
            permissionOverwrites: permissionOverwrites?.map(\.domain),
            memberListID: memberListID,
            lastMessageID: lastMessageID.flatMap(MessageID.init),
            lastPinTimestamp: lastPinTimestamp.flatMap(DiscordDate.parse),
            flags: flags ?? 0,
            availableTags: availableTags?.compactMap(\.domain) ?? [],
            defaultReaction: defaultReactionEmoji.map {
                ForumDefaultReaction(emojiID: $0.emojiID, emojiName: $0.emojiName)
            },
            defaultSortOrder: defaultSortOrder.flatMap(ForumSortOrder.init(rawValue:)),
            defaultForumLayout: defaultForumLayout.flatMap(ForumLayout.init(rawValue:))
                ?? .defaultLayout,
            defaultTagMatch: defaultTagSetting.flatMap(ForumTagMatch.init(rawValue:)) ?? .matchSome,
            defaultAutoArchiveDuration: defaultAutoArchiveDuration,
            defaultThreadRateLimitPerUser: defaultThreadRateLimitPerUser,
            rateLimitPerUser: rateLimitPerUser ?? 0,
            voiceStatus: status,
            voiceStartTime: voiceStartTime?.date
        )
    }

    func forumPost(fallbackGuildID: GuildID?) throws -> ForumPost {
        guard let id = ChannelID(id) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid forum post identifier.")
        }
        let guild = guildID.flatMap(GuildID.init) ?? fallbackGuildID
        // Forum search records can contain a deliberately partial embedded owner
        // or starter message. The thread itself is still a valid search result;
        // the parallel first_messages payload and Gateway user cache hydrate what
        // Discord omitted without dropping the post.
        let ownerUser = owner?.value.flatMap { try? $0.domain() }
        let firstMessage = message.flatMap { try? $0.domain() }
        return ForumPost(
            thread: MessageThreadSummary(
                id: id,
                guildID: guild,
                parentID: parentID.flatMap(ChannelID.init),
                name: name ?? "Untitled post",
                messageCount: messageCount ?? totalMessageSent ?? (firstMessage == nil ? 0 : 1),
                memberCount: memberCount ?? 0,
                lastMessageID: lastMessageID.flatMap(MessageID.init),
                isArchived: threadMetadata?.archived ?? false,
                isLocked: threadMetadata?.locked ?? false,
                ownerID: ownerID.flatMap(UserID.init) ?? ownerUser?.id,
                appliedTagIDs: appliedTags?.compactMap(ForumTagID.init) ?? [],
                flags: flags ?? 0,
                archiveTimestamp: threadMetadata?.archiveTimestamp.flatMap(DiscordDate.parse),
                createdAt: threadMetadata?.createTimestamp.flatMap(DiscordDate.parse),
                autoArchiveDuration: threadMetadata?.autoArchiveDuration,
                totalMessageSent: totalMessageSent ?? messageCount ?? 0,
                notificationSettings: member?.domain
            ),
            owner: ownerUser ?? firstMessage?.author,
            firstMessage: firstMessage,
            mostRecentMessage: nil,
            isUnread: false
        )
    }
}

/// Discord's private-channel model does not preserve the server's recipient
/// array order. It orders each recipient by the signed 32-bit result of the
/// JavaScript expressions `parseInt(userID) ^ parseInt(channelID)`. Parsing via
/// `Double` intentionally preserves JavaScript's precision loss for snowflakes.
enum DiscordPrivateRecipientOrdering {
    static func sortedUsers(
        _ users: [UserDTO],
        channelID: String,
        channelType: Int
    ) -> [UserDTO] {
        guard channelType == 1 || channelType == 3 else { return users }
        return stableSort(users, channelID: channelID, id: \UserDTO.id)
    }

    static func sortedIDs(
        _ ids: [String],
        channelID: String,
        channelType: Int
    ) -> [String] {
        guard channelType == 1 || channelType == 3 else { return ids }
        return stableSort(ids, channelID: channelID, id: { $0 })
    }

    static func sortedDomainUsers(
        _ users: [User],
        channelID: String,
        channelType: Int
    ) -> [User] {
        guard channelType == 1 || channelType == 3 else { return users }
        return stableSort(users, channelID: channelID, id: { $0.id.description })
    }

    private static func stableSort<Value>(
        _ values: [Value],
        channelID: String,
        id: (Value) -> String
    ) -> [Value] {
        let channelBits = javascriptInt32Bits(channelID)
        return values.enumerated().sorted { lhs, rhs in
            let left = Int32(bitPattern: javascriptInt32Bits(id(lhs.element)) ^ channelBits)
            let right = Int32(bitPattern: javascriptInt32Bits(id(rhs.element)) ^ channelBits)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func javascriptInt32Bits(_ value: String) -> UInt32 {
        guard let parsed = Double(value), parsed.isFinite else { return 0 }
        let modulus = 4_294_967_296.0
        var remainder = parsed.rounded(.towardZero)
            .truncatingRemainder(dividingBy: modulus)
        if remainder < 0 { remainder += modulus }
        return UInt32(remainder)
    }
}

struct GuildActivityEmojiDTO: Decodable {
    var name: String?
    var id: String?
    var animated: Bool?
}

struct GuildActivityDTO: Decodable {
    var name: String?
    var type: Int?
    var state: String?
    var emoji: GuildActivityEmojiDTO?

    var displayText: String? {
        let emojiPrefix =
            emoji.flatMap { emoji -> String? in
                guard let name = emoji.name else { return nil }
                if let id = emoji.id {
                    return "<\(emoji.animated == true ? "a" : ""):\(name):\(id)> "
                }
                return "\(name) "
            } ?? ""
        if type == 4, let state, !state.isEmpty {
            return emojiPrefix + state
        }
        return state.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }
}

struct GuildPresenceDTO: Decodable {
    var status: String?
    var activities: [GuildActivityDTO]?
}

struct GuildMemberDTO: Decodable {
    var user: UserDTO
    var nick: String?
    var roles: [String]?
    var presence: GuildPresenceDTO?
    var avatar: String?
    var banner: String?
    var bio: String?

    func domain(
        currentUserID: UserID?,
        currentStatus: PresenceStatus,
        presence overridePresence: GuildPresenceDTO? = nil,
        guildRoles: [GuildRoleDTO] = [],
        guildID: GuildID? = nil
    ) throws -> Member {
        var domainUser = try user.domain()
        let globalDisplayName = domainUser.displayName
        if let nick, !nick.isEmpty {
            domainUser.displayName = nick
        }
        let guildAvatarURL = guildAvatarURL(guildID: guildID, userID: domainUser.id)
        if let guildAvatarURL {
            domainUser.avatarURL = guildAvatarURL
        }
        let status =
            domainUser.id == currentUserID
                ? currentStatus
                : (overridePresence ?? presence)?.status.flatMap(PresenceStatus.init(rawValue:))
                ?? .offline
        let memberRoleIDs = Set(roles ?? [])
        let categoryRole =
            guildRoles
                .filter { $0.hoist && memberRoleIDs.contains($0.id) }
                .max { lhs, rhs in
                    if lhs.position != rhs.position {
                        return lhs.position < rhs.position
                    }
                    return lhs.id < rhs.id
                }
        let domainRoles =
            guildRoles
                .filter { memberRoleIDs.contains($0.id) }
                .sorted { $0.position > $1.position }
                .compactMap(\.domain)
        let activities = (overridePresence ?? presence)?.activities ?? []
        let customStatus = activities.first(where: { $0.type == 4 })?.displayText
        return Member(
            user: domainUser,
            roleName: categoryRole?.name ?? "Member",
            status: status,
            roleID: categoryRole.flatMap { RoleID($0.id) },
            rolePosition: categoryRole?.position,
            isRoleCategory: categoryRole != nil,
            roleIDs: (roles ?? []).compactMap(RoleID.init),
            roles: domainRoles,
            guildAvatarURL: guildAvatarURL,
            globalDisplayName: globalDisplayName,
            activityText: activities.first(where: { $0.type != 4 })?.displayText ?? customStatus,
            customStatus: customStatus
        )
    }

    private func guildAvatarURL(guildID: GuildID?, userID: UserID) -> URL? {
        guard let avatar, let guildID else { return nil }
        return URL(
            string:
            "https://cdn.discordapp.com/guilds/\(guildID)/users/\(userID)/avatars/\(avatar).webp?size=128&animated=\(avatar.hasPrefix("a_") ? "true" : "false")"
        )
    }
}

struct GuildRoleColorsDTO: Decodable {
    var primaryColor: UInt32?

    enum CodingKeys: String, CodingKey {
        case primaryColor = "primary_color"
    }
}

struct GuildRoleDTO: Decodable {
    var id: String
    var name: String
    var position: Int
    var hoist: Bool
    var color: UInt32?
    private var colors: GuildRoleColorsDTO?
    var icon: String?
    var unicodeEmoji: String?
    var mentionable: Bool?
    var permissions: String?
    enum CodingKeys: String, CodingKey {
        case id, name, position, hoist, color, colors, icon
        case unicodeEmoji = "unicode_emoji"
        case mentionable, permissions
    }

    var domain: GuildRole? {
        guard let id = RoleID(id) else { return nil }
        let colorHex = colors?.primaryColor.flatMap { $0 == 0 ? nil : $0 }
            ?? color.flatMap { $0 == 0 ? nil : $0 }
        let iconURL = icon.flatMap {
            URL(string: "https://cdn.discordapp.com/role-icons/\(id)/\($0).png?size=32")
        }
        return GuildRole(
            id: id,
            name: name,
            position: position,
            colorHex: colorHex,
            iconURL: iconURL,
            unicodeEmoji: unicodeEmoji,
            isMentionable: mentionable ?? false,
            permissions: permissions.flatMap(UInt64.init)
        )
    }
}

struct GatewayGuildMembersChunkDTO: Decodable {
    var guildID: String
    var members: [GuildMemberDTO]
    var chunkIndex: Int
    var chunkCount: Int
    var notFound: [String]?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case members
        case chunkIndex = "chunk_index"
        case chunkCount = "chunk_count"
        case notFound = "not_found"
    }
}

struct MessageMentionDTO: Decodable {
    private struct PartialMemberDTO: Decodable {
        var nick: String?
        var avatar: String?
    }

    private var user: UserDTO
    private var member: PartialMemberDTO?

    private enum CodingKeys: String, CodingKey { case member }

    init(from decoder: Decoder) throws {
        user = try UserDTO(from: decoder)
        member = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(PartialMemberDTO.self, forKey: .member)
    }

    func domain(guildID: GuildID?) throws -> User {
        var value = try user.domain()
        if let nickname = member?.nick?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty
        {
            value.displayName = nickname
        }
        if let guildID, let avatarHash = member?.avatar {
            value.avatarURL = URL(
                string:
                "https://cdn.discordapp.com/guilds/\(guildID)/users/\(value.id)/avatars/\(avatarHash).webp?size=128&animated=\(avatarHash.hasPrefix("a_") ? "true" : "false")"
            )
        }
        return value
    }

    var searchIndexUser: UserDTO { user }
}
