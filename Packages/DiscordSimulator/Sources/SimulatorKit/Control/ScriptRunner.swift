import Foundation
import Synchronization

/// Timed event streams for live benchmarks (message arrivals, reaction storms,
/// presence churn, unread mentions), started through the control API.
public final class ScriptRunner: Sendable {
    public typealias Script = @Sendable (World, JSON) async throws -> Void

    let world: World
    let log: SimulatorLog
    private let scripts: [String: Script]
    private let running = Mutex<[String: Task<Void, Never>]>([:])
    /// Start IDs only ever count up, so a stopped script's ID is never handed out again.
    private let started = Atomic<Int>(0)

    init(world: World, log: SimulatorLog, scripts: [String: Script]) {
        self.world = world
        self.log = log
        self.scripts = scripts
    }

    public var names: [String] { scripts.keys.sorted() }

    func start(_ name: String, params: JSON) async throws -> String {
        guard let script = scripts[name] else {
            throw WorldError.invalidBody("unknown script \(name); available: \(names.joined(separator: ", "))")
        }
        let id = "\(name)-\(started.add(1, ordering: .relaxed).newValue)"
        let world = world, log = log
        let task = Task {
            do { try await script(world, params) } catch is CancellationError {} catch { log.error("script", "\(name) failed: \(error)") }
            log.info("script", "\(name) finished")
        }
        running.withLock { $0[id] = task }
        return id
    }

    /// Stops running scripts by start ID (`live-activity-1`) or by name; returns the IDs stopped.
    func stop(_ key: String) -> [String] {
        running.withLock { tasks in
            let ids = tasks.keys.filter { $0 == key || $0.hasPrefix(key + "-") }.sorted()
            for id in ids { tasks.removeValue(forKey: id)?.cancel() }
            return ids
        }
    }

    var runningIDs: [String] { running.withLock { $0.keys.sorted() } }

    public func cancelAll() {
        running.withLock { tasks in
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }
}
