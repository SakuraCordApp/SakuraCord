import Foundation
import Synchronization
import Testing
import SakuraCordModels
@testable import DiscordProtocol

/// An Activity acts through the account: these guard the one consent write it
/// may cause and keep its own OAuth token's rejection from ending the session.
struct EmbeddedActivityContractTests {
    private static let location = EmbeddedActivityLocation(
        id: "gc-100000000000000001-100000000000000002",
        channelID: ChannelID("100000000000000002")!,
        guildID: GuildID("100000000000000001")
    )

    @Test func `authorization reads the grant then authorizes once in the voice channel`() async throws {
        let accountID = UUID().uuidString
        let recorder = ActivityRequestRecorder(authorization: accountID)
        let provider = makeProvider(accountID)
        let request = authorization(state: "granted")
        #expect(try await provider.embeddedActivityAuthorizationPreview(request).isAuthorized)
        #expect(try await provider.authorizeEmbeddedActivity(request, granted: true) == "one-time-code")
        let requests = recorder.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /api/v9/applications/880218394199220334/disclosures", "GET /api/v9/oauth2/authorize",
            "POST /api/v9/oauth2/authorize",
        ])
        let previewQuery = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(previewQuery.contains(URLQueryItem(name: "integration_type", value: "1")))
        #expect(previewQuery.contains(URLQueryItem(name: "scope", value: "identify guilds")))
        let body = try #require(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        #expect(body["authorize"] as? Bool == true)
        #expect(body["integration_type"] as? Int == 1)
        let context = try #require(body["location_context"] as? [String: Any])
        #expect(context["guild_id"] as? String == "100000000000000001")
        #expect(context["channel_id"] as? String == "100000000000000002")
        #expect(context["channel_type"] as? Int == 2)
        await provider.disconnect()
    }

    @Test func `a refused consent is recorded once and yields no code`() async throws {
        let accountID = UUID().uuidString
        let recorder = ActivityRequestRecorder(authorization: accountID)
        let provider = makeProvider(accountID)
        await #expect(throws: OAuth2AuthorizationError.self) {
            _ = try await provider.authorizeEmbeddedActivity(authorization(state: "refused"), granted: false)
        }
        let requests = recorder.requests
        #expect(requests.map(\.httpMethod) == ["POST"])
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        #expect(body["authorize"] as? Bool == false)
        #expect(body["permissions"] as? String == "0")
        await provider.disconnect()
    }

    @Test func `a forged authorization state yields no code`() async throws {
        let provider = makeProvider(UUID().uuidString)
        await #expect(throws: OAuth2AuthorizationError.self) {
            _ = try await provider.authorizeEmbeddedActivity(authorization(state: "forged"), granted: true)
        }
        await provider.disconnect()
    }

    @Test func `a rejected Activity token leaves the account session running`() async throws {
        let token = UUID().uuidString
        let recorder = ActivityRequestRecorder(authorization: "Bearer \(token)")
        let provider = makeProvider(UUID().uuidString)
        await #expect(throws: OAuth2AuthorizationError.self) {
            _ = try await provider.authenticateEmbeddedActivity(ApplicationID("880218394199220334")!, accessToken: token)
        }
        #expect(recorder.requests.count == 1)
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }

    private func authorization(state: String) -> EmbeddedActivityAuthorizationRequest {
        .init(applicationID: ApplicationID("880218394199220334")!, scopes: ["identify", "guilds"], state: state,
              location: Self.location, channelType: 2)
    }

    private func makeProvider(_ accountID: String) -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityURLProtocol.self]
        return DiscordRESTProvider(
            credentials: ActivityCredentialStore(), handle: .init(accountID: accountID),
            session: URLSession(configuration: configuration)
        )
    }
}

private actor ActivityCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle { .init(accountID: accountID) }
    func credential(for handle: CredentialHandle) async throws -> Data { Data(handle.accountID.utf8) }
    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

/// Collects the requests one test sends, told apart by their Authorization header.
private final class ActivityRequestRecorder {
    private final class Storage: Sendable { let requests = Mutex<[URLRequest]>([]) }
    private let storage = Storage()
    private var observer: (any NSObjectProtocol)?

    init(authorization: String) {
        let storage = storage
        observer = NotificationCenter.default.addObserver(forName: ActivityURLProtocol.captured, object: nil, queue: nil) { notification in
            guard let request = notification.object as? URLRequest,
                  request.value(forHTTPHeaderField: "Authorization") == authorization else { return }
            storage.requests.withLock { $0.append(request) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var requests: [URLRequest] { storage.requests.withLock { $0 } }
}

private final class ActivityURLProtocol: URLProtocol, @unchecked Sendable {
    static let captured = Notification.Name("EmbeddedActivityContractRequest")

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
        var capturedRequest = request
        capturedRequest.httpBody = body
        NotificationCenter.default.post(name: Self.captured, object: capturedRequest)

        let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        let (status, json): (Int, String) = switch (request.url!.path, request.httpMethod, state) {
        case (let path, "GET", _) where path.hasSuffix("/disclosures"):
            (200, #"{"disclosures":[],"acked_disclosures":[],"all_acked":true}"#)
        case ("/api/v9/oauth2/@me", _, _):
            (401, #"{"code":0,"message":"401: Unauthorized"}"#)
        case (_, "GET", _):
            (200, #"{"application":{"id":"880218394199220334","name":"Watch Together"},"authorized":true}"#)
        case (_, _, "forged"):
            (200, #"{"location":"http://127.0.0.1/?code=stolen&state=other"}"#)
        default:
            (200, #"{"location":"http://127.0.0.1/?iss=https%3A%2F%2Fdiscord.com&code=one-time-code&state=\#(state)"}"#)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
