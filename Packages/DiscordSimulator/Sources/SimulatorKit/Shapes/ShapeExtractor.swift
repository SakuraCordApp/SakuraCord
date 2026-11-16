import Foundation

/// Builds a `ShapeCatalog` from dcap capture records (`capture.jsonl`). Only
/// kinds, field names, order and ETF tags are kept; no captured value is.
public struct ShapeExtractor {
    public private(set) var catalog: ShapeCatalog

    private struct Interval {
        let label: String
        let markSeq: Int64
        var records: [JSON] = []
    }

    private struct Startup {
        let socket: String
        var steps: [String] = []
        var done = false
    }

    private var interval: Interval?
    /// Received steps on the first Gateway socket until READY_SUPPLEMENTAL. Sent and received
    /// frames are recorded by different CDP events, so only received order is reliable.
    private var startup: Startup?

    static let apiHosts: Set<String> = ["discord.com", "canary.discord.com", "ptb.discord.com", "discordapp.com"]
    /// Steps that occur in every interval regardless of the user's action.
    static let noiseRoutes = ["/science", "/metrics", "/quests", "/promotions", "/billing", "/entitlements",
                              "/store/", "/collectibles", "/content-inventory", "/games", "/oauth2/tokens",
                              "/partner-sdk", "/widget-configs", "/referrals", "/library", "/unclaimed-games"]
    static let noiseEvents: Set<String> = ["PRESENCE_UPDATE", "PASSIVE_UPDATE_V2", "SESSIONS_REPLACE",
                                           "GENERIC_PUSH_NOTIFICATION_SENT", "USER_SETTINGS_PROTO_UPDATE",
                                           "CONTENT_INVENTORY_INBOX_STALE", "GUILD_MEMBER_LIST_UPDATE",
                                           "GUILD_MEMBERS_CHUNK", "CHANNEL_INFO", "REACTION_NOTIFICATION_SENT",
                                           "GUILD_AUDIT_LOG_ENTRY_CREATE", "THREAD_LIST_SYNC"]

    public init(merging catalog: ShapeCatalog = ShapeCatalog()) {
        self.catalog = catalog
    }

    /// Feeds one capture file in record order.
    public mutating func absorb(captureFile url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let record = try? JSON.parse(String(line)) else { continue }
            absorb(record: record)
        }
        finishInterval()
    }

    public mutating func absorb(record: JSON) {
        // Records before the first mark (the reload's Hello and READY) form the startup interval.
        let markSeq = record["markSeq"]?.intValue ?? -1
        if markSeq != interval?.markSeq {
            finishInterval()
            interval = Interval(label: record["mark"]?.stringValue ?? "startup", markSeq: markSeq)
        }
        switch record["kind"]?.stringValue {
        case "http"?:
            absorbHTTP(record)
            interval?.records.append(record)
        case "gw"?:
            absorbGateway(record)
            absorbStartup(record)
            interval?.records.append(record)
        default:
            break
        }
    }

    // MARK: REST

    private mutating func absorbHTTP(_ record: JSON) {
        guard let host = record["host"]?.stringValue, Self.apiHosts.contains(host),
              let method = record["method"]?.stringValue, let path = record["path"]?.stringValue,
              path.hasPrefix("/api/v"), !Self.noiseRoutes.contains(where: path.contains),
              let status = record["status"]?.intValue
        else { return }
        let route = RouteTemplate.template(method: method, path: path)
        var entry = catalog.routes[route] ?? ShapeCatalog.Route()
        entry.samples += 1
        if record["requestBodyFormat"]?.stringValue == "json", let body = record["requestBody"], body.objectValue != nil || body.arrayValue != nil {
            var node = entry.request ?? ShapeNode()
            node.absorb(body)
            entry.request = node
        }
        if record["responseBodyState"]?.stringValue == "captured", record["responseBodyFormat"]?.stringValue == "json",
           let body = record["responseBody"] {
            var node = entry.responses[Int(status)] ?? ShapeNode()
            node.absorb(body)
            entry.responses[Int(status)] = node
        } else if entry.responses[Int(status)] == nil, (record["responseBodyState"]?.stringValue ?? "").hasPrefix("none") {
            // A bodiless status (204, 304) is still a captured outcome.
            entry.responses[Int(status)] = ShapeNode()
        }
        let headers = Set((record["responseHeaders"]?.objectValue?.keys ?? []).map { $0.lowercased() }
            .filter { $0.hasPrefix("x-ratelimit") || $0 == "retry-after" || $0 == "content-type" || $0 == "etag" })
        entry.headers.formUnion(headers)
        catalog.routes[route] = entry
    }

    // MARK: Gateway

    private mutating func absorbGateway(_ record: JSON) {
        guard let op = record["op"]?.intValue, let payload = record["d"], record["scope"]?.stringValue != "omitted",
              record["scope"]?.stringValue != "out"
        else { return }
        let event = record["event"]?.stringValue
        let name = event ?? "op\(op)"
        let frame: JSON = .object(JSONObject([
            ("t", event.map(JSON.string) ?? .null),
            ("s", record["s"] ?? .null),
            ("op", .int(op)),
            ("d", payload),
        ]))
        var node = ShapeNode()
        node.absorb(frame)
        if let etfTypes = record["etfTypes"]?.objectValue {
            for (path, tags) in etfTypes {
                let tagSet = Set((tags.stringValue ?? "").split(separator: "|").map(String.init))
                node.applyETF(path: path, tags: tagSet)
            }
        }
        if record["dir"]?.stringValue == "out" {
            var merged = catalog.gatewaySent[name] ?? ShapeNode()
            merged.merge(node)
            catalog.gatewaySent[name] = merged
        } else {
            var merged = catalog.gateway[name] ?? ShapeNode()
            merged.merge(node)
            catalog.gateway[name] = merged
        }
    }

    // MARK: Sequences

    private mutating func finishInterval() {
        guard let finished = interval else { return }
        interval = nil
        // REST records are written when the response ends; order requests by when they started.
        let records = finished.records.enumerated().sorted { lhs, rhs in
            let left = Self.time(of: lhs.element), right = Self.time(of: rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        // Only flows the parity suite replays: other capture labels are research
        // free text, which can name accounts, and would sit unused in the catalog.
        guard ParitySuite.replayedFlows.contains(finished.label), let steps = Self.flowSequence(records), !steps.isEmpty else { return }
        if catalog.sequences[finished.label] == nil { catalog.sequences[finished.label] = steps }
    }

    static func time(of record: JSON) -> String {
        record["startedAt"]?.stringValue ?? record["ts"]?.stringValue ?? ""
    }

    private mutating func absorbStartup(_ record: JSON) {
        guard record["dir"]?.stringValue == "in", let socket = record["socket"]?.stringValue else { return }
        let op = record["op"]?.intValue ?? -1
        if startup == nil, op == 10 { startup = Startup(socket: socket) }
        guard var current = startup, !current.done, current.socket == socket else { return }
        let event = record["event"]?.stringValue
        if let event, Self.noiseEvents.contains(event) { return }
        current.steps.append("GW \(event ?? "op\(op)")")
        current.done = event == "READY_SUPPLEMENTAL"
        startup = current
        if current.done { catalog.sequences["startup"] = current.steps }
    }

    /// The client's requests and the events about the channel they targeted.
    static func flowSequence(_ records: [JSON]) -> [String]? {
        var channels: Set<String> = []
        var steps: [String] = []
        for record in records {
            if record["kind"]?.stringValue == "http" {
                guard let host = record["host"]?.stringValue, apiHosts.contains(host),
                      let method = record["method"]?.stringValue, let path = record["path"]?.stringValue,
                      !noiseRoutes.contains(where: path.contains)
                else { continue }
                if method != "GET", channels.isEmpty,
                   let channel = path.split(separator: "/").drop(while: { $0 != "channels" }).dropFirst().first {
                    channels.insert(String(channel))
                }
                if method != "GET" { steps.append("REST \(RouteTemplate.template(method: method, path: path))") }
            } else if record["kind"]?.stringValue == "gw", record["dir"]?.stringValue == "in",
                      let event = record["event"]?.stringValue, !noiseEvents.contains(event) {
                let data = record["d"]
                let ids = [data?["channel_id"], data?["id"], data?["parent_id"]].compactMap { $0?.stringValue }
                guard !channels.isEmpty, ids.contains(where: channels.contains) else { continue }
                if event == "THREAD_CREATE", let id = data?["id"]?.stringValue { channels.insert(id) }
                steps.append("GW \(event)")
            }
        }
        return steps.contains(where: { $0.hasPrefix("GW ") }) ? steps : nil
    }
}

extension ShapeNode {
    /// Applies a dcap `etfTypes` entry such as `/d/author/id` or `/d/roles/[]` or `/d/id#key`.
    mutating func applyETF(path: String, tags: Set<String>) {
        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        var isKey = false
        if let last = segments.last, last.hasSuffix("#key") {
            segments[segments.count - 1] = String(last.dropLast(4))
            isKey = true
        }
        if segments.last == "#tail" { return }
        apply(segments[...], tags: tags, isKey: isKey)
    }

    private mutating func apply(_ segments: ArraySlice<String>, tags: Set<String>, isKey: Bool) {
        guard let head = segments.first else {
            if isKey { keyETF.formUnion(tags) } else { etf.formUnion(tags) }
            return
        }
        let rest = segments.dropFirst()
        if head == "[]" {
            guard var element = items?.value else { return }
            element.apply(rest, tags: tags, isKey: isKey)
            items = Box(element)
        } else if let index = fields.firstIndex(where: { $0.name == head }) {
            fields[index].node.apply(rest, tags: tags, isKey: isKey)
        } else if var element = values?.value {
            element.apply(rest, tags: tags, isKey: isKey)
            values = Box(element)
        }
    }
}
