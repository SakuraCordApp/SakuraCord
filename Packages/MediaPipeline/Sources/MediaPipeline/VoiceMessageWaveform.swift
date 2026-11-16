import Foundation

/// Discord's voice-message waveform: 32–256 unsigned RMS bins, about ten per
/// second, base64-encoded in the attachment's `waveform` field.
public enum VoiceMessageWaveform {
    public static let minimumBinCount = 32
    public static let maximumBinCount = 256
    public static let binsPerSecond = 10.0

    /// Collects signal energy in short chunks so a long recording never has to
    /// retain its samples to compute the waveform afterwards.
    struct Accumulator: Sendable {
        /// 10 ms at 48 kHz; finer than the densest waveform bin.
        static let chunkSamples = 480

        private(set) var chunkEnergies: [Float] = []
        private(set) var sampleCount = 0
        private var currentEnergy: Float = 0
        private var currentSamples = 0

        init() {}

        mutating func append(_ samples: UnsafeBufferPointer<Float>) {
            for sample in samples {
                currentEnergy += sample * sample
                currentSamples += 1
                if currentSamples == Self.chunkSamples {
                    chunkEnergies.append(currentEnergy)
                    currentEnergy = 0
                    currentSamples = 0
                }
            }
            sampleCount += samples.count
        }

        /// Chunk energies including the incomplete final chunk, and the
        /// number of samples each represents.
        var chunks: [(energy: Float, samples: Int)] {
            var chunks = chunkEnergies.map { ($0, Self.chunkSamples) }
            if currentSamples > 0 { chunks.append((currentEnergy, currentSamples)) }
            return chunks
        }
    }

    public static func binCount(duration: Double) -> Int {
        min(max(Int((duration * binsPerSecond).rounded(.down)), minimumBinCount), maximumBinCount)
    }

    /// RMS bins scaled to 0–255, then eased towards full scale the way
    /// Vencord's VoiceMessages plugin normalizes quiet recordings.
    static func bins(from accumulator: Accumulator, sampleRate: Double = 48_000) -> [UInt8] {
        let chunks = accumulator.chunks
        guard !chunks.isEmpty else { return [UInt8](repeating: 0, count: minimumBinCount) }
        let count = min(binCount(duration: Double(accumulator.sampleCount) / sampleRate), chunks.count)
        var bins = [UInt8](repeating: 0, count: max(count, 1))
        for bin in bins.indices {
            let lower = bin * chunks.count / bins.count
            let upper = max(lower + 1, (bin + 1) * chunks.count / bins.count)
            var energy: Float = 0
            var samples = 0
            for chunk in chunks[lower ..< upper] {
                energy += chunk.energy
                samples += chunk.samples
            }
            let rms = samples > 0 ? (energy / Float(samples)).squareRoot() : 0
            bins[bin] = UInt8(min(max((rms * 255).rounded(.down), 0), 255))
        }
        guard let maximum = bins.max(), maximum > 0 else { return bins }
        let ratio = normalizationRatio(maximum: Double(maximum))
        return bins.map { UInt8(min(255, (Double($0) * ratio).rounded(.down))) }
    }

    /// The plugin's eased peak normalization for a loudest bin of
    /// `maximum` on the 0–255 scale. Double arithmetic matches its
    /// JavaScript rounding.
    static func normalizationRatio(maximum: Double) -> Double {
        let peak = maximum / 255
        let easing = min(1, 100 * peak * peak * peak)
        return 1 + (255 / maximum - 1) * easing
    }

    /// Live 0–1 RMS levels normalized the way `bins` normalizes a finished
    /// recording, so the waveform keeps its shape when recording stops.
    public static func normalized(_ levels: [Float], peak: Float) -> [Float] {
        let maximum = (min(max(peak, 0), 1) * 255).rounded(.down)
        guard maximum > 0 else { return levels.map { _ in 0 } }
        let scale = Float(normalizationRatio(maximum: Double(maximum)))
        return levels.map { min(1, ($0 * 255).rounded(.down) * scale / 255) }
    }

    public static func encode(_ bins: [UInt8]) -> String {
        Data(bins).base64EncodedString()
    }

    /// Normalized 0–1 values; nil when the field is absent or malformed.
    public static func decode(_ waveform: String?) -> [Float]? {
        guard let waveform, let data = Data(base64Encoded: waveform), !data.isEmpty else { return nil }
        return data.map { Float($0) / 255 }
    }

    /// `count` bars spanning the whole recording: Discord's reduction when
    /// there are more values than bars, linear interpolation when fewer.
    public static func overview(_ values: [Float], count: Int) -> [Float] {
        guard count > 0, values.count > 1, values.count < count else {
            return bars(values, count: count)
        }
        let scale = Double(values.count - 1) / Double(count - 1)
        return (0 ..< count).map { index in
            let position = Double(index) * scale
            let lower = Int(position)
            let upper = min(lower + 1, values.count - 1)
            let fraction = Float(position - Double(lower))
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
    }

    /// Discord's display reduction: contiguous averages when there are more
    /// values than bars, zero padding when there are fewer.
    public static func bars(_ values: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard values.count > count else {
            return values + [Float](repeating: 0, count: count - values.count)
        }
        let ratio = Double(values.count) / Double(count)
        var result = [Float](repeating: 0, count: count)
        var start = 0
        for index in 0 ..< count {
            let end = min(values.count, max(start + 1, Int((Double(index + 1) * ratio).rounded())))
            var sum: Float = 0
            for value in values[start ..< end] { sum += value }
            result[index] = sum / Float(end - start)
            start = end
        }
        return result
    }
}
