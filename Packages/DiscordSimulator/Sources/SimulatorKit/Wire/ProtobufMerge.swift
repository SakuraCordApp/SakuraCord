import Foundation

/// Merges a settings-proto PATCH into the stored settings at the wire level,
/// without the settings schema. Clients send each changed section (a
/// top-level field) complete, so a section in the patch replaces the stored
/// one, clears included, and every other section is kept.
enum ProtobufMerge {
    struct Field {
        var number: UInt64
        /// The whole field, key included.
        var bytes: Data
        /// The value: a varint's or fixed number's bytes, or a length-delimited field's contents.
        var payload: Data
    }

    /// Nil when either side isn't a well-formed protobuf message.
    static func merge(_ stored: Data, _ patch: Data) -> Data? {
        guard let old = fields(stored), let new = fields(patch) else { return nil }
        let patched = Set(new.map(\.number))
        return (old.filter { !patched.contains($0.number) } + new)
            .sorted { $0.number < $1.number }
            .reduce(into: Data()) { $0 += $1.bytes }
    }

    /// Increments `versions.data_version` (field 1, its field 3), keeping the
    /// versions' other fields. Settings with no versions start at 1.
    static func bumpingDataVersion(_ settings: Data) -> Data {
        guard let sections = fields(settings) else { return settings }
        let versions = sections.first { $0.number == 1 }.flatMap { fields($0.payload) } ?? []
        let dataVersion = versions.first { $0.number == 3 }.flatMap { varint($0.payload) } ?? 0
        let kept = versions.filter { $0.number != 3 }.reduce(into: Data()) { $0 += $1.bytes }
        return merge(settings, Protobuf.field(1, kept + Protobuf.varint(3, dataVersion + 1))) ?? settings
    }

    private static func varint(_ data: Data) -> UInt64? {
        var value: UInt64 = 0
        for (index, byte) in data.prefix(10).enumerated() {
            value |= UInt64(byte & 0x7F) << (7 * UInt64(index))
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    static func fields(_ data: Data) -> [Field]? {
        let bytes = [UInt8](data)
        var index = 0, result: [Field] = []
        func readVarint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            let keyStart = index
            guard let key = readVarint(), key >> 3 > 0 else { return nil }
            let start: Int, length: Int
            switch key & 7 {
            case 0:
                start = index
                guard readVarint() != nil else { return nil }
                length = index - start
            case 1, 5:
                start = index
                length = key & 7 == 1 ? 8 : 4
            case 2:
                guard let size = readVarint(), size <= UInt64(bytes.count - index) else { return nil }
                start = index
                length = Int(size)
            default:
                return nil
            }
            guard start + length <= bytes.count else { return nil }
            index = start + length
            result.append(Field(number: key >> 3, bytes: Data(bytes[keyStart ..< index]), payload: Data(bytes[start ..< index])))
        }
        return result
    }
}

/// The few protobuf wire pieces the settings proto needs.
enum Protobuf {
    static func field(_ number: UInt64, _ payload: Data) -> Data {
        varintBytes(number << 3 | 2) + varintBytes(UInt64(payload.count)) + payload
    }

    static func varint(_ number: UInt64, _ value: UInt64) -> Data {
        varintBytes(number << 3) + varintBytes(value)
    }

    private static func varintBytes(_ value: UInt64) -> Data {
        var value = value, bytes = Data()
        repeat {
            bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }
}
