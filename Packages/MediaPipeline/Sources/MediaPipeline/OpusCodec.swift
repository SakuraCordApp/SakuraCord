import AudioToolbox
import AVFAudio
import Foundation

public final class OpusCodec: @unchecked Sendable {
    public static let sampleRate: Double = 48000
    public static let channels: AVAudioChannelCount = 2
    public static let frameSamples: AVAudioFrameCount = 960
    public static let maximumPacketSize = 1275

    public nonisolated static var pcmFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    private let encoderOpusFormat: AVAudioFormat
    private let decoderOpusFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter
    private let lock = NSLock()

    public init(bitRate: Int = 64000) throws {
        var encoderDescription = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: Self.frameSamples,
            mBytesPerFrame: 0,
            mChannelsPerFrame: Self.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var decoderDescription = encoderDescription
        decoderDescription.mFramesPerPacket = 0
        guard let encoderOpusFormat = AVAudioFormat(streamDescription: &encoderDescription),
              let decoderOpusFormat = AVAudioFormat(streamDescription: &decoderDescription),
              let encoder = AVAudioConverter(from: Self.pcmFormat, to: encoderOpusFormat),
              let decoder = AVAudioConverter(from: decoderOpusFormat, to: Self.pcmFormat)
        else {
            throw OpusCodecError.converterUnavailable
        }
        encoder.bitRate = bitRate
        self.encoderOpusFormat = encoderOpusFormat
        self.decoderOpusFormat = decoderOpusFormat
        self.encoder = encoder
        self.decoder = decoder
    }

    public func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        try lock.withLock { try encodeLocked(buffer) }
    }

    private func encodeLocked(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.format == Self.pcmFormat,
              buffer.frameLength == Self.frameSamples
        else {
            throw OpusCodecError.invalidPCMFrame
        }
        let output = AVAudioCompressedBuffer(
            format: encoderOpusFormat,
            packetCapacity: 1,
            maximumPacketSize: Self.maximumPacketSize
        )
        var supplied = false
        var conversionError: NSError?
        let status = encoder.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw conversionError
        }
        guard output.byteLength > 0 else {
            throw OpusCodecError.noOutput(status: status.rawValue, bytes: output.byteLength)
        }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }

    public func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        try lock.withLock { try decodeLocked(packet) }
    }

    private func decodeLocked(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard !packet.isEmpty, packet.count <= Self.maximumPacketSize else { throw OpusCodecError.invalidPacket }
        let packetSamples = try OpusPacket.sampleCount(packet)
        let input = AVAudioCompressedBuffer(
            format: decoderOpusFormat,
            packetCapacity: 1,
            maximumPacketSize: Self.maximumPacketSize
        )
        packet.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        if let descriptions = input.packetDescriptions {
            descriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: packetSamples,
                mDataByteSize: UInt32(packet.count)
            )
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.pcmFormat,
            frameCapacity: packetSamples
        ) else { throw OpusCodecError.noOutput(status: -1, bytes: 0) }
        var supplied = false
        var conversionError: NSError?
        let status = decoder.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw conversionError
        }
        guard output.frameLength > 0 else {
            throw OpusCodecError.noOutput(status: status.rawValue, bytes: output.frameLength)
        }
        return output
    }
}

enum OpusPacket {
    static let maximumSamples = AVAudioFrameCount(OpusCodec.sampleRate * 0.12)

    static func sampleCount(_ packet: Data) throws -> AVAudioFrameCount {
        guard let toc = packet.first else { throw OpusCodecError.invalidPacket }
        let configuration = Int(toc >> 3)
        let samplesPerFrame: Int
        switch configuration {
        case 0 ... 11:
            samplesPerFrame = [480, 960, 1_920, 2_880][configuration % 4]
        case 12 ... 15:
            samplesPerFrame = [480, 960][configuration % 2]
        default:
            samplesPerFrame = [120, 240, 480, 960][configuration % 4]
        }

        let frameCount: Int
        switch toc & 0x03 {
        case 0:
            frameCount = 1
        case 1, 2:
            frameCount = 2
        default:
            guard packet.count >= 2 else { throw OpusCodecError.invalidPacket }
            frameCount = Int(packet[packet.index(after: packet.startIndex)] & 0x3F)
        }
        let sampleCount = samplesPerFrame * frameCount
        guard frameCount > 0,
              sampleCount <= Int(maximumSamples)
        else { throw OpusCodecError.invalidPacket }
        return AVAudioFrameCount(sampleCount)
    }
}

public enum OpusCodecError: Error, Equatable {
    case converterUnavailable
    case invalidPCMFrame
    case invalidPacket
    case noOutput(status: Int, bytes: UInt32)
}
