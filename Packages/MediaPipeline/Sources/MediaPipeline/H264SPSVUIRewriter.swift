import Foundation

/// Normalizes VideoToolbox SPS VUI metadata for WebRTC receivers. Discord's
/// receiver requires an explicit zero-reorder restriction even when the encoder
/// itself is configured with frame reordering disabled.
enum H264SPSVUIRewriter {
    static func rewriteAnnexBFrame(_ frame: Data) -> Data {
        let nalUnits = AnnexB.split(frame: frame)
        guard !nalUnits.isEmpty else { return frame }
        var output = Data()
        for nalUnit in nalUnits {
            let rewritten: Data = if nalUnit.first.map({ $0 & 0x1F }) == 7 {
                rewriteSPS(nalUnit) ?? nalUnit
            } else {
                nalUnit
            }
            AnnexB.append(nalUnit: rewritten, to: &output)
        }
        return output
    }

    private static func rewriteSPS(_ nalUnit: Data) -> Data? {
        guard nalUnit.count > 4, let nalHeader = nalUnit.first else { return nil }
        var reader = BitReader(data: removeEmulationPrevention(Data(nalUnit.dropFirst())))
        var writer = BitWriter()

        guard let profileIDC = reader.readBits(8) else { return nil }
        writer.writeBits(profileIDC, count: 8)
        guard let constraints = reader.readBits(8) else { return nil }
        writer.writeBits(constraints, count: 8)
        guard let levelIDC = reader.readBits(8) else { return nil }
        writer.writeBits(levelIDC, count: 8)
        guard copyUE(from: &reader, to: &writer) != nil else { return nil }

        // SakuraCord deliberately emits constrained Baseline. Refuse to rewrite a
        // high-profile SPS unless its extra syntax is explicitly supported.
        let highProfiles: Set<UInt64> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 144]
        guard !highProfiles.contains(profileIDC) else { return nil }

        guard copyUE(from: &reader, to: &writer) != nil else { return nil } // log2_max_frame_num_minus4
        guard let picOrderCountType = copyUE(from: &reader, to: &writer) else { return nil }
        if picOrderCountType == 0 {
            guard copyUE(from: &reader, to: &writer) != nil else { return nil }
        } else if picOrderCountType == 1 {
            guard copyBits(1, from: &reader, to: &writer) else { return nil }
            guard copySE(from: &reader, to: &writer), copySE(from: &reader, to: &writer) else { return nil }
            guard let cycleCount = copyUE(from: &reader, to: &writer) else { return nil }
            for _ in 0 ..< cycleCount {
                guard copySE(from: &reader, to: &writer) else { return nil }
            }
        }

        guard let maxReferenceFrames = copyUE(from: &reader, to: &writer) else { return nil }
        guard copyBits(1, from: &reader, to: &writer) else { return nil } // gaps_in_frame_num_value_allowed_flag
        guard copyUE(from: &reader, to: &writer) != nil else { return nil } // width
        guard copyUE(from: &reader, to: &writer) != nil else { return nil } // height
        guard let frameOnly = reader.readBits(1) else { return nil }
        writer.writeBits(frameOnly, count: 1)
        if frameOnly == 0, !copyBits(1, from: &reader, to: &writer) {
            return nil
        }
        guard copyBits(1, from: &reader, to: &writer) else { return nil } // direct_8x8_inference_flag
        guard let cropping = reader.readBits(1) else { return nil }
        writer.writeBits(cropping, count: 1)
        if cropping != 0 {
            for _ in 0 ..< 4 {
                guard copyUE(from: &reader, to: &writer) != nil else { return nil }
            }
        }

        // Replace any existing VUI. The fields before this point define the
        // coded picture and remain byte-for-byte equivalent at the bit level.
        guard reader.readBits(1) != nil else { return nil }
        writer.writeBits(1, count: 1) // vui_parameters_present_flag
        writer.writeBits(0, count: 2) // aspect ratio, overscan
        writer.writeBits(0, count: 1) // video signal type
        writer.writeBits(0, count: 5) // chroma location, timing, HRD x2, pic structure
        writer.writeBits(1, count: 1) // bitstream_restriction_flag
        writer.writeBits(1, count: 1) // motion_vectors_over_pic_boundaries_flag
        writer.writeUE(2) // max_bytes_per_pic_denom
        writer.writeUE(1) // max_bits_per_mb_denom
        writer.writeUE(16) // log2_max_mv_length_horizontal
        writer.writeUE(16) // log2_max_mv_length_vertical
        writer.writeUE(0) // max_num_reorder_frames
        writer.writeUE(maxReferenceFrames) // max_dec_frame_buffering
        let rbsp = writer.finishRBSP()

        var rewritten = Data([nalHeader])
        rewritten.append(addEmulationPrevention(rbsp))
        return rewritten
    }

    @discardableResult
    private static func copyUE(from reader: inout BitReader, to writer: inout BitWriter) -> UInt64? {
        guard let value = reader.readUE() else { return nil }
        writer.writeUE(value)
        return value
    }

    private static func copySE(from reader: inout BitReader, to writer: inout BitWriter) -> Bool {
        guard let value = reader.readUE() else { return false }
        writer.writeUE(value)
        return true
    }

    private static func copyBits(_ count: Int, from reader: inout BitReader, to writer: inout BitWriter) -> Bool {
        guard let value = reader.readBits(count) else { return false }
        writer.writeBits(value, count: count)
        return true
    }

    private static func removeEmulationPrevention(_ data: Data) -> Data {
        var output = Data()
        var zeroCount = 0
        for byte in data {
            if zeroCount >= 2, byte == 0x03 {
                continue
            }
            output.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return output
    }

    private static func addEmulationPrevention(_ data: Data) -> Data {
        var output = Data()
        var zeroCount = 0
        for byte in data {
            if zeroCount >= 2, byte <= 0x03 {
                output.append(0x03)
                zeroCount = 0
            }
            output.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return output
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func readBits(_ count: Int) -> UInt64? {
        guard count >= 0, count <= 64, bitOffset + count <= bytes.count * 8 else { return nil }
        var value: UInt64 = 0
        for _ in 0 ..< count {
            let byte = bytes[bitOffset / 8]
            let shift = 7 - (bitOffset % 8)
            value = (value << 1) | UInt64((byte >> shift) & 1)
            bitOffset += 1
        }
        return value
    }

    mutating func readUE() -> UInt64? {
        var leadingZeros = 0
        while true {
            guard let bit = readBits(1) else { return nil }
            if bit == 1 {
                break
            }
            leadingZeros += 1
            guard leadingZeros < 63 else { return nil }
        }
        guard leadingZeros > 0 else { return 0 }
        guard let suffix = readBits(leadingZeros) else { return nil }
        return (UInt64(1) << leadingZeros) - 1 + suffix
    }
}

private struct BitWriter {
    private var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var bitCount = 0

    mutating func writeBits(_ value: UInt64, count: Int) {
        guard count > 0 else { return }
        for bitIndex in stride(from: count - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> bitIndex) & 1)
            bitCount += 1
            if bitCount == 8 {
                bytes.append(current)
                current = 0
                bitCount = 0
            }
        }
    }

    mutating func writeUE(_ value: UInt64) {
        let codeNumber = value + 1
        let bitLength = 64 - codeNumber.leadingZeroBitCount
        writeBits(0, count: bitLength - 1)
        writeBits(codeNumber, count: bitLength)
    }

    mutating func finishRBSP() -> Data {
        writeBits(1, count: 1)
        if bitCount != 0 {
            writeBits(0, count: 8 - bitCount)
        }
        return Data(bytes)
    }
}
