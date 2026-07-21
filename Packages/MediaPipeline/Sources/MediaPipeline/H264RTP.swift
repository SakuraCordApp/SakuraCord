import Foundation

public struct H264RTPFragment: Equatable, Sendable {
    public var payload: Data
    public var marker: Bool
}

public enum H264RTPError: Error, Equatable {
    case malformedFrame
    case malformedPacket
}

public enum H264RTPPacketizer {
    public static func packetize(_ annexBFrame: Data, maximumPayloadSize: Int = 1180) throws -> [H264RTPFragment] {
        guard maximumPayloadSize > 2 else { throw H264RTPError.malformedFrame }
        let nalUnits = AnnexB.split(frame: annexBFrame)
        guard !nalUnits.isEmpty else { throw H264RTPError.malformedFrame }
        var fragments: [H264RTPFragment] = []
        for nalu in nalUnits {
            guard let first = nalu.first else { continue }
            if nalu.count <= maximumPayloadSize {
                fragments.append(H264RTPFragment(payload: nalu, marker: false))
                continue
            }
            let indicator = (first & 0xE0) | 28
            let originalType = first & 0x1F
            var offset = 1
            let chunkSize = maximumPayloadSize - 2
            while offset < nalu.count {
                let end = min(offset + chunkSize, nalu.count)
                let isStart = offset == 1
                let isEnd = end == nalu.count
                let fuHeader = (isStart ? 0x80 : 0) | (isEnd ? 0x40 : 0) | originalType
                var payload = Data([indicator, fuHeader])
                payload.append(nalu[offset ..< end])
                fragments.append(H264RTPFragment(payload: payload, marker: false))
                offset = end
            }
        }
        guard !fragments.isEmpty else { throw H264RTPError.malformedFrame }
        fragments[fragments.count - 1].marker = true
        return fragments
    }
}

public struct H264RTPDepacketizer: Sendable {
    private var timestamp: UInt32?
    private var frame = Data()
    private var fragmentedNAL = Data()
    private var expectedSequence: UInt16?
    private var frameIsDamaged = false

    public init() {}

    public mutating func append(header: RTPHeader, payload: Data) throws -> Data? {
        guard let first = payload.first else { throw H264RTPError.malformedPacket }
        if timestamp != header.timestamp {
            timestamp = header.timestamp
            frame.removeAll(keepingCapacity: true)
            fragmentedNAL.removeAll(keepingCapacity: true)
            expectedSequence = nil
            frameIsDamaged = false
        }
        if let expectedSequence, expectedSequence != header.sequence {
            frame.removeAll(keepingCapacity: true)
            fragmentedNAL.removeAll(keepingCapacity: true)
            frameIsDamaged = true
        }
        expectedSequence = header.sequence &+ 1

        if frameIsDamaged {
            if header.marker {
                frameIsDamaged = false
                expectedSequence = nil
            }
            return nil
        }

        switch first & 0x1F {
        case 1 ... 23:
            AnnexB.append(nalUnit: payload, to: &frame)
        case 24:
            try appendAggregationPacket(payload)
        case 28:
            try appendFragmentationUnit(payload)
        default:
            throw H264RTPError.malformedPacket
        }

        guard header.marker, fragmentedNAL.isEmpty, !frame.isEmpty else { return nil }
        let completed = frame
        frame.removeAll(keepingCapacity: true)
        expectedSequence = nil
        return completed
    }

    private mutating func appendAggregationPacket(_ payload: Data) throws {
        var offset = 1
        while offset < payload.count {
            guard let length = payload.readUInt16BigEndian(at: offset), length > 0 else {
                throw H264RTPError.malformedPacket
            }
            offset += 2
            let end = offset + Int(length)
            guard end <= payload.count else { throw H264RTPError.malformedPacket }
            let lowerBound = payload.index(payload.startIndex, offsetBy: offset)
            let upperBound = payload.index(payload.startIndex, offsetBy: end)
            AnnexB.append(nalUnit: payload[lowerBound ..< upperBound], to: &frame)
            offset = end
        }
    }

    private mutating func appendFragmentationUnit(_ payload: Data) throws {
        guard payload.count >= 3 else { throw H264RTPError.malformedPacket }
        let indicator = payload[payload.startIndex]
        let fuHeader = payload[payload.index(after: payload.startIndex)]
        let isStart = fuHeader & 0x80 != 0
        let isEnd = fuHeader & 0x40 != 0
        if isStart {
            fragmentedNAL = Data([(indicator & 0xE0) | (fuHeader & 0x1F)])
        } else if fragmentedNAL.isEmpty {
            throw H264RTPError.malformedPacket
        }
        fragmentedNAL.append(payload.dropFirst(2))
        if isEnd {
            AnnexB.append(nalUnit: fragmentedNAL, to: &frame)
            fragmentedNAL.removeAll(keepingCapacity: true)
        }
    }
}

enum AnnexB {
    static let startCode = Data([0, 0, 0, 1])

    static func split(frame: Data) -> [Data] {
        let bytes = [UInt8](frame)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1
            {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { item -> Data? in
            let (position, start) = item
            let begin = start.offset + start.length
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard begin < end else { return nil }
            return Data(bytes[begin ..< end])
        }
    }

    static func append(nalUnit: some Sequence<UInt8>, to frame: inout Data) {
        frame.append(startCode)
        frame.append(contentsOf: nalUnit)
    }

    static func isKeyframe(_ frame: Data) -> Bool {
        split(frame: frame).contains { nalu in
            nalu.first.map { $0 & 0x1F == 5 } ?? false
        }
    }
}
