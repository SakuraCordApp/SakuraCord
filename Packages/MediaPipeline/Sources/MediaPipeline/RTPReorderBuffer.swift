import Foundation

struct RTPBufferedPacket: Equatable, Sendable {
    var header: RTPHeader
    var payload: Data
}

struct RTPReorderBuffer: Sendable {
    private var expectedSequence: UInt16?
    private var packets: [UInt16: RTPBufferedPacket] = [:]
    private var missingSequences = Set<UInt16>()
    private var newlyMissingSequences: [UInt16] = []
    private var skippedGap = false
    private let maximumHold: Int

    init(maximumHold: Int = 8) {
        self.maximumHold = max(1, maximumHold)
    }

    mutating func insert(_ packet: RTPBufferedPacket) -> [RTPBufferedPacket] {
        if expectedSequence == nil {
            expectedSequence = packet.header.sequence
        }
        guard let expectedSequence else { return [] }
        let distance = packet.header.sequence &- expectedSequence
        if missingSequences.remove(packet.header.sequence) != nil {
            newlyMissingSequences.removeAll { $0 == packet.header.sequence }
        }
        guard distance <= UInt16.max / 2 else { return [] }
        if distance > 0, distance <= 128 {
            for step in 0 ..< distance {
                let missing = expectedSequence &+ step
                if packets[missing] == nil, missingSequences.insert(missing).inserted {
                    newlyMissingSequences.append(missing)
                }
            }
        }
        packets[packet.header.sequence] = packet

        var output = drainContiguous()
        if output.isEmpty, packets.count >= maximumHold, let expected = self.expectedSequence {
            let next = packets.keys.min { ($0 &- expected) < ($1 &- expected) }
            if let next, next != expected {
                skippedGap = true
                missingSequences = Set(missingSequences.filter { sequence in
                    (sequence &- next) <= UInt16.max / 2
                })
            }
            self.expectedSequence = next
            output = drainContiguous()
        }
        return output
    }

    mutating func takeNewMissingSequences() -> [UInt16] {
        defer { newlyMissingSequences.removeAll(keepingCapacity: true) }
        return newlyMissingSequences
    }

    mutating func takeSkippedGap() -> Bool {
        defer { skippedGap = false }
        return skippedGap
    }

    private mutating func drainContiguous() -> [RTPBufferedPacket] {
        var output: [RTPBufferedPacket] = []
        while let expected = expectedSequence, let packet = packets.removeValue(forKey: expected) {
            output.append(packet)
            expectedSequence = expected &+ 1
        }
        return output
    }
}
