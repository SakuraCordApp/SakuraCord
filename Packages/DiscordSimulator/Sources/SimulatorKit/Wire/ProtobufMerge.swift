import Foundation

/// Merges a settings-proto PATCH into the stored settings at the wire level,
/// without the settings schema: a field the patch sets replaces the stored
/// one, and a sub-message set on both sides merges one level further, so
/// saving favorites keeps status and developer settings saved earlier.
enum ProtobufMerge {
    private struct Field {
        var number: UInt64
        var wireType: UInt64
        var key: Data
        var payload: Data
    }

    /// Nil when either side isn't a well-formed protobuf message.
    static func merge(_ stored: Data, _ patch: Data, depth: Int = 2) -> Data? {
        guard let old = fields(stored), let new = fields(patch) else { return nil }
        let patched = Set(new.map(\.number))
        var merged = old.filter { !patched.contains($0.number) }
        for field in new {
            let previous = old.filter { $0.number == field.number }
            let repeats = new.count { $0.number == field.number } > 1
            if depth > 1, !repeats, previous.count == 1, field.wireType == 2, previous[0].wireType == 2,
               let inner = merge(previous[0].payload, field.payload, depth: depth - 1) {
                merged.append(Field(number: field.number, wireType: 2, key: field.key, payload: inner))
            } else {
                merged.append(field)
            }
        }
        return merged.sorted { $0.number < $1.number }.reduce(into: Data()) { data, field in
            data += field.key
            if field.wireType == 2 { data += varint(UInt64(field.payload.count)) }
            data += field.payload
        }
    }

    private static func fields(_ data: Data) -> [Field]? {
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
            let keyBytes = Data(bytes[keyStart ..< index])
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
            result.append(Field(number: key >> 3, wireType: key & 7, key: keyBytes, payload: Data(bytes[start ..< index])))
        }
        return result
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            data.append(value == 0 ? byte : byte | 0x80)
        } while value != 0
        return data
    }
}
