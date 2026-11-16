import Foundation

/// SplitMix64. The simulator's only source of randomness, so a seed fully
/// determines a run. Derive an independent stream per subsystem with `fork`.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// A stream that depends only on this generator's seed and `label`.
    public func fork(_ label: String) -> SeededRandom {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in label.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return SeededRandom(seed: state ^ hash)
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }

    /// Uniform in `0..<1`.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }

    public mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}
