import Foundation

/// Merges a settings-proto PATCH into the stored settings at the wire level,
/// without the settings schema. Clients send each changed section (a
/// top-level field) complete, so a section in the patch replaces the stored
/// one, clears included, and every other section is kept.
enum ProtobufMerge {
    private struct Field {
        var number: UInt64
        var bytes: Data
    }

    /// Nil when either side isn't a well-formed protobuf message.
    static func merge(_ stored: Data, _ patch: Data) -> Data? {
        guard let old = fields(stored), let new = fields(patch) else { return nil }
        let patched = Set(new.map(\.number))
        return (old.filter { !patched.contains($0.number) } + new)
            .sorted { $0.number < $1.number }
            .reduce(into: Data()) { $0 += $1.bytes }
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
            result.append(Field(number: key >> 3, bytes: Data(bytes[keyStart ..< index])))
        }
        return result
    }
}
