import AVFoundation
import Foundation
import Synchronization

/// Speech-like audio we generate ourselves: a voiced buzz at the speaker's
/// pitch, shaped by vowel formants into syllables and words with pauses,
/// encoded as 20 ms stereo Opus packets (what Discord voice carries).
enum SpeechSynthesizer {
    static let sampleRate = 48_000.0
    static let samplesPerPacket = 960

    /// Vowel formants (F1, F2) in Hz.
    private static let vowels: [(Float, Float)] = [(730, 1090), (530, 1840), (270, 2290), (570, 840), (300, 870), (660, 1720)]

    /// Encoded voices by seed: each turn someone talks reuses theirs.
    private static let voices = Mutex<[UInt64: [Data]]>([:])

    /// About eight seconds of one person's chatter as Opus packets.
    static func opusPackets(seed: UInt64) -> [Data] {
        if let cached = voices.withLock({ $0[seed] }) { return cached }
        let packets = encodeOpus(samples(seed: seed, seconds: 8))
        voices.withLock { $0[seed] = packets }
        return packets
    }

    static func samples(seed: UInt64, seconds: Double) -> [Float] {
        var random = SeededRandom(seed: seed)
        let count = Int(seconds * sampleRate)
        let pitch = Float(95 + random.next() % 130)
        var output = [Float](repeating: 0, count: count)
        var phase: Float = 0
        var index = 0
        while index < count {
            let syllables = 2 + Int(random.next() % 5)
            for _ in 0 ..< syllables where index < count {
                let length = Int(sampleRate * (0.14 + Double(random.next() % 120) / 1000))
                let (f1, f2) = vowels[Int(random.next() % UInt64(vowels.count))]
                let start = index
                while index < min(count, start + length) {
                    let progress = Float(index - start) / Float(length)
                    let time = Float(index) / Float(sampleRate)
                    let f0 = pitch * (1 + 0.07 * sin(2 * .pi * 0.6 * time) + 0.03 * sin(2 * .pi * 4.3 * time))
                    phase += 2 * .pi * f0 / Float(sampleRate)
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    output[index] = voiced(phase: phase, f0: f0, f1: f1, f2: f2) * pow(sin(.pi * progress), 2)
                    index += 1
                }
            }
            index += Int(sampleRate * (0.12 + Double(random.next() % 450) / 1000))
        }
        let peak = output.map(abs).max() ?? 1
        return output.map { $0 * 0.35 / max(peak, 0.0001) }
    }

    /// Harmonics of `f0` weighted by two formant resonances.
    private static func voiced(phase: Float, f0: Float, f1: Float, f2: Float) -> Float {
        var sample: Float = 0
        var harmonic: Float = 1
        while harmonic * f0 < 3_800 {
            let frequency = harmonic * f0
            let weight = exp(-pow((frequency - f1) / 110, 2)) + 0.6 * exp(-pow((frequency - f2) / 150, 2)) + 0.04
            sample += weight / harmonic.squareRoot() * sin(harmonic * phase)
            harmonic += 1
        }
        return sample
    }

    /// Mono samples to 20 ms stereo Opus packets with Core Audio's encoder.
    static func encodeOpus(_ samples: [Float]) -> [Data] {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(samples.count)),
              let interleaved = input.floatChannelData?[0]
        else { return [] }
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                                      mFramesPerPacket: UInt32(samplesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 2,
                                                      mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: pcm, to: opus) else { return [] }
        converter.bitRate = 64_000
        input.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            interleaved[2 * index] = sample
            interleaved[2 * index + 1] = sample
        }
        var supplied = false
        var packets: [Data] = []
        while true {
            let output = AVAudioCompressedBuffer(format: opus, packetCapacity: 64, maximumPacketSize: converter.maximumOutputPacketSize)
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            for packet in 0 ..< Int(output.packetCount) {
                guard let described = output.packetDescriptions?[packet] else { continue }
                packets.append(Data(bytes: output.data + Int(described.mStartOffset), count: Int(described.mDataByteSize)))
            }
            if status != .haveData { break }
        }
        return packets
    }
}
