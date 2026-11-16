import Foundation
import Synchronization

/// The simulator's notion of "now". It starts at the scenario's epoch and runs
/// with real time unless frozen, so timestamps and snowflakes are repeatable.
public final class SimulatorClock: Sendable {
    private struct State {
        var anchorSimulated: Date
        var anchorReal: Date
        var frozen: Bool
    }

    private let state: Mutex<State>

    public init(epoch: Date, frozen: Bool = false) {
        state = Mutex(State(anchorSimulated: epoch, anchorReal: Date(), frozen: frozen))
    }

    public var now: Date {
        state.withLock { $0.frozen ? $0.anchorSimulated : $0.anchorSimulated.addingTimeInterval(Date().timeIntervalSince($0.anchorReal)) }
    }

    public var isFrozen: Bool { state.withLock { $0.frozen } }

    public func set(_ date: Date) {
        state.withLock { $0.anchorSimulated = date; $0.anchorReal = Date() }
    }

    public func advance(by seconds: TimeInterval) { set(now.addingTimeInterval(seconds)) }

    public func freeze(_ shouldFreeze: Bool) {
        let current = now
        state.withLock { $0 = State(anchorSimulated: current, anchorReal: Date(), frozen: shouldFreeze) }
    }
}
