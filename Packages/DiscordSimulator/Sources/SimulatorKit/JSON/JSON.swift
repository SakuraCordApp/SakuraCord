import Foundation

/// A JSON value that keeps object key order. Discord's payloads have a stable
/// key order per object type, and the parity harness compares it.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    public subscript(key: String) -> JSON? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    public var intValue: Int64? {
        switch self {
        case let .int(value): value
        case let .double(value): Int64(exactly: value)
        case let .string(value): Int64(value)
        default: nil
        }
    }
    public var boolValue: Bool? { if case let .bool(value) = self { value } else { nil } }
    public var arrayValue: [JSON]? { if case let .array(value) = self { value } else { nil } }
    public var objectValue: JSONObject? { if case let .object(value) = self { value } else { nil } }
    public var doubleValue: Double? { if case let .double(value) = self { value } else { intValue.map(Double.init) } }
}

public struct JSONObject: Sendable, Equatable, Sequence {
    public private(set) var entries: [(key: String, value: JSON)] = []

    public init() {}
    public init(_ entries: [(String, JSON)]) {
        for (key, value) in entries { self[key] = value }
    }

    public var keys: [String] { entries.map(\.key) }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public subscript(key: String) -> JSON? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: JSON)]> { entries.makeIterator() }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

public extension JSON {
    /// `nil` becomes `null`, matching how Discord writes absent-but-present fields.
    static func optional(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
    static func optional(_ value: Int?) -> JSON { value.map { .int(Int64($0)) } ?? .null }
    static func optional(_ value: Bool?) -> JSON { value.map(JSON.bool) ?? .null }
    static func optional(_ value: JSON?) -> JSON { value ?? .null }
    static func int(_ value: Int) -> JSON { .int(Int64(value)) }
}

// MARK: - Serialization

public extension JSON {
    /// Discord's REST bodies use `", "` and `": "` separators.
    func serialized(spaced: Bool = true) -> String {
        var out = ""
        write(into: &out, spaced: spaced)
        return out
    }

    func data(spaced: Bool = true) -> Data { Data(serialized(spaced: spaced).utf8) }

    private func write(into out: inout String, spaced: Bool) {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .int(value): out += String(value)
        case let .double(value):
            if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
                out += String(format: "%.1f", value)
            } else {
                out += String(value)
            }
        case let .string(value): JSON.writeString(value, into: &out)
        case let .array(values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += spaced ? ", " : "," }
                value.write(into: &out, spaced: spaced)
            }
            out += "]"
        case let .object(object):
            out += "{"
            for (index, entry) in object.entries.enumerated() {
                if index > 0 { out += spaced ? ", " : "," }
                JSON.writeString(entry.key, into: &out)
                out += spaced ? ": " : ":"
                entry.value.write(into: &out, spaced: spaced)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON parse error at \(offset): \(reason)" }
}

public extension JSON {
    static func parse(_ data: Data) throws -> JSON {
        var parser = JSONParser(bytes: [UInt8](data))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
        return value
    }

    static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    func error(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws -> JSON {
        skipWhitespace()
        guard index < bytes.count else { throw error("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw error("expected \(literal)") }
            index += 1
        }
    }

    mutating func parseObject() throws -> JSON {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected :") }
            index += 1
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("expected , or }")
        }
    }

    mutating func parseArray() throws -> JSON {
        index += 1
        var values: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
        while true {
            values.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
            throw error("expected , or ]")
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() {
            if !raw.isEmpty { scalars.append(contentsOf: (String(bytes: raw, encoding: .utf8) ?? "").unicodeScalars); raw = [] }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { index += 1; flush(); return String(scalars) }
            if byte == UInt8(ascii: "\\") {
                flush()
                index += 1
                guard index < bytes.count else { break }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "u"):
                    var code = try parseHex4()
                    if (0xD800 ... 0xDBFF).contains(code), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00 ... 0xDFFF).contains(low) else { throw error("unpaired surrogate") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    // A lone surrogate is no scalar; the body is rejected as malformed.
                    guard let scalar = Unicode.Scalar(code) else { throw error("unpaired surrogate") }
                    scalars.append(scalar)
                default: scalars.append(Unicode.Scalar(escaped))
                }
                continue
            }
            raw.append(byte)
            index += 1
        }
        throw error("unterminated string")
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(bytes: bytes[index ..< index + 4], encoding: .utf8) ?? "", radix: 16)
        else { throw error("bad \\u escape") }
        index += 4
        return value
    }

    mutating func parseNumber() throws -> JSON {
        let start = index
        var isFloat = false
        while index < bytes.count {
            let byte = bytes[index]
            if (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") {
                index += 1
            } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                isFloat = true
                index += 1
            } else {
                break
            }
        }
        let text = String(bytes: bytes[start ..< index], encoding: .utf8) ?? ""
        if !isFloat, let value = Int64(text) { return .int(value) }
        guard let value = Double(text) else { throw error("bad number \(text)") }
        return .double(value)
    }
}
