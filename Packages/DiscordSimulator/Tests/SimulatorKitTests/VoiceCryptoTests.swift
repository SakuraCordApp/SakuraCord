import CryptoKit
import Foundation
@testable import SimulatorKit
import Testing

/// The voice transport modes against their published test vectors: a wrong
/// key schedule here would make every packet the app sends or receives fail.
struct VoiceCryptoTests {
    static func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! }
    }

    @Test func hChaCha20MatchesTheDraftVector() {
        let subkey = VoiceCrypto.hChaCha20(key: Array(0 ..< 32), nonce: Self.hex("000000090000004a0000000031415927"))
        #expect(subkey == Self.hex("82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc"))
    }

    @Test func xChaCha20Poly1305MatchesTheDraftVector() throws {
        let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let (subkey, nonce) = try VoiceCrypto.xChaChaParameters(key: Array(0x80 ... 0x9F), nonce: Data(Array(0x40 ... 0x57)))
        let box = try ChaChaPoly.seal(plaintext, using: subkey, nonce: nonce, authenticating: Self.hex("50515253c0c1c2c3c4c5c6c7"))
        #expect([UInt8](box.tag) == Self.hex("c0875924c1c7987947deafd8780acf49"))
    }

    @Test(arguments: VoiceCrypto.Mode.allCases)
    func packetsRoundTripAndRejectTampering(_ mode: VoiceCrypto.Mode) throws {
        let key = (0 ..< 32).map { UInt8($0 * 7 & 0xFF) }
        let header = VoiceMediaServer.rtpHeader(sequence: 9, timestamp: 960, ssrc: 0x1234)
        var packet = try VoiceCrypto.seal(header: header, payload: Data([0xFC, 1, 2, 3]), key: key, counter: 5, mode: mode)
        let opened = try VoiceCrypto.open(packet, key: key, mode: mode)
        #expect(opened.header == header && opened.body == Data([0xFC, 1, 2, 3]))
        #expect(packet.suffix(4) == Data([0, 0, 0, 5]))
        packet[packet.startIndex + 2] ^= 1
        #expect(throws: VoiceCrypto.Failure.self) { try VoiceCrypto.open(packet, key: key, mode: mode) }
    }
}
