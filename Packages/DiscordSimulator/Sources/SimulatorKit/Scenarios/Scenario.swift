import Foundation

/// A seeded world. Building is deterministic: the same seed gives the same IDs,
/// content and media.
public protocol Scenario: Sendable {
    static var name: String { get }
    static var summary: String { get }
    /// Builds the world. `parameters` come from `--param key=value` on the command line.
    static func build(into world: World, parameters: [String: String]) async throws
    /// Scripts started with the simulator, by name with their params; none by default,
    /// so benchmarks see only the activity they start themselves.
    static func liveScripts(parameters: [String: String]) -> [String: JSON]
}

public extension Scenario {
    static func liveScripts(parameters: [String: String]) -> [String: JSON] { [:] }
}

public enum ScenarioRegistry {
    public static let all: [any Scenario.Type] = [RealisticScenario.self, SmallAccountScenario.self, LargeAccountScenario.self, DemoScenario.self] + BenchmarkScenarios.all

    public static func scenario(named name: String) -> (any Scenario.Type)? {
        all.first { $0.name == name }
    }
}

/// The scenario's "now". Content is written for a Sunday at 21:30, so by
/// default the world starts at the most recent Sunday 21:30 in the Mac's time
/// zone: weekdays in the chat line up and "today" stays close to real time.
/// A fixed `--epoch` makes runs on different days identical.
public enum ScenarioEpoch {
    public static func recentSundayEvening(before now: Date = Date(), calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.weekday = 1
        components.hour = 21
        components.minute = 30
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, direction: .backward) ?? now
    }

    /// Accounts date from a fixed day rather than the weekly epoch, so user IDs
    /// and tokens (and the app's saved simulator accounts) survive the epoch
    /// moving each Sunday. An earlier `--epoch` pulls it back so no account
    /// is created after "now".
    public static func accountsReference(for epoch: Date) -> Date {
        min(epoch, Date(timeIntervalSince1970: 1_790_000_000))
    }
}
