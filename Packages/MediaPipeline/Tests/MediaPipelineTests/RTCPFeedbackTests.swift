import Foundation
@testable import MediaPipeline
import Testing

@Test func `generic NACK compacts and expands wraparound sequences`() throws {
    let nack = RTCPGenericNACK(
        senderSSRC: 10,
        mediaSSRC: 20,
        lostSequences: [65535, 0, 1, 22]
    )
    let header = try #require(RTCPHeader.parse(from: nack.header))

    #expect(header.packetType == 205)
    #expect(header.countOrFormat == 1)
    #expect(header.lengthInWordsMinusOne == 4)
    #expect(nack.payload == Data([
        0, 0, 0, 20,
        0xFF, 0xFF, 0, 3,
        0, 22, 0, 0
    ]))
    #expect(RTCPGenericNACK.parse(header: header, payload: nack.payload) == nack)
}

@Test func `retransmission cache evicts oldest packets`() {
    var cache = RTPRetransmissionCache(capacity: 2)
    for sequence in 1 ... 3 {
        cache.insert(RTPRetransmissionPacket(
            sequence: UInt16(sequence),
            timestamp: UInt32(sequence * 90),
            marker: sequence == 3,
            payload: Data([UInt8(sequence)])
        ))
    }

    #expect(cache.packet(sequence: 1) == nil)
    #expect(cache.packet(sequence: 2)?.payload == Data([2]))
    #expect(cache.packet(sequence: 3)?.marker == true)
}

@Test func `picture loss indication uses RFC 4585 payload specific feedback layout`() throws {
    let pli = RTCPPictureLossIndication(senderSSRC: 10, mediaSSRC: 20)
    let header = try #require(RTCPHeader.parse(from: pli.header))

    #expect(header.packetType == 206)
    #expect(header.countOrFormat == 1)
    #expect(header.lengthInWordsMinusOne == 2)
    #expect(pli.payload == Data([0, 0, 0, 20]))
    #expect(RTCPPictureLossIndication.parse(header: header, payload: pli.payload) == pli)
}
