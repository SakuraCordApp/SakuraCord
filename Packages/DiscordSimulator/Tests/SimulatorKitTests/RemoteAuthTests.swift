import CryptoKit
import Foundation
import Security
@testable import SimulatorKit
import Testing

/// QR sign-in end to end: the documented v2 handshake, the phone approving, and the ticket exchange.
struct RemoteAuthTests {
    @Test func phoneApprovalSignsTheQRCodeIn() async throws {
        var configuration = DiscordSimulator.Configuration()
        configuration.network = .instant
        configuration.epoch = Date(timeIntervalSince1970: 1_794_778_200)
        configuration.basePort = UInt16(42_000 + Int(ProcessInfo.processInfo.processIdentifier % 1_000) * 10)
        let simulator = try await DiscordSimulator.make(configuration: configuration)
        try await simulator.start()
        defer { simulator.stop() }

        let privateKey = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        // SubjectPublicKeyInfo for a 2048-bit RSA key: a fixed header, then the PKCS#1 key.
        let spki = Data([0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
                         0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00]) + pkcs1
        func decrypt(_ base64: String?) throws -> Data {
            let data = try #require(base64.flatMap { Data(base64Encoded: $0) })
            return try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, data as CFData, nil) as Data?)
        }

        let socket = URLSession(configuration: .ephemeral)
            .webSocketTask(with: URL(string: "ws://127.0.0.1:\(simulator.port(.gateway))/?v=2")!)
        socket.resume()
        func receive() async throws -> JSON {
            guard case let .string(text) = try await socket.receive() else { throw WorldError.invalidBody("binary frame") }
            return try JSON.parse(text)
        }
        func send(_ payload: JSON) async throws { try await socket.send(.string(payload.serialized(spaced: false))) }

        #expect(try await receive()["op"]?.stringValue == "hello")
        try await send(["op": "init", "encoded_public_key": .string(spki.base64EncodedString())])
        let nonce = try decrypt(try await receive()["encrypted_nonce"]?.stringValue)
        try await send(["op": "nonce_proof", "nonce": .string(RemoteAuthGateway.base64URL(nonce))])
        let fingerprint = try await receive()["fingerprint"]?.stringValue
        #expect(fingerprint == RemoteAuthGateway.base64URL(Data(SHA256.hash(data: spki))))

        let me = try #require(await simulator.world.primaryUserID)
        try await simulator.hub.remoteAuth.phone(fingerprint: fingerprint, userID: me, approve: true)
        let summary = String(bytes: try decrypt(try await receive()["encrypted_user_payload"]?.stringValue), encoding: .utf8) ?? ""
        #expect(summary.hasPrefix("\(me):0:"))
        let ticket = try #require(try await receive()["ticket"]?.stringValue)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(simulator.port(.api))/api/v9/users/@me/remote-auth/login")!)
        request.httpMethod = "POST"
        request.httpBody = JSON.object(JSONObject([("ticket", .string(ticket))])).data()
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        let token = String(bytes: try decrypt(try JSON.parse(data)["encrypted_token"]?.stringValue), encoding: .utf8) ?? ""
        #expect(await simulator.world.userID(forToken: token) == me)
    }
}
