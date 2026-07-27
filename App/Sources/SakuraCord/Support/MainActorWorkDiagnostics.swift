import Foundation
import OSLog

/// Opt-in timing for the state derivations that run on the main actor.
///
/// The app target is `defaultIsolation(MainActor.self)`, so every `didSet`
/// cascade in `AppModel` is frame time by construction. Before moving any of it
/// off the main actor, this says which pieces actually cost anything: an
/// Instruments Points of Interest interval plus a periodic summary of count,
/// total, and worst case per stage.
///
/// Shares `--scroll-diagnostics`, so ordinary and packaged runs pay nothing.
/// Records durations only — no message, member, or channel value is logged.
@MainActor
enum MainActorWorkDiagnostics {
    enum Stage: CaseIterable {
        case memberSections
        case hiddenChannels
        case messageRows
        case authorPresentations
        case gatewayEvent

        var label: String {
            switch self {
            case .memberSections: "memberSections"
            case .hiddenChannels: "hiddenChannels"
            case .messageRows: "messageRows"
            case .authorPresentations: "authorPresentations"
            case .gatewayEvent: "gatewayEvent"
            }
        }

        /// Signpost names must be static, so they cannot come from `label`.
        var signpostName: StaticString {
            switch self {
            case .memberSections: "memberSections"
            case .hiddenChannels: "hiddenChannels"
            case .messageRows: "messageRows"
            case .authorPresentations: "authorPresentations"
            case .gatewayEvent: "gatewayEvent"
            }
        }
    }

    private struct Tally {
        var count = 0
        var totalMilliseconds = 0.0
        var worstMilliseconds = 0.0
    }

    static let isEnabled = ScrollDiagnostics.isEnabled

    /// One frame at 60Hz. Anything reliably under this is not worth moving.
    static let frameBudgetMilliseconds = 16.7

    private static let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "MainActorWork"
    )
    private static let signposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )

    private static var tallies: [Stage: Tally] = [:]
    private static var windowStartedAt: ContinuousClock.Instant?
    private static let reportingInterval: Duration = .seconds(5)

    /// Times `work` and reports it. Returns `work`'s value untouched, so call
    /// sites read the same as they did before.
    static func measure<T>(_ stage: Stage, _ work: () throws -> T) rethrows -> T {
        guard isEnabled else { return try work() }
        let startedAt = ContinuousClock.now
        let interval = signposter.beginInterval(stage.signpostName)
        defer {
            signposter.endInterval(stage.signpostName, interval)
            record(stage, elapsed: startedAt.duration(to: .now))
        }
        return try work()
    }

    private static func record(_ stage: Stage, elapsed: Duration) {
        let milliseconds = Self.milliseconds(elapsed)
        var tally = tallies[stage] ?? Tally()
        tally.count += 1
        tally.totalMilliseconds += milliseconds
        tally.worstMilliseconds = max(tally.worstMilliseconds, milliseconds)
        tallies[stage] = tally

        guard let windowStartedAt else {
            self.windowStartedAt = ContinuousClock.now
            return
        }
        let windowElapsed = windowStartedAt.duration(to: .now)
        guard windowElapsed >= reportingInterval else { return }
        report(over: windowElapsed)
    }

    /// Reports whatever has accumulated without waiting for the interval.
    ///
    /// Reporting is otherwise driven from `record`, so a window that ends in
    /// silence would never flush — and the interesting case is exactly that:
    /// scroll, stop, read the numbers.
    static func flush() {
        guard isEnabled, let windowStartedAt else { return }
        report(over: windowStartedAt.duration(to: .now))
    }

    private static func report(over windowElapsed: Duration) {
        let summary = Stage.allCases.compactMap { stage -> String? in
            guard let tally = tallies[stage], tally.count > 0 else { return nil }
            return String(
                format: "%@ n=%d total=%.1fms worst=%.2fms",
                stage.label,
                tally.count,
                tally.totalMilliseconds,
                tally.worstMilliseconds
            )
        }
        tallies = [:]
        windowStartedAt = ContinuousClock.now
        guard !summary.isEmpty else { return }
        let window = Self.milliseconds(windowElapsed) / 1000
        // Stage labels and durations only, so redaction would hide the whole
        // point of the line without protecting anything.
        logger.info(
            """
            main-actor work over \(window, format: .fixed(precision: 1))s — \
            \(summary.joined(separator: ", "), privacy: .public)
            """
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
