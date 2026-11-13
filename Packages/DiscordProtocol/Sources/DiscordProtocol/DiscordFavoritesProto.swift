import Foundation
import SakuraCordModels

/// settings-proto/1 field 15 (`Favorites`). Every favourites write sends the
/// complete message in field order: the `favorite_channels` map (1), `muted`
/// (2), `guild_visible` (3, a BoolValue), then Thread Settings:
/// `auto_add_joined_threads` (4), `prune_inactive_threads` (5, a BoolValue),
/// `prune_inactive_threads_days` (6), `prune_all_favorited_threads` (7) and
/// `auto_add_joined_threads_per_guild` (8). Defaults are omitted, as the
/// official encoder omits them; fields SakuraCord does not model, such as
/// category collapse, are carried over from the stored copy.
enum DiscordFavoritesProto {
    static let settingsField = 15

    /// The raw Favorites message, or nil when the settings don't carry one.
    static func message(inSettings data: Data) -> Data? {
        var reader = ProtoReader(data: data)
        var result: Data?
        while let field = reader.readRawField() {
            if field.field == settingsField { result = field.payload }
        }
        return result
    }

    static func settings(from message: Data) -> FavoritesSettings {
        var settings = FavoritesSettings()
        for field in ProtoReader.fields(message) {
            switch field.field {
            case 1:
                if let entry = entry(from: field.payload ?? Data()) { settings.entries.append(entry.entry) }
            case 2: settings.isMuted = field.varint.map { $0 != 0 } ?? false
            case 3: settings.storedVisibility = boolValue(field)
            case 4: settings.threadSettings.autoAddsJoinedThreads = field.varint.map { $0 != 0 } ?? false
            case 5: settings.threadSettings.removesReadThreads = boolValue(field)
            case 6: settings.threadSettings.removalDays = UInt32(truncatingIfNeeded: field.varint ?? 0)
            case 7: settings.threadSettings.removesFromAllThreads = field.varint.map { $0 != 0 } ?? false
            case 8: settings.threadSettings.autoAddsPerServer = field.varint.map { $0 != 0 } ?? false
            default:
                break
            }
        }
        return settings
    }

    /// The complete Favorites message for `settings`, preserving everything
    /// the model doesn't describe from `stored`.
    static func message(for settings: FavoritesSettings, preserving stored: Data) -> Data {
        var storedValues: [ChannelID: [RawProtoField]] = [:]
        var otherFields: [RawProtoField] = []
        for field in ProtoReader.fields(stored) {
            if field.field == 1, let decoded = entry(from: field.payload ?? Data()) {
                storedValues[decoded.entry.id] = decoded.unmodelled
            } else if !(1 ... 8).contains(field.field) {
                otherFields.append(field)
            }
        }
        var result = Data()
        for entry in settings.entries {
            let key = DiscordSettingsProto.protoFixed64Field(1, entry.id.rawValue)
            let value = entryValue(entry, unmodelled: storedValues[entry.id] ?? [])
            result.append(DiscordSettingsProto.protoLengthDelimitedField(1, key + DiscordSettingsProto.protoLengthDelimitedField(2, value)))
        }
        let thread = settings.threadSettings
        if settings.isMuted { result.append(DiscordSettingsProto.protoVarintField(2, 1)) }
        if let isVisible = settings.storedVisibility { result.append(boolValueField(3, isVisible)) }
        if thread.autoAddsJoinedThreads { result.append(DiscordSettingsProto.protoVarintField(4, 1)) }
        if let removes = thread.removesReadThreads { result.append(boolValueField(5, removes)) }
        if thread.removalDays > 0 { result.append(DiscordSettingsProto.protoVarintField(6, UInt64(thread.removalDays))) }
        if thread.removesFromAllThreads { result.append(DiscordSettingsProto.protoVarintField(7, 1)) }
        if thread.autoAddsPerServer { result.append(DiscordSettingsProto.protoVarintField(8, 1)) }
        for field in otherFields { result.append(field.raw) }
        return result
    }

    /// A google.protobuf.BoolValue; false is its empty message.
    private static func boolValueField(_ number: Int, _ value: Bool) -> Data {
        DiscordSettingsProto.protoLengthDelimitedField(number, value ? DiscordSettingsProto.protoVarintField(1, 1) : Data())
    }

    private static func boolValue(_ field: RawProtoField) -> Bool {
        ProtoReader.fields(field.payload ?? Data()).last { $0.field == 1 }?.varint.map { $0 != 0 } ?? false
    }

    /// FavoriteChannel fields 1–5, omitting defaults like the official
    /// encoder; text channels (type 0) still record an empty Int32Value.
    private static func entryValue(_ entry: FavoritesSettings.Entry, unmodelled: [RawProtoField]) -> Data {
        var value = Data()
        if !entry.nickname.isEmpty { value.append(DiscordSettingsProto.protoStringField(1, entry.nickname)) }
        value.append(DiscordSettingsProto.protoVarintField(2, entry.isCategory ? 2 : 1))
        if entry.position > 0 { value.append(DiscordSettingsProto.protoVarintField(3, UInt64(entry.position))) }
        if let parentID = entry.parentID { value.append(DiscordSettingsProto.protoFixed64Field(4, parentID.rawValue)) }
        if let channelType = entry.channelType {
            value.append(DiscordSettingsProto.protoLengthDelimitedField(
                5, channelType == 0 ? Data() : DiscordSettingsProto.protoVarintField(1, UInt64(channelType))
            ))
        }
        for field in unmodelled { value.append(field.raw) }
        return value
    }

    private static func entry(from mapEntry: Data) -> (entry: FavoritesSettings.Entry, unmodelled: [RawProtoField])? {
        var id: UInt64?
        var value = Data()
        for field in ProtoReader.fields(mapEntry) {
            if field.field == 1 { id = field.fixed64 }
            if field.field == 2 { value = field.payload ?? Data() }
        }
        guard let id else { return nil }
        var entry = FavoritesSettings.Entry(id: ChannelID(rawValue: id), position: 0)
        var unmodelled: [RawProtoField] = []
        for field in ProtoReader.fields(value) {
            switch field.field {
            case 1: entry.nickname = String(bytes: field.payload ?? Data(), encoding: .utf8) ?? ""
            case 2: entry.isCategory = field.varint == 2
            case 3: entry.position = UInt32(truncatingIfNeeded: field.varint ?? 0)
            case 4: entry.parentID = field.fixed64.flatMap { $0 == 0 ? nil : ChannelID(rawValue: $0) }
            case 5:
                entry.channelType = Int(truncatingIfNeeded: Int32(truncatingIfNeeded:
                    ProtoReader.fields(field.payload ?? Data()).last { $0.field == 1 }?.varint ?? 0))
            default: unmodelled.append(field)
            }
        }
        return (entry, unmodelled)
    }
}
