import Foundation

/// Agent controls for the other side of server and sign-in flows: the phone
/// approving a QR sign-in, a moderator reviewing an application, two-factor setup.
extension ControlAPI {
    func serverRoute(_ request: HTTPRequest, _ route: [String], _ body: JSON) async throws -> HTTPResponse? {
        switch (request.method, route.first ?? "", route.count) {
        case ("GET", "remote-auth", _):
            return ok(["waiting": .array(await simulator.hub.remoteAuth.waitingFingerprints.map(JSON.string))])
        case ("POST", "remote-auth", _):
            // `action`: scan (shows the account on the QR screen), approve, or cancel.
            let action = body["action"]?.stringValue ?? "approve"
            guard ["scan", "approve", "cancel"].contains(action) else { throw WorldError.invalidBody("action must be scan, approve or cancel") }
            try await simulator.hub.remoteAuth.phone(fingerprint: body["fingerprint"]?.stringValue, userID: try await resolveUser(body["user"]),
                                                     approve: action == "scan" ? nil : action == "approve")
            return ok([:])
        case ("POST", "join-requests", _):
            let guildID = try await self.guild(body)
            let guild = try await world.guild(guildID)
            let action = body["action"]?.stringValue ?? "approve"
            guard action == "approve" || action == "reject" else { throw WorldError.invalidBody("action must be approve or reject") }
            let moderator = try await body["moderator"].asyncMap { try await resolveUser($0) } ?? guild.ownerID
            try await world.reviewJoinRequest(guildID, applicant: try await resolveUser(body["user"]), approve: action == "approve",
                                              by: moderator, reason: body["reason"]?.stringValue)
            return ok([:])
        case ("POST", "captcha", _):
            // Arms `route` (a route template substring, e.g. "POST /api/v9/auth/login") for `count` captchas.
            simulator.router.captcha.arm(route: body["route"]?.stringValue ?? "", count: Int(body["count"]?.intValue ?? 1))
            return ok(["site_key": .string(CaptchaGate.testSiteKey)])
        case ("DELETE", "captcha", _):
            simulator.router.captcha.clear()
            return ok([:])
        case ("PUT", "users", 3) where route[2] == "mfa":
            let userID = try await resolveUser(.string(route[1]))
            try await world.configureMFA(userID, code: body["authenticator_code"]?.stringValue,
                                         backupCodes: (body["backup_codes"]?.arrayValue ?? []).compactMap(\.stringValue),
                                         phone: body["phone"]?.stringValue)
            return ok([:])
        default:
            return nil
        }
    }
}

extension World {
    /// Turns two-factor sign-in on with `code` (six digits), or off when nil.
    func configureMFA(_ userID: Snowflake, code: String?, backupCodes: [String], phone: String?) throws {
        _ = try user(userID)
        if let code, code.count != 6 || !code.allSatisfy(\.isNumber) { throw WorldError.invalidBody("authenticator_code must be six digits") }
        signIn.authenticatorCodes[userID] = code
        signIn.backupCodes[userID] = code == nil ? nil : Set(backupCodes.map { $0.lowercased() })
        signIn.phones[userID] = code == nil ? nil : phone
    }
}
