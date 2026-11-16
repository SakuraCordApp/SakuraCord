import CryptoKit
import Foundation

/// Discord's voice transport encryption for the two `_rtpsize` modes
/// (discord.com/developers/docs/topics/voice-connections#transport-encryption-modes):
/// the RTP header, CSRCs and the 4-byte extension header are authenticated
/// data; the extension body and payload are encrypted; a 32-bit big-endian
/// counter follows the tag and fills the start of an otherwise zero nonce.
enum VoiceCrypto {
    enum Mode: String, CaseIterable, Sendable {
        case aes256GCM = "aead_aes256_gcm_rtpsize"
        case xChaCha20Poly1305 = "aead_xchacha20_poly1305_rtpsize"
    }

    enum Failure: Error { case truncated, authentication }

    static let tagLength = 16

    /// `header` and `payload` sealed into a packet, with `counter` as its nonce.
    static func seal(header: Data, payload: Data, key: [UInt8], counter: UInt32, mode: Mode) throws -> Data {
        let counterBytes = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        switch mode {
        case .aes256GCM:
            let box = try AES.GCM.seal(payload, using: SymmetricKey(data: key), nonce: try AES.GCM.Nonce(data: counterBytes + Data(count: 8)),
                                       authenticating: header)
            return header + box.ciphertext + box.tag + counterBytes
        case .xChaCha20Poly1305:
            let (subkey, nonce) = try xChaChaParameters(key: key, nonce: counterBytes + Data(count: 20))
            let box = try ChaChaPoly.seal(payload, using: subkey, nonce: nonce, authenticating: header)
            return header + box.ciphertext + box.tag + counterBytes
        }
    }

    /// The authenticated header and decrypted body (extension body, then payload) of a packet.
    static func open(_ packet: Data, key: [UInt8], mode: Mode) throws -> (header: Data, body: Data) {
        let packet = Data(packet)
        let headerLength = try authenticatedHeaderLength(packet)
        guard packet.count >= headerLength + tagLength + 4 else { throw Failure.truncated }
        let header = packet.prefix(headerLength)
        let counterBytes = packet.suffix(4)
        let ciphertext = packet[headerLength ..< packet.count - 4 - tagLength]
        let tag = packet[packet.count - 4 - tagLength ..< packet.count - 4]
        do {
            switch mode {
            case .aes256GCM:
                let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: counterBytes + Data(count: 8)), ciphertext: ciphertext, tag: tag)
                return (Data(header), try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header))
            case .xChaCha20Poly1305:
                let (subkey, nonce) = try xChaChaParameters(key: key, nonce: counterBytes + Data(count: 20))
                let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                return (Data(header), try ChaChaPoly.open(box, using: subkey, authenticating: header))
            }
        } catch {
            throw Failure.authentication
        }
    }

    /// Fixed header, CSRCs and, when the extension bit is set, the 4-byte extension header.
    static func authenticatedHeaderLength(_ packet: Data) throws -> Int {
        guard packet.count >= 12 else { throw Failure.truncated }
        let first = packet[packet.startIndex]
        let length = 12 + Int(first & 0x0F) * 4 + (first & 0x10 != 0 ? 4 : 0)
        guard packet.count >= length else { throw Failure.truncated }
        return length
    }

    /// XChaCha20-Poly1305 as ChaCha20-Poly1305 under an HChaCha20 subkey (draft-irtf-cfrg-xchacha).
    static func xChaChaParameters(key: [UInt8], nonce: Data) throws -> (SymmetricKey, ChaChaPoly.Nonce) {
        let nonce = [UInt8](nonce)
        let subkey = hChaCha20(key: key, nonce: Array(nonce[0 ..< 16]))
        return (SymmetricKey(data: subkey), try ChaChaPoly.Nonce(data: [0, 0, 0, 0] + nonce[16 ..< 24]))
    }

    static func hChaCha20(key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        func word(_ bytes: [UInt8], _ index: Int) -> UInt32 {
            (0 ..< 4).reduce(0) { $0 | UInt32(bytes[index * 4 + $1]) << (8 * $1) }
        }
        var state: [UInt32] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]
            + (0 ..< 8).map { word(key, $0) } + (0 ..< 4).map { word(nonce, $0) }
        func quarterRound(_ wa: Int, _ wb: Int, _ wc: Int, _ wd: Int) {
            state[wa] &+= state[wb]; state[wd] ^= state[wa]; state[wd] = state[wd] << 16 | state[wd] >> 16
            state[wc] &+= state[wd]; state[wb] ^= state[wc]; state[wb] = state[wb] << 12 | state[wb] >> 20
            state[wa] &+= state[wb]; state[wd] ^= state[wa]; state[wd] = state[wd] << 8 | state[wd] >> 24
            state[wc] &+= state[wd]; state[wb] ^= state[wc]; state[wb] = state[wb] << 7 | state[wb] >> 25
        }
        for _ in 0 ..< 10 {
            quarterRound(0, 4, 8, 12); quarterRound(1, 5, 9, 13); quarterRound(2, 6, 10, 14); quarterRound(3, 7, 11, 15)
            quarterRound(0, 5, 10, 15); quarterRound(1, 6, 11, 12); quarterRound(2, 7, 8, 13); quarterRound(3, 4, 9, 14)
        }
        return [0, 1, 2, 3, 12, 13, 14, 15].flatMap { index in (0 ..< 4).map { UInt8(truncatingIfNeeded: state[index] >> (8 * $0)) } }
    }
}
