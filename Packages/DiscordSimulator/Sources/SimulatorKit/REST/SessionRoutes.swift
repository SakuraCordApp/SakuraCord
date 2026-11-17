import Foundation

/// Settings → Devices: the account's signed-in sessions.
enum SessionRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/auth/sessions"] = { context in
            .json(.object(JSONObject([("user_sessions", .array(await context.world.authSessions(for: context.userID)))])))
        }
    }
}

extension World {
    /// The desktop client signed in now, and a phone used yesterday.
    func authSessions(for userID: Snowflake) -> [JSON] {
        let devices: [(client: JSON, lastUsed: Date)] = [
            (["os": "Mac OS X", "platform": "Discord Client"], clock.now),
            (["os": "iOS", "platform": "Discord iOS"], clock.now.addingTimeInterval(-26 * 3600)),
        ]
        return devices.enumerated().map { index, device in
            .object(JSONObject([
                ("id_hash", .string(String(format: "%016llx%016llx", userID.rawValue &* 0x9e37_79b9_7f4a_7c15, (userID.rawValue ^ UInt64(index + 1)) &* 0xbf58_476d_1ce4_e5b9))),
                ("approx_last_used_time", World.timestamp(device.lastUsed)),
                ("client_info", device.client.merging(["location": "Amsterdam, North Holland, Netherlands"])),
            ]))
        }
    }
}
