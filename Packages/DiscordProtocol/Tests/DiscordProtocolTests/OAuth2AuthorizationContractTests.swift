import Foundation
import Testing
import SakuraCordModels
@testable import DiscordProtocol

struct OAuth2AuthorizationContractTests {
    private static let redirect = URL(string: "https://sakuracord.app/report/callback")!

    @Test func `authorization reads consent details then authorizes once without following the redirect`() async throws {
        let capture = RequestRecorder(OAuth2URLProtocol.captured)
        let provider = stubbedProvider(OAuth2URLProtocol.self, token: capture.id, accountID: capture.id)
        let grant = try await provider.authorizeOAuth2(.init(
            clientID: "1530180517155176458", scopes: ["identify"], redirectURI: Self.redirect, state: "granted"
        ))
        #expect(grant == .init(code: "one-time-code", applicationName: "SakuraCord"))
        let requests = capture.requests
        #expect(requests.map(\.method) == ["GET", "POST"])
        #expect(requests.allSatisfy { $0.path == "/api/v9/oauth2/authorize" })
        for request in requests {
            #expect(request.queryItems == [
                URLQueryItem(name: "client_id", value: "1530180517155176458"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: Self.redirect.absoluteString),
                URLQueryItem(name: "scope", value: "identify"),
                URLQueryItem(name: "state", value: "granted"),
            ])
        }
        #expect(requests[0].httpBody?.isEmpty ?? true)
        let body = try #require(requests[1].jsonBody)
        #expect(body["authorize"] as? Bool == true)
        #expect(Set(body.keys) == ["authorize", "location_context"])
        let location = try #require(body["location_context"] as? [String: Any])
        #expect(location["guild_id"] as? String == "10000")
        #expect(location["channel_id"] as? String == "10000")
        #expect(location["channel_type"] as? Int == 10_000)
        await provider.disconnect()
    }

    @Test(arguments: ["rejected", "foreign", "denied", "forged"])
    func `rejected or mismatched authorizations never produce a code or a second write`(state: String) async throws {
        let capture = RequestRecorder(OAuth2URLProtocol.captured)
        let provider = stubbedProvider(OAuth2URLProtocol.self, token: capture.id, accountID: capture.id)
        await #expect(throws: OAuth2AuthorizationError.self) {
            _ = try await provider.authorizeOAuth2(.init(
                clientID: "1530180517155176458", scopes: ["identify"], redirectURI: Self.redirect, state: state
            ))
        }
        let writes = capture.requests.filter { $0.method == "POST" }
        #expect(writes.count == (state == "rejected" || state == "foreign" ? 0 : 1))
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }
}

private final class OAuth2URLProtocol: URLProtocol, @unchecked Sendable {
    static let captured = Notification.Name("OAuth2ContractCapturedRequest")

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.bodyData ?? Data()
        var capturedRequest = request
        capturedRequest.httpBody = body
        NotificationCenter.default.post(name: Self.captured, object: capturedRequest)

        let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        let callback = "https://sakuracord.app/report/callback"
        let (status, json): (Int, String) = switch (request.httpMethod, state) {
        case ("GET", "rejected"):
            (400, #"{"code":50035,"message":"Invalid Form Body"}"#)
        case ("GET", "foreign"):
            (200, #"{"application":{"id":"1","name":"Other"},"authorized":false}"#)
        case ("GET", _):
            (200, #"{"application":{"id":"1530180517155176458","name":"SakuraCord"},"authorized":true}"#)
        case (_, "denied"):
            (200, #"{"location":"\#(callback)?error=access_denied&state=denied"}"#)
        case (_, "forged"):
            (200, #"{"location":"https://example.com/report/callback?code=stolen&state=forged"}"#)
        default:
            (200, #"{"location":"\#(callback)?code=one-time-code&state=\#(state)"}"#)
        }
        respond(status: status, body: Data(json.utf8))
    }

    override func stopLoading() {}
}
