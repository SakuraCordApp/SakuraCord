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
