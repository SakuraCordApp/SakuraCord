@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension ProviderRequestContractTests {
    @Test func `pending desktop login proceeds when installation identity is omitted`() async throws {
        InstallationOmittingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstallationOmittingURLProtocol.self]
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("pending-without-installation"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "user": .object([
                    "id": .string("1"),
                    "username": .string("pending"),
                    "global_name": .string("Pending"),
                    "avatar": .null,
                ]),
                "guilds": .array([]),
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let pending = try PendingDiscordCredential(
            Data("pending-session-credential-value".utf8)
        )
        let provider = DiscordRESTProvider(
            pendingCredential: pending,
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            usesDesktopHeartbeat: true,
            installationID: nil
        )

        try await provider.prepareAuthentication()
        try await provider.prepareAuthentication()
        let snapshot = try await provider.bootstrap()

        let requests = InstallationOmittingURLProtocol.requests
        #expect(requests.map { $0.url?.path } == [
            "/api/v9/apex/experiments", "/api/v9/experiments",
        ])
        let experimentsRequest = try #require(requests.last)
        let query = URLComponents(
            url: try #require(experimentsRequest.url),
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        #expect(Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        }) == ["with_guild_experiments": "true"])
        #expect(experimentsRequest.httpMethod == "GET")
        #expect(experimentsRequest.url?.host == "discordapp.com")
        #expect(experimentsRequest.value(forHTTPHeaderField: "Referer") == "https://discordapp.com/login")
        #expect(experimentsRequest.value(forHTTPHeaderField: "X-Context-Properties") == Data(
            #"{"location":"Login"}"#.utf8
        ).base64EncodedString())
        #expect(experimentsRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(experimentsRequest.value(forHTTPHeaderField: "X-Installation-ID") == nil)
        #expect(experimentsRequest.value(forHTTPHeaderField: "X-Fingerprint") == nil)
        #expect(experimentsRequest.httpBody?.isEmpty != false)
        let encodedProperties = try #require(
            experimentsRequest.value(forHTTPHeaderField: "X-Super-Properties")
        )
        let propertiesData = try #require(Data(base64Encoded: encodedProperties))
        let properties = try #require(
            JSONSerialization.jsonObject(with: propertiesData) as? [String: Any]
        )
        #expect(properties["client_heartbeat_session_id"] == nil)
        let resolvedMetadata = await provider.clientMetadata
        #expect(resolvedMetadata.installationID == nil)
        #expect(snapshot.currentUser.id == UserID(rawValue: 1))
        let identifyData = try #require(await socket.sentPayload(opcode: 2))
        let identify = try #require(
            JSONSerialization.jsonObject(with: identifyData) as? [String: Any]
        )
        let identifyBody = try #require(identify["d"] as? [String: Any])
        #expect(
            (identifyBody["capabilities"] as? NSNumber)?.intValue
                == DiscordProductionBaseline.august2026
                    .privateChannelObfuscationCapabilities
        )
        let identifyProperties = try #require(identifyBody["properties"] as? [String: Any])
        #expect(identifyProperties["installation_id"] == nil)
        await provider.disconnect()
        await provider.discardPendingCredential()
    }
}

private final class InstallationOmittingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        requests = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        let body: String
        switch request.url?.path {
        case "/api/v9/apex/experiments":
            body = #"{"assignments":{}}"#
        case "/api/v9/experiments":
            body = #"{"fingerprint":"server-issued-fingerprint","assignments":[],"guild_experiments":[]}"#
        default:
            body = #"{"message":"not found"}"#
        }
        let status = request.url?.path == "/api/v9/apex/experiments"
            || request.url?.path == "/api/v9/experiments" ? 200 : 404
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
