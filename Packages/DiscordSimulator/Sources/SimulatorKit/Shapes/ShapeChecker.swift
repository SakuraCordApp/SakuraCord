import Foundation

public struct ShapeViolation: Sendable, CustomStringConvertible, Equatable {
    public enum Kind: String, Sendable {
        case type, extraField = "extra-field", missingField = "missing-field", order, etf
        /// The capture never saw an element here, so its shape can't be checked.
        case unverified
    }

    public var kind: Kind
    public var path: String
    public var detail: String

    public var description: String { "\(kind.rawValue) at \(path.isEmpty ? "/" : path): \(detail)" }
}

/// Compares simulator output to a captured shape by kinds, nullability,
/// fields, field order and (for the Gateway) ETF term tags.
public enum ShapeChecker {
    /// `elsewhere` holds, per field name, the kinds and ETF tags that field had anywhere in the
    /// captures. A kind the capture saw for the same field in another context (a user's
    /// `banner` in a profile, say) is reported as unverified rather than wrong.
    public static func check(_ value: JSON, against node: ShapeNode, path: String = "",
                             elsewhere: FieldIndex? = nil) -> [ShapeViolation] {
        var violations: [ShapeViolation] = []
        check(value, node, path, elsewhere, &violations)
        return violations
    }

    /// Checks the ETF tags the encoder used (`path -> tag`, as `ETFEncoder` reports them).
    public static func checkETF(_ tags: [String: String], against node: ShapeNode, elsewhere: FieldIndex? = nil) -> [ShapeViolation] {
        tags.sorted { $0.key < $1.key }.compactMap { path, tag in
            let isKey = path.hasSuffix("#key")
            let trimmed = isKey ? String(path.dropLast(4)) : path
            guard let target = node.resolve(trimmed) else { return nil }
            let allowed = isKey ? target.keyETF : target.etf
            guard !allowed.isEmpty, !allowed.contains(tag) else { return nil }
            // A value only captured as null never showed its own term type, and an
            // empty list is always NIL_EXT whatever tag the captured non-empty one had.
            if !isKey, target.kinds == [.null] { return nil }
            // ETF has one term for null, the atom `nil`, whatever type the field has when set.
            if !isKey, tag == "atom", target.kinds.contains(.null) { return nil }
            if tag == "nil", !allowed.isDisjoint(with: ["list", "string"]) { return nil }
            // Older JSON-only captures saw this type without its ETF term, so there is nothing to compare.
            let used = Self.kinds(ofETF: tag)
            if !isKey, !target.kinds.isDisjoint(with: used), allowed.allSatisfy({ Self.kinds(ofETF: $0).isDisjoint(with: used) }) {
                return ShapeViolation(kind: .unverified, path: path, detail: "\(tag) never captured over ETF")
            }
            let field = String(trimmed.split(separator: "/").last ?? "")
            let parentPath = trimmed.split(separator: "/").dropLast().joined(separator: "/")
            if !isKey, elsewhere?.acceptsETF(tag, field: field, parent: node.resolve("/" + parentPath)) == true {
                return ShapeViolation(kind: .unverified, path: path, detail: "ETF \(tag) captured for \(field) in another context")
            }
            return ShapeViolation(kind: .etf, path: path, detail: "used \(tag), captured \(allowed.sorted().joined(separator: "|"))")
        }
    }

    /// The JSON kinds an ETF term can carry.
    static func kinds(ofETF tag: String) -> Set<ValueKind> {
        switch tag {
        case "small_int", "integer", "small_big", "large_big": [.int, .snowflake]
        case "new_float", "float": [.float]
        case "binary", "string": [.string, .snowflake, .timestamp]
        case "atom", "small_atom", "atom_utf8", "small_atom_utf8": [.bool, .null]
        case "map": [.object, .map]
        case "list", "nil": [.array]
        default: []
        }
    }

    private static func check(_ value: JSON, _ node: ShapeNode, _ path: String, _ elsewhere: FieldIndex?,
                              parent: ShapeNode? = nil, _ out: inout [ShapeViolation]) {
        let kind = ValueKind.of(value)
        let field = String(path.split(separator: "/").last ?? "")
        if !node.kinds.isEmpty, !node.kinds.contains(where: { $0.accepts(kind) }),
           elsewhere?.acceptsKind(kind, field: field, parent: parent) == true {
            out.append(ShapeViolation(kind: .unverified, path: path, detail: "\(kind.rawValue) captured for \(field) in another context"))
            return
        }
        // A field only ever captured as null never showed its value's type.
        if node.kinds == [.null], kind != .null {
            out.append(ShapeViolation(kind: .unverified, path: path, detail: "captured only as null"))
            return
        }
        guard !node.kinds.isEmpty else {
            out.append(ShapeViolation(kind: .unverified, path: path, detail: "no captured shape for \(kind.rawValue)"))
            return
        }
        guard node.kinds.contains(where: { $0.accepts(kind) }) else {
            out.append(ShapeViolation(kind: .type, path: path,
                                      detail: "\(kind.rawValue), captured \(node.kinds.sorted().map(\.rawValue).joined(separator: "|"))"))
            return
        }
        switch value {
        case let .object(object) where !node.fields.isEmpty:
            checkFields(object, node, path, elsewhere, &out)
        case let .object(object):
            // Captured only empty: its keys can't be checked, like a field captured only as null.
            guard let values = node.values?.value else {
                if !object.isEmpty { out.append(ShapeViolation(kind: .unverified, path: path, detail: "captured only empty")) }
                return
            }
            for (key, element) in object { check(element, values, "\(path)/\(key)", elsewhere, &out) }
        case let .array(elements):
            guard let items = node.items?.value else {
                if !elements.isEmpty { out.append(ShapeViolation(kind: .unverified, path: path, detail: "no captured array elements")) }
                return
            }
            for element in elements { check(element, items, "\(path)/[]", elsewhere, &out) }
        default:
            break
        }
    }

    private static func checkFields(_ object: JSONObject, _ node: ShapeNode, _ path: String, _ elsewhere: FieldIndex?, _ out: inout [ShapeViolation]) {
        var lastIndex = -1
        var lastName = ""
        for (key, element) in object {
            guard let index = node.fields.firstIndex(where: { $0.name == key }) else {
                out.append(ShapeViolation(kind: .extraField, path: "\(path)/\(key)", detail: "field the capture never had"))
                continue
            }
            if index < lastIndex {
                out.append(ShapeViolation(kind: .order, path: "\(path)/\(key)", detail: "came after \(lastName)"))
            }
            lastIndex = max(lastIndex, index)
            lastName = key
            check(element, node.fields[index].node, "\(path)/\(key)", elsewhere, parent: node, &out)
        }
        let present = Set(object.keys)
        for field in node.fields where !field.optional && !present.contains(field.name) {
            if elsewhere?.isOptionalElsewhere(field.name, parent: node) == true {
                out.append(ShapeViolation(kind: .unverified, path: "\(path)/\(field.name)", detail: "always present here, optional in other captured contexts"))
            } else {
                out.append(ShapeViolation(kind: .missingField, path: "\(path)/\(field.name)", detail: "required by every capture"))
            }
        }
    }
}

public extension ShapeNode {
    /// Follows a path like `/d/author/id` or `/d/roles/[]` through fields, items and map values.
    func resolve(_ path: String) -> ShapeNode? {
        var node = self
        for segment in path.split(separator: "/") {
            if segment == "[]" {
                guard let items = node.items?.value else { return nil }
                node = items
            } else if let field = node[field: String(segment)] {
                node = field
            } else if let values = node.values?.value {
                node = values
            } else {
                return nil
            }
        }
        return node
    }

    /// Reorders object keys to the captured order and drops keys the capture
    /// never had. Returns the dropped paths so callers can log them.
    func conform(_ value: JSON, path: String = "") -> (JSON, dropped: [String]) {
        var dropped: [String] = []
        let result = conform(value, path, &dropped)
        return (result, dropped)
    }

    private func conform(_ value: JSON, _ path: String, _ dropped: inout [String]) -> JSON {
        switch value {
        case let .object(object) where !fields.isEmpty:
            var ordered = JSONObject()
            for field in fields {
                if let element = object[field.name] {
                    ordered[field.name] = field.node.conform(element, "\(path)/\(field.name)", &dropped)
                }
            }
            for key in object.keys where self[field: key] == nil { dropped.append("\(path)/\(key)") }
            return .object(ordered)
        case let .object(object):
            guard let values = values?.value else { return value }
            var mapped = JSONObject()
            for (key, element) in object { mapped[key] = values.conform(element, "\(path)/\(key)", &dropped) }
            return .object(mapped)
        case let .array(elements):
            guard let items = items?.value else { return value }
            return .array(elements.map { items.conform($0, "\(path)/[]", &dropped) })
        default:
            return value
        }
    }
}

/// What each field looked like in other captured objects of the same kind:
/// a field counts as "the same" only in objects whose field sets overlap at
/// least half, so a user's `banner` in a profile informs a message author's
/// `banner`, but an unrelated object's `id` informs nothing.
public struct FieldIndex: Sendable {
    struct Context: Sendable {
        var siblings: Set<String>
        var kinds: Set<ValueKind>
        var etf: Set<String>
        var optional: Bool
    }

    private var contexts: [String: [Context]] = [:]

    public init(_ catalog: ShapeCatalog) {
        var roots: [ShapeNode] = Array(catalog.gateway.values)
        for route in catalog.routes.values { roots += Array(route.responses.values) }
        for root in roots { visit(root) }
    }

    private mutating func visit(_ node: ShapeNode) {
        let siblings = Set(node.fields.map(\.name))
        for field in node.fields {
            contexts[field.name, default: []].append(Context(siblings: siblings, kinds: field.node.kinds,
                                                             etf: field.node.etf, optional: field.optional))
            visit(field.node)
        }
        if let items = node.items?.value { visit(items) }
        if let values = node.values?.value { visit(values) }
    }

    func similar(_ field: String, in parent: ShapeNode?) -> [Context] {
        guard let parent, let candidates = contexts[field] else { return [] }
        let siblings = Set(parent.fields.map(\.name))
        return candidates.filter { context in
            let union = context.siblings.union(siblings).count
            return union > 0 && Double(context.siblings.intersection(siblings).count) / Double(union) >= 0.5
        }
    }

    func acceptsKind(_ kind: ValueKind, field: String, parent: ShapeNode?) -> Bool {
        similar(field, in: parent).contains { $0.kinds.contains { $0.accepts(kind) } }
    }

    func acceptsETF(_ tag: String, field: String, parent: ShapeNode?) -> Bool {
        similar(field, in: parent).contains { $0.etf.contains(tag) }
    }

    func isOptionalElsewhere(_ field: String, parent: ShapeNode?) -> Bool {
        similar(field, in: parent).contains { $0.optional }
    }
}
