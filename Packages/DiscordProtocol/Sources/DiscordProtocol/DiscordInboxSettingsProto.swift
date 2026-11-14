import Foundation
import SakuraCordModels

/// Settings-proto/1 replaces each supplied top-level message. Preserve all
/// unknown fields and sibling guild/channel settings when changing Inbox state.
enum DiscordInboxSettingsProto {
    static func settings(in data: Data) -> InboxSettings {
        let root = ProtoReader.fields(data)
        let inbox = ProtoReader.fields(root.first { $0.field == 2 }?.payload ?? Data())
        let tab = inbox.first { $0.field == 1 }?.varint.flatMap { Int(exactly: $0).flatMap(InboxTab.init(rawValue:)) } ?? .unread
        var collapsed = Set<ChannelID>()
        var collapsedEvents = Set<GuildID>()
        for guild in ProtoReader.fields(root.first { $0.field == 3 }?.payload ?? Data()) where guild.field == 1 {
            let guildID = ProtoReader.fields(guild.payload ?? Data()).first(where: { $0.field == 1 }).flatMap(\.fixed64)
            let value = ProtoReader.fields(guild.payload ?? Data()).first { $0.field == 2 }?.payload ?? Data()
            for channel in ProtoReader.fields(value) where channel.field == 1 {
                let entry = ProtoReader.fields(channel.payload ?? Data())
                guard let key = entry.first(where: { $0.field == 1 }),
                      let id = key.fixed64,
                      let settings = entry.first(where: { $0.field == 2 })?.payload,
                      ProtoReader.fields(settings).contains(where: { $0.field == 1 && $0.varint == 1 })
                else { continue }
                if id == 1_539_033_557_786_173_450, let guildID {
                    collapsedEvents.insert(GuildID(rawValue: guildID))
                } else { collapsed.insert(ChannelID(rawValue: id)) }
            }
        }
        let favorites = Set(ProtoReader.fields(root.first { $0.field == 15 }?.payload ?? Data()).compactMap { entry -> ChannelID? in
            guard entry.field == 1,
                  let key = ProtoReader.fields(entry.payload ?? Data()).first(where: { $0.field == 1 }),
                  let id = key.fixed64 else { return nil }
            return ChannelID(rawValue: id)
        })
        return InboxSettings(tab: tab, collapsedChannelIDs: collapsed, favoriteChannelIDs: favorites, collapsedEventGuildIDs: collapsedEvents)
    }

    static func updatingTab(_ tab: InboxTab, in data: Data) -> Data {
        let current = ProtoReader.fields(data).first { $0.field == 2 }?.payload ?? Data()
        return wrapped(2, replacing(1, with: Data([8, UInt8(tab.rawValue)]), in: current))
    }

    static func updatingCollapsed(_ collapsed: Bool, channelID: ChannelID, guildID: GuildID?, in data: Data) -> Data {
        let guilds = ProtoReader.fields(data).first { $0.field == 3 }?.payload ?? Data()
        let updated = updatingMap(guilds, key: guildID?.rawValue ?? 0) { guild in
            updatingMap(guild, key: channelID.rawValue) { channel in
                replacing(1, with: collapsed ? Data([8, 1]) : Data(), in: channel)
            }
        }
        return wrapped(3, updated)
    }

    private static func updatingMap(_ data: Data, key: UInt64, update: (Data) -> Data) -> Data {
        var found = false
        var result = Data()
        for field in ProtoReader.fields(data) {
            let entry = ProtoReader.fields(field.payload ?? Data())
            if field.field == 1, entry.first(where: { $0.field == 1 }).flatMap(\.fixed64) == key {
                let value = entry.first { $0.field == 2 }?.payload ?? Data()
                result.append(wrapped(1, replacing(2, with: wrapped(2, update(value)), in: field.payload ?? Data())))
                found = true
            } else {
                result.append(field.raw)
            }
        }
        if !found {
            var entry = DiscordSettingsProto.protoFixed64Field(1, key)
            entry.append(wrapped(2, update(Data())))
            result.append(wrapped(1, entry))
        }
        return result
    }

    private static func replacing(_ number: Int, with replacement: Data, in data: Data) -> Data {
        var result = ProtoReader.fields(data).filter { $0.field != number }.reduce(into: Data()) { $0.append($1.raw) }
        result.append(replacement)
        return result
    }

    private static func wrapped(_ number: Int, _ data: Data) -> Data {
        DiscordSettingsProto.protoLengthDelimitedField(number, data)
    }
}
