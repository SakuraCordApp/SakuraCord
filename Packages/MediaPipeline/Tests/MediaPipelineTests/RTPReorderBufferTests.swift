import Foundation
@testable import MediaPipeline
import Testing

@Test func `rtp reorder buffer restores sequence and handles wraparound`() {
    var buffer = RTPReorderBuffer(maximumHold: 3)
    func packet(_ sequence: UInt16) -> RTPBufferedPacket {
        RTPBufferedPacket(
            header: RTPHeader(payloadType: 120, sequence: sequence, timestamp: UInt32(sequence), ssrc: 1),
            payload: Data([UInt8(truncatingIfNeeded: sequence)])
        )
    }
    #expect(buffer.insert(packet(65534)).map(\.header.sequence) == [65534])
    #expect(buffer.insert(packet(0)).isEmpty)
    #expect(buffer.insert(packet(65535)).map(\.header.sequence) == [65535, 0])
    #expect(buffer.insert(packet(0)).isEmpty)
}

@Test func `rtp reorder buffer skips A confirmed gap`() {
    var buffer = RTPReorderBuffer(maximumHold: 3)
    func packet(_ sequence: UInt16) -> RTPBufferedPacket {
        RTPBufferedPacket(
            header: RTPHeader(payloadType: 101, sequence: sequence, timestamp: 1, ssrc: 1),
            payload: Data([1])
        )
    }
    #expect(buffer.insert(packet(10)).map(\.header.sequence) == [10])
    #expect(buffer.insert(packet(12)).isEmpty)
    #expect(buffer.takeNewMissingSequences() == [11])
    #expect(buffer.insert(packet(13)).isEmpty)
    #expect(buffer.takeNewMissingSequences().isEmpty)
    #expect(buffer.insert(packet(14)).map(\.header.sequence) == [12, 13, 14])
    let didSkipGap = buffer.takeSkippedGap()
    let didSkipAgain = buffer.takeSkippedGap()
    #expect(didSkipGap)
    #expect(!didSkipAgain)
}

@Test func `rtp reorder buffer clears pending NACK when retransmission arrives`() {
    var buffer = RTPReorderBuffer(maximumHold: 4)
    func packet(_ sequence: UInt16) -> RTPBufferedPacket {
        RTPBufferedPacket(
            header: RTPHeader(payloadType: 101, sequence: sequence, timestamp: 1, ssrc: 1),
            payload: Data([1])
        )
    }

    #expect(buffer.insert(packet(65535)).map(\.header.sequence) == [65535])
    #expect(buffer.insert(packet(1)).isEmpty)
    #expect(buffer.takeNewMissingSequences() == [0])
    #expect(buffer.insert(packet(0)).map(\.header.sequence) == [0, 1])
    #expect(buffer.takeNewMissingSequences().isEmpty)
    let didSkipGap = buffer.takeSkippedGap()
    #expect(!didSkipGap)
}
