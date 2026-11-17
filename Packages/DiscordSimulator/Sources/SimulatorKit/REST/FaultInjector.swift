import Foundation
import Synchronization

/// REST faults set through the control API, plus Discord's per-route rate
/// limits for the routes clients most often hit them on.
public final class FaultInjector: Sendable {
    public struct Rule: Sendable, Codable, Equatable {
        /// 429 or a 5xx status.
        public var status: Int
        /// Substring of the route template (`"POST /api/v9/channels/{id}/messages"`); empty matches all.
        public var route: String
        /// How many matching requests fail before the rule expires; nil means until cleared.
        public var remaining: Int?
        /// `retry_after` for 429s, in seconds.
        public var retryAfter: Double
        public var global: Bool

        public init(status: Int, route: String = "", remaining: Int? = 1, retryAfter: Double = 1.5, global: Bool = false) {
            self.status = status
            self.route = route
            self.remaining = remaining
            self.retryAfter = retryAfter
            self.global = global
        }
    }

    private struct Bucket { var resetAt: Date; var remaining: Int }

    private let rules = Mutex<[Rule]>([])
    private let buckets = Mutex<[String: Bucket]>([:])
    private let enforcesRateLimits: Bool

    public init(enforcesRateLimits: Bool = true) { self.enforcesRateLimits = enforcesRateLimits }

    public func add(_ rule: Rule) { rules.withLock { $0.append(rule) } }
    public func clear() { rules.withLock { $0.removeAll() } }
    public var activeRules: [Rule] { rules.withLock { $0 } }

    func restFault(for template: String) -> HTTPResponse? {
        let matched: Rule? = rules.withLock { rules in
            guard let index = rules.firstIndex(where: { $0.route.isEmpty || template.contains($0.route) }) else { return nil }
            let rule = rules[index]
            if let remaining = rule.remaining {
                if remaining <= 1 { rules.remove(at: index) } else { rules[index].remaining = remaining - 1 }
            }
            return rule
        }
        guard let rule = matched else { return nil }
        if rule.status == 429 { return Self.rateLimited(retryAfter: rule.retryAfter, global: rule.global, bucket: "fault") }
        let message = rule.status == 503 ? "upstream connect error or disconnect/reset before headers. reset reason: overflow"
            : "\(rule.status): Internal Server Error"
        return .discordError(rule.status, message)
    }

    /// Discord limits message creation to 5 per 5 seconds per channel and reactions to 1 per 0.25 s.
    func rateLimit(template: String, userID: Snowflake, parameters: [String]) -> HTTPResponse? {
        guard enforcesRateLimits else { return nil }
        let limits: [String: (count: Int, window: TimeInterval)] = [
            "POST /api/v9/channels/{id}/messages": (5, 5),
            "PUT /api/v9/channels/{id}/messages/{id}/reactions/{emoji}/@me": (4, 1),
            "POST /api/v9/channels/{id}/typing": (5, 5),
        ]
        guard let limit = limits[template] else { return nil }
        let key = "\(template)|\(userID)|\(parameters.first ?? "")"
        let now = Date()
        let waited: TimeInterval? = buckets.withLock { buckets in
            var bucket = buckets[key] ?? Bucket(resetAt: now.addingTimeInterval(limit.window), remaining: limit.count)
            if bucket.resetAt <= now { bucket = Bucket(resetAt: now.addingTimeInterval(limit.window), remaining: limit.count) }
            guard bucket.remaining > 0 else { return bucket.resetAt.timeIntervalSince(now) }
            bucket.remaining -= 1
            buckets[key] = bucket
            return nil
        }
        guard let waited else { return nil }
        let bucket = template.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return Self.rateLimited(retryAfter: (waited * 1000).rounded() / 1000, global: false, bucket: String(bucket, radix: 16))
    }

    static func rateLimited(retryAfter: Double, global: Bool, bucket: String) -> HTTPResponse {
        var response = HTTPResponse.json(429, .object(JSONObject([
            ("message", "You are being rate limited."), ("retry_after", .double(retryAfter)), ("global", .bool(global)),
        ])))
        response.headers += [
            ("Retry-After", String(Int(retryAfter.rounded(.up)))),
            ("X-RateLimit-Limit", "5"), ("X-RateLimit-Remaining", "0"),
            ("X-RateLimit-Reset-After", String(format: "%.3f", retryAfter)),
            ("X-RateLimit-Bucket", bucket), ("X-RateLimit-Scope", global ? "global" : "user"),
        ]
        if global { response.headers.append(("X-RateLimit-Global", "true")) }
        return response
    }
}
