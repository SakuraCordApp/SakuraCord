@testable import DiscordProtocol
import Foundation
import Testing

@Suite(.serialized)
struct RESTSessionRecoveryTests {
    @Test func `timed out read rotates owned REST session and retries once`() async throws {
        RESTSessionRecoveryURLProtocol.reset()
        let provider = makeProvider()

        let (_, response) = try await provider.perform(
            "/transport-recovery",
            method: "GET",
            query: [],
            body: nil
        )

        #expect(response.statusCode == 200)
        #expect(RESTSessionRecoveryURLProtocol.requestMethods == ["GET", "GET"])
        #expect(await provider.restSessionGeneration == 1)
        await provider.disconnect()
    }

    @Test func `timed out mutation rotates transport without replaying mutation`() async throws {
        RESTSessionRecoveryURLProtocol.reset()
        let provider = makeProvider()

        await #expect(throws: URLError.self) {
            try await provider.perform(
                "/transport-recovery",
                method: "POST",
                query: [],
                body: nil
            )
        }
        let (_, response) = try await provider.perform(
            "/transport-recovery",
            method: "GET",
            query: [],
            body: nil
        )

        #expect(response.statusCode == 200)
        #expect(RESTSessionRecoveryURLProtocol.requestMethods == ["POST", "GET"])
        #expect(await provider.restSessionGeneration == 1)
        await provider.disconnect()
    }

    @Test func `timed out direct message search retries as a read`() async throws {
        RESTSessionRecoveryURLProtocol.reset()
        let provider = makeProvider()

        let (_, response) = try await provider.perform(
            "/users/@me/messages/search/tabs",
            method: "POST",
            query: [],
            body: ["tabs": .object([:])]
        )

        #expect(response.statusCode == 200)
        #expect(RESTSessionRecoveryURLProtocol.requestMethods == ["POST", "POST"])
        #expect(await provider.restSessionGeneration == 1)
        await provider.disconnect()
    }

    @Test func `stale failures share one replacement generation`() async {
        let provider = makeProvider()

        let firstRecovered = await provider.recoverRESTSessionIfNeeded(
            after: URLError(.timedOut),
            requestGeneration: 0
        )
        let staleRequestRecovered = await provider.recoverRESTSessionIfNeeded(
            after: URLError(.cancelled),
            requestGeneration: 0
        )

        #expect(firstRecovered)
        #expect(staleRequestRecovered)
        #expect(await provider.restSessionGeneration == 1)
        await provider.disconnect()
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RESTSessionRecoveryURLProtocol.self]
        return DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: RESTSessionRecoveryGatewayTransport(),
            installationID: "test-installation",
            ownsRESTSession: true
        )
    }
}

private struct RESTSessionRecoveryGatewayTransport: GatewayTransport {
    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        throw URLError(.cannotConnectToHost)
    }
}

private final class RESTSessionRecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shouldTimeOutNextRequest = true
    nonisolated(unsafe) private static var recordedRequestMethods: [String] = []

    static var requestMethods: [String] {
        lock.withLock { recordedRequestMethods }
    }

    static func reset() {
        lock.withLock {
            shouldTimeOutNextRequest = true
            recordedRequestMethods = []
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let shouldTimeOut = Self.lock.withLock {
            Self.recordedRequestMethods.append(request.httpMethod ?? "GET")
            defer { Self.shouldTimeOutNextRequest = false }
            return Self.shouldTimeOutNextRequest
        }
        if shouldTimeOut {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
