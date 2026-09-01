import Foundation
@testable import MediaPipeline
import Testing

@Test func `voice endpoint normalization uses gateway version eight`() throws {
    let url = try #require(VoiceGatewayConnection.endpointURL("voice.example.test:443"))
    #expect(url.scheme == "wss")
    #expect(url.host == "voice.example.test")
    #expect(url.port == 443)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "v", value: "8")])
}

@Test func `voice IP discovery uses documented seventy four byte packet`() {
    let request = VoiceIPDiscovery.request(ssrc: 0x0102_0304)
    #expect(request.count == 74)
    #expect(request.prefix(8) == Data([0, 1, 0, 70, 1, 2, 3, 4]))

    var response = Data([0, 2, 0, 70, 1, 2, 3, 4])
    response.append(Data("203.0.113.9".utf8))
    response.append(0)
    response.append(Data(repeating: 0, count: 63 - "203.0.113.9".utf8.count))
    response.append(contentsOf: [0xC3, 0x50])
    #expect(response.count == 74)
    #expect(VoiceIPDiscovery.parseResponse(response) == VoiceDiscoveredAddress(ip: "203.0.113.9", port: 50000))
}

@Test func `video datagram pacing limits each network submission`() {
    let sizes = Array(repeating: 1_200, count: 10)
    let plan = RTPDatagramPacingPlan.make(
        datagramSizes: sizes,
        bitsPerSecond: 9_000_000
    )

    #expect(plan.ranges == [0 ..< 4, 4 ..< 8, 8 ..< 10])
    #expect(plan.ranges.flatMap(Array.init) == Array(sizes.indices))
    #expect(plan.ranges.allSatisfy { range in
        range.reduce(0) { $0 + sizes[$1] } <= 5_625
    })
}

@Test func `video pacing drains packet overhead faster than encoded media arrives`() {
    let datagramSizes = Array(repeating: 1_200, count: 10)
    let wireRate = RTPDatagramPacingPlan.wireBitsPerSecond(
        mediaBitsPerSecond: 9_000_000,
        mediaByteCount: 11_000,
        datagramSizes: datagramSizes
    )

    #expect(wireRate == 10_799_999)
    let mediaDuration = Double(11_000 * 8) / 9_000_000
    let wireDuration = Double(datagramSizes.reduce(0, +) * 8) / Double(wireRate)
    #expect(wireDuration < mediaDuration)
}
