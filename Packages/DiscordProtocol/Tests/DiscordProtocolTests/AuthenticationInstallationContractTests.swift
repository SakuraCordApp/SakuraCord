@testable import DiscordProtocol
import Foundation
import Testing

extension ProviderRequestContractTests {
    @Test func `pending desktop login falls back when apex omits installation identity`() async throws {
        RateLimitURLProtocol.reset()
        RateLimitURLProtocol.apexOmitsInstallation = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let socket = ReadyGatewaySocket()
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

        #expect(RateLimitURLProtocol.totalRequestCount == 2)
        #expect(RateLimitURLProtocol.apexInstallationRequests == 1)
        #expect(RateLimitURLProtocol.loginExperimentsRequests == 1)
        #expect(RateLimitURLProtocol.loginExperimentsQuery == [
            "with_guild_experiments": "true"
        ])
        #expect(RateLimitURLProtocol.loginExperimentsMethod == "GET")
        #expect(RateLimitURLProtocol.loginExperimentsHost == "discordapp.com")
        #expect(RateLimitURLProtocol.loginExperimentsReferer == "https://discordapp.com/login")
        #expect(RateLimitURLProtocol.loginExperimentsContext == Data(
            #"{"location":"Login"}"#.utf8
        ).base64EncodedString())
        #expect(RateLimitURLProtocol.loginExperimentsAuthorization == nil)
        #expect(RateLimitURLProtocol.loginExperimentsInstallationHeader == nil)
        #expect(RateLimitURLProtocol.loginExperimentsFingerprint == nil)
        #expect(!RateLimitURLProtocol.loginExperimentsHadBody)
        let encodedProperties = try #require(
            RateLimitURLProtocol.loginExperimentsSuperProperties
        )
        let propertiesData = try #require(Data(base64Encoded: encodedProperties))
        let properties = try #require(
            JSONSerialization.jsonObject(with: propertiesData) as? [String: Any]
        )
        #expect(properties["client_heartbeat_session_id"] == nil)
        let resolvedMetadata = await provider.clientMetadata
        #expect(resolvedMetadata.installationID == "fallback-installation")
        #expect(await socket.sentCount == 0)
        await provider.discardPendingCredential()
    }
}
