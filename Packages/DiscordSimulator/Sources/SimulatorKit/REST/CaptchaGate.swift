import Foundation
import Synchronization

/// Captcha challenges armed through the control API. An armed route answers
/// with Discord's captcha-required body until the client retries with a
/// solved token. The challenge uses hCaptcha's published test site key, whose
/// widget passes without a puzzle and yields the published test token, so the
/// app's captcha web view can finish offline from Discord.
public final class CaptchaGate: Sendable {
    public static let testSiteKey = "10000000-ffff-ffff-ffff-000000000001"
    public static let testToken = "10000000-aaaa-bbbb-cccc-000000000001"

    private struct Challenge { var route: String; var remaining: Int; var rqtoken: String; var sessionID: String }

    private struct State {
        var challenges: [Challenge] = []
        var random = SeededRandom(seed: 0).fork("captcha")
    }

    private let state = Mutex(State())

    /// Arms `route` (a substring of the route template) for `count` solved captchas.
    public func arm(route: String, count: Int) {
        state.withLock { state in
            let challenge = Challenge(route: route, remaining: count, rqtoken: state.random.urlSafeString(64), sessionID: state.random.urlSafeString(36))
            state.challenges.append(challenge)
        }
    }

    public func clear() { state.withLock { $0.challenges.removeAll() } }

    /// The 400 to answer with, or nil when the route isn't armed or the retry carries a solved captcha.
    func check(template: String, request: HTTPRequest) -> HTTPResponse? {
        state.withLock { state in
            guard let index = state.challenges.firstIndex(where: { template.contains($0.route) }) else { return nil }
            let challenge = state.challenges[index]
            let key = request.header("X-Captcha-Key")
            if key == Self.testToken, request.header("X-Captcha-Rqtoken") == challenge.rqtoken {
                state.challenges[index].remaining -= 1
                if state.challenges[index].remaining <= 0 { state.challenges.remove(at: index) }
                return nil
            }
            return .json(400, .object(JSONObject([
                ("captcha_key", [key == nil ? "captcha-required" : "invalid-response"]),
                ("captcha_sitekey", .string(Self.testSiteKey)), ("captcha_service", "hcaptcha"),
                ("captcha_session_id", .string(challenge.sessionID)), ("captcha_rqdata", .string(state.random.urlSafeString(128))),
                ("captcha_rqtoken", .string(challenge.rqtoken)),
            ])))
        }
    }
}
