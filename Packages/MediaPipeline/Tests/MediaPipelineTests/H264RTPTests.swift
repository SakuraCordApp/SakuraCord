import Foundation
@testable import MediaPipeline
import Testing

@Test func `h 264 RTP round trips single and fragmented NAL units`() throws {
    var frame = Data([0, 0, 0, 1, 0x67, 1, 2, 3])
    frame.append(contentsOf: [0, 0, 1, 0x65])
    frame.append(Data(repeating: 0xAB, count: 4000))
    let fragments = try H264RTPPacketizer.packetize(frame, maximumPayloadSize: 500)
    #expect(fragments.count > 2)
    #expect(fragments.last?.marker == true)

    var depacketizer = H264RTPDepacketizer()
    var output: Data?
    for (index, fragment) in fragments.enumerated() {
        output = try depacketizer.append(
            header: RTPHeader(
                marker: fragment.marker,
                payloadType: 101,
                sequence: UInt16(index),
                timestamp: 90000,
                ssrc: 77
            ),
            payload: fragment.payload
        ) ?? output
    }
    #expect(try AnnexB.split(frame: #require(output)) == AnnexB.split(frame: frame))
}

@Test func `h 264 RTP depacketizer rejects orphaned fragment`() {
    var depacketizer = H264RTPDepacketizer()
    #expect(throws: H264RTPError.malformedPacket) {
        try depacketizer.append(
            header: RTPHeader(marker: true, payloadType: 101, sequence: 2, timestamp: 1, ssrc: 1),
            payload: Data([0x7C, 0x45, 1, 2])
        )
    }
}

@Test func `h 264 aggregation packet handles non zero data start index`() throws {
    var slicedPayload = Data([0xFF, 0xFF, 24, 0, 2, 0x67, 0x01, 0, 2, 0x65, 0x02])
    slicedPayload.removeFirst(2)
    var depacketizer = H264RTPDepacketizer()
    let frame = try depacketizer.append(
        header: RTPHeader(
            marker: true,
            payloadType: 101,
            sequence: 1,
            timestamp: 90000,
            ssrc: 42
        ),
        payload: slicedPayload
    )

    #expect(frame == Data([0, 0, 0, 1, 0x67, 0x01, 0, 0, 0, 1, 0x65, 0x02]))
}

@Test func `h 264 depacketizer drops entire frame after sequence gap`() throws {
    var depacketizer = H264RTPDepacketizer()
    let first = try depacketizer.append(
        header: RTPHeader(marker: false, payloadType: 101, sequence: 10, timestamp: 1, ssrc: 1),
        payload: Data([0x61, 1])
    )
    let damaged = try depacketizer.append(
        header: RTPHeader(marker: true, payloadType: 101, sequence: 12, timestamp: 1, ssrc: 1),
        payload: Data([0x61, 2])
    )
    let recovered = try depacketizer.append(
        header: RTPHeader(marker: true, payloadType: 101, sequence: 13, timestamp: 2, ssrc: 1),
        payload: Data([0x65, 3])
    )

    #expect(first == nil)
    #expect(damaged == nil)
    #expect(try AnnexB.isKeyframe(#require(recovered)))
}
