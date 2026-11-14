import Foundation
import SakuraCordModels
import Synchronization
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct AttachmentLinkContractTests {
    private let original = "https://cdn.discordapp.com/attachments/1/2/cat.gif"

    @Test func `attachment link refresh sends one first party request and returns the signed URL`() async throws {
        let signed = "\(original)?ex=6a000000&is=69f00000&hm=abc&"
        AttachmentRefreshURLProtocol.reset(status: 200, body: #"""
        {"refreshed_urls":[{"original":"\#(original)","refreshed":"\#(signed)"}]}
        """#)
        let diagnostics = DiscordAPIDiagnosticStore(maximumEntries: 10, capturesPayloadDetails: false)
        let provider = makeProvider(diagnostics: diagnostics)

        let refreshed = try await provider.refreshAttachmentURL(try #require(URL(string: original)))

        #expect(refreshed?.absoluteString == signed)
        let request = try #require(AttachmentRefreshURLProtocol.requests.first)
        #expect(AttachmentRefreshURLProtocol.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/attachments/refresh-urls")
        #expect(Set(request.body.keys) == ["attachment_urls"])
        #expect(request.body["attachment_urls"] as? [String] == [original])
        await provider.disconnect()
        let loggedPaths = try diagnostics.exportData().split(separator: UInt8(ascii: "\n")).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["path"] as? String
        }
        #expect(loggedPaths.contains("/attachments/refresh-urls"))
    }

    @Test func `attachment link refresh returns nil for a null URL and never retries a failure`() async throws {
        let url = try #require(URL(string: original))
        AttachmentRefreshURLProtocol.reset(status: 200, body: #"{"refreshed_urls":[{"original":"x","refreshed":null}]}"#)
        let provider = makeProvider()
        #expect(try await provider.refreshAttachmentURL(url) == nil)

        AttachmentRefreshURLProtocol.reset(status: 500, body: "{}")
        await #expect(throws: ChatProviderError.self) {
            _ = try await provider.refreshAttachmentURL(url)
        }
        #expect(AttachmentRefreshURLProtocol.requests.count == 1)
        await provider.disconnect()
    }

    private func makeProvider(diagnostics: DiscordAPIDiagnosticStore? = nil) -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttachmentRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let handle = CredentialHandle(accountID: "attachment-link-contract")
        if let diagnostics {
            return DiscordRESTProvider(
                credentials: TestCredentialStore(token: "attachment-link-contract-session", handles: []), handle: handle, session: session,
                apiDiagnostics: diagnostics
            )
        }
        return DiscordRESTProvider(credentials: TestCredentialStore(token: "attachment-link-contract-session", handles: []), handle: handle, session: session)
    }
}

private struct CapturedAttachmentRefreshRequest: @unchecked Sendable {
    let method: String
    let path: String
    let body: [String: Any]
}

private final class AttachmentRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var requests: [CapturedAttachmentRefreshRequest] = []
        var status = 200
        var responseBody = ""
    }

    private static let state = Mutex(State())

    static var requests: [CapturedAttachmentRefreshRequest] {
        state.withLock { $0.requests }
    }

    static func reset(status: Int, body: String) {
        state.withLock { $0 = State(status: status, responseBody: body) }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.bodyData ?? Data()
        let captured = CapturedAttachmentRefreshRequest(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        )
        let (status, responseBody) = Self.state.withLock {
            $0.requests.append(captured)
            return ($0.status, $0.responseBody)
        }
        respond(status: status, body: Data(responseBody.utf8))
    }

    override func stopLoading() {}
}
