import DiscordProtocol
import Foundation
import Security

nonisolated struct DiscordRemoteAuthUser: Equatable, Sendable {
    let id: String
    let discriminator: String
    let avatar: String?
    let username: String
}

nonisolated enum DiscordRemoteAuthEvent: Sendable {
    case connecting
    case qrCode(URL)
    case scanned(DiscordRemoteAuthUser?)
    case pendingLogin(ticket: String)
    case cancelled
    case failed(String)
}

nonisolated struct DiscordRemoteAuthPayload: Decodable, Sendable {
    enum Opcode: String, Decodable, Sendable {
        case hello
        case heartbeat
        case heartbeatAck = "heartbeat_ack"
        case nonceProof = "nonce_proof"
        case pendingRemoteInit = "pending_remote_init"
        case pendingTicket = "pending_ticket"
        case pendingLogin = "pending_login"
        case cancel
        case initialize = "init"
    }

    let op: Opcode
    let heartbeatInterval: Int?
    let encryptedNonce: String?
    let fingerprint: String?
    let encryptedUserPayload: String?
    let ticket: String?

    enum CodingKeys: String, CodingKey {
        case op, fingerprint, ticket
        case heartbeatInterval = "heartbeat_interval"
        case encryptedNonce = "encrypted_nonce"
        case encryptedUserPayload = "encrypted_user_payload"
    }
}

/// Paicord-compatible Discord remote-auth v2 session. The WebSocket only
/// creates and observes one user-driven QR login; it never performs account
/// actions. Ticket exchange and its single interactive challenge replay are
/// owned by `DiscordSessionAuthenticator`.
actor DiscordRemoteAuthManager {
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var privateKey: SecKey?
    private var continuations: [UUID: AsyncStream<DiscordRemoteAuthEvent>.Continuation] = [:]
    private var generation = UUID()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func events() -> AsyncStream<DiscordRemoteAuthEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func connect() async {
        await disconnect(emit: false)
        do {
            let (generatedPrivateKey, encodedPublicKey) = try Self.makeKeyPair()
            privateKey = generatedPrivateKey
            generation = UUID()

            var request = URLRequest(
                url: URL(string: "wss://remote-auth-gateway.discord.gg/?v=2")!
            )
            request.timeoutInterval = 20
            let metadata = DiscordClientMetadata()
            metadata.applyRemoteAuthWebSocketHeaders(to: &request)

            let socket = session.webSocketTask(with: request)
            webSocket = socket
            emit(.connecting)
            socket.resume()

            let currentGeneration = generation
            receiveTask = Task { [weak self] in
                await self?.receiveMessages(
                    from: socket,
                    encodedPublicKey: encodedPublicKey,
                    generation: currentGeneration
                )
            }
        } catch {
            emit(.failed("SakuraCord could not create a private QR sign-in session."))
        }
    }

    func restart() async {
        await connect()
    }

    func disconnect() async {
        await disconnect(emit: false, clearPrivateKey: true)
    }

    func decryptToken(_ encryptedToken: String) throws -> String {
        guard let data = Data(base64Encoded: encryptedToken),
              let decrypted = decrypt(data),
              let token = String(data: decrypted, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw DiscordRemoteAuthError.tokenDecryptionFailed
        }
        return token
    }

    private func receiveMessages(
        from socket: URLSessionWebSocketTask,
        encodedPublicKey: String,
        generation: UUID
    ) async {
        do {
            while !Task.isCancelled, self.generation == generation {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(value): data = value
                @unknown default: continue
                }
                let payload = try JSONDecoder().decode(DiscordRemoteAuthPayload.self, from: data)
                try await process(payload, encodedPublicKey: encodedPublicKey, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.generation == generation else { return }
            emit(.failed("QR sign-in lost its connection. You can create a fresh code and try again."))
            await disconnect(emit: false)
        }
    }

    private func process(
        _ payload: DiscordRemoteAuthPayload,
        encodedPublicKey: String,
        generation: UUID
    ) async throws {
        switch payload.op {
        case .hello:
            guard let interval = payload.heartbeatInterval, interval > 0 else {
                throw DiscordRemoteAuthError.invalidGatewayPayload
            }
            try await send(["op": "init", "encoded_public_key": encodedPublicKey])
            startHeartbeat(every: interval, generation: generation)

        case .heartbeat:
            try await send(["op": "heartbeat"])

        case .heartbeatAck, .initialize:
            break

        case .nonceProof:
            guard let encrypted = payload.encryptedNonce,
                  let encryptedData = Data(base64Encoded: encrypted),
                  let nonce = decrypt(encryptedData)
            else {
                throw DiscordRemoteAuthError.invalidGatewayPayload
            }
            try await send(["op": "nonce_proof", "nonce": Self.base64URL(nonce)])

        case .pendingRemoteInit:
            guard let fingerprint = payload.fingerprint,
                  let url = Self.qrCodeURL(fingerprint: fingerprint)
            else {
                throw DiscordRemoteAuthError.invalidGatewayPayload
            }
            emit(.qrCode(url))

        case .pendingTicket:
            let user = payload.encryptedUserPayload
                .flatMap { Data(base64Encoded: $0) }
                .flatMap(decrypt)
                .flatMap(Self.decodeUser)
            emit(.scanned(user))

        case .pendingLogin:
            guard let ticket = payload.ticket, !ticket.isEmpty else {
                throw DiscordRemoteAuthError.invalidGatewayPayload
            }
            emit(.pendingLogin(ticket: ticket))
            // The REST exchange can present an interactive CAPTCHA. Close the
            // completed socket while retaining this session's one-use RSA key
            // until that user-driven exchange either succeeds or is cancelled.
            await disconnect(emit: false, clearPrivateKey: false)

        case .cancel:
            emit(.cancelled)
        }
    }

    private func startHeartbeat(every milliseconds: Int, generation: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard !Task.isCancelled else { return }
                do {
                    guard let self, await self.generation == generation else { return }
                    try await send(["op": "heartbeat"])
                } catch {
                    return
                }
            }
        }
    }

    private func send(_ object: [String: String]) async throws {
        guard let webSocket else { throw DiscordRemoteAuthError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DiscordRemoteAuthError.invalidGatewayPayload
        }
        try await webSocket.send(.string(text))
    }

    private func disconnect(emit _: Bool, clearPrivateKey: Bool = true) async {
        generation = UUID()
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        if clearPrivateKey {
            privateKey = nil
        }
    }

    private func decrypt(_ ciphertext: Data) -> Data? {
        guard let privateKey else { return nil }
        var error: Unmanaged<CFError>?
        let result = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA256,
            ciphertext as CFData,
            &error
        )
        return result as Data?
    }

    private func emit(_ event: DiscordRemoteAuthEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    nonisolated static func qrCodeURL(fingerprint: String) -> URL? {
        guard !fingerprint.isEmpty else { return nil }
        return URL(string: "https://discord.com/ra/\(fingerprint)")
    }

    nonisolated static func decodeUser(_ data: Data) -> DiscordRemoteAuthUser? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let parts = value.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        return DiscordRemoteAuthUser(
            id: String(parts[0]),
            discriminator: String(parts[1]),
            avatar: parts[2].isEmpty ? nil : String(parts[2]),
            username: String(parts[3])
        )
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    private nonisolated static func makeKeyPair() throws -> (privateKey: SecKey, encodedPublicKey: String) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let rawPublicKey = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw DiscordRemoteAuthError.keyGenerationFailed
        }
        let spki = subjectPublicKeyInfo(for: rawPublicKey)
        return (privateKey, spki.base64EncodedString())
    }

    private nonisolated static func subjectPublicKeyInfo(for pkcs1: Data) -> Data {
        let rsaAlgorithmIdentifier = Data([
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
            0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00
        ])
        let bitStringBody = Data([0x00]) + pkcs1
        let bitString = Data([0x03]) + derLength(bitStringBody.count) + bitStringBody
        let body = rsaAlgorithmIdentifier + bitString
        return Data([0x30]) + derLength(body.count) + body
    }

    private nonisolated static func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

nonisolated enum DiscordRemoteAuthError: LocalizedError {
    case keyGenerationFailed
    case notConnected
    case invalidGatewayPayload
    case tokenDecryptionFailed

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: "SakuraCord could not create the private key for QR sign-in."
        case .notConnected: "The QR sign-in session is no longer connected."
        case .invalidGatewayPayload: "Discord returned an invalid QR sign-in response."
        case .tokenDecryptionFailed: "Discord approved the QR sign-in, but the encrypted session could not be opened."
        }
    }
}
