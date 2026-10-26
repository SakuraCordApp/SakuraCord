@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

/// Discord can challenge any route, so opening a DM with someone new must not
/// dead-end in a generic error.
struct CaptchaReplayContractTests {
    private let fixture = CaptchaReplayFixture()

    @Test(arguments: [false, true])
    func `a challenge on any route is solved once and replays the identical request once`(challengesReplay: Bool) async throws {
        fixture.challengesReplay.withLock { $0 = challengesReplay }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptchaReplayURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: fixture, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let provider = DiscordRESTProvider(credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "captcha"), session: session)
        let fixture = fixture
        // Installed as the app does, through the provider interface.
        await (provider as any ChatProvider).setCaptchaHandler { challenge in
            #expect(challenge.siteKey == "site-key")
            fixture.presentations.withLock { $0 += 1 }
            return "human-solution"
        }
        let userID = UserID(rawValue: 2)
        if challengesReplay {
            await #expect(throws: ChatProviderError.invalidRequest("Couldn’t complete the security check.")) {
                try await provider.ensurePrivateChannel(for: userID)
            }
        } else {
            #expect(try await provider.ensurePrivateChannel(for: userID).id == ChannelID(rawValue: 41))
        }
        #expect(fixture.presentations.withLock { $0 } == 1)
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.count == 2)
        let original = requests[0], replay = requests[1]
        #expect(original.request.httpMethod == "POST" && replay.request.httpMethod == "POST")
        #expect(original.request.url == replay.request.url)
        #expect(original.request.url?.path == "/api/v9/users/@me/channels")
        #expect(original.body == replay.body)
        #expect(original.request.value(forHTTPHeaderField: "X-Captcha-Key") == nil)
        #expect(replay.request.value(forHTTPHeaderField: "X-Captcha-Key") == "human-solution")
        #expect(replay.request.value(forHTTPHeaderField: "X-Captcha-Rqtoken") == "request-token")
        #expect(replay.request.value(forHTTPHeaderField: "X-Captcha-Session-Id") == "captcha-session")
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }
}

private final class CaptchaReplayFixture: NSObject, URLSessionTaskDelegate {
    struct Captured: Sendable {
        let request: URLRequest
        let body: Data
    }

    let requests = Mutex<[Captured]>([])
    let challengesReplay = Mutex(false)
    let presentations = Mutex(0)

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        task.delegate = self
    }
}

private final class CaptchaReplayURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with task: URLSessionTask) -> Bool { true }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = task?.delegate as? CaptchaReplayFixture else {
            Issue.record("CAPTCHA transport is missing its test-owned fixture")
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        fixture.requests.withLock { $0.append(.init(request: request, body: body)) }
        let solved = request.value(forHTTPHeaderField: "X-Captcha-Key") != nil
        let challenged = !solved || fixture.challengesReplay.withLock { $0 }
        let response = challenged ? """
            {"captcha_key":["captcha-required"],"captcha_service":"hcaptcha","captcha_sitekey":"site-key",
             "captcha_rqtoken":"request-token","captcha_session_id":"captcha-session"}
            """ : #"{"id":"41","type":1,"recipients":[{"id":"2","username":"known"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: challenged ? 400 : 200, httpVersion: "HTTP/1.1",
                                                             headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
