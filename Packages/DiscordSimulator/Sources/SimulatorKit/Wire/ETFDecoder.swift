import Foundation

/// Decodes client-sent ETF frames into JSON the way Discord's clients read
/// them: atoms `nil`/`true`/`false` become null and bools, tuples become
/// arrays, and integers past 2^53 become decimal strings so snowflakes survive.
public enum ETFDecoder {
    public static func decode(_ data: Data) throws -> JSON {
        try decodeWithTags(data).value
    }

    /// Also reports the tag found at each path, in `ETFEncoder`'s path syntax,
    /// so a client can check the term types it actually received.
    public static func decodeWithTags(_ data: Data) throws -> (value: JSON, tags: [String: String]) {
        var reader = ETFReader(bytes: [UInt8](data))
        guard try reader.byte() == ETFTag.version else { throw reader.error("missing ETF version byte 131") }
        let value = try reader.term(path: "")
        guard reader.index == reader.bytes.count else { throw reader.error("trailing bytes") }
        return (value, reader.tags)
    }
}

private struct ETFReader {
    let bytes: [UInt8]
    var index = 0
    var tags: [String: String] = [:]

    func error(_ reason: String) -> WireError { WireError("ETF decode error at \(index): \(reason)") }

    mutating func term(asKey: Bool = false, path: String? = nil) throws -> JSON {
        let raw = try byte()
        guard let tag = ETFTag(rawValue: raw) else { throw error("unsupported tag \(raw)") }
        if let path { tags[path.isEmpty ? "/" : path] = tag.name }
        switch tag {
        case .smallInteger, .integer, .newFloat, .float, .smallBig, .largeBig: return try number(tag)
        case .atom, .atomUTF8: return atom(try take(Int(try integer(UInt16.self))), asKey: asKey)
        case .smallAtom, .smallAtomUTF8: return atom(try take(Int(try byte())), asKey: asKey)
        case .binary: return .string(String(bytes: try take(Int(try integer(UInt32.self))), encoding: .utf8) ?? "")
        case .string: return .array(try take(Int(try integer(UInt16.self))).map { .int(Int64($0)) })
        case .nil: return .array([])
        case .smallTuple: return .array(try terms(Int(try byte()), path: path))
        case .largeTuple: return .array(try terms(Int(try integer(UInt32.self)), path: path))
        case .list:
            let elements = try terms(Int(try integer(UInt32.self)), path: path)
            guard try byte() == ETFTag.nil.rawValue else { throw error("improper list") }
            return .array(elements)
        case .map:
            var object = JSONObject()
            for _ in 0 ..< Int(try integer(UInt32.self)) {
                let keyTag = index < bytes.count ? ETFTag(rawValue: bytes[index])?.name : nil
                let key = Self.keyString(try term(asKey: true))
                let child = path.map { "\($0)/\(key)" }
                if let child, let keyTag { tags["\(child)#key"] = keyTag }
                object[key] = try term(path: child)
            }
            return .object(object)
        }
    }

    private mutating func number(_ tag: ETFTag) throws -> JSON {
        switch tag {
        case .smallInteger: return .int(Int64(try byte()))
        case .integer: return .int(Int64(Int32(bitPattern: try integer(UInt32.self))))
        case .newFloat: return .double(Double(bitPattern: try integer(UInt64.self)))
        case .smallBig: return try big(count: Int(try byte()))
        case .largeBig: return try big(count: Int(try integer(UInt32.self)))
        default:
            let text = String(bytes: try take(31).prefix { $0 != 0 }, encoding: .utf8) ?? ""
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else { throw error("bad FLOAT_EXT \(text)") }
            return .double(number)
        }
    }

    private mutating func terms(_ count: Int, path: String? = nil) throws -> [JSON] {
        guard count <= bytes.count - index else { throw error("length \(count) past end") }
        return try (0 ..< count).map { _ in try term(path: path.map { "\($0)/[]" }) }
    }

    private func atom(_ name: ArraySlice<UInt8>, asKey: Bool) -> JSON {
        let text = String(bytes: name, encoding: .utf8) ?? ""
        if asKey { return .string(text) }
        switch text {
        case "nil", "null": return .null
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return .string(text)
        }
    }

    private static func keyString(_ key: JSON) -> String {
        switch key {
        case let .string(text): text
        case let .int(number): String(number)
        default: key.serialized(spaced: false)
        }
    }

    /// Little-endian magnitude; JSON numbers lose precision past 2^53, so bigger values become strings.
    private mutating func big(count: Int) throws -> JSON {
        let negative = try byte() != 0
        let digits = try take(count)
        if digits.count <= 8 {
            let magnitude = digits.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if magnitude <= 1 << 53 { return .int(negative ? -Int64(magnitude) : Int64(magnitude)) }
        }
        return .string((negative ? "-" : "") + Self.decimal(littleEndian: Array(digits)))
    }

    private static func decimal(littleEndian digits: [UInt8]) -> String {
        var number = Array(digits.reversed().drop { $0 == 0 })
        var text: [Character] = []
        while !number.isEmpty {
            var remainder = 0
            number = number.map { digit in
                let value = remainder << 8 | Int(digit)
                remainder = value % 10
                return UInt8(value / 10)
            }
            number = Array(number.drop { $0 == 0 })
            text.append(Character(String(remainder)))
        }
        return text.isEmpty ? "0" : String(text.reversed())
    }

    mutating func byte() throws -> UInt8 { try take(1).first! }

    private mutating func integer<Value: FixedWidthInteger>(_: Value.Type) throws -> Value {
        try take(MemoryLayout<Value>.size).reduce(Value.zero) { $0 << 8 | Value($1) }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= bytes.count - index else { throw error("length \(count) past end") }
        defer { index += count }
        return bytes[index ..< index + count]
    }
}
