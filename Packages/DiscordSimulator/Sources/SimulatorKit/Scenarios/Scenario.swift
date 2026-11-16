import Foundation

/// A seeded world. Building is deterministic: the same seed gives the same IDs,
/// content and media.
public protocol Scenario: Sendable {
    static var name: String { get }
    static var summary: String { get }
    /// Builds the world. `parameters` come from `--param key=value` on the command line.
    static func build(into world: World, parameters: [String: String]) async throws
}

public enum ScenarioRegistry {
    public static let all: [any Scenario.Type] = [DemoScenario.self] + BenchmarkScenarios.all

    public static func scenario(named name: String) -> (any Scenario.Type)? {
        all.first { $0.name == name }
    }

    /// Opens the existential so the static requirement is called on a concrete type.
    public static func build(_ scenario: any Scenario.Type, into world: World, parameters: [String: String]) async throws {
        try await build(concrete: scenario, into: world, parameters: parameters)
    }

    private static func build<S: Scenario>(concrete: S.Type, into world: World, parameters: [String: String]) async throws {
        try await S.build(into: world, parameters: parameters)
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
