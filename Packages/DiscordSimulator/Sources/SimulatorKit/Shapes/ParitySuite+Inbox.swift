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

    /// The client reserves an upload slot, then discards it unsent; the slot must be gone afterwards.
    mutating func discardedUpload(_ target: Targets) async throws {
        let slots = try await rest("POST", "/api/v9/channels/\(target.channel)/attachments",
                                   body: ["files": [["filename": "discarded.png", "file_size": 70, "id": "0", "is_clip": false]]])
        guard let name = slots["attachments"]?.arrayValue?.first?["upload_filename"]?.stringValue else { return }
        _ = try await rest("DELETE", "/api/v9/attachments/\(name.replacingOccurrences(of: "/", with: "%2F"))")
        if await simulator.world.pendingUploads[name] != nil { report.sequenceFailures.append("discarded upload \(name) is still reserved") }
    }

    /// Mute, leave, rejoin, rename and archive a thread; a reply reopens it (captured); then delete it.
    mutating func threadMembership(_ target: Targets) async throws {
        guard let thread = await simulator.world.channels.values.filter({ $0.parentID == target.channel && $0.type.isThread }).map(\.id).max()
        else { throw WorldError.invalidBody("no thread under the target channel") }
        let path = "/api/v9/channels/\(thread)"
        await flowStart()
        try await gateway?.send(.object(JSONObject([("op", 37), ("d", .object(JSONObject([("subscriptions", .object(JSONObject([
            (target.guild.description, .object(JSONObject([("thread_member_lists", [.string(thread.description)])]))),
        ])))])))])))
        _ = try await rest("PATCH", "\(path)/thread-members/@me/settings", body: ["muted": true])
        _ = try await rest("DELETE", "\(path)/thread-members/@me?location=Context%20Menu")
        _ = try await rest("POST", "\(path)/thread-members/@me?location=Banner")
        _ = try await rest("PATCH", path, body: ["name": "parity thread renamed", "type": 11, "locked": false, "invitable": true])
        _ = try await rest("PATCH", path, body: ["archived": true])
        _ = try await postMessage(in: thread, "parity reopen")
        if await simulator.world.channels[thread]?.thread?.archived != false { report.sequenceFailures.append("a reply did not reopen the archived thread") }
        _ = try await rest("DELETE", path)
        await flowEnd(nil)
    }

    /// Editing a reply keeps or drops its ping on the replied-to author as `allowed_mentions.replied_user` says.
    mutating func editedReplyMentions(_ target: Targets) async throws {
        let path = "/api/v9/channels/\(target.channel)/messages"
        let original = try await simulator.world.sendMessage(MessageDraft(content: "parity original"), as: target.otherUser, in: target.channel,
                                                             checkPermissions: false)
        let reply = try await postMessage(in: target.channel, "parity reply", [
            ("message_reference", .object(JSONObject([("channel_id", .string(target.channel.description)), ("message_id", original.id.json)]))),
        ])
        guard let replyID = reply["id"]?.stringValue else { return }
        for pings in [false, true] {
            let edited = try await rest("PATCH", "\(path)/\(replyID)", body: .object(JSONObject([
                ("content", "parity reply edited"),
                ("allowed_mentions", .object(JSONObject([("parse", ["users", "roles", "everyone"]), ("replied_user", .bool(pings))]))),
            ])))
            let mentioned = edited["mentions"]?.arrayValue?.contains { $0["id"]?.stringValue == target.otherUser.description } ?? false
            if mentioned != pings { report.sequenceFailures.append("edited reply ping is \(mentioned), replied_user was \(pings)") }
        }
    }
}
