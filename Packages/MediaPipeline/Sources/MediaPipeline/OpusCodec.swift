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

    private let opusFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter
    private let lock = NSLock()

    public init(bitRate: Int = 64000) throws {
        var description = AudioStreamBasicDescription(
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
        guard let opusFormat = AVAudioFormat(streamDescription: &description),
              let encoder = AVAudioConverter(from: Self.pcmFormat, to: opusFormat),
              let decoder = AVAudioConverter(from: opusFormat, to: Self.pcmFormat)
        else {
            throw OpusCodecError.converterUnavailable
        }
        encoder.bitRate = bitRate
        self.opusFormat = opusFormat
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
            format: opusFormat,
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
        let input = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: Self.maximumPacketSize
        )
        packet.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        if let descriptions = input.packetDescriptions {
            descriptions[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: Self.frameSamples,
                mDataByteSize: UInt32(packet.count)
            )
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.pcmFormat,
            frameCapacity: Self.frameSamples * 6
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

public enum OpusCodecError: Error, Equatable {
    case converterUnavailable
    case invalidPCMFrame
    case invalidPacket
    case noOutput(status: Int, bytes: UInt32)
}
