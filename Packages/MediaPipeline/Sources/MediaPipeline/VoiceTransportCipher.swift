import Clibsodium
import CryptoKit
import Foundation
import Sodium

public enum VoiceTransportMode: String, CaseIterable, Sendable {
    case aes256GCMRTPSize = "aead_aes256_gcm_rtpsize"
    case xChaCha20Poly1305RTPSize = "aead_xchacha20_poly1305_rtpsize"

    public static func preferred(from modes: [String]) -> VoiceTransportMode? {
        if modes.contains(aes256GCMRTPSize.rawValue) {
            return .aes256GCMRTPSize
        }
        if modes.contains(xChaCha20Poly1305RTPSize.rawValue) {
            return .xChaCha20Poly1305RTPSize
        }
        return nil
    }
}

public enum VoiceTransportCipherError: Error, Equatable {
    case invalidKey
    case malformedPacket
    case authenticationFailed
}

public struct VoiceTransportCipher: Sendable {
    public let mode: VoiceTransportMode
    private let key: [UInt8]
    private var nonceCounter: UInt32

    public init(mode: VoiceTransportMode, key: [UInt8], initialNonce: UInt32 = 0) throws {
        guard key.count == 32 else { throw VoiceTransportCipherError.invalidKey }
        self.mode = mode
        self.key = key
        nonceCounter = initialNonce
    }

    public mutating func seal(header: Data, plaintext: Data) throws -> Data {
        nonceCounter &+= 1
        let suffix = nonceCounter.bigEndianBytes
        let nonce = nonceBytes(suffix: suffix)
        let authenticatedCiphertext: Data
        switch mode {
        case .aes256GCMRTPSize:
            let sealed = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: header
            )
            authenticatedCiphertext = sealed.ciphertext + sealed.tag
        case .xChaCha20Poly1305RTPSize:
            _ = Sodium()
            var sealed = [UInt8](repeating: 0, count: plaintext.count + 16)
            var sealedLength: UInt64 = 0
            let status = crypto_aead_xchacha20poly1305_ietf_encrypt(
                &sealed,
                &sealedLength,
                plaintext.bytes,
                UInt64(plaintext.count),
                header.bytes,
                UInt64(header.count),
                nil,
                nonce,
                key
            )
            guard status == 0 else { throw VoiceTransportCipherError.authenticationFailed }
            authenticatedCiphertext = Data(sealed.prefix(Int(sealedLength)))
        }
        return header + authenticatedCiphertext + suffix
    }

    public func open(packet: Data) throws -> (header: RTPHeader, payload: Data) {
        guard let parsed = RTPHeader.parse(from: packet), packet.count >= parsed.headerSize + 20 else {
            throw VoiceTransportCipherError.malformedPacket
        }
        var mediaPayload = try openPayload(packet: packet, headerSize: parsed.headerSize)
        if let extensionLength = parsed.header.extensionLengthInWords {
            let byteCount = Int(extensionLength) * 4
            guard mediaPayload.count >= byteCount else { throw VoiceTransportCipherError.malformedPacket }
            mediaPayload = Data(mediaPayload.dropFirst(byteCount))
        }
        if parsed.header.padding {
            guard let paddingLength = mediaPayload.last.map(Int.init),
                  paddingLength > 0,
                  paddingLength <= mediaPayload.count
            else {
                throw VoiceTransportCipherError.malformedPacket
            }
            mediaPayload.removeLast(paddingLength)
        }
        return (parsed.header, mediaPayload)
    }

    func openRTCP(packet: Data) throws -> (header: RTCPHeader, payload: Data) {
        guard let header = RTCPHeader.parse(from: packet), packet.count >= 28 else {
            throw VoiceTransportCipherError.malformedPacket
        }
        return try (header, openPayload(packet: packet, headerSize: 8))
    }

    private func openPayload(packet: Data, headerSize: Int) throws -> Data {
        let headerData = packet.prefix(headerSize)
        let suffix = Data(packet.suffix(4))
        let authenticatedCiphertext = Data(packet[headerSize ..< (packet.count - 4)])
        let nonce = nonceBytes(suffix: suffix)
        let plaintext: Data
        switch mode {
        case .aes256GCMRTPSize:
            guard authenticatedCiphertext.count >= 16 else { throw VoiceTransportCipherError.malformedPacket }
            let ciphertext = authenticatedCiphertext.dropLast(16)
            let tag = authenticatedCiphertext.suffix(16)
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonce),
                    ciphertext: ciphertext,
                    tag: tag
                )
                plaintext = try AES.GCM.open(
                    box,
                    using: SymmetricKey(data: key),
                    authenticating: headerData
                )
            } catch {
                throw VoiceTransportCipherError.authenticationFailed
            }
        case .xChaCha20Poly1305RTPSize:
            let sodium = Sodium()
            guard let opened = sodium.aead.xchacha20poly1305ietf.decrypt(
                authenticatedCipherText: authenticatedCiphertext.bytes,
                secretKey: key,
                nonce: nonce,
                additionalData: headerData.bytes
            ) else { throw VoiceTransportCipherError.authenticationFailed }
            plaintext = Data(opened)
        }

        return plaintext
    }

    private func nonceBytes(suffix: Data) -> [UInt8] {
        let size = mode == .aes256GCMRTPSize ? 12 : 24
        return suffix.bytes + Array(repeating: 0, count: size - suffix.count)
    }
}

private extension UInt32 {
    var bigEndianBytes: Data {
        var data = Data()
        data.appendBigEndian(self)
        return data
    }
}

private extension Data {
    var bytes: [UInt8] {
        Array(self)
    }
}
