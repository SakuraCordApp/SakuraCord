import Foundation
import SakuraCordModels
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
                credentials: AttachmentRefreshCredentialStore(), handle: handle, session: session,
                apiDiagnostics: diagnostics
            )
        }
        return DiscordRESTProvider(credentials: AttachmentRefreshCredentialStore(), handle: handle, session: session)
    }
}

private actor AttachmentRefreshCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }
    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("attachment-link-contract-session".utf8)
    }
    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private struct CapturedAttachmentRefreshRequest: @unchecked Sendable {
    let method: String
    let path: String
    let body: [String: Any]
}

private final class AttachmentRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [CapturedAttachmentRefreshRequest] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = ""

    static func reset(status: Int, body: String) {
        requests = []
        self.status = status
        responseBody = body
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        Self.requests.append(CapturedAttachmentRefreshRequest(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        ))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
