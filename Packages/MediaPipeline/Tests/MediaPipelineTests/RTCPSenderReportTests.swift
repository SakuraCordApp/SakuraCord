import Foundation
@testable import MediaPipeline
import Testing

@Test func `rtcp sender report uses RFC 3550 layout`() throws {
    var tracker = RTCPSenderTracker()
    tracker.record(packets: 3, octets: 1500)
    let date = Date(timeIntervalSince1970: 1_700_000_000.5)
    let pendingReport = tracker.reportIfDue(ssrc: 42, rtpTimestamp: 90000, now: date)
    let report = try #require(pendingReport)
    #expect(report.header == Data([0x80, 200, 0, 6, 0, 0, 0, 42]))
    #expect(report.payload.count == 20)
    #expect(report.payload.readUInt32BigEndian(at: 8) == 90000)
    #expect(report.payload.readUInt32BigEndian(at: 12) == 3)
    #expect(report.payload.readUInt32BigEndian(at: 16) == 1500)
    #expect(tracker.reportIfDue(ssrc: 42, rtpTimestamp: 90001, now: date.addingTimeInterval(0.5)) == nil)
}
