import Foundation

struct RTCPHeader: Equatable, Sendable {
    var countOrFormat: UInt8
    var packetType: UInt8
    var lengthInWordsMinusOne: UInt16
    var senderSSRC: UInt32

    var encoded: Data {
        var data = Data([0x80 | (countOrFormat & 0x1F), packetType])
        data.appendBigEndian(lengthInWordsMinusOne)
        data.appendBigEndian(senderSSRC)
        return data
    }

    static func parse(from packet: Data) -> RTCPHeader? {
        guard packet.count >= 8,
              packet[0] >> 6 == 2,
              let length = packet.readUInt16BigEndian(at: 2),
              let senderSSRC = packet.readUInt32BigEndian(at: 4) else { return nil }
        return RTCPHeader(
            countOrFormat: packet[0] & 0x1F,
            packetType: packet[1],
            lengthInWordsMinusOne: length,
            senderSSRC: senderSSRC
        )
    }

    static func looksLikeRTCP(_ packet: Data) -> Bool {
        guard packet.count >= 8, packet[0] >> 6 == 2 else { return false }
        return (200 ... 206).contains(packet[1])
    }
}

struct RTCPGenericNACK: Equatable, Sendable {
    var senderSSRC: UInt32
    var mediaSSRC: UInt32
    var lostSequences: [UInt16]

    var header: Data {
        RTCPHeader(
            countOrFormat: 1,
            packetType: 205,
            lengthInWordsMinusOne: UInt16(clamping: 2 + entries.count),
            senderSSRC: senderSSRC
        ).encoded
    }

    var payload: Data {
        var data = Data()
        data.appendBigEndian(mediaSSRC)
        for entry in entries {
            data.appendBigEndian(entry.packetID)
            data.appendBigEndian(entry.bitmask)
        }
        return data
    }

    static func parse(header: RTCPHeader, payload: Data) -> RTCPGenericNACK? {
        guard header.packetType == 205,
              header.countOrFormat == 1,
              payload.count >= 8,
              (payload.count - 4).isMultiple(of: 4),
              let mediaSSRC = payload.readUInt32BigEndian(at: 0) else { return nil }
        var lost: [UInt16] = []
        var offset = 4
        while offset + 4 <= payload.count {
            guard let packetID = payload.readUInt16BigEndian(at: offset),
                  let bitmask = payload.readUInt16BigEndian(at: offset + 2) else { return nil }
            lost.append(packetID)
            for bit in 0 ..< 16 where bitmask & (UInt16(1) << UInt16(bit)) != 0 {
                lost.append(packetID &+ UInt16(bit + 1))
            }
            offset += 4
        }
        return RTCPGenericNACK(
            senderSSRC: header.senderSSRC,
            mediaSSRC: mediaSSRC,
            lostSequences: lost
        )
    }

    private struct Entry: Equatable {
        var packetID: UInt16
        var bitmask: UInt16
    }

    private var entries: [Entry] {
        var remaining: [UInt16] = []
        var seen = Set<UInt16>()
        for sequence in lostSequences where seen.insert(sequence).inserted {
            remaining.append(sequence)
        }

        var result: [Entry] = []
        while let packetID = remaining.first {
            remaining.removeFirst()
            var bitmask: UInt16 = 0
            remaining.removeAll { sequence in
                let distance = sequence &- packetID
                guard distance > 0, distance <= 16 else { return false }
                bitmask |= UInt16(1) << UInt16(distance - 1)
                return true
            }
            result.append(Entry(packetID: packetID, bitmask: bitmask))
        }
        return result
    }
}

struct RTCPPictureLossIndication: Equatable, Sendable {
    var senderSSRC: UInt32
    var mediaSSRC: UInt32

    var header: Data {
        RTCPHeader(
            countOrFormat: 1,
            packetType: 206,
            lengthInWordsMinusOne: 2,
            senderSSRC: senderSSRC
        ).encoded
    }

    var payload: Data {
        var data = Data()
        data.appendBigEndian(mediaSSRC)
        return data
    }

    static func parse(header: RTCPHeader, payload: Data) -> RTCPPictureLossIndication? {
        guard header.packetType == 206,
              header.countOrFormat == 1,
              payload.count >= 4,
              let mediaSSRC = payload.readUInt32BigEndian(at: 0) else { return nil }
        return RTCPPictureLossIndication(senderSSRC: header.senderSSRC, mediaSSRC: mediaSSRC)
    }
}

struct RTPRetransmissionPacket: Equatable, Sendable {
    var sequence: UInt16
    var timestamp: UInt32
    var marker: Bool
    var payload: Data
}

struct RTPRetransmissionCache: Sendable {
    private let capacity: Int
    private var order: [UInt16?]
    private var nextEvictionIndex = 0
    private var cachedPacketCount = 0
    private var packets: [UInt16: RTPRetransmissionPacket] = [:]

    init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
        order = Array(repeating: nil, count: max(1, capacity))
    }

    mutating func insert(_ packet: RTPRetransmissionPacket) {
        if packets[packet.sequence] == nil {
            if cachedPacketCount == capacity, let evicted = order[nextEvictionIndex] {
                packets[evicted] = nil
            } else {
                cachedPacketCount += 1
            }
            order[nextEvictionIndex] = packet.sequence
            nextEvictionIndex = (nextEvictionIndex + 1) % capacity
        }
        packets[packet.sequence] = packet
    }

    func packet(sequence: UInt16) -> RTPRetransmissionPacket? {
        packets[sequence]
    }

    mutating func removeAll() {
        order = Array(repeating: nil, count: capacity)
        nextEvictionIndex = 0
        cachedPacketCount = 0
        packets.removeAll(keepingCapacity: true)
    }
}
