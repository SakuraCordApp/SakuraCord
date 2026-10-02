import Foundation

/// Ephemeral challenge data shared by authentication and explicit server joins.
public struct DiscordCaptchaChallenge: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let siteKey: String
    public let rqdata: String?
    public let rqtoken: String?
    public let sessionID: String?
    public let shouldServeInvisible: Bool

    public init(id: UUID = UUID(), siteKey: String, rqdata: String?, rqtoken: String?, sessionID: String?, shouldServeInvisible: Bool) {
        self.id = id
        self.siteKey = siteKey
        self.rqdata = rqdata
        self.rqtoken = rqtoken
        self.sessionID = sessionID
        self.shouldServeInvisible = shouldServeInvisible
    }

    static func joinChallenge(data: Data, status: Int, method: String, path: String) -> Self? {
        guard status == 400, isJoinRoute(method: method, path: path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.service == "hcaptcha", !payload.key.isEmpty,
              !payload.siteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self(siteKey: payload.siteKey, rqdata: payload.rqdata,
                    rqtoken: payload.rqtoken, sessionID: payload.sessionID,
                    shouldServeInvisible: payload.shouldServeInvisible ?? false)
    }

    /// Explicit server joins: invite acceptance and a discoverable server's full-membership request.
    static func isJoinRoute(method: String, path: String) -> Bool {
        let segments = path.split(separator: "/")
        if method == "POST", segments.count == 2, segments[0] == "invites" { return true }
        return method == "PUT" && segments.count == 4 && segments[0] == "guilds" && UInt64(segments[1]) != nil
            && segments[2] == "members" && segments[3] == "@me"
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
        }

        let key: [String]
        let service: String
        let siteKey: String
        let rqdata: String?
        let rqtoken: String?
        let sessionID: String?
        let shouldServeInvisible: Bool?
    }
}

public typealias DiscordCaptchaHandler = @Sendable (DiscordCaptchaChallenge) async throws -> String
