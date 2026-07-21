import Foundation

public struct RTPHeader: Equatable, Sendable {
    public var padding: Bool
    public var marker: Bool
    public var payloadType: UInt8
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var csrcs: [UInt32]
    public var extensionProfile: UInt16?
    public var extensionLengthInWords: UInt16?

    public init(
        padding: Bool = false,
        marker: Bool = false,
        payloadType: UInt8,
        sequence: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        csrcs: [UInt32] = [],
        extensionProfile: UInt16? = nil,
        extensionLengthInWords: UInt16? = nil
    ) {
        self.padding = padding
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.csrcs = Array(csrcs.prefix(15))
        self.extensionProfile = extensionProfile
        self.extensionLengthInWords = extensionLengthInWords
    }

    public var hasExtension: Bool {
        extensionProfile != nil && extensionLengthInWords != nil
    }

    public var encoded: Data {
        var data = Data()
        var first: UInt8 = 0x80 | UInt8(csrcs.count)
        if padding {
            first |= 0x20
        }
        if hasExtension {
            first |= 0x10
        }
        data.append(first)
        data.append((marker ? 0x80 : 0) | (payloadType & 0x7F))
        data.appendBigEndian(sequence)
        data.appendBigEndian(timestamp)
        data.appendBigEndian(ssrc)
        for csrc in csrcs {
            data.appendBigEndian(csrc)
        }
        if let extensionProfile, let extensionLengthInWords {
            data.appendBigEndian(extensionProfile)
            data.appendBigEndian(extensionLengthInWords)
        }
        return data
    }

    public static func parse(from packet: Data) -> (header: RTPHeader, headerSize: Int)? {
        guard packet.count >= 12 else { return nil }
        let first = packet[0]
        guard first >> 6 == 2 else { return nil }
        let csrcCount = Int(first & 0x0F)
        var offset = 12
        guard packet.count >= offset + csrcCount * 4 else { return nil }
        var csrcs: [UInt32] = []
        for _ in 0 ..< csrcCount {
            guard let value = packet.readUInt32BigEndian(at: offset) else { return nil }
            csrcs.append(value)
            offset += 4
        }
        var extensionProfile: UInt16?
        var extensionLength: UInt16?
        if first & 0x10 != 0 {
            guard packet.count >= offset + 4 else { return nil }
            extensionProfile = packet.readUInt16BigEndian(at: offset)
            extensionLength = packet.readUInt16BigEndian(at: offset + 2)
            offset += 4
        }
        guard
            let sequence = packet.readUInt16BigEndian(at: 2),
            let timestamp = packet.readUInt32BigEndian(at: 4),
            let ssrc = packet.readUInt32BigEndian(at: 8)
        else { return nil }
        return (
            RTPHeader(
                padding: first & 0x20 != 0,
                marker: packet[1] & 0x80 != 0,
                payloadType: packet[1] & 0x7F,
                sequence: sequence,
                timestamp: timestamp,
                ssrc: ssrc,
                csrcs: csrcs,
                extensionProfile: extensionProfile,
                extensionLengthInWords: extensionLength
            ),
            offset
        )
    }
}

extension Data {
    mutating func appendBigEndian(_ value: some FixedWidthInteger) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readUInt16BigEndian(at offset: Int) -> UInt16? {
        guard offset >= 0, count >= offset + 2 else { return nil }
        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return (UInt16(self[first]) << 8) | UInt16(self[second])
    }

    func readUInt32BigEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        let third = index(after: second)
        let fourth = index(after: third)
        return (UInt32(self[first]) << 24)
            | (UInt32(self[second]) << 16)
            | (UInt32(self[third]) << 8)
            | UInt32(self[fourth])
    }
}
