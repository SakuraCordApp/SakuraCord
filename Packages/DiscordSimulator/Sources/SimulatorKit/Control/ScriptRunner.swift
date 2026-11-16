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
        let id = "\(name)-\(running.withLock { $0.count + 1 })"
        let world = world, log = log
        let task = Task {
            do { try await script(world, params) } catch { log.error("script", "\(name) failed: \(error)") }
            log.info("script", "\(name) finished")
        }
        running.withLock { $0[id] = task }
        return id
    }

    public func cancelAll() {
        running.withLock { tasks in
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }
}
