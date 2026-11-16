import Foundation

/// The simulator's notion of "now". It starts at the scenario's epoch and runs
/// with real time unless frozen, so timestamps and snowflakes are repeatable.
public final class SimulatorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var anchorSimulated: Date
    private var anchorReal: Date
    private var frozen: Bool

    public init(epoch: Date, frozen: Bool = false) {
        anchorSimulated = epoch
        anchorReal = Date()
        self.frozen = frozen
    }

    public var now: Date {
        lock.withLock { frozen ? anchorSimulated : anchorSimulated.addingTimeInterval(Date().timeIntervalSince(anchorReal)) }
    }

    public var isFrozen: Bool { lock.withLock { frozen } }

    public func set(_ date: Date) {
        lock.withLock { anchorSimulated = date; anchorReal = Date() }
    }

    public func advance(by seconds: TimeInterval) { set(now.addingTimeInterval(seconds)) }

    public func freeze(_ shouldFreeze: Bool) {
        let current = now
        lock.withLock { anchorSimulated = current; anchorReal = Date(); frozen = shouldFreeze }
    }
}
