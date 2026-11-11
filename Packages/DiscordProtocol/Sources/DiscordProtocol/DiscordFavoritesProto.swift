import Foundation
import SakuraCordModels

/// settings-proto/1 field 15 (`Favorites`). Every favourites write sends the
/// complete message: the `favorite_channels` map (1), then the remaining
/// top-level fields in number order, with `guild_visible` (3) as a BoolValue.
/// Fields SakuraCord does not model, such as category collapse and the thread
/// automation settings, are carried over from the stored copy.
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
            case 3:
                settings.storedVisibility = ProtoReader.fields(field.payload ?? Data()).last { $0.field == 1 }?.varint.map { $0 != 0 } ?? false
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
            } else if field.field != 1, field.field != 3 {
                otherFields.append(field)
            }
        }
        var result = Data()
        for entry in settings.entries {
            let key = DiscordSettingsProto.protoFixed64Field(1, entry.id.rawValue)
            let value = entryValue(entry, unmodelled: storedValues[entry.id] ?? [])
            result.append(DiscordSettingsProto.protoLengthDelimitedField(1, key + DiscordSettingsProto.protoLengthDelimitedField(2, value)))
        }
        for field in otherFields where field.field < 3 { result.append(field.raw) }
        if let isVisible = settings.storedVisibility {
            result.append(DiscordSettingsProto.protoLengthDelimitedField(
                3, isVisible ? DiscordSettingsProto.protoVarintField(1, 1) : Data()
            ))
        }
        for field in otherFields where field.field > 3 { result.append(field.raw) }
        return result
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
