import Foundation

/// Decodes typed Gateway DTOs directly from the JSON-compatible value tree
/// produced by the ETF parser. This avoids serializing large dispatch payloads
/// to JSON only for `JSONDecoder` to parse the same structure again.
struct JSONValueDecoder {
    func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: JSONValue
    ) throws -> Value {
        try Value(from: JSONValueDecoderImplementation(value: value, codingPath: []))
    }
}

private struct JSONValueDecoderImplementation: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        guard case let .object(object) = value else {
            throw typeMismatch([String: JSONValue].self, value: value, codingPath: codingPath)
        }
        return KeyedDecodingContainer(
            JSONValueKeyedDecodingContainer<Key>(
                object: object,
                codingPath: codingPath
            )
        )
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case let .array(array) = value else {
            throw typeMismatch([JSONValue].self, value: value, codingPath: codingPath)
        }
        return JSONValueUnkeyedDecodingContainer(values: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        JSONValueSingleValueDecodingContainer(value: value, codingPath: codingPath)
    }
}

private struct JSONValueKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: [String: JSONValue]
    let codingPath: [any CodingKey]

    var allKeys: [Key] {
        object.keys.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
        object[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let value = object[key.stringValue] else {
            throw keyNotFound(key, codingPath: codingPath)
        }
        if case .null = value { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try singleValue(forKey: key).decode(type)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try singleValue(forKey: key).decode(type)
    }

    func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Value {
        let value = try requiredValue(forKey: key)
        return try Value(
            from: JSONValueDecoderImplementation(
                value: value,
                codingPath: codingPath
            )
        )
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try decoder(forKey: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try decoder(forKey: key).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        JSONValueDecoderImplementation(value: .object(object), codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        try decoder(forKey: key)
    }

    private func requiredValue(forKey key: Key) throws -> JSONValue {
        guard let value = object[key.stringValue] else {
            throw keyNotFound(key, codingPath: codingPath)
        }
        return value
    }

    private func decoder(forKey key: Key) throws -> JSONValueDecoderImplementation {
        JSONValueDecoderImplementation(
            value: try requiredValue(forKey: key),
            codingPath: codingPath
        )
    }

    private func singleValue(
        forKey key: Key
    ) throws -> JSONValueSingleValueDecodingContainer {
        JSONValueSingleValueDecodingContainer(
            value: try requiredValue(forKey: key),
            codingPath: codingPath
        )
    }
}

private struct JSONValueUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let values: [JSONValue]
    let codingPath: [any CodingKey]
    var currentIndex = 0

    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    mutating func decodeNil() throws -> Bool {
        let value = try currentValue()
        if case .null = value {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try decodePrimitive(type) }
    mutating func decode(_ type: String.Type) throws -> String { try decodePrimitive(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try decodePrimitive(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try decodePrimitive(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try decodePrimitive(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try decodePrimitive(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try decodePrimitive(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try decodePrimitive(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try decodePrimitive(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try decodePrimitive(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try decodePrimitive(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try decodePrimitive(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try decodePrimitive(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try decodePrimitive(type) }

    mutating func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let decoder = try decoderForCurrentValue()
        let result = try Value(from: decoder)
        currentIndex += 1
        return result
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let decoder = try decoderForCurrentValue()
        let result = try decoder.container(keyedBy: type)
        currentIndex += 1
        return result
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let decoder = try decoderForCurrentValue()
        let result = try decoder.unkeyedContainer()
        currentIndex += 1
        return result
    }

    mutating func superDecoder() throws -> any Decoder {
        let decoder = try decoderForCurrentValue()
        currentIndex += 1
        return decoder
    }

    private mutating func decodePrimitive<Value: Decodable>(
        _ type: Value.Type
    ) throws -> Value {
        let decoder = try decoderForCurrentValue()
        let result = try Value(from: decoder)
        currentIndex += 1
        return result
    }

    private func currentValue() throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                JSONValue.self,
                .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end.")
            )
        }
        return values[currentIndex]
    }

    private func decoderForCurrentValue() throws -> JSONValueDecoderImplementation {
        JSONValueDecoderImplementation(
            value: try currentValue(),
            codingPath: codingPath
        )
    }
}

private struct JSONValueSingleValueDecodingContainer: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool {
        if case .null = value { return true }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case let .bool(result) = value else { throw mismatch(type) }
        return result
    }

    func decode(_ type: String.Type) throws -> String {
        guard case let .string(result) = value else { throw mismatch(type) }
        return result
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard case let .number(result) = value else { throw mismatch(type) }
        return result
    }

    func decode(_ type: Float.Type) throws -> Float {
        let number = try decode(Double.self)
        guard number >= -Double(Float.greatestFiniteMagnitude),
              number <= Double(Float.greatestFiniteMagnitude)
        else { throw mismatch(type) }
        return Float(number)
    }

    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        if type == JSONValue.self, let result = value as? Value { return result }
        return try Value(
            from: JSONValueDecoderImplementation(value: value, codingPath: codingPath)
        )
    }

    private func integer<Value: FixedWidthInteger>(_ type: Value.Type) throws -> Value {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              let result = Value(exactly: number)
        else { throw mismatch(type) }
        return result
    }

    private func mismatch(_ type: Any.Type) -> DecodingError {
        typeMismatch(type, value: value, codingPath: codingPath)
    }
}

private func keyNotFound(
    _ key: some CodingKey,
    codingPath: [any CodingKey]
) -> DecodingError {
    .keyNotFound(
        key,
        .init(
            codingPath: codingPath,
            debugDescription: "No value associated with key \(key.stringValue)."
        )
    )
}

private func typeMismatch(
    _ type: Any.Type,
    value: JSONValue,
    codingPath: [any CodingKey]
) -> DecodingError {
    .typeMismatch(
        type,
        .init(
            codingPath: codingPath,
            debugDescription: "Expected \(type), but found \(value.kindDescription)."
        )
    )
}

private extension JSONValue {
    var kindDescription: String {
        switch self {
        case .string: "a string"
        case .number: "a number"
        case .bool: "a boolean"
        case .object: "an object"
        case .array: "an array"
        case .null: "null"
        }
    }
}
