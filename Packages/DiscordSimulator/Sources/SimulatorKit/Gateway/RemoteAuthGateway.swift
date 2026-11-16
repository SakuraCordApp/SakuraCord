import CryptoKit
import Foundation
import Security

/// QR-code sign-in: `wss://remote-auth-gateway.discord.gg/?v=2`, whose redirect
/// lands on the Gateway port. The official client can't be captured on this
/// host, so the protocol follows Discord's documented remote-auth v2 flow:
/// hello, init (SPKI public key), nonce_proof both ways, pending_remote_init
/// with the key fingerprint, then the phone's pending_ticket and pending_login
/// (or cancel). Payloads are RSA-OAEP SHA-256 encrypted to the client's key.
/// The phone side is played through the control API.
public actor RemoteAuthGateway {
    static let heartbeatIntervalMilliseconds: Int64 = 41_250
    static let timeoutMilliseconds: Int64 = 150_000

    private final class Session {
        let connection: WebSocketConnection
        var publicKey: SecKey?
        var fingerprint: String?
        var expectedNonce: String?
        var scannedBy: Snowflake?

        init(connection: WebSocketConnection) { self.connection = connection }
    }

    let world: World
    let log: SimulatorLog
    private var random: SeededRandom
    /// Sessions waiting for a phone, by fingerprint.
    private var pending: [String: Session] = [:]
    /// Approved logins waiting for the ticket exchange.
    private var tickets: [String: (userID: Snowflake, publicKey: SecKey)] = [:]

    public init(world: World, log: SimulatorLog, seed: UInt64) {
        self.world = world
        self.log = log
        random = SeededRandom(seed: seed).fork("remote-auth")
    }

    public func handle(_ connection: WebSocketConnection) async {
        let session = Session(connection: connection)
        await send(["op": "hello", "heartbeat_interval": .int(Self.heartbeatIntervalMilliseconds),
                    "timeout_ms": .int(Self.timeoutMilliseconds)], to: session)
        let timeout = Task {
            try await Task.sleep(for: .milliseconds(Self.timeoutMilliseconds))
            await connection.close(code: 4003, reason: "Session timed out.")
        }
        defer { timeout.cancel() }
        for await message in connection.messages {
            guard case let .text(text) = message, let payload = try? JSON.parse(text) else { break }
            guard await receive(payload, session: session) else { break }
        }
        if let fingerprint = session.fingerprint, pending[fingerprint] === session { pending[fingerprint] = nil }
    }

    /// Returns false once the connection is closed.
    private func receive(_ payload: JSON, session: Session) async -> Bool {
        switch payload["op"]?.stringValue {
        case "heartbeat":
            await send(["op": "heartbeat_ack"], to: session)
        case "init":
            guard session.publicKey == nil, let encoded = payload["encoded_public_key"]?.stringValue,
                  let spki = Data(base64Encoded: encoded), let key = Self.publicKey(spki: spki) else {
                return await fail(session, code: 4002, "Handshake failure.")
            }
            let nonce = Data((0 ..< 4).flatMap { _ in withUnsafeBytes(of: random.next()) { Array($0) } })
            guard let encrypted = Self.encrypt(nonce, to: key) else { return await fail(session, code: 4002, "Handshake failure.") }
            session.publicKey = key
            session.fingerprint = Self.base64URL(Data(SHA256.hash(data: spki)))
            session.expectedNonce = Self.base64URL(nonce)
            await send(["op": "nonce_proof", "encrypted_nonce": .string(encrypted.base64EncodedString())], to: session)
        case "nonce_proof":
            guard let expected = session.expectedNonce, payload["nonce"]?.stringValue == expected, let fingerprint = session.fingerprint else {
                return await fail(session, code: 4001, "Invalid nonce proof.")
            }
            session.expectedNonce = nil
            pending[fingerprint] = session
            await send(["op": "pending_remote_init", "fingerprint": .string(fingerprint)], to: session)
        default:
            return await fail(session, code: 4001, "Decode error.")
        }
        return true
    }

    private func fail(_ session: Session, code: UInt16, _ reason: String) async -> Bool {
        log.error("remote-auth", "closing \(code): \(reason)")
        await session.connection.close(code: code, reason: reason)
        return false
    }

    // MARK: The phone

    /// Fingerprints of QR codes currently on screen, oldest first.
    public var waitingFingerprints: [String] { pending.keys.sorted() }

    /// The phone scans the code (`pending_ticket`), then approves (`pending_login`)
    /// or cancels. With no fingerprint, the only waiting code is used.
    public func phone(fingerprint: String?, userID: Snowflake, approve: Bool?) async throws {
        guard let fingerprint = fingerprint ?? (pending.count == 1 ? pending.keys.first : nil), let session = pending[fingerprint],
              let key = session.publicKey else { throw WorldError.invalidBody("no QR code is waiting for a phone (or several are; pass fingerprint)") }
        let user = try await world.user(userID)
        if session.scannedBy != userID {
            let summary = [user.id.description, "0", user.avatar ?? "0", user.username].joined(separator: ":")
            guard let encrypted = Self.encrypt(Data(summary.utf8), to: key) else { throw WorldError.invalidBody("could not encrypt") }
            session.scannedBy = userID
            await send(["op": "pending_ticket", "encrypted_user_payload": .string(encrypted.base64EncodedString())], to: session)
        }
        guard let approve else { return }
        pending[fingerprint] = nil
        if approve {
            let ticket = random.urlSafeString(43)
            tickets[ticket] = (userID, key)
            await send(["op": "pending_login", "ticket": .string(ticket)], to: session)
        } else {
            await send(["op": "cancel"], to: session)
        }
        await session.connection.close(code: 1000, reason: "")
    }

    /// `POST /users/@me/remote-auth/login`: the ticket buys the account's token, encrypted to the QR code's key.
    func exchange(ticket: String) async throws -> JSON {
        guard let approved = tickets.removeValue(forKey: ticket) else { throw WorldError.invalidBody("ticket: Invalid ticket") }
        guard let token = await world.tokens.first(where: { $0.value == approved.userID })?.key,
              let encrypted = Self.encrypt(Data(token.utf8), to: approved.publicKey) else { throw WorldError.unauthorized }
        return .object(JSONObject([("encrypted_token", .string(encrypted.base64EncodedString()))]))
    }

    // MARK: Wire

    private func send(_ payload: JSON, to session: Session) async {
        await session.connection.send(text: payload.serialized(spaced: false))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func encrypt(_ data: Data, to key: SecKey) -> Data? {
        SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, data as CFData, nil) as Data?
    }

    /// Reads an RSA SubjectPublicKeyInfo (DER): SEQUENCE { AlgorithmIdentifier, BIT STRING { PKCS#1 key } }.
    static func publicKey(spki: Data) -> SecKey? {
        var reader = DERReader(bytes: [UInt8](spki))
        guard var outer = reader.element(tag: 0x30), outer.element(tag: 0x30) != nil,
              let bitString = outer.element(tag: 0x03), bitString.bytes.first == 0 else { return nil }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(Data(bitString.bytes.dropFirst()) as CFData, attributes as CFDictionary, nil)
    }
}

/// Just enough DER to walk a SubjectPublicKeyInfo.
private struct DERReader {
    var bytes: ArraySlice<UInt8>

    init(bytes: [UInt8]) { self.bytes = bytes[...] }
    init(slice: ArraySlice<UInt8>) { bytes = slice }

    mutating func element(tag: UInt8) -> DERReader? {
        guard bytes.count >= 2, bytes.first == tag else { return nil }
        var index = bytes.startIndex + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, bytes.endIndex - index >= count else { return nil }
            length = bytes[index ..< index + count].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard bytes.endIndex - index >= length else { return nil }
        defer { bytes = bytes[(index + length)...] }
        return DERReader(slice: bytes[index ..< index + length])
    }
}
