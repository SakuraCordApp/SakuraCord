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
