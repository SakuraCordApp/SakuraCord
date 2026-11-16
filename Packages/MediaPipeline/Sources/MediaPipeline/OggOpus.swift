import Foundation

/// Muxes encoded Opus packets into an Ogg Opus stream (RFC 7845).
///
/// Apple's toolchain encodes Opus but cannot write the Ogg container that
/// Discord requires for voice messages; it writes only CAF.
public struct OggOpusWriter: Sendable {
    /// Discord's own voice recordings are mono at 48 kHz.
    public let channelCount: UInt8
    /// Samples of encoder delay to discard at the start of playback.
    public let preSkip: UInt16
    public let serialNumber: UInt32

    private(set) var data = Data()
    private var pageSequence: UInt32 = 0
    private var pendingSegments: [UInt8] = []
    private var pendingBody = Data()
    /// Granule position of the last packet completed in the pending page.
    private var pendingGranule: Int64 = 0
    private var pendingPacketCount = 0
    private var encodedSamples: Int64 = 0

    /// Pages carry about one second of 20 ms packets, as Discord's do.
    static let packetsPerPage = 50

    public init(channelCount: UInt8 = 1, preSkip: UInt16, serialNumber: UInt32 = .random(in: .min ... .max)) {
        self.channelCount = channelCount
        self.preSkip = preSkip
        self.serialNumber = serialNumber
        writeHeaders()
    }

    public mutating func append(packet: Data, samples: Int) {
        // Pages are flushed lazily so the end-of-stream page always carries
        // the final packet; Apple's Ogg parser rejects an empty EOS page.
        if pendingPacketCount >= Self.packetsPerPage || pendingSegments.count > 255 - 6 {
            flushPage(final: false, granule: pendingGranule)
        }
        encodedSamples += Int64(samples)
        var remaining = packet.count
        // A packet whose length is a multiple of 255 ends with a zero lacing value.
        repeat {
            let lace = min(remaining, 255)
            pendingSegments.append(UInt8(lace))
            remaining -= lace
            if lace < 255 { break }
            if remaining == 0 {
                pendingSegments.append(0)
                break
            }
        } while true
        pendingBody.append(packet)
        // The granule counts decoded samples, which include the pre-skip.
        pendingGranule = encodedSamples
        pendingPacketCount += 1
    }

    /// Completes the stream. `sampleCount` trims the encoder's trailing padding
    /// so the decoded duration matches the captured audio; the caller must
    /// have flushed at least `preSkip` samples of padding through the encoder.
    public mutating func finish(sampleCount: Int) -> Data {
        let granule = min(Int64(preSkip) + Int64(sampleCount), encodedSamples)
        flushPage(final: true, granule: granule)
        return data
    }

    private mutating func writeHeaders() {
        var head = Data("OpusHead".utf8)
        head.append(1)
        head.append(channelCount)
        head.appendLittleEndian(preSkip)
        head.appendLittleEndian(UInt32(48_000))
        head.appendLittleEndian(UInt16(0))
        head.append(0)
        writePage(body: head, segments: [UInt8(head.count)], headerType: 0x02, granule: 0)

        var tags = Data("OpusTags".utf8)
        let vendor = Data("SakuraCord".utf8)
        tags.appendLittleEndian(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLittleEndian(UInt32(0))
        writePage(body: tags, segments: [UInt8(tags.count)], headerType: 0, granule: 0)
    }

    private mutating func flushPage(final: Bool, granule: Int64) {
        guard final || !pendingSegments.isEmpty else { return }
        writePage(
            body: pendingBody,
            segments: pendingSegments,
            headerType: final ? 0x04 : 0,
            granule: granule
        )
        pendingSegments.removeAll(keepingCapacity: true)
        pendingBody.removeAll(keepingCapacity: true)
        pendingPacketCount = 0
    }

    private mutating func writePage(body: Data, segments: [UInt8], headerType: UInt8, granule: Int64) {
        var page = Data("OggS".utf8)
        page.append(0)
        page.append(headerType)
        page.appendLittleEndian(UInt64(bitPattern: granule))
        page.appendLittleEndian(serialNumber)
        page.appendLittleEndian(pageSequence)
        let checksumOffset = page.count
        page.appendLittleEndian(UInt32(0))
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(body)
        let checksum = OggCRC.checksum(page)
        page.replaceSubrange(checksumOffset ..< checksumOffset + 4, with: withUnsafeBytes(of: checksum.littleEndian) { Data($0) })
        data.append(page)
        pageSequence += 1
    }
}

private enum OggCRC {
    static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index) << 24
        for _ in 0 ..< 8 {
            value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { crc, byte in
            (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
    }
}

struct OggOpusParser {
    var audioPackets: [Data]
    var preSkip: Int
    var finalGranulePosition: UInt64?

    static func parse(_ data: Data) throws -> Self {
        var offset = 0
        var pendingPacket = Data()
        var packets: [Data] = []
        var finalGranulePosition: UInt64?
        while offset < data.count {
            guard offset + 27 <= data.count,
                  data[offset ..< offset + 4] == Data("OggS".utf8),
                  data[offset + 4] == 0
            else { throw SoundboardAudioError.invalidOgg }
            let granule = littleEndianUInt64(data, at: offset + 6)
            let segmentCount = Int(data[offset + 26])
            let segmentTableStart = offset + 27
            guard segmentTableStart + segmentCount <= data.count else {
                throw SoundboardAudioError.invalidOgg
            }
            let bodyStart = segmentTableStart + segmentCount
            let bodyLength = data[segmentTableStart ..< bodyStart].reduce(0) { $0 + Int($1) }
            guard bodyStart + bodyLength <= data.count else {
                throw SoundboardAudioError.invalidOgg
            }
            var bodyOffset = bodyStart
            for lengthByte in data[segmentTableStart ..< bodyStart] {
                let length = Int(lengthByte)
                pendingPacket.append(data[bodyOffset ..< bodyOffset + length])
                bodyOffset += length
                if length < 255 {
                    packets.append(pendingPacket)
                    pendingPacket.removeAll(keepingCapacity: true)
                }
            }
            if granule != UInt64.max { finalGranulePosition = granule }
            offset = bodyStart + bodyLength
        }
        guard pendingPacket.isEmpty,
              packets.count >= 3,
              packets[0].starts(with: Data("OpusHead".utf8)),
              packets[1].starts(with: Data("OpusTags".utf8)),
              packets[0].count >= 12
        else { throw SoundboardAudioError.invalidOgg }
        let preSkip = Int(packets[0][10]) | Int(packets[0][11]) << 8
        return Self(
            audioPackets: Array(packets.dropFirst(2)),
            preSkip: preSkip,
            finalGranulePosition: finalGranulePosition
        )
    }

    private static func littleEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0 ..< 8).reduce(into: UInt64(0)) { result, index in
            result |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
    }
}
