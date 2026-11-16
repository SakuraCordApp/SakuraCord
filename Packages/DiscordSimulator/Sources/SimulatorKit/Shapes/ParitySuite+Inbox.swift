import Foundation

/// Inbox, notification settings, scheduled messages and thread membership, as the official client drives them.
extension ParityRun {
    mutating func inboxAndScheduling(_ target: Targets) async throws {
        _ = try await rest("GET", "/api/v9/users/@me/mentions?limit=25&roles=true&everyone=true")

        await flowStart()
        let channel = target.channel.description
        _ = try await rest("PATCH", "/api/v9/users/@me/guilds/settings", body: .object(JSONObject([("guilds", .object(JSONObject([
            (target.guild.description, .object(JSONObject([("channel_overrides", .object(JSONObject([(channel, ["muted": true])])))]))),
        ])))])))
        await flowEnd(nil)

        let path = "/api/v9/users/@me/scheduled-messages"
        let clock = simulator.world.clock
        let later = { (minutes: Double) in World.timestamp(clock.now.addingTimeInterval(minutes * 60)) }
        await flowStart()
        let scheduled = try await rest("POST", path, body: .object(JSONObject([
            ("channel_id", .string(channel)), ("content", "parity scheduled"), ("scheduled_timestamp", later(60)),
            ("flags", 0), ("attachments", []),
        ])))
        _ = try await rest("GET", path)
        if let id = scheduled["id"]?.stringValue {
            _ = try await rest("PATCH", "\(path)/\(id)", body: .object(JSONObject([("content", "parity rescheduled"), ("scheduled_timestamp", later(90))])))
            _ = try await rest("POST", "\(path)/\(id)/send")
        }
        let cancelled = try await rest("POST", path, body: .object(JSONObject([
            ("channel_id", .string(channel)), ("content", "parity cancelled"), ("scheduled_timestamp", later(60)), ("flags", 0), ("attachments", []),
        ])))
        if let id = cancelled["id"]?.stringValue { _ = try await rest("DELETE", "\(path)/\(id)") }
        await flowEnd(nil)
    }

    /// Mute, leave, rejoin, rename, archive, reopen and delete a thread under the target channel.
    mutating func threadMembership(_ target: Targets) async throws {
        guard let thread = await simulator.world.channels.values.filter({ $0.parentID == target.channel && $0.type.isThread }).map(\.id).max()
        else { throw WorldError.invalidBody("no thread under the target channel") }
        let path = "/api/v9/channels/\(thread)"
        await flowStart()
        _ = try await rest("PATCH", "\(path)/thread-members/@me/settings", body: ["muted": true])
        _ = try await rest("DELETE", "\(path)/thread-members/@me?location=Context%20Menu")
        _ = try await rest("POST", "\(path)/thread-members/@me?location=Banner")
        _ = try await rest("PATCH", path, body: ["name": "parity thread renamed", "type": 11, "locked": false, "invitable": true])
        _ = try await rest("PATCH", path, body: ["archived": true])
        _ = try await rest("PATCH", path, body: ["archived": false])
        _ = try await rest("DELETE", path)
        await flowEnd(nil)
    }
}
