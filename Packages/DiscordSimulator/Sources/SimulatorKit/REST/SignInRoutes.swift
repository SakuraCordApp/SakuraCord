import Foundation

/// Two-factor sign-in and the QR ticket exchange. The official client can't be
/// captured signing in without the account owner, so these follow Discord's
/// documented responses, like `POST /auth/login`.
enum SignInRoutes {
    static let unauthenticated: Set<String> = [
        "POST /api/v9/auth/mfa/totp", "POST /api/v9/auth/mfa/backup", "POST /api/v9/auth/mfa/sms",
        "POST /api/v9/auth/mfa/sms/send", "POST /api/v9/users/@me/remote-auth/login",
    ]

    static func register(into routes: inout [String: RouteHandler], remoteAuth: RemoteAuthGateway) {
        for method in ["totp", "backup", "sms"] {
            routes["POST /api/v9/auth/mfa/\(method)"] = { context in
                let body = try context.json
                return .json(try await context.world.completeMFA(ticket: body["ticket"]?.stringValue ?? "",
                                                                 code: body["code"]?.stringValue ?? "", method: method))
            }
        }
        routes["POST /api/v9/auth/mfa/sms/send"] = { context in
            .json(try await context.world.sendMFASMS(ticket: try context.json["ticket"]?.stringValue ?? ""))
        }
        routes["POST /api/v9/users/@me/remote-auth/login"] = { context in
            .json(try await remoteAuth.exchange(ticket: try context.json["ticket"]?.stringValue ?? ""))
        }
    }
}

/// Two-factor state for sign-in. Codes are simulator-local secrets, like passwords.
public struct SignInState: Sendable {
    /// The six-digit authenticator code each two-factor account accepts.
    public var authenticatorCodes: [Snowflake: String] = [:]
    public var backupCodes: [Snowflake: Set<String>] = [:]
    /// Phone numbers for SMS codes; an account without one can't use SMS.
    public var phones: [Snowflake: String] = [:]
    /// Login tickets awaiting a second factor.
    var tickets: [String: Snowflake] = [:]
}

extension World {
    /// The `POST /auth/login` answer for a two-factor account: a ticket instead of a token.
    func mfaChallenge(for userID: Snowflake) -> JSON {
        let ticket = "\(nextID()).\(random.urlSafeString(64))"
        signIn.tickets[ticket] = userID
        return .object(JSONObject([
            ("user_id", userID.json), ("mfa", true), ("sms", .bool(signIn.phones[userID] != nil)), ("ticket", .string(ticket)),
            ("backup", .bool(!(signIn.backupCodes[userID] ?? []).isEmpty)), ("totp", true), ("webauthn", .null),
            ("login_instance_id", .string(nextID().description)),
        ]))
    }

    private func mfaUser(ticket: String) throws -> Snowflake {
        guard let userID = signIn.tickets[ticket] else { throw WorldError(status: 401, code: 0, message: "Invalid two-factor auth ticket") }
        return userID
    }

    func completeMFA(ticket: String, code: String, method: String) throws -> JSON {
        let userID = try mfaUser(ticket: ticket)
        let digits = code.filter { !$0.isWhitespace && $0 != "-" }
        let accepted = switch method {
        case "backup": signIn.backupCodes[userID]?.remove(digits.lowercased()) != nil
        case "sms": signIn.phones[userID] != nil && digits == signIn.authenticatorCodes[userID]
        default: digits == signIn.authenticatorCodes[userID]
        }
        guard accepted else { throw WorldError(status: 400, code: 60008, message: "Invalid two-factor code") }
        signIn.tickets[ticket] = nil
        return try signedIn(userID)
    }

    /// The token answer that ends a sign-in, after the password or the second factor.
    func signedIn(_ userID: Snowflake) throws -> JSON {
        guard let token = tokens.first(where: { $0.value == userID })?.key else { throw WorldError.unauthorized }
        return .object(JSONObject([
            ("user_id", userID.json), ("token", .string(token)),
            ("user_settings", .object(JSONObject([("locale", "en-US"), ("theme", "dark")]))),
        ]))
    }

    /// Sends the code by SMS; the response masks the phone number.
    func sendMFASMS(ticket: String) throws -> JSON {
        let userID = try mfaUser(ticket: ticket)
        guard let phone = signIn.phones[userID] else { throw WorldError.invalidBody("ticket: SMS is not enabled for this account") }
        return .object(JSONObject([("phone", .string(String(repeating: "*", count: max(0, phone.count - 4)) + phone.suffix(4)))]))
    }
}
