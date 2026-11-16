import Foundation

/// Every shape captured from the official client: REST request and response
/// bodies per route and status, Gateway payloads per event, and the order of
/// Gateway events and requests in each captured flow.
public struct ShapeCatalog: Sendable {
    public struct Route: Sendable {
        public var request: ShapeNode?
        public var responses: [Int: ShapeNode] = [:]
        public var samples = 0
        /// Rate-limit and content headers the route answered with.
        public var headers: Set<String> = []
    }

    /// `"GET /api/v9/channels/{id}/messages"`.
    public var routes: [String: Route] = [:]
    /// `"MESSAGE_CREATE"` for dispatches, `"op10"` for other ops; the whole frame `{op, d, s, t}`.
    public var gateway: [String: ShapeNode] = [:]
    /// Client-sent Gateway frames, keyed like `gateway`.
    public var gatewaySent: [String: ShapeNode] = [:]
    /// Named flows as ordered steps such as `"REST POST /api/v9/channels/{id}/messages"` or `"GW MESSAGE_CREATE"`.
    public var sequences: [String: [String]] = [:]

    public init() {}

    public func response(_ route: String, status: Int) -> ShapeNode? { routes[route]?.responses[status] }
}

// MARK: - Route templates

public enum RouteTemplate {
    /// Turns a concrete request path into the template the catalog keys on.
    public static func template(method: String, path: String) -> String {
        let trimmed = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        var segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for index in segments.indices {
            let segment = segments[index]
            let previous = index > 0 ? segments[index - 1] : ""
            if segment == "%40me" { segments[index] = "@me"; continue }
            if previous == "reactions", segment != "@me" { segments[index] = "{emoji}"; continue }
            if previous == "answers", segment != "@me" { segments[index] = "{answer_id}"; continue }
            if previous == "invites" { segments[index] = "{code}"; continue }
            if previous == "settings-proto" { continue }
            // Account identifiers must never become literal template text: a
            // connection's ID can be a plain name, and other IDs mix letters and digits.
            if index > 1, segments[index - 2] == "connections" { segments[index] = "{connection_id}"; continue }
            if Snowflake.looksLike(segment) || looksLikeIdentifier(segment) { segments[index] = "{id}" }
        }
        return "\(method) \(segments.joined(separator: "/"))"
    }

    static func looksLikeIdentifier(_ segment: String) -> Bool {
        segment.count >= 12 && segment.contains(where: \.isNumber) && segment.contains(where: \.isLetter)
    }
}

// MARK: - Files

public extension ShapeCatalog {
    static let fileNames = (rest: "rest.json", gateway: "gateway.json", sequences: "sequences.json")

    /// The catalog bundled with the simulator.
    static func bundled() throws -> ShapeCatalog {
        guard let directory = Bundle.module.url(forResource: "Shapes", withExtension: nil) else {
            throw ShapeError.malformed("bundled Shapes directory is missing")
        }
        return try load(from: directory)
    }

    static func load(from directory: URL) throws -> ShapeCatalog {
        var catalog = ShapeCatalog()
        let rest = try JSON.parse(Data(contentsOf: directory.appending(path: fileNames.rest)))
        for (route, entry) in rest.objectValue ?? JSONObject() {
            var value = Route()
            value.samples = Int(entry["samples"]?.intValue ?? 0)
            value.headers = Set(entry["headers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            if let request = entry["request"] { value.request = try ShapeNode(encoded: request) }
            for (status, node) in entry["responses"]?.objectValue ?? JSONObject() {
                guard let code = Int(status) else { continue }
                value.responses[code] = try ShapeNode(encoded: node)
            }
            catalog.routes[route] = value
        }
        let gateway = try JSON.parse(Data(contentsOf: directory.appending(path: fileNames.gateway)))
        for (name, node) in gateway["received"]?.objectValue ?? JSONObject() {
            catalog.gateway[name] = try ShapeNode(encoded: node)
        }
        for (name, node) in gateway["sent"]?.objectValue ?? JSONObject() {
            catalog.gatewaySent[name] = try ShapeNode(encoded: node)
        }
        let sequences = try JSON.parse(Data(contentsOf: directory.appending(path: fileNames.sequences)))
        for (name, steps) in sequences.objectValue ?? JSONObject() {
            catalog.sequences[name] = steps.arrayValue?.compactMap(\.stringValue) ?? []
        }
        return catalog
    }

    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rest = JSONObject()
        for route in routes.keys.sorted() {
            let value = routes[route]!
            var entry = JSONObject()
            entry["samples"] = .int(value.samples)
            entry["headers"] = .array(value.headers.sorted().map(JSON.string))
            if let request = value.request { entry["request"] = request.encoded() }
            var responses = JSONObject()
            for status in value.responses.keys.sorted() { responses[String(status)] = value.responses[status]!.encoded() }
            entry["responses"] = .object(responses)
            rest[route] = .object(entry)
        }
        try JSON.object(rest).prettyData().write(to: directory.appending(path: Self.fileNames.rest))
        var received = JSONObject()
        for name in gateway.keys.sorted() { received[name] = gateway[name]!.encoded() }
        var sent = JSONObject()
        for name in gatewaySent.keys.sorted() { sent[name] = gatewaySent[name]!.encoded() }
        try JSON.object(JSONObject([("received", .object(received)), ("sent", .object(sent))]))
            .prettyData().write(to: directory.appending(path: Self.fileNames.gateway))
        var flows = JSONObject()
        for name in sequences.keys.sorted() { flows[name] = .array(sequences[name]!.map(JSON.string)) }
        try JSON.object(flows).prettyData().write(to: directory.appending(path: Self.fileNames.sequences))
    }
}

public extension JSON {
    /// Two-space indented output for committed files.
    func prettyData() -> Data {
        var out = ""
        writePretty(into: &out, indent: 0)
        out += "\n"
        return Data(out.utf8)
    }

    private func writePretty(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closing = String(repeating: "  ", count: indent)
        switch self {
        case let .array(values) where !values.isEmpty:
            out += "[\n"
            for (index, value) in values.enumerated() {
                out += pad
                value.writePretty(into: &out, indent: indent + 1)
                out += index < values.count - 1 ? ",\n" : "\n"
            }
            out += closing + "]"
        case let .object(object) where !object.isEmpty:
            // Leaf shape nodes stay on one line so files read like a schema.
            if object.allSatisfy({ $0.value.objectValue == nil && $0.value.arrayValue == nil }) {
                out += serialized(spaced: true)
                return
            }
            out += "{\n"
            for (index, entry) in object.entries.enumerated() {
                out += pad + JSON.string(entry.key).serialized() + ": "
                entry.value.writePretty(into: &out, indent: indent + 1)
                out += index < object.count - 1 ? ",\n" : "\n"
            }
            out += closing + "}"
        default:
            out += serialized(spaced: true)
        }
    }
}
