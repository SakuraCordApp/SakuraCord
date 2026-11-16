@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

/// Serves one fixed session credential; suites give theirs a distinct value
/// to tell their requests apart.
actor TestCredentialStore: CredentialStore {
    static let defaultToken = "test-session-credential-value"
    private let token: String
    private let storedHandles: [CredentialHandle]
    private(set) var credentialReadCount = 0

    init(
        token: String = defaultToken,
        handles: [CredentialHandle] = [CredentialHandle(accountID: "1")]
    ) {
        self.token = token
        storedHandles = handles
    }

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        credentialReadCount += 1
        return Data(token.utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] {
        storedHandles
    }
}

/// A provider whose REST requests are served by `protocolClass`.
func stubbedProvider(
    _ protocolClass: URLProtocol.Type, token: String = TestCredentialStore.defaultToken, accountID: String = "1"
) -> DiscordRESTProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return DiscordRESTProvider(
        credentials: TestCredentialStore(token: token), handle: CredentialHandle(accountID: accountID),
        session: URLSession(configuration: configuration)
    )
}

struct UnavailableGatewayTransport: GatewayTransport {
    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        throw URLError(.notConnectedToInternet)
    }
}

struct ReadyGatewayTransport: GatewayTransport {
    let socket: ReadyGatewaySocket

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        socket
    }
}

/// Keeps the Gateway's own timers from firing. `ReadyGatewaySocket` never
/// acknowledges heartbeats, so a heartbeat timer elapsing mid-test would
/// reconnect the session at a random point.
struct HeldGatewayClock: GatewayClock {
    func sleep(for _: Duration) async throws {
        try await Task.sleep(for: .seconds(86_400))
    }
}

private enum ReadyGatewayError: Error { case closed }

actor ReadyGatewaySocket: GatewaySocket {
    private var queued: [GatewaySocketMessage] = []
    private var receiver: CheckedContinuation<GatewaySocketMessage, any Error>?
    private var heldOpcode: Int?
    private var heldSend: CheckedContinuation<Void, any Error>?
    private var heldSendWaiter: CheckedContinuation<Void, Never>?
    private(set) var sentCount = 0
    private(set) var sentPayloads: [Data] = []
    private(set) var sentInstants: [ContinuousClock.Instant] = []

    func receive() async throws -> GatewaySocketMessage {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func send(_ data: Data) async throws {
        sentCount += 1
        sentPayloads.append(data)
        sentInstants.append(.now)
        if let heldOpcode,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (object["op"] as? NSNumber)?.intValue == heldOpcode {
            self.heldOpcode = nil
            try await withCheckedThrowingContinuation { continuation in
                heldSend = continuation
                heldSendWaiter?.resume()
                heldSendWaiter = nil
            }
        }
    }

    func holdNextSend(opcode: Int) {
        heldOpcode = opcode
    }

    func waitForHeldSend() async {
        guard heldSend == nil else { return }
        await withCheckedContinuation { heldSendWaiter = $0 }
    }

    func releaseHeldSend() {
        heldSend?.resume()
        heldSend = nil
    }

    func sentPayload(opcode: Int) -> Data? {
        sentPayloads.last { data in
            guard
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { return false }
            return (object["op"] as? NSNumber)?.intValue == opcode
        }
    }

    func sentPayloadCount(opcode: Int) -> Int {
        sentPayloads.count { data in
            guard
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { return false }
            return (object["op"] as? NSNumber)?.intValue == opcode
        }
    }

    func sentOpcodes() -> [Int] {
        sentPayloads.compactMap { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (object["op"] as? NSNumber)?.intValue
        }
    }

    func close(code: Int) async {
        heldSend?.resume(throwing: ReadyGatewayError.closed)
        heldSend = nil
        heldSendWaiter?.resume()
        heldSendWaiter = nil
        receiver?.resume(throwing: ReadyGatewayError.closed)
        receiver = nil
    }

    func closeCode() async -> Int? { nil }

    func push(_ message: GatewaySocketMessage) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: message)
        } else {
            queued.append(message)
        }
    }
}

func gatewayMessage(
    op: Int,
    data: JSONValue?,
    sequence: Int? = nil,
    eventName: String? = nil
) -> GatewaySocketMessage {
    let envelope = GatewayEnvelope(
        op: op, data: data, sequence: sequence, eventName: eventName
    )
    return .text(restrictionGatewayText(envelope))
}

private func restrictionGatewayText(_ envelope: GatewayEnvelope) -> String {
    let data: Data
    do {
        data = try JSONGatewayCodec().encode(envelope)
    } catch {
        preconditionFailure("Invalid test Gateway envelope: \(error)")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        preconditionFailure("Gateway JSON encoder returned non-UTF-8 data")
    }
    return text
}

private enum RestrictionGatewayError: Error { case closed }

struct RestrictionGatewayTransport: GatewayTransport {
    let socket: RestrictionGatewaySocket

    func connect(to url: URL, maximumMessageSize: Int) async throws -> any GatewaySocket {
        socket
    }
}

actor RestrictionGatewaySocket: GatewaySocket {
    private var queued: [GatewaySocketMessage] = [
        gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ),
        gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("restriction-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "guilds": .array([]),
            ]),
            sequence: 1,
            eventName: "READY"
        ),
    ]
    private var receiver: CheckedContinuation<GatewaySocketMessage, any Error>?
    private(set) var receiveStarted = false
    private(set) var closeCodes: [Int] = []

    func receive() async throws -> GatewaySocketMessage {
        receiveStarted = true
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func send(_ data: Data) async throws {}

    func close(code: Int) async {
        closeCodes.append(code)
        receiver?.resume(throwing: RestrictionGatewayError.closed)
        receiver = nil
    }

    func closeCode() async -> Int? {
        nil
    }
}

/// Collects the requests one test sends through a URL protocol that posts each
/// materialized request as `notification`. A unique `id` in `header`, the
/// session credential by default, tells concurrent tests apart.
final class RequestRecorder {
    let id: String
    private final class Storage: Sendable { let requests = Mutex<[URLRequest]>([]) }
    private let storage: Storage
    private let observer: any NSObjectProtocol

    init(_ notification: Notification.Name, header: String = "Authorization", id: String = UUID().uuidString) {
        self.id = id
        let storage = Storage()
        self.storage = storage
        observer = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: nil) { note in
            guard let request = note.object as? URLRequest, request.value(forHTTPHeaderField: header) == id else { return }
            storage.requests.withLock { $0.append(request) }
        }
    }

    deinit { NotificationCenter.default.removeObserver(observer) }

    var requests: [URLRequest] { storage.requests.withLock { $0 } }
}

actor ReactionProjectionEventRecorder {
    private(set) var reactionUpdateCount = 0
    private(set) var forumCataloguePublishCount = 0

    func record(_ event: ClientEvent) {
        switch event {
        case .messageReactionUpdated:
            reactionUpdateCount += 1
        case .forumPostsChanged:
            forumCataloguePublishCount += 1
        default:
            break
        }
    }
}

/// Polls `condition` in the caller's isolation until it holds. Sleeps between
/// checks so work on other tasks and actors can run; fails after 10 seconds.
func eventually(
    isolation _: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        guard (try? await Task.sleep(for: .milliseconds(1))) != nil else {
            break
        }
    }
    return await condition()
}

/// PreloadedUserSettings carrying StatusSettings.status and, optionally,
/// versions.data_version.
func statusSettingsFixture(_ status: String, dataVersion: UInt32? = nil) -> Data {
    var root = Data()
    if let dataVersion {
        root.append(DiscordSettingsProto.protoLengthDelimitedField(1, DiscordSettingsProto.protoVarintField(3, UInt64(dataVersion))))
    }
    root.append(DiscordSettingsProto.protoLengthDelimitedField(
        11, DiscordSettingsProto.protoLengthDelimitedField(1, DiscordSettingsProto.protoLengthDelimitedField(1, Data(status.utf8)))
    ))
    return root
}

/// The status of every opcode 3 the socket sent, in order.
func presenceStatuses(_ socket: ReadyGatewaySocket) async -> [String] {
    await socket.sentPayloads.compactMap { data -> String? in
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["op"] as? NSNumber)?.intValue == 3 else { return nil }
        return (object["d"] as? [String: Any])?["status"] as? String
    }
}

/// Account-status events received until the provider disconnected.
func statusEvents(_ events: AsyncStream<ClientEvent>) async -> [PresenceStatus] {
    var received: [PresenceStatus] = []
    for await event in events {
        if case let .currentUserStatusChanged(status) = event { received.append(status) }
    }
    return received
}

extension URLRequest {
    /// The body a test URLProtocol receives, which URLSession usually hands
    /// over as a stream.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    var method: String { httpMethod ?? "" }
    var path: String { url?.path ?? "" }
    var queryItems: [URLQueryItem] {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }

    /// The body as a JSON object; nil when it is absent or not an object.
    var jsonBody: [String: Any]? {
        bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

extension URLProtocol {
    /// Answers the request with `status` and `body`, then finishes loading.
    func respond(status: Int, body: Data, headers: [String: String]? = ["Content-Type": "application/json"]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    func respond(status: Int, body: String) {
        respond(status: status, body: Data(body.utf8))
    }
}
