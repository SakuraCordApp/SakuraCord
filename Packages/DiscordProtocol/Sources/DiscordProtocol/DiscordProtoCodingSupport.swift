import Foundation
import SakuraCordModels

struct ProtoReader {
    var data: Data
    var index = 0

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let value = readVarint() else { return nil }
        return (Int(value >> 3), Int(value & 0x07))
    }

    mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count, shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }
        return nil
    }

    mutating func readFixed64() -> UInt64? {
        guard index + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for offset in 0 ..< 8 {
            value |= UInt64(data[index + offset]) << UInt64(offset * 8)
        }
        index += 8
        return value
    }

    mutating func readLengthDelimited() -> Data? {
        guard let rawLength = readVarint(), rawLength <= UInt64(Int.max) else { return nil }
        let length = Int(rawLength)
        guard index + length <= data.count else { return nil }
        defer { index += length }
        return Data(data[index ..< (index + length)])
    }

    mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0: return readVarint() != nil
        case 1:
            guard index + 8 <= data.count else { return false }
            index += 8
            return true
        case 2: return readLengthDelimited() != nil
        case 5:
            guard index + 4 <= data.count else { return false }
            index += 4
            return true
        default: return false
        }
    }

    mutating func readRawField() -> RawProtoField? {
        let start = index
        guard let tag = readTag() else { return nil }
        var payload: Data?
        var varint: UInt64?
        switch tag.wireType {
        case 0:
            varint = readVarint()
            guard varint != nil else { return nil }
        case 1:
            guard index + 8 <= data.count else { return nil }
            index += 8
        case 2:
            payload = readLengthDelimited()
            guard payload != nil else { return nil }
        case 5:
            guard index + 4 <= data.count else { return nil }
            index += 4
        default:
            return nil
        }
        return RawProtoField(
            field: tag.field,
            wireType: tag.wireType,
            payload: payload,
            varint: varint,
            raw: Data(data[start ..< index])
        )
    }
}

extension ProtoReader {
    /// A singular embedded message field: protobuf merges repeated
    /// occurrences, which parsing their payloads concatenated in wire order
    /// does. nil when the field is absent.
    static func mergedMessage(_ field: Int, in data: Data) -> Data? {
        let payloads = fields(data).filter { $0.field == field }.compactMap(\.payload)
        return payloads.isEmpty ? nil : payloads.reduce(Data(), +)
    }

    static func fields(_ data: Data) -> [RawProtoField] {
        var reader = ProtoReader(data: data)
        var result: [RawProtoField] = []
        while let field = reader.readRawField() { result.append(field) }
        return result
    }
}

struct RawProtoField {
    var field: Int
    var wireType: Int
    var payload: Data?
    var varint: UInt64?
    var raw: Data

    /// The value of a fixed64 field, such as a snowflake map key.
    var fixed64: UInt64? {
        guard wireType == 1 else { return nil }
        var reader = ProtoReader(data: raw)
        _ = reader.readTag()
        return reader.readFixed64()
    }
}

struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skippedCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                try elements.append(container.decode(Element.self))
            } catch {
                skippedCount += 1
                _ = try? container.decode(JSONValue.self)
            }
        }
    }
}

extension LossyList: Sendable where Element: Sendable {}

struct LossyValue<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}
