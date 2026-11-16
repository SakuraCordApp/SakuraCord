import Foundation

/// Encodes Gateway frames as ETF with the term types Discord used at each
/// captured path, so a client's decoder sees the same tags it gets in production.
public enum ETFEncoder {
    /// Returns the bytes and the tag used at each path (`/d/author/id`,
    /// `/d/roles/[]`, `/d/author/id#key`), in the syntax `ShapeChecker.checkETF` reads.
    ///
    /// Without captured tags the encoder falls back to what the captures show
    /// most: snowflake strings as binaries, `nil` for empty lists, STRING_EXT for
    /// byte lists (as Erlang does), atom keys for the frame itself, and nested
    /// keys styled like their captured siblings or, failing that, like the key
    /// that holds their object.
    public static func encode(_ value: JSON, shape: ShapeNode?) -> (bytes: Data, tags: [String: String]) {
        var writer = ETFWriter(recordsTags: true)
        writer.bytes.append(ETFTag.version)
        writer.write(value, node: shape, path: "", inheritedKey: .atom)
        return (Data(writer.bytes), writer.tags)
    }

    /// The same bytes without the per-path tags, for sending: a big account's READY has millions of paths.
    public static func bytes(_ value: JSON, shape: ShapeNode?) -> Data {
        var writer = ETFWriter(recordsTags: false)
        writer.bytes.append(ETFTag.version)
        writer.write(value, node: shape, path: "", inheritedKey: .atom)
        return Data(writer.bytes)
    }
}

private enum KeyStyle { case atom, binary }

private struct ETFWriter {
    let recordsTags: Bool
    var bytes: [UInt8] = []
    var tags: [String: String] = [:]

    mutating func write(_ value: JSON, node: ShapeNode?, path: String, inheritedKey: KeyStyle) {
        let captured = node?.etf ?? []
        switch value {
        case .null:
            writeAtom("nil", captured: captured, path: path)
        case let .bool(flag):
            writeAtom(flag ? "true" : "false", captured: captured, path: path)
        case let .int(number):
            writeInteger(number, captured: captured, path: path)
        case let .double(number):
            record(.newFloat, path)
            bytes.append(ETFTag.newFloat.rawValue)
            append(number.bitPattern)
        case let .string(text):
            if captured.contains(ETFTag.smallBig.name), let id = UInt64(text) {
                writeBig(magnitude: id, negative: false, path: path)
            } else if !captured.contains(ETFTag.binary.name), atomTag(captured) != nil, text.utf8.count <= 255 {
                writeAtom(text, captured: captured, path: path)
            } else {
                writeBinary(text, path: path)
            }
        case let .array(elements):
            writeList(elements, node: node, path: path, inheritedKey: inheritedKey)
        case let .object(object):
            writeMap(object, node: node, path: path, inheritedKey: inheritedKey)
        }
    }

    private mutating func writeList(_ elements: [JSON], node: ShapeNode?, path: String, inheritedKey: KeyStyle) {
        let captured = node?.etf ?? []
        // Some Erlang-side values (experiment assignments) reach the client as tuples.
        if captured.contains(ETFTag.smallTuple.name), !captured.contains(ETFTag.list.name), elements.count <= 255 {
            record(.smallTuple, path)
            bytes += [ETFTag.smallTuple.rawValue, UInt8(elements.count)]
            writeElements(elements, node: node, path: path, inheritedKey: inheritedKey)
            return
        }
        if elements.isEmpty {
            // Erlang writes `[]` as NIL_EXT; a zero-length LIST_EXT only when the capture never saw nil.
            if captured.contains(ETFTag.list.name), !captured.contains(ETFTag.nil.name) {
                record(.list, path)
                bytes.append(ETFTag.list.rawValue)
                append(UInt32(0))
            } else {
                record(.nil, path)
            }
            bytes.append(ETFTag.nil.rawValue)
            return
        }
        // Erlang packs a list of bytes as STRING_EXT, as Discord did for ranges and descriptors.
        let byteValues = elements.compactMap { element -> UInt8? in
            guard case let .int(number) = element else { return nil }
            return UInt8(exactly: number)
        }
        if byteValues.count == elements.count, elements.count <= Int(UInt16.max),
           captured.isEmpty || captured.contains(ETFTag.string.name) {
            record(.string, path)
            bytes.append(ETFTag.string.rawValue)
            append(UInt16(byteValues.count))
            bytes += byteValues
            return
        }
        record(.list, path)
        bytes.append(ETFTag.list.rawValue)
        append(UInt32(elements.count))
        writeElements(elements, node: node, path: path, inheritedKey: inheritedKey)
        bytes.append(ETFTag.nil.rawValue)
    }

    private mutating func writeElements(_ elements: [JSON], node: ShapeNode?, path: String, inheritedKey: KeyStyle) {
        let itemPath = recordsTags ? "\(path)/[]" : ""
        for element in elements {
            write(element, node: node?.items?.value, path: itemPath, inheritedKey: inheritedKey)
        }
    }

    private mutating func writeMap(_ object: JSONObject, node: ShapeNode?, path: String, inheritedKey: KeyStyle) {
        record(.map, path)
        bytes.append(ETFTag.map.rawValue)
        append(UInt32(object.count))
        let defaultKey = node.flatMap(Self.siblingKeyStyle) ?? inheritedKey
        for (key, value) in object {
            let child = node.flatMap { $0[field: key] ?? $0.values?.value }
            let childPath = recordsTags ? "\(path)/\(key)" : ""
            let style = writeKey(key, captured: child?.keyETF ?? [], fallback: defaultKey, path: recordsTags ? "\(childPath)#key" : "")
            write(value, node: child, path: childPath, inheritedKey: style)
        }
    }

    /// Writes a map key and returns the style nested objects without captured keys inherit.
    private mutating func writeKey(_ key: String, captured: Set<String>, fallback: KeyStyle, path: String) -> KeyStyle {
        if !captured.isDisjoint(with: Self.integerTags), let number = Int64(key) {
            writeInteger(number, captured: captured, path: path)
            return fallback
        }
        let hasAtom = atomTag(captured) != nil
        let hasBinary = captured.contains(ETFTag.binary.name)
        let style: KeyStyle = switch (hasAtom, hasBinary) {
        case (true, false): .atom
        case (false, true): .binary
        default: fallback
        }
        if style == .atom, key.utf8.count <= 255 {
            writeAtom(key, captured: captured, path: path)
        } else {
            writeBinary(key, path: path)
        }
        return style
    }

    /// Discord mixes atom keys (built by the Gateway) and binary keys (passed
    /// through from the API) per object, so an unknown key follows its siblings.
    private static func siblingKeyStyle(_ node: ShapeNode) -> KeyStyle? {
        let children = node.fields.map(\.node) + [node.values?.value].compactMap { $0 }
        let atoms = children.count { $0.keyETF.contains(ETFTag.atom.name) }
        let binaries = children.count { $0.keyETF.contains(ETFTag.binary.name) }
        if atoms == binaries { return nil }
        return atoms > binaries ? .atom : .binary
    }

    // MARK: Terms

    private func atomTag(_ captured: Set<String>) -> ETFTag? {
        [ETFTag.atom, .smallAtomUTF8, .atomUTF8, .smallAtom].first { captured.contains($0.name) }
    }

    private mutating func writeAtom(_ text: String, captured: Set<String>, path: String) {
        let utf8 = Array(text.utf8)
        var tag = atomTag(captured) ?? .atom
        // ATOM_EXT and SMALL_ATOM_EXT are Latin-1; only plain ASCII stays in them.
        if [.atom, .smallAtom].contains(tag), !text.allSatisfy(\.isASCII) { tag = .smallAtomUTF8 }
        record(tag, path)
        bytes.append(tag.rawValue)
        if tag == .smallAtom || tag == .smallAtomUTF8 {
            bytes.append(UInt8(utf8.count))
        } else {
            append(UInt16(utf8.count))
        }
        bytes += utf8
    }

    private mutating func writeBinary(_ text: String, path: String) {
        let utf8 = Array(text.utf8)
        record(.binary, path)
        bytes.append(ETFTag.binary.rawValue)
        append(UInt32(utf8.count))
        bytes += utf8
    }

    /// The narrowest captured integer tag that holds the value, else the narrowest that does.
    private mutating func writeInteger(_ number: Int64, captured: Set<String>, path: String) {
        let fitting: [ETFTag] = (0 ... 255).contains(number) ? [.smallInteger, .integer, .smallBig]
            : Int32(exactly: number) != nil ? [.integer, .smallBig] : [.smallBig]
        switch fitting.first(where: { captured.contains($0.name) }) ?? fitting[0] {
        case .smallInteger:
            record(.smallInteger, path)
            bytes += [ETFTag.smallInteger.rawValue, UInt8(number)]
        case .integer:
            record(.integer, path)
            bytes.append(ETFTag.integer.rawValue)
            append(UInt32(bitPattern: Int32(number)))
        default:
            writeBig(magnitude: number.magnitude, negative: number < 0, path: path)
        }
    }

    private mutating func writeBig(magnitude: UInt64, negative: Bool, path: String) {
        var digits: [UInt8] = []
        var rest = magnitude
        repeat {
            digits.append(UInt8(truncatingIfNeeded: rest))
            rest >>= 8
        } while rest > 0
        record(.smallBig, path)
        bytes += [ETFTag.smallBig.rawValue, UInt8(digits.count), negative ? 1 : 0] + digits
    }

    private static let integerTags: Set = [ETFTag.smallInteger.name, ETFTag.integer.name, ETFTag.smallBig.name]

    private mutating func record(_ tag: ETFTag, _ path: String) {
        if recordsTags, tags[path] == nil { tags[path] = tag.name }
    }

    private mutating func append(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.bigEndian) { bytes += $0 }
    }
}
