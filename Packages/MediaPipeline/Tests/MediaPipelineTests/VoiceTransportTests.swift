import Foundation
@testable import MediaPipeline
import Testing

@Test(arguments: VoiceTransportMode.allCases)
func `transport encryption round trips and authenticates RTP header`(mode: VoiceTransportMode) throws {
    let header = RTPHeader(
        payloadType: 120,
        sequence: 65530,
        timestamp: 123_456,
        ssrc: 42
    ).encoded
    var cipher = try VoiceTransportCipher(mode: mode, key: Array(0 ..< 32), initialNonce: 7)
    let opus = Data([0xF8, 0xFF, 0xFE])
    let packet = try cipher.seal(header: header, plaintext: opus)
    let opened = try cipher.open(packet: packet)

    #expect(opened.header.sequence == 65530)
    #expect(opened.header.ssrc == 42)
    #expect(opened.payload == opus)
    #expect(packet.suffix(4) == Data([0, 0, 0, 8]))

    var tampered = packet
    tampered[2] ^= 1
    #expect(throws: VoiceTransportCipherError.authenticationFailed) {
        _ = try cipher.open(packet: tampered)
    }
}

@Test func `rtp size mode authenticates extension preamble and encrypts extension data`() throws {
    let header = RTPHeader(
        payloadType: 120,
        sequence: 1,
        timestamp: 960,
        ssrc: 99,
        csrcs: [4],
        extensionProfile: 0xBEDE,
        extensionLengthInWords: 1
    )
    var cipher = try VoiceTransportCipher(mode: .aes256GCMRTPSize, key: Array(repeating: 9, count: 32))
    let extensionData = Data([1, 2, 3, 4])
    let opus = Data([5, 6, 7])
    let packet = try cipher.seal(header: header.encoded, plaintext: extensionData + opus)
    let opened = try cipher.open(packet: packet)

    #expect(opened.header.csrcs == [4])
    #expect(opened.header.extensionProfile == 0xBEDE)
    #expect(opened.payload == opus)
}

@Test func `rtp size mode strips authenticated RTP padding before media decode`() throws {
    let header = RTPHeader(
        padding: true,
        payloadType: 101,
        sequence: 12,
        timestamp: 90000,
        ssrc: 77
    )
    var cipher = try VoiceTransportCipher(
        mode: .aes256GCMRTPSize,
        key: Array(repeating: 3, count: 32)
    )
    let media = Data([0x65, 1, 2, 3])
    let padding = Data([0, 0, 0, 4])
    let packet = try cipher.seal(header: header.encoded, plaintext: media + padding)
    let opened = try cipher.open(packet: packet)

    #expect(opened.header.padding)
    #expect(opened.payload == media)
}

@Test(arguments: VoiceTransportMode.allCases)
func `transport encryption round trips RTCP feedback`(mode: VoiceTransportMode) throws {
    let nack = RTCPGenericNACK(
        senderSSRC: 42,
        mediaSSRC: 99,
        lostSequences: [500, 501, 517]
    )
    var cipher = try VoiceTransportCipher(mode: mode, key: Array(repeating: 7, count: 32))
    let packet = try cipher.seal(header: nack.header, plaintext: nack.payload)
    let opened = try cipher.openRTCP(packet: packet)
    let decoded = try #require(RTCPGenericNACK.parse(header: opened.header, payload: opened.payload))

    #expect(decoded == nack)
}
