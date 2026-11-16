import Foundation

/// Helpers shared by scenarios for turning content into world records.
public struct WorldBuilder {
    public let world: World
    public var random: SeededRandom

    public init(world: World, label: String) async {
        self.world = world
        random = SeededRandom(seed: world.seed).fork(label)
    }

    /// A real-shaped user token: base64 user ID, timestamp and signature parts.
    public mutating func token(for id: Snowflake) -> String {
        let idPart = Data(id.description.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let time = String((0 ..< 6).map { _ in alphabet[Int(random.next() % 64)] })
        let signature = String((0 ..< 38).map { _ in alphabet[Int(random.next() % 64)] })
        return "\(idPart).\(time).\(signature)"
    }

    /// A 32-hex asset hash whose first 16 digits are `seed`, so the CDN renders
    /// the content's chosen image for it.
    public mutating func hash(seed: UInt64, animated: Bool = false) -> String {
        let value = String(format: "%016llx%016llx", seed, random.next())
        return animated ? "a_" + value : value
    }

    public func presence(_ status: PresenceStatus, custom: String? = nil, emoji: String? = nil, activity: JSON? = nil) -> Presence {
        var presence = Presence(status: status)
        if custom != nil || emoji != nil {
            var object = JSONObject([("type", 4), ("state", .optional(custom)), ("name", "Custom Status"), ("id", "custom")])
            if let emoji { object["emoji"] = .object(JSONObject([("name", .string(emoji))])) }
            presence.activities.append(.object(object))
        }
        if let activity { presence.activities.append(activity) }
        return presence
    }

    public static func activity(type: Int, name: String, details: String? = nil, state: String? = nil, start: Date) -> JSON {
        var object = JSONObject([("type", .int(type)), ("name", .string(name)), ("id", .string(String(name.hashValueStable, radix: 16))),
                                 ("created_at", .int(Int64(start.timeIntervalSince1970 * 1000))),
                                 ("timestamps", .object(JSONObject([("start", .int(Int64(start.timeIntervalSince1970 * 1000)))])))])
        if let details { object["details"] = .string(details) }
        if let state { object["state"] = .string(state) }
        return .object(object)
    }

    /// The @everyone role, created with the guild's ID as Discord does.
    public static func everyoneRole(guildID: Snowflake) -> Role {
        Role(id: guildID, name: "@everyone", permissions: .everyoneDefault)
    }
}

extension String {
    /// FNV-1a, stable across runs (Swift's `hashValue` is seeded per process).
    var hashValueStable: UInt64 {
        utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }
}
