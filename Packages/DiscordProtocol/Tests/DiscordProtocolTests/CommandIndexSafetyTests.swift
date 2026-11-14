@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Suite(.serialized)
struct CommandIndexSafetyTests {
    @Test func `unavailable channel command indexes cannot stop other conversations`() async throws {
        let provider = makeProvider()
        for id in [200, 201] {
            await #expect(throws: ChatProviderError.self) {
                _ = try await provider.applicationCommandCatalog(for: .channel(.init(rawValue: UInt64(id))))
            }
        }
        #expect(await !provider.requestSafetyCircuitIsOpen)
        let catalog = try await provider.applicationCommandCatalog(for: .user)
        #expect(catalog.target == .user)
        #expect(CommandIndexSafetyURLProtocol.paths.withLock { $0 } == [
            "/api/v9/channels/200/application-command-index",
            "/api/v9/channels/201/application-command-index",
            "/api/v9/users/@me/application-command-index"
        ])
        await provider.disconnect()
    }

    @Test(arguments: [
        (400, #"{"code":50035,"message":"Invalid Form Body"}"#),
        (400, #"{"code":40004,"message":"Send messages temporarily disabled"}"#),
        (403, #"{"code":40333,"message":"Request rejected"}"#),
        (400, #"{"captcha_key":["required"],"captcha_service":"unsupported"}"#),
        (403, #"{"code":50013,"message":"Missing Permissions"}"#),
        (404, #"{"code":10003,"message":"Unknown Channel"}"#),
        (500, #"{"message":"Internal Server Error"}"#),
    ])
    func `rejected operations report errors without stopping later reads or writes`(status: Int, body: String) async throws {
        let provider = makeProvider()
        await provider.markGatewayReadyForRecoveryTest()
        CommandIndexSafetyURLProtocol.rejection.withLock { $0 = (status, body) }
        // Repeated failures on the same route used to permanently stop the session.
        for _ in 0 ..< 2 {
            await #expect(throws: ChatProviderError.transport(status: status, requestID: nil)) {
                try await provider.requestEmpty("/rejected-resource", method: "PATCH")
            }
        }
        await #expect(throws: ChatProviderError.transport(status: status, requestID: nil)) {
            let _: JSONValue = try await provider.request("/rejected-resource")
        }
        #expect(CommandIndexSafetyURLProtocol.paths.withLock { $0.count } == 3, "Rejected operations must not be replayed")
        #expect(await !provider.requestSafetyCircuitIsOpen)
        #expect(await provider.gatewayReady)
        let catalog = try await provider.applicationCommandCatalog(for: .user)
        #expect(catalog.target == .user)
        // A later explicit action can succeed on the formerly failing route.
        CommandIndexSafetyURLProtocol.rejection.withLock { $0 = nil }
        try await provider.requestEmpty("/rejected-resource", method: "PATCH")
        #expect(CommandIndexSafetyURLProtocol.paths.withLock { $0.count } == 5)
        await provider.disconnect()
    }

    @Test(arguments: [(401, 40001), (400, 40001), (403, 50014)])
    func `invalid credentials stop the session and prevent later requests`(status: Int, code: Int) async throws {
        let provider = makeProvider()
        await provider.markGatewayReadyForRecoveryTest()
        CommandIndexSafetyURLProtocol.rejection.withLock { $0 = (status, "{\"code\":\(code)}") }
        await #expect(throws: ChatProviderError.unauthenticated) {
            try await provider.requestEmpty("/rejected-resource", method: "PATCH")
        }
        #expect(await provider.requestSafetyCircuitIsOpen)
        #expect(await !provider.gatewayReady)
        let count = CommandIndexSafetyURLProtocol.paths.withLock { $0.count }
        do {
            _ = try await provider.applicationCommandCatalog(for: .user)
            Issue.record("An unauthenticated session must reject the next request")
        } catch {
            #expect(error.localizedDescription == ChatProviderError.unauthenticated.localizedDescription)
        }
        #expect(CommandIndexSafetyURLProtocol.paths.withLock { $0.count } == count)
        await provider.disconnect()
    }

    private func makeProvider() -> DiscordRESTProvider {
        CommandIndexSafetyURLProtocol.paths.withLock { $0.removeAll() }
        CommandIndexSafetyURLProtocol.rejection.withLock { $0 = nil }
        return stubbedProvider(CommandIndexSafetyURLProtocol.self, accountID: "command-index-safety")
    }
}

private final class CommandIndexSafetyURLProtocol: URLProtocol, @unchecked Sendable {
    static let paths = Mutex<[String]>([])
    static let rejection = Mutex<(Int, String)?>(nil)
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.paths.withLock { $0.append(url.path) }
        let status: Int
        let body: String
        if url.path == "/api/v9/rejected-resource", let rejection = Self.rejection.withLock({ $0 }) {
            (status, body) = rejection
        } else if url.path == "/api/v9/users/@me/application-command-index" || url.path == "/api/v9/rejected-resource" {
            status = 200
            body = #"{"applications":[],"application_commands":[]}"#
        } else {
            status = 404
            body = #"{"code":10003,"message":"Unknown Channel"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                                                            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension DiscordRESTProvider {
    func markGatewayReadyForRecoveryTest() {
        gatewayReady = true
    }
}
