@testable import DiscordProtocol
import Foundation
import Testing

@Test func `disconnect during credential authorization cannot start Gateway`() async {
    let credentials = BlockingCredentialStore()
    let transport = CountingGatewayTransport()
    let provider = DiscordRESTProvider(
        credentials: credentials,
        handle: CredentialHandle(accountID: "1"),
        session: URLSession(configuration: .ephemeral),
        gatewayTransport: transport,
        installationID: "server-issued-installation"
    )
    let start = Task {
        try await provider.startGateway()
    }

    await credentials.waitUntilCredentialReadStarts()
    await provider.disconnect()
    await credentials.releaseCredential()

    do {
        try await start.value
        Issue.record("A disconnected provider started its Gateway session.")
    } catch {
        #expect(error is ChatProviderError)
    }
    #expect(await transport.connectionCount == 0)
}

@Test func `authentication failure before initial snapshot waiter is retained`() async {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(),
        handle: CredentialHandle(accountID: "1"),
        session: URLSession(configuration: .ephemeral),
        installationID: "server-issued-installation"
    )

    await provider.handleGatewaySessionEvent(.stateChanged(.authenticationFailed))

    await #expect(throws: ChatProviderError.self) {
        try await provider.waitForInitialGatewaySnapshot()
    }
}

@Test func `terminal disconnect before initial snapshot waiter is retained`() async {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(),
        handle: CredentialHandle(accountID: "1"),
        session: URLSession(configuration: .ephemeral),
        installationID: "server-issued-installation"
    )

    await provider.handleGatewaySessionEvent(.stateChanged(.disconnected))

    await #expect(throws: ChatProviderError.self) {
        try await provider.waitForInitialGatewaySnapshot()
    }
}

@Test func `pending login rejects malformed Ready before completing bootstrap`() async throws {
    RateLimitURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RateLimitURLProtocol.self]
    let socket = ReadyGatewaySocket()
    await socket.push(gatewayMessage(
        op: 10, data: .object(["heartbeat_interval": .number(60_000)])
    ))
    await socket.push(gatewayMessage(
        op: 0,
        data: .object([
            "guilds": .array([]),
            "user": .object([
                "id": .string("1"),
                "username": .string("pending"),
            ]),
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
        gatewayTransport: ReadyGatewayTransport(socket: socket)
    )

    await #expect(throws: ChatProviderError.self) {
        try await provider.bootstrap()
    }

    #expect(RateLimitURLProtocol.totalRequestCount == 0)
    await provider.disconnect()
    await pending.discard()
}

private actor BlockingCredentialStore: CredentialStore {
    private var credentialContinuation: CheckedContinuation<Data, Never>?
    private var readStartContinuations: [CheckedContinuation<Void, Never>] = []

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        for continuation in readStartContinuations {
            continuation.resume()
        }
        readStartContinuations = []
        return await withCheckedContinuation { credentialContinuation = $0 }
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }

    func waitUntilCredentialReadStarts() async {
        guard credentialContinuation == nil else { return }
        await withCheckedContinuation { readStartContinuations.append($0) }
    }

    func releaseCredential() {
        credentialContinuation?.resume(
            returning: Data("test-session-credential-value".utf8)
        )
        credentialContinuation = nil
    }
}

private actor CountingGatewayTransport: GatewayTransport {
    private(set) var connectionCount = 0

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        connectionCount += 1
        throw URLError(.cancelled)
    }
}
