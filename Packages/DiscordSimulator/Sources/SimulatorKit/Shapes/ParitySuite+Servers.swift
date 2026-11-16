import Foundation

extension ParityRun {
    /// Invites, the server guide, and applying to, joining and leaving a server that reviews applications.
    mutating func servers(_ target: Targets) async throws {
        let world = simulator.world
        let guilds = await world.guilds.values
        guard let garden = guilds.first(where: { $0.name == "Linden Street Garden" }),
              let club = guilds.first(where: { $0.name == "Riverside Readers" }),
              let action = await world.servers.guides[garden.id]?["new_member_actions"]?.arrayValue?.first?["channel_id"]?.stringValue
        else { throw WorldError.invalidBody("demo has no garden guide or book club") }
        let code = DemoConverter.bookClubInvite

        _ = try await rest("GET", "/api/v9/invites/porchlight?with_counts=true&with_expiration=true&with_permissions=true")
        _ = try await rest("POST", "/api/v9/channels/\(target.channel)/invites",
                           body: ["validate": .null, "max_age": 604_800, "max_uses": 0, "target_type": .null, "temporary": false, "flags": 0])
        for path in ["profile", "new-member-welcome", "new-member-actions", "onboarding"] {
            _ = try await rest("GET", "/api/v9/guilds/\(garden.id)/\(path)")
        }
        _ = try await rest("POST", "/api/v9/guilds/\(garden.id)/new-member-action/\(action)")
        if let role = garden.roles.first(where: { $0.id != garden.id }) {
            _ = try await rest("GET", "/api/v9/guilds/\(garden.id)/roles/\(role.id)/member-ids")
        }

        await flowStart()
        _ = try await rest("GET", "/api/v9/invites/\(code)?with_counts=true&with_expiration=true&with_permissions=true")
        _ = try await rest("POST", "/api/v9/invites/\(code)", body: ["session_id": "parity"])
        let form = try await rest("GET", "/api/v9/guilds/\(club.id)/member-verification?with_guild=true")
        let answers = JSON.array((form["form_fields"]?.arrayValue ?? []).map { field in
            let response: JSON = switch field["field_type"]?.stringValue {
            case "TERMS": true
            case "MULTIPLE_CHOICE": 0
            default: "parity answer"
            }
            return field.merging(["response": response])
        })
        let submitted = try await rest("PUT", "/api/v9/guilds/\(club.id)/requests/@me",
                                       body: .object(JSONObject([("version", form["version"] ?? .null), ("form_fields", answers)])))
        _ = try await rest("GET", "/api/v9/users/@me/join-request-guilds")
        if let id = submitted["id"]?.stringValue { _ = try await rest("GET", "/api/v9/join-requests/\(id)") }
        _ = try await rest("DELETE", "/api/v9/guilds/\(club.id)/requests/@me")
        _ = try await rest("POST", "/api/v9/guilds/\(club.id)/requests/@me")
        _ = try await rest("PUT", "/api/v9/guilds/\(club.id)/requests/@me",
                           body: .object(JSONObject([("version", form["version"] ?? .null), ("form_fields", answers)])))
        guard let me = await world.primaryUserID else { return }
        try await world.reviewJoinRequest(club.id, applicant: me, approve: true, by: club.ownerID, reason: nil)
        await flowEnd(nil)

        await flowStart()
        _ = try await rest("DELETE", "/api/v9/users/@me/guilds/\(club.id)", body: ["lurking": false])
        await flowEnd(nil)
    }
}
