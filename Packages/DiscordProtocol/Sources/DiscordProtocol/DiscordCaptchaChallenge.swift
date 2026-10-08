import Foundation

/// Ephemeral challenge data shared by authentication, explicit server joins
/// and friend requests. Never logged or persisted.
public struct DiscordCaptchaChallenge: Equatable, Identifiable, Sendable {
    // Official stable633029 module645320 service dispatch.
    public enum Service: String, Sendable {
        case hcaptcha
        case recaptcha
        case recaptchaEnterprise = "recaptcha_enterprise"
        case turnstile
    }

    public let id: UUID
    public let service: Service
    public let siteKey: String
    public let rqdata: String?
    /// Binds the replay to the original request; not the widget's response.
    public let rqtoken: String?
    public let sessionID: String?
    public let shouldServeInvisible: Bool
    /// The reCAPTCHA Enterprise action.
    public let userFlow: String?

    public init(
        id: UUID = UUID(), service: Service = .hcaptcha, siteKey: String, rqdata: String?, rqtoken: String?,
        sessionID: String?, shouldServeInvisible: Bool, userFlow: String? = nil
    ) {
        self.id = id
        self.service = service
        self.siteKey = siteKey
        self.rqdata = rqdata
        self.rqtoken = rqtoken
        self.sessionID = sessionID
        self.shouldServeInvisible = shouldServeInvisible
        self.userFlow = userFlow
    }

    /// A supported challenge on a route with an explicit human-completion
    /// path. Unknown services and other routes keep the safety boundary.
    static func routeChallenge(data: Data, status: Int, method: String, path: String) -> Self? {
        guard status == 400, isJoinRoute(method: method, path: path) || isRelationshipRequestRoute(method: method, path: path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let service = Service(rawValue: payload.service), !payload.key.isEmpty,
              !payload.siteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self(service: service, siteKey: payload.siteKey, rqdata: payload.rqdata,
                    rqtoken: payload.rqtoken, sessionID: payload.sessionID,
                    shouldServeInvisible: payload.shouldServeInvisible ?? false, userFlow: payload.userFlow)
    }

    /// Explicit server joins: invite acceptance and a discoverable server's full-membership request.
    static func isJoinRoute(method: String, path: String) -> Bool {
        let segments = path.split(separator: "/")
        if method == "POST", segments.count == 2, segments[0] == "invites" { return true }
        return method == "PUT" && segments.count == 4 && segments[0] == "guilds" && UInt64(segments[1]) != nil
            && segments[2] == "members" && segments[3] == "@me"
    }

    /// Sending a request by username, or accepting or blocking one user.
    static func isRelationshipRequestRoute(method: String, path: String) -> Bool {
        let segments = path.split(separator: "/")
        guard segments.count >= 3, segments[0] == "users", segments[1] == "@me", segments[2] == "relationships" else { return false }
        if segments.count == 3 { return method == "POST" }
        return segments.count == 4 && method == "PUT" && UInt64(segments[3]) != nil
    }

    private struct Payload: Decodable {
        enum CodingKeys: String, CodingKey {
            case key = "captcha_key"
            case service = "captcha_service"
            case siteKey = "captcha_sitekey"
            case rqdata = "captcha_rqdata"
            case rqtoken = "captcha_rqtoken"
            case sessionID = "captcha_session_id"
            case shouldServeInvisible = "should_serve_invisible"
            case userFlow = "user_flow"
        }

        let key: [String]
        let service: String
        let siteKey: String
        let rqdata: String?
        let rqtoken: String?
        let sessionID: String?
        let shouldServeInvisible: Bool?
        let userFlow: String?
    }
}

public typealias DiscordCaptchaHandler = @Sendable (DiscordCaptchaChallenge) async throws -> String

/// Why a challenged request ended without a completed replay.
enum CaptchaReplayFailure: Error {
    case handlerUnavailable, emptySolution, rejected

    var message: String {
        switch self {
        case .handlerUnavailable: "Discord requires a CAPTCHA for this action. Try again in Discord."
        case .emptySolution: "CAPTCHA verification did not return a solution. Try again."
        case .rejected: "Discord did not accept the CAPTCHA. Try again to get a new challenge."
        }
    }
}

extension DiscordRESTProvider {
    /// Performs one mutation. A supported challenge is solved by a human once
    /// and the identical request, with its original context, replayed once
    /// with the solution headers. A second challenge ends the attempt.
    func performChallengeable(
        _ path: String, method: String, query: [URLQueryItem], body: [String: JSONValue]?,
        headers: [String: String], captchaHandler: DiscordCaptchaHandler?,
        replayIsCurrent: () async -> Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let original = try await perform(path, method: method, query: query, body: body, headers: headers, maximumAttempts: 1)
        guard let challenge = DiscordCaptchaChallenge.routeChallenge(
            data: original.0, status: original.1.statusCode, method: method, path: path
        ) else { return original }
        guard let captchaHandler else { throw CaptchaReplayFailure.handlerUnavailable }
        try Task.checkCancellation()
        let token = try await captchaHandler(challenge)
        try Task.checkCancellation()
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptchaReplayFailure.emptySolution }
        // Never replay a solution against another account or session.
        guard !requestSafetyCircuitIsOpen, await replayIsCurrent() else { throw CancellationError() }
        var headers = headers
        headers["X-Captcha-Key"] = token
        headers["X-Captcha-Rqtoken"] = challenge.rqtoken
        headers["X-Captcha-Session-Id"] = challenge.sessionID
        let completed = try await perform(path, method: method, query: query, body: body, headers: headers, maximumAttempts: 1)
        if DiscordCaptchaChallenge.routeChallenge(
            data: completed.0, status: completed.1.statusCode, method: method, path: path
        ) != nil { throw CaptchaReplayFailure.rejected }
        return completed
    }
}
