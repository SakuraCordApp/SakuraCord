import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = try .array(container.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct GatewayEnvelope: Codable, Equatable, Sendable {
    public var op: Int
    public var data: JSONValue?
    public var sequence: Int?
    public var eventName: String?

    enum CodingKeys: String, CodingKey { case op, data = "d", sequence = "s", eventName = "t" }

    public init(op: Int, data: JSONValue? = nil, sequence: Int? = nil, eventName: String? = nil) {
        self.op = op
        self.data = data
        self.sequence = sequence
        self.eventName = eventName
    }
}

public protocol GatewayCodec: Sendable {
    func encode(_ envelope: GatewayEnvelope) throws -> Data
    func decode(_ data: Data) throws -> GatewayEnvelope
}

public struct JSONGatewayCodec: GatewayCodec {
    public init() {}
    public func encode(_ envelope: GatewayEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public func decode(_ data: Data) throws -> GatewayEnvelope {
        try JSONDecoder().decode(GatewayEnvelope.self, from: data)
    }
}

/// Discord's desktop client uses Erlang's External Term Format (ETF) for the
/// Gateway. This codec intentionally supports only the JSON-compatible term
/// subset Discord emits: maps, lists, UTF-8 binaries, numbers, booleans, and
/// nil. Unsupported or improper terms fail closed.
public struct ETFGatewayCodec: GatewayCodec {
    public init() {}

    public func encode(_ envelope: GatewayEnvelope) throws -> Data {
        let json = try JSONEncoder().encode(envelope)
        let value = try JSONDecoder().decode(JSONValue.self, from: json)
        var output = Data([131]) // ETF version.
        try Self.append(value, to: &output)
        return output
    }

    public func decode(_ data: Data) throws -> GatewayEnvelope {
        var parser = ETFParser(data: data)
        let value = try parser.parse()
        guard parser.isAtEnd else { throw GatewaySessionError.malformedPayload }
        let json = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(GatewayEnvelope.self, from: json)
    }

    private static func append(_ value: JSONValue, to output: inout Data) throws {
        switch value {
        case let .string(string):
            let bytes = Data(string.utf8)
            output.append(109) // BINARY_EXT
            appendUInt32(bytes.count, to: &output)
            output.append(bytes)
        case let .number(number):
            try appendNumber(number, to: &output)
        case let .bool(value):
            appendAtom(value ? "true" : "false", to: &output)
        case let .object(object):
            output.append(116) // MAP_EXT
            appendUInt32(object.count, to: &output)
            for key in object.keys.sorted() {
                try append(.string(key), to: &output)
                try append(object[key] ?? .null, to: &output)
            }
        case let .array(values):
            output.append(108) // LIST_EXT
            appendUInt32(values.count, to: &output)
            for value in values {
                try append(value, to: &output)
            }
            output.append(106) // NIL_EXT list tail.
        case .null:
            appendAtom("nil", to: &output)
        }
    }

    private static func appendNumber(_ value: Double, to output: inout Data) throws {
        guard value.isFinite else { throw GatewaySessionError.malformedPayload }
        if value.rounded(.towardZero) == value,
           value >= Double(Int64.min), value <= Double(Int64.max)
        {
            let integer = Int64(value)
            if (0 ... 255).contains(integer) {
                output.append(97) // SMALL_INTEGER_EXT
                output.append(UInt8(integer))
            } else if (Int64(Int32.min) ... Int64(Int32.max)).contains(integer) {
                output.append(98) // INTEGER_EXT
                appendUInt32(UInt32(bitPattern: Int32(integer)), to: &output)
            } else {
                var magnitude = integer.magnitude
                var bytes: [UInt8] = []
                repeat {
                    bytes.append(UInt8(truncatingIfNeeded: magnitude))
                    magnitude >>= 8
                } while magnitude > 0
                guard bytes.count <= 255 else { throw GatewaySessionError.malformedPayload }
                output.append(110) // SMALL_BIG_EXT
                output.append(UInt8(bytes.count))
                output.append(integer < 0 ? 1 : 0)
                output.append(contentsOf: bytes)
            }
        } else {
            output.append(70) // NEW_FLOAT_EXT
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
        }
    }

    private static func appendAtom(_ atom: String, to output: inout Data) {
        let bytes = Array(atom.utf8)
        output.append(119) // SMALL_ATOM_UTF8_EXT
        output.append(UInt8(bytes.count))
        output.append(contentsOf: bytes)
    }

    private static func appendUInt32(_ value: Int, to output: inout Data) {
        appendUInt32(UInt32(value), to: &output)
    }

    private static func appendUInt32(_ value: UInt32, to output: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
    }
}

private struct ETFParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { index == bytes.count }

    mutating func parse() throws -> JSONValue {
        guard try readByte() == 131 else { throw GatewaySessionError.malformedPayload }
        return try parseTerm(depth: 0)
    }

    private mutating func parseTerm(depth: Int) throws -> JSONValue {
        guard depth <= 96 else { throw GatewaySessionError.malformedPayload }
        let tag = try readByte()
        switch tag {
        case 70, 97, 98, 99, 110, 111:
            return try parseNumber(tag: tag)
        case 100, 109, 115, 118, 119:
            return try parseText(tag: tag)
        case 107: // STRING_EXT is an optimized Erlang byte list, not text.
            let count = Int(try readUInt16())
            var values: [JSONValue] = []
            values.reserveCapacity(count)
            for _ in 0 ..< count {
                values.append(.number(Double(try readByte())))
            }
            return .array(values)
        case 104: // SMALL_TUPLE_EXT
            return try parseTuple(
                count: checkedCollectionCount(Int(try readByte()), minimumBytesPerElement: 1),
                depth: depth
            )
        case 105: // LARGE_TUPLE_EXT
            return try parseTuple(
                count: checkedCollectionCount(
                    try checkedCount(readUInt32()),
                    minimumBytesPerElement: 1
                ),
                depth: depth
            )
        case 106: // NIL_EXT
            return .array([])
        case 108: // LIST_EXT
            let count = try checkedCollectionCount(
                checkedCount(readUInt32()),
                minimumBytesPerElement: 1,
                trailingBytes: 1
            )
            var values: [JSONValue] = []
            values.reserveCapacity(count)
            for _ in 0 ..< count {
                values.append(try parseTerm(depth: depth + 1))
            }
            guard try parseTerm(depth: depth + 1) == .array([]) else {
                throw GatewaySessionError.malformedPayload
            }
            return .array(values)
        case 116: // MAP_EXT
            let count = try checkedCollectionCount(
                checkedCount(readUInt32()),
                minimumBytesPerElement: 2
            )
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(count)
            for _ in 0 ..< count {
                let key = try parseMapKey(depth: depth + 1)
                object[key] = try parseTerm(depth: depth + 1)
            }
            return .object(object)
        default:
            throw GatewaySessionError.malformedPayload
        }
    }

    private mutating func parseNumber(tag: UInt8) throws -> JSONValue {
        switch tag {
        case 70: // NEW_FLOAT_EXT
            return .number(Double(bitPattern: try readUInt64()))
        case 97: // SMALL_INTEGER_EXT
            return .number(Double(try readByte()))
        case 98: // INTEGER_EXT
            return .number(Double(Int32(bitPattern: try readUInt32())))
        case 99: // FLOAT_EXT
            let string = try readString(count: 31).prefix { $0 != "\0" }
            guard let value = Double(String(string)) else {
                throw GatewaySessionError.malformedPayload
            }
            return .number(value)
        case 110: // SMALL_BIG_EXT
            return try parseBigInteger(count: Int(try readByte()))
        case 111: // LARGE_BIG_EXT
            return try parseBigInteger(count: checkedCount(try readUInt32()))
        default:
            throw GatewaySessionError.malformedPayload
        }
    }

    private mutating func parseText(tag: UInt8) throws -> JSONValue {
        switch tag {
        case 100, 118: // ATOM_EXT / ATOM_UTF8_EXT
            return try atomValue(readString(count: Int(try readUInt16())))
        case 107: // STRING_EXT
            // JSON object keys must be strings. Discord normally emits binary
            // keys, but retain a bounded textual interpretation if an ETF map
            // uses the byte-list optimization for a key.
            return .string(try readString(count: Int(try readUInt16())))
        case 109: // BINARY_EXT
            return .string(try readString(count: checkedCount(try readUInt32())))
        case 115, 119: // SMALL_ATOM_EXT / SMALL_ATOM_UTF8_EXT
            return try atomValue(readString(count: Int(try readByte())))
        default:
            throw GatewaySessionError.malformedPayload
        }
    }

    private mutating func parseTuple(count: Int, depth: Int) throws -> JSONValue {
        var values: [JSONValue] = []
        values.reserveCapacity(count)
        for _ in 0 ..< count {
            values.append(try parseTerm(depth: depth + 1))
        }
        return .array(values)
    }

    private mutating func parseMapKey(depth: Int) throws -> String {
        guard depth <= 96 else { throw GatewaySessionError.malformedPayload }
        let tag = try readByte()
        switch tag {
        case 100, 107, 109, 115, 118, 119:
            return switch try parseText(tag: tag) {
            case let .string(value): value
            case let .bool(value): String(value)
            case .null: "null"
            default: throw GatewaySessionError.malformedPayload
            }
        case 70:
            let value = Double(bitPattern: try readUInt64())
            guard value.isFinite else { throw GatewaySessionError.malformedPayload }
            return String(value)
        case 97:
            return String(try readByte())
        case 98:
            return String(Int32(bitPattern: try readUInt32()))
        case 99:
            let string = try readString(count: 31).prefix { $0 != "\0" }
            guard Double(String(string))?.isFinite == true else {
                throw GatewaySessionError.malformedPayload
            }
            return String(string)
        case 110:
            return try parseBigIntegerKey(count: Int(try readByte()))
        case 111:
            return try parseBigIntegerKey(count: checkedCount(try readUInt32()))
        default:
            throw GatewaySessionError.malformedPayload
        }
    }

    private mutating func parseBigInteger(count: Int) throws -> JSONValue {
        let (sign, magnitude) = try parseBigIntegerComponents(count: count)
        let maximumExactlyRepresentableInteger: UInt64 = (1 << 53) - 1
        if magnitude > maximumExactlyRepresentableInteger {
            let value = sign == 1 && magnitude != 0 ? "-\(magnitude)" : String(magnitude)
            return .string(value)
        }
        let value = Double(magnitude) * (sign == 0 ? 1 : -1)
        guard value.isFinite else { throw GatewaySessionError.malformedPayload }
        return .number(value)
    }

    private mutating func parseBigIntegerKey(count: Int) throws -> String {
        let (sign, magnitude) = try parseBigIntegerComponents(count: count)
        return sign == 1 && magnitude != 0 ? "-\(magnitude)" : String(magnitude)
    }

    private mutating func parseBigIntegerComponents(
        count: Int
    ) throws -> (sign: UInt8, magnitude: UInt64) {
        let sign = try readByte()
        guard sign <= 1, count <= 8 else { throw GatewaySessionError.malformedPayload }
        var magnitude: UInt64 = 0
        for offset in 0 ..< count {
            magnitude |= UInt64(try readByte()) << UInt64(offset * 8)
        }
        return (sign, magnitude)
    }

    private func atomValue(_ atom: String) throws -> JSONValue {
        switch atom {
        case "true": .bool(true)
        case "false": .bool(false)
        case "nil", "null", "undefined": .null
        default: .string(atom)
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard bytes.indices.contains(index) else { throw GatewaySessionError.malformedPayload }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func readUInt16() throws -> UInt16 {
        (UInt16(try readByte()) << 8) | UInt16(try readByte())
    }

    private mutating func readUInt32() throws -> UInt32 {
        (UInt32(try readByte()) << 24)
            | (UInt32(try readByte()) << 16)
            | (UInt32(try readByte()) << 8)
            | UInt32(try readByte())
    }

    private mutating func readUInt64() throws -> UInt64 {
        (UInt64(try readUInt32()) << 32) | UInt64(try readUInt32())
    }

    private mutating func readString(count: Int) throws -> String {
        guard count >= 0, index <= bytes.count - count else {
            throw GatewaySessionError.malformedPayload
        }
        defer { index += count }
        guard let string = String(bytes: bytes[index ..< index + count], encoding: .utf8) else {
            throw GatewaySessionError.malformedPayload
        }
        return string
    }

    private func checkedCount(_ value: UInt32) throws -> Int {
        guard value <= 16 * 1024 * 1024 else { throw GatewaySessionError.malformedPayload }
        return Int(value)
    }

    private func checkedCollectionCount(
        _ count: Int,
        minimumBytesPerElement: Int,
        trailingBytes: Int = 0
    ) throws -> Int {
        let remainingBytes = bytes.count - index
        guard remainingBytes >= trailingBytes,
              count <= (remainingBytes - trailingBytes) / minimumBytesPerElement
        else {
            throw GatewaySessionError.malformedPayload
        }
        return count
    }
}
