import AVFAudio
import Foundation

public struct SoundboardPCMClip: Sendable {
    public let left: [Float]
    public let right: [Float]

    public init(left: [Float], right: [Float]) throws {
        guard !left.isEmpty, left.count == right.count else {
            throw SoundboardAudioError.invalidAudio
        }
        guard left.count <= Int(OpusCodec.sampleRate * 10) else {
            throw SoundboardAudioError.audioTooLong
        }
        self.left = left
        self.right = right
    }

    public var frameCount: Int { left.count }

    public var duration: Duration {
        .seconds(Double(frameCount) / OpusCodec.sampleRate)
    }

    func audioBuffer() throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: OpusCodec.pcmFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = buffer.floatChannelData else {
            throw SoundboardAudioError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        left.withUnsafeBufferPointer { source in
            channels[0].update(from: source.baseAddress!, count: frameCount)
        }
        right.withUnsafeBufferPointer { source in
            channels[1].update(from: source.baseAddress!, count: frameCount)
        }
        return buffer
    }
}

public enum SoundboardAudioDecoder {
    public static func decode(_ data: Data) throws -> SoundboardPCMClip {
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else {
            throw SoundboardAudioError.invalidAudio
        }
        if data.starts(with: Data("OggS".utf8)) {
            return try decodeOggOpus(data)
        }
        return try decodeAppleAudio(data)
    }

    private static func decodeAppleAudio(_ data: Data) throws -> SoundboardPCMClip {
        let fileExtension: String
        if data.starts(with: Data("RIFF".utf8)) {
            fileExtension = "wav"
        } else if data.count >= 8,
                  String(data: data[4 ..< 8], encoding: .ascii) == "ftyp"
        {
            fileExtension = "m4a"
        } else {
            fileExtension = "mp3"
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SakuraCord/Soundboard Decode", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = directory.appending(path: "sound.\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 10),
                  let input = AVAudioPCMBuffer(
                      pcmFormat: file.processingFormat,
                      frameCapacity: AVAudioFrameCount(file.length)
                  )
            else { throw SoundboardAudioError.audioTooLong }
            try file.read(into: input)
            return try convertedClip(from: input)
        } catch let error as SoundboardAudioError {
            throw error
        } catch {
            throw SoundboardAudioError.decodeFailed
        }
    }

    private static func convertedClip(from input: AVAudioPCMBuffer) throws -> SoundboardPCMClip {
        guard let converter = AVAudioConverter(from: input.format, to: OpusCodec.pcmFormat) else {
            throw SoundboardAudioError.decodeFailed
        }
        let ratio = OpusCodec.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 64
        guard capacity <= AVAudioFrameCount(OpusCodec.sampleRate * 10),
              let output = AVAudioPCMBuffer(
                  pcmFormat: OpusCodec.pcmFormat,
                  frameCapacity: capacity
              )
        else { throw SoundboardAudioError.audioTooLong }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0,
              let channels = output.floatChannelData
        else { throw SoundboardAudioError.decodeFailed }
        let count = Int(output.frameLength)
        return try SoundboardPCMClip(
            left: Array(UnsafeBufferPointer(start: channels[0], count: count)),
            right: Array(UnsafeBufferPointer(start: channels[1], count: count))
        )
    }

    private static func decodeOggOpus(_ data: Data) throws -> SoundboardPCMClip {
        let parsed = try OggOpusParser.parse(data)
        let codec = try OpusCodec()
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(Int(OpusCodec.sampleRate * 6))
        right.reserveCapacity(Int(OpusCodec.sampleRate * 6))
        for packet in parsed.audioPackets {
            let decoded = try codec.decode(packet)
            guard let channels = decoded.floatChannelData else {
                throw SoundboardAudioError.decodeFailed
            }
            let count = Int(decoded.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: count))
            guard left.count <= Int(OpusCodec.sampleRate * 10) else {
                throw SoundboardAudioError.audioTooLong
            }
        }
        let preSkip = min(parsed.preSkip, left.count)
        if preSkip > 0 {
            left.removeFirst(preSkip)
            right.removeFirst(preSkip)
        }
        if let granulePosition = parsed.finalGranulePosition {
            let expectedCount = max(0, min(left.count, Int(granulePosition) - preSkip))
            left.removeLast(left.count - expectedCount)
            right.removeLast(right.count - expectedCount)
        }
        return try SoundboardPCMClip(left: left, right: right)
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

final class OutgoingSoundboardMixer: @unchecked Sendable {
    struct Metrics: Equatable, Sendable {
        var triggerCount = 0
        var peakConcurrentVoices = 0
        var mixedFrameCount = 0
    }

    private struct Voice {
        let soundID: String
        let clip: SoundboardPCMClip
        let volume: Float
        var offset = 0
    }

    private let lock = NSLock()
    private var voices: [Voice] = []
    private var metrics = Metrics()
    private static let maximumConcurrentVoices = 32

    @discardableResult
    func enqueue(_ clip: SoundboardPCMClip, soundID: String, volume: Float) -> Bool {
        lock.withLock {
            voices.removeAll { $0.soundID == soundID }
            if voices.count == Self.maximumConcurrentVoices {
                voices.removeFirst()
            }
            voices.append(Voice(
                soundID: soundID,
                clip: clip,
                volume: min(max(volume, 0), 2)
            ))
            metrics.triggerCount += 1
            metrics.peakConcurrentVoices = max(metrics.peakConcurrentVoices, voices.count)
            return true
        }
    }

    func mix(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int)
        -> Bool
    {
        lock.withLock {
            guard !voices.isEmpty else { return false }
            var peak: Float = 0
            for index in 0 ..< count {
                var leftSample = left[index]
                var rightSample = right[index]
                for voice in voices where voice.offset + index < voice.clip.frameCount {
                    leftSample += voice.clip.left[voice.offset + index] * voice.volume
                    rightSample += voice.clip.right[voice.offset + index] * voice.volume
                }
                left[index] = min(max(leftSample, -1), 1)
                right[index] = min(max(rightSample, -1), 1)
                peak = max(peak, max(abs(left[index]), abs(right[index])))
            }
            for index in voices.indices { voices[index].offset += count }
            voices.removeAll { $0.offset >= $0.clip.frameCount }
            metrics.mixedFrameCount += count
            return peak > 0.000_1
        }
    }

    func removeAll() {
        lock.withLock { voices.removeAll(keepingCapacity: true) }
    }

    var hasActiveAudio: Bool { lock.withLock { !voices.isEmpty } }
    var diagnostics: Metrics { lock.withLock { metrics } }
}

public enum SoundboardAudioError: Error, Equatable {
    case invalidAudio
    case audioTooLong
    case invalidOgg
    case decodeFailed
}

extension SoundboardAudioError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAudio: "The soundboard audio is invalid."
        case .audioTooLong: "The soundboard audio is longer than the safe playback limit."
        case .invalidOgg: "The soundboard Ogg stream is malformed."
        case .decodeFailed: "The soundboard audio could not be decoded."
        }
    }
}
