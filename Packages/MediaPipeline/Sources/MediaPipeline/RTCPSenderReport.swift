import Foundation

struct RTCPSenderReport: Equatable, Sendable {
    var ssrc: UInt32
    var rtpTimestamp: UInt32
    var packetCount: UInt32
    var octetCount: UInt32
    var date: Date

    var header: Data {
        var data = Data([0x80, 200])
        data.appendBigEndian(UInt16(6))
        data.appendBigEndian(ssrc)
        return data
    }

    var payload: Data {
        let ntp = date.timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(max(0, ntp.rounded(.down)))
        let fraction = UInt32((ntp - ntp.rounded(.down)) * 4_294_967_296)
        var data = Data()
        data.appendBigEndian(seconds)
        data.appendBigEndian(fraction)
        data.appendBigEndian(rtpTimestamp)
        data.appendBigEndian(packetCount)
        data.appendBigEndian(octetCount)
        return data
    }
}

struct RTCPSenderTracker: Sendable {
    private(set) var packetCount: UInt32 = 0
    private(set) var octetCount: UInt32 = 0
    private var lastReportDate = Date.distantPast

    mutating func record(packets: Int, octets: Int) {
        packetCount &+= UInt32(clamping: packets)
        octetCount &+= UInt32(clamping: octets)
    }

    mutating func reportIfDue(ssrc: UInt32, rtpTimestamp: UInt32, now: Date = .now) -> RTCPSenderReport? {
        guard now.timeIntervalSince(lastReportDate) >= 1 else { return nil }
        lastReportDate = now
        return RTCPSenderReport(
            ssrc: ssrc,
            rtpTimestamp: rtpTimestamp,
            packetCount: packetCount,
            octetCount: octetCount,
            date: now
        )
    }
}
