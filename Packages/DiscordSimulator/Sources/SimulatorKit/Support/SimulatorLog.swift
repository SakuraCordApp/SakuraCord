import Foundation
import Synchronization

/// Simulator log: errors and warnings go to stderr immediately and are kept
/// for the control API, so unknown routes and protocol mistakes are visible.
public final class SimulatorLog: Sendable {
    public struct Entry: Sendable {
        public var time: Date
        public var level: String
        public var area: String
        public var message: String
    }

    private let entries = Mutex<[Entry]>([])
    private let verbose: Bool

    public init(verbose: Bool = false) { self.verbose = verbose }

    public func error(_ area: String, _ message: String) { record("ERROR", area, message, print: true) }
    public func warning(_ area: String, _ message: String) { record("WARN", area, message, print: true) }
    public func info(_ area: String, _ message: String) { record("INFO", area, message, print: verbose) }
    public func debug(_ area: String, _ message: String) { record("DEBUG", area, message, print: verbose) }

    public func recent(minimumLevel: String = "WARN", limit: Int = 200) -> [Entry] {
        let levels = ["DEBUG", "INFO", "WARN", "ERROR"]
        let floor = levels.firstIndex(of: minimumLevel) ?? 0
        return entries.withLock { all in
            Array(all.filter { (levels.firstIndex(of: $0.level) ?? 0) >= floor }.suffix(limit))
        }
    }

    private func record(_ level: String, _ area: String, _ message: String, print: Bool) {
        let entry = Entry(time: Date(), level: level, area: area, message: message)
        entries.withLock { all in
            all.append(entry)
            if all.count > 5_000 { all.removeFirst(all.count - 5_000) }
        }
        if print { FileHandle.standardError.write(Data("[\(level.lowercased()):\(area)] \(message)\n".utf8)) }
    }
}
