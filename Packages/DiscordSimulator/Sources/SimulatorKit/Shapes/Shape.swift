import Foundation

/// The kind of a JSON value as the parity harness sees it. Strings are split
/// further so a snowflake or timestamp field can't silently become free text.
public enum ValueKind: String, Sendable, CaseIterable, Comparable {
    case null, bool, int, float, string, snowflake, timestamp, object, map, array

    public static func < (lhs: ValueKind, rhs: ValueKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Kinds a captured kind also accepts: a captured free-text string field
    /// may hold an ID or a date, and a float field may hold a whole number.
    func accepts(_ other: ValueKind) -> Bool {
        if self == other { return true }
        switch (self, other) {
        case (.string, .snowflake), (.string, .timestamp), (.float, .int): return true
        case (.object, .map), (.map, .object): return true
        default: return false
        }
    }

    static func of(_ value: JSON) -> ValueKind {
        switch value {
        case .null: .null
        case .bool: .bool
        case .int: .int
        case .double: .float
        case let .string(text): Snowflake.looksLike(text) ? .snowflake : (Timestamps.looksLike(text) ? .timestamp : .string)
        case .array: .array
        case let .object(object): ShapeNode.isMapLike(object) ? .map : .object
        }
    }
}

enum Timestamps {
    static func looksLike(_ text: String) -> Bool {
        // 2026-11-16T00:23:41.123000+00:00
        guard text.count >= 20, text.count <= 40 else { return false }
        let bytes = Array(text.utf8)
        return bytes[4] == UInt8(ascii: "-") && bytes[7] == UInt8(ascii: "-") && bytes[10] == UInt8(ascii: "T")
            && bytes[13] == UInt8(ascii: ":") && bytes[0 ... 3].allSatisfy { (48 ... 57).contains($0) }
    }
}

/// A field of an object shape.
public struct FieldShape: Sendable, Equatable {
    public var name: String
    public var optional: Bool
    public var node: ShapeNode
}

/// The captured shape of one JSON value: which kinds it took, the ordered
/// fields of an object, the element shape of an array or map, and the ETF
/// term tags the Gateway used for it.
public struct ShapeNode: Sendable, Equatable {
    public var kinds: Set<ValueKind> = []
    public var fields: [FieldShape] = []
    public var items: Box<ShapeNode>?
    public var values: Box<ShapeNode>?
    /// ETF tags for this value and for its key in the parent map (Gateway only).
    public var etf: Set<String> = []
    public var keyETF: Set<String> = []
    /// How many object samples this node absorbed; a field missing from any of them is optional.
    var objectSamples = 0

    public init() {}

    public subscript(field name: String) -> ShapeNode? {
        fields.first { $0.name == name }?.node
    }

    /// Objects whose keys are all IDs are dictionaries keyed by ID, not records.
    static func isMapLike(_ object: JSONObject) -> Bool {
        !object.isEmpty && object.keys.allSatisfy { Snowflake.looksLike($0) || $0.allSatisfy(\.isNumber) }
    }

    /// Folds one more observed value into the shape.
    public mutating func absorb(_ value: JSON) {
        let kind = ValueKind.of(value)
        switch value {
        case let .array(elements):
            kinds.insert(.array)
            var element = items?.value ?? ShapeNode()
            for item in elements { element.absorb(item) }
            if !elements.isEmpty || items != nil { items = Box(element) }
        case let .object(object) where kind == .map:
            kinds.insert(.map)
            var element = values?.value ?? ShapeNode()
            for (_, item) in object { element.absorb(item) }
            values = Box(element)
        case let .object(object):
            kinds.insert(.object)
            absorbFields(of: object)
        default:
            kinds.insert(kind)
        }
    }

    private mutating func absorbFields(of object: JSONObject) {
        let firstSample = objectSamples == 0
        objectSamples += 1
        var previousIndex: Int?
        for (key, value) in object {
            if let index = fields.firstIndex(where: { $0.name == key }) {
                fields[index].node.absorb(value)
                previousIndex = index
            } else {
                var node = ShapeNode()
                node.absorb(value)
                let insertAt = previousIndex.map { $0 + 1 } ?? 0
                // A field missing from earlier samples is optional.
                fields.insert(FieldShape(name: key, optional: !firstSample, node: node), at: insertAt)
                previousIndex = insertAt
            }
        }
        let present = Set(object.keys)
        for index in fields.indices where !present.contains(fields[index].name) {
            fields[index].optional = true
        }
    }

    public mutating func merge(_ other: ShapeNode) {
        kinds.formUnion(other.kinds)
        etf.formUnion(other.etf)
        keyETF.formUnion(other.keyETF)
        if let otherItems = other.items {
            var merged = items?.value ?? ShapeNode()
            merged.merge(otherItems.value)
            items = Box(merged)
        }
        if objectSamples == 0, other.objectSamples > 0 {
            fields = other.fields
            objectSamples = other.objectSamples
            if let otherValues = other.values { values = Box(otherValues.value) }
            return
        }
        objectSamples += other.objectSamples
        if let otherValues = other.values {
            var merged = values?.value ?? ShapeNode()
            merged.merge(otherValues.value)
            values = Box(merged)
        }
        var previousIndex: Int?
        for field in other.fields {
            if let index = fields.firstIndex(where: { $0.name == field.name }) {
                fields[index].node.merge(field.node)
                fields[index].optional = fields[index].optional || field.optional
                previousIndex = index
            } else {
                let insertAt = previousIndex.map { $0 + 1 } ?? 0
                fields.insert(FieldShape(name: field.name, optional: true, node: field.node), at: insertAt)
                previousIndex = insertAt
            }
        }
        let names = Set(other.fields.map(\.name))
        if other.objectSamples > 0 {
            for index in fields.indices where !names.contains(fields[index].name) { fields[index].optional = true }
        }
    }
}

public final class Box<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
    public static func == (lhs: Box, rhs: Box) -> Bool { lhs.value == rhs.value }
}

// MARK: - Committed file format

/// `{"t": "object|null", "f": {"id": {"t": "snowflake"}, "nick": {"t": "string", "opt": true}}}`.
/// Arrays use `i`, ID-keyed maps use `v`, and Gateway shapes add `etf` and `ketf`.
public extension ShapeNode {
    func encoded() -> JSON {
        var object = JSONObject()
        object["t"] = .string(kinds.sorted().map(\.rawValue).joined(separator: "|"))
        if !etf.isEmpty { object["etf"] = .string(etf.sorted().joined(separator: "|")) }
        if !keyETF.isEmpty { object["ketf"] = .string(keyETF.sorted().joined(separator: "|")) }
        if !fields.isEmpty {
            var encodedFields = JSONObject()
            for field in fields {
                var node = field.node.encoded()
                if field.optional, case var .object(inner) = node {
                    inner["opt"] = true
                    node = .object(inner)
                }
                encodedFields[field.name] = node
            }
            object["f"] = .object(encodedFields)
        }
        if let items { object["i"] = items.value.encoded() }
        if let values { object["v"] = values.value.encoded() }
        return .object(object)
    }

    init(encoded json: JSON) throws {
        guard let object = json.objectValue, let kindText = object["t"]?.stringValue else {
            throw ShapeError.malformed("shape node needs a \"t\" string")
        }
        self.init()
        kinds = Set(try kindText.split(separator: "|").map {
            guard let kind = ValueKind(rawValue: String($0)) else { throw ShapeError.malformed("unknown kind \($0)") }
            return kind
        })
        etf = Set(object["etf"]?.stringValue?.split(separator: "|").map(String.init) ?? [])
        keyETF = Set(object["ketf"]?.stringValue?.split(separator: "|").map(String.init) ?? [])
        if let encodedFields = object["f"]?.objectValue {
            fields = try encodedFields.map { name, node in
                FieldShape(name: name, optional: node["opt"]?.boolValue ?? false, node: try ShapeNode(encoded: node))
            }
        }
        objectSamples = kinds.contains(.object) ? 1 : 0
        if let items = object["i"] { self.items = Box(try ShapeNode(encoded: items)) }
        if let values = object["v"] { self.values = Box(try ShapeNode(encoded: values)) }
    }
}

public enum ShapeError: Error, CustomStringConvertible {
    case malformed(String)
    public var description: String {
        switch self {
        case let .malformed(reason): "malformed shape: \(reason)"
        }
    }
}
