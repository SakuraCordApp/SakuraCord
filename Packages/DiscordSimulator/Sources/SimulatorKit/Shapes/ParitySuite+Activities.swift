import Foundation

/// Activities: the shelf, an application's details and disclosures, a proxy
/// ticket and the page served for it, launching through the entry-point
/// command, joining through the channel, and leaving, with the events captured.
extension ParityRun {
    mutating func activities(_ target: Targets) async throws {
        let shelf = try await rest("GET", "/api/v9/activities/shelf?guild_id=\(target.guild)")
        guard let appID = shelf["applications"]?.arrayValue?.first?["id"]?.stringValue else {
            throw WorldError.invalidBody("the shelf lists no Activity")
        }
        _ = try await rest("GET", "/api/v9/applications/\(appID)/public?with_guild=false")
        _ = try await rest("GET", "/api/v9/applications/\(appID)/disclosures")
        _ = try await rest("POST", "/api/v9/applications/\(appID)/disclosures", body: ["disclosures": [1]])
        let ticket = try await rest("POST", "/api/v9/applications/\(appID)/proxy-tickets",
                                    body: ["use_stateless_ticket": true, "channel_id": .string(target.channel.description)])
        await checkActivityPage(ticket: ticket["ticket"]?.stringValue ?? "", appID: appID)

        await flowStart()
        _ = try await rest("POST", "/api/v9/interactions", body: .object(JSONObject([
            ("type", 2), ("application_id", .string(appID)), ("guild_id", .string(target.guild.description)),
            ("channel_id", .string(target.channel.description)), ("session_id", "parity"), ("nonce", .string(nonce())),
            ("data", .object(JSONObject([("type", 4), ("name", "launch"), ("options", []), ("attachments", [])]))),
            ("analytics_location", "app_launcher"), ("source", "TEXT"),
        ])))
        let launched = await voiceFlow("activity-launch", expecting: ["INTERACTION_CREATE", "INTERACTION_SUCCESS", "EMBEDDED_ACTIVITY_UPDATE_V2"])
        guard let instance = launched.last(where: { $0.name == "EMBEDDED_ACTIVITY_UPDATE_V2" })?.payload["d"],
              let location = instance["location"]?["id"]?.stringValue, let instanceID = instance["instance_id"]?.stringValue
        else { return }
        let leavePath = "/api/v9/applications/\(appID)/activities/\(location)/instances/\(instanceID)/leave"
        await flowStart()
        _ = try await rest("POST", leavePath, body: ["session_id": "parity"])
        await voiceFlow("activity-end", expecting: ["EMBEDDED_ACTIVITY_UPDATE_V2", "EMBEDDED_ACTIVITY_UPDATE_V2"])

        await flowStart()
        _ = try await rest("POST", "/api/v9/activities/\(target.channel)/\(appID)", body: ["session_id": "parity"])
        let joined = await voiceFlow("activity-join", expecting: ["EMBEDDED_ACTIVITY_UPDATE_V2"])
        if let rejoined = joined.last?.payload["d"]?["instance_id"]?.stringValue {
            await flowStart()
            _ = try await rest("POST", "/api/v9/applications/\(appID)/activities/\(location)/instances/\(rejoined)/leave", body: ["session_id": "parity"])
            await voiceFlow("activity-end", expecting: ["EMBEDDED_ACTIVITY_UPDATE_V2", "EMBEDDED_ACTIVITY_UPDATE_V2"])
        }
    }

    /// The `{id}.discordsays.com` page for a ticket: the Activity's HTML naming its client ID, and its backend.
    private mutating func checkActivityPage(ticket: String, appID: String) async {
        let base = "http://127.0.0.1:\(simulator.port(.activity))"
        report.checked.append("ACTIVITY page")
        guard let pageURL = URL(string: "\(base)/?frame_id=parity&instance_id=parity&discord_proxy_ticket=\(ticket)"),
              let countURL = URL(string: "\(base)/.proxy/api/count?instance=parity"),
              let (page, _) = try? await session.data(from: pageURL), String(bytes: page, encoding: .utf8)?.contains(appID) == true
        else {
            report.sequenceFailures.append("activity: the page for a proxy ticket doesn't load")
            return
        }
        var request = URLRequest(url: countURL)
        request.httpMethod = "POST"
        let count = (try? await session.data(for: request)).flatMap { try? JSON.parse($0.0) }?["count"]?.intValue
        if count != 1 { report.sequenceFailures.append("activity: the backend count didn't go up") }
    }
}
