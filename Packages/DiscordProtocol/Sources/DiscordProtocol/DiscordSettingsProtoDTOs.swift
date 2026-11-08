import Foundation
import SakuraCordModels

struct UserSettingsProtoDTO: Decodable {
    var settings: String
    /// Set when `required_data_version` no longer matched and the server
    /// discarded the write; `settings` is then the server's current proto.
    var outOfDate: Bool?

    enum CodingKeys: String, CodingKey {
        case settings
        case outOfDate = "out_of_date"
    }
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
    static func guildOrder(from data: Data) -> [GuildID]? {
        guard let layout = guildLayout(from: data) else { return nil }
        let folderOrder = layout.folders.flatMap(\.guildIDs)
        return folderOrder.isEmpty ? layout.guildPositions : folderOrder
    }

    static func guildLayout(from data: Data) -> DiscordGuildLayout? {
        guildFoldersSettings(in: data).map(layout(fromGuildFolders:))
    }

    /// The raw GuildFolders message in root field 14, or nil when the settings
    /// do not carry one.
    static func guildFoldersSettings(in data: Data) -> Data? {
        var topLevel = ProtoReader(data: data)
        while let tag = topLevel.readTag() {
            if tag.field == 14, tag.wireType == 2, let guildFolders = topLevel.readLengthDelimited() {
                return guildFolders
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
        return EmojiUserSettings(
            favoriteKeys: favorites,
            dataVersion: dataVersion(in: data),
            messageHistory: frecencyHistory(from: data, field: 6) ?? .init(),
            reactionHistory: frecencyHistory(from: data, field: 13) ?? .init(),
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

    static func updatingEmojiFavorite(
        in data: Data,
        key: String,
        isFavorite: Bool
    ) throws -> (data: Data, settings: EmojiUserSettings) {
        var favorites = emojiSettings(from: data).favoriteKeys
        favorites.removeAll { $0 == key }
        if isFavorite {
            guard favorites.count < 250 else {
                throw ChatProviderError.invalidRequest(
                    "Discord's emoji favorites limit has been reached."
                )
            }
            favorites.append(key)
        }

        var payload = Data()
        for favorite in favorites {
            payload.append(protoStringField(1, favorite))
        }
        let updated = replacingLengthDelimitedField(5, in: data, with: payload)
        return (updated, emojiSettings(from: updated))
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

    static func replacingLengthDelimitedField(
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

    static func protoStringField(_ field: Int, _ value: String) -> Data {
        protoLengthDelimitedField(field, Data(value.utf8))
    }

    static func protoLengthDelimitedField(_ field: Int, _ value: Data) -> Data {
        var data = protoVarint(UInt64(field << 3 | 2))
        data.append(protoVarint(UInt64(value.count)))
        data.append(value)
        return data
    }

    static func protoVarintField(_ field: Int, _ value: UInt64) -> Data {
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

    struct FrecencyEntry {
        var key: String
        var score: Int
        var frecency: Int
    }

    static func stringFrecencyEntries(
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
        return frecency(totalUses: totalUses, recentUses: recentUses, nowMilliseconds: nowMilliseconds)
        }
    }

    /// The official client's frecency store: the age weights of the first ten
    /// recent uses, and uses × their mean weight.
    static func frecency(
        totalUses: Int, recentUses: [UInt64], nowMilliseconds: UInt64
    ) -> (score: Int, frecency: Int)? {
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

    private static func computedFrecency(
        from data: Data,
        nowMilliseconds: UInt64
    ) -> (score: Int, frecency: Int)? {
        frecencyComputation(data, nowMilliseconds)
    }

    static func layout(fromGuildFolders data: Data) -> DiscordGuildLayout {
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

    static func folder(from data: Data) -> DiscordGuildLayout.Folder {
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

    static func readFixed64Values(wireType: Int, reader: inout ProtoReader) -> [GuildID] {
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
