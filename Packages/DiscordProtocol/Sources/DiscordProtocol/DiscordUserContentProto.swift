import Foundation

/// settings-proto/1 field 4 (`UserContentSettings`). `dismissed_contents` (1)
/// is a bitset of DismissibleContent values, least significant bit first in
/// each byte. A write sends the complete message with only that bitset
/// changed, re-encoded as the official client encodes it: fields in number
/// order and `recurring_dismissible_content_states` (7) by ascending key.
enum DiscordUserContentProto {
    static let settingsField = 4
    /// DismissibleContent `FAVORITES_GUILD_SUGGESTIONS`, the Favorites server's
    /// Suggested Channels.
    static let favoritesSuggestions = 807

    static func message(inSettings data: Data) -> Data? {
        ProtoReader.lastMessage(settingsField, in: data)
    }

    static func isDismissed(_ content: Int, in message: Data) -> Bool {
        let bits = dismissedContents(message)
        return content / 8 < bits.count && bits[content / 8] & (1 << (content % 8)) != 0
    }

    /// Sets or clears one content's bit; clearing keeps the bitset's length,
    /// as the official client does.
    static func setting(_ content: Int, dismissed: Bool, in message: Data) -> Data {
        var bits = [UInt8](dismissedContents(message))
        if dismissed {
            if bits.count <= content / 8 { bits += [UInt8](repeating: 0, count: content / 8 + 1 - bits.count) }
            bits[content / 8] |= 1 << (content % 8)
        } else if content / 8 < bits.count {
            bits[content / 8] &= ~(1 << (content % 8))
        }
        let others = ProtoReader.fields(message).filter { $0.field != 1 }.enumerated().sorted { lhs, rhs in
            let left = (lhs.element.field, mapKey(lhs.element), lhs.offset)
            let right = (rhs.element.field, mapKey(rhs.element), rhs.offset)
            return left < right
        }
        let encodedOthers = others.reduce(into: Data()) { $0.append($1.element.raw) }
        return (bits.isEmpty ? Data() : DiscordSettingsProto.protoLengthDelimitedField(1, Data(bits))) + encodedOthers
    }

    /// The int32 key of a `recurring_dismissible_content_states` entry.
    private static func mapKey(_ field: RawProtoField) -> Int64 {
        guard field.field == 7 else { return 0 }
        return ProtoReader.fields(field.payload ?? Data()).first { $0.field == 1 }?.varint.map { Int64(Int32(truncatingIfNeeded: $0)) } ?? 0
    }

    private static func dismissedContents(_ message: Data) -> Data {
        ProtoReader.fields(message).last { $0.field == 1 }?.payload ?? Data()
    }
}
