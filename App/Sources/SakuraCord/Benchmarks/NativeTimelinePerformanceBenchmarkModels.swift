import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

nonisolated enum NativeTimelineBenchmarkStartupPolicy {
    static let minimumPresentedFrames = 2
    static let quietInterval: TimeInterval = 0.100

    static func isReady(
        completedTicks: Int,
        uptime: TimeInterval,
        lastDelayedTickUptime: TimeInterval
    ) -> Bool {
        completedTicks >= minimumPresentedFrames
            && uptime >= lastDelayedTickUptime + quietInterval
    }
}

/// Runs for one fixed wall-clock interval at a refresh-independent target
/// speed. Delayed frames remain part of the result: the step cap avoids
/// measuring a stall twice, while the artifact records the resulting spatial
/// deficit instead of censoring the run.
nonisolated enum NativeTimelineBenchmarkScrollPolicy {
    // Keep the authenticated workload continuously moving at reading or
    // skimming speed. Much faster runs exhaust live history sooner than a
    // person could read it, which hides account-scale costs.
    static let pointsPerSecond: CGFloat = 1_200
    static let maximumStep: CGFloat = 40
    static let duration: TimeInterval = 20
    static let nominalDistance = pointsPerSecond * duration
    static let isIdle = AppLaunchConfiguration.current.isChatPerformanceIdle

    static func distance(tickInterval: TimeInterval) -> CGFloat {
        guard !isIdle else { return 0 }
        return min(
            maximumStep,
            max(0, CGFloat(tickInterval)) * pointsPerSecond
        )
    }

    static func distanceDeficit(completedDistance: CGFloat) -> CGFloat {
        max(0, nominalDistance - completedDistance)
    }

    static func spatialQuality(completedDistance: CGFloat) -> Double {
        min(1, max(0, Double(completedDistance / nominalDistance)))
    }
}

nonisolated struct NativeTimelineBenchmarkScrollController {
    let startedAt: TimeInterval
    private(set) var completedDistance: CGFloat = 0

    /// How the run ends after this tick, or nil while it continues.
    mutating func recordTick(
        uptime: TimeInterval,
        previousDocumentY: CGFloat,
        currentDocumentY: CGFloat,
        hasMoreMessages: Bool,
        paginationFailed: Bool = false
    ) -> NativeTimelineBenchmarkFinishOutcome? {
        let advance = max(0, previousDocumentY - currentDocumentY)
        completedDistance += advance
        if paginationFailed {
            return .paginationFailed
        }
        if advance <= 0.5, !hasMoreMessages {
            return .insufficientHistory
        }
        if uptime - startedAt >= NativeTimelineBenchmarkScrollPolicy.duration {
            return .completed
        }
        return nil
    }
}

enum NativeTimelineBenchmarkFinishOutcome: String {
    case completed
    case insufficientHistory
    case cancelled
    case paginationFailed
}

/// Display-tick statistics shared by the timeline startup, timeline run and
/// member-list auto-scroll benchmarks.
struct NativeTimelineBenchmarkTickStats {
    struct DelayedTick {
        let offset: TimeInterval
        let interval: TimeInterval
    }

    let startedAt: TimeInterval
    private(set) var previousTickUptime: TimeInterval
    private(set) var completedTicks = 0
    private(set) var delayedTicks = 0
    private(set) var intervals: [TimeInterval] = []
    private(set) var delayedTickSamples: [DelayedTick] = []
    private(set) var maximumTickInterval = 0.0
    var maximumScrollWork = 0.0
    private(set) var historyStarvedTicks = 0
    private(set) var maximumConsecutiveHistoryStarvedTicks = 0
    private var consecutiveHistoryStarvedTicks = 0

    init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.startedAt = startedAt
        previousTickUptime = startedAt
        intervals.reserveCapacity(1_500)
        delayedTickSamples.reserveCapacity(64)
    }

    /// Records a display tick and returns its interval since the previous one.
    mutating func recordTick(at uptime: TimeInterval) -> TimeInterval {
        let interval = uptime - previousTickUptime
        previousTickUptime = uptime
        completedTicks += 1
        intervals.append(interval)
        maximumTickInterval = max(maximumTickInterval, interval)
        if interval > 0.033 {
            delayedTicks += 1
            delayedTickSamples.append(.init(offset: uptime - startedAt, interval: interval))
        }
        return interval
    }

    mutating func recordHistoryProgress(didAdvance: Bool, hasMoreHistory: Bool) {
        if !didAdvance, hasMoreHistory {
            historyStarvedTicks += 1
            consecutiveHistoryStarvedTicks += 1
            maximumConsecutiveHistoryStarvedTicks = max(
                maximumConsecutiveHistoryStarvedTicks,
                consecutiveHistoryStarvedTicks
            )
        } else {
            consecutiveHistoryStarvedTicks = 0
        }
    }
}

@MainActor
enum NativeTimelineBenchmarkArtifact {
    static func write(
        outcome: NativeTimelineBenchmarkFinishOutcome,
        completedDistance: CGFloat,
        elapsed: TimeInterval,
        ticks: NativeTimelineBenchmarkTickStats? = nil,
        renderTelemetry: NativeTimelineRenderTelemetry? = nil,
        mainThreadCPUTime: TimeInterval? = nil,
        timelineUpdates: (count: Int, milliseconds: Double)? = nil
    ) {
        PerformanceBenchmarkHarness.writeResultFields {
            let duration = NativeTimelineBenchmarkScrollPolicy.duration
            var fields: [(String, Any)] = [
                ("outcome", outcome.rawValue),
                ("elapsed_seconds", elapsed),
                ("nominal_duration_seconds", duration),
                ("elapsed_overshoot_seconds", max(0, elapsed - duration)),
            ]
            // A still timeline covers no distance by design.
            if !NativeTimelineBenchmarkScrollPolicy.isIdle {
                fields += [
                    ("completed_distance_points", completedDistance),
                    ("nominal_distance_points", NativeTimelineBenchmarkScrollPolicy.nominalDistance),
                    (
                        "distance_deficit_points",
                        NativeTimelineBenchmarkScrollPolicy.distanceDeficit(completedDistance: completedDistance)
                    ),
                    (
                        "spatial_quality_ratio",
                        NativeTimelineBenchmarkScrollPolicy.spatialQuality(completedDistance: completedDistance)
                    ),
                ]
            }
            if let ticks {
                let sortedTickIntervals = ticks.intervals.sorted()
                func percentile(_ fraction: Double) -> Double {
                    PerformanceBenchmarkHarness.nearestRankPercentile(sortedTickIntervals, fraction)
                }
                let delayedTickRate = ticks.completedTicks > 0
                    ? Double(ticks.delayedTicks) / Double(ticks.completedTicks)
                    : 0
                let delayedTickSampleText = ticks.delayedTickSamples.map { sample in
                    "\(sample.offset * 1_000):\(sample.interval * 1_000)"
                }.joined(separator: ",")
                fields += [
                    ("completed_ticks", ticks.completedTicks),
                    ("delayed_ticks_over_33ms", ticks.delayedTicks),
                    ("delayed_tick_rate", delayedTickRate),
                    ("median_tick_interval_ms", percentile(0.50) * 1_000),
                    ("p95_tick_interval_ms", percentile(0.95) * 1_000),
                    ("p99_tick_interval_ms", percentile(0.99) * 1_000),
                    ("maximum_tick_interval_ms", ticks.maximumTickInterval * 1_000),
                    ("delayed_tick_samples_offset_ms_interval_ms", delayedTickSampleText),
                    ("maximum_scroll_work_ms", ticks.maximumScrollWork * 1_000),
                    ("history_starved_ticks", ticks.historyStarvedTicks),
                    (
                        "maximum_consecutive_history_starved_ticks",
                        ticks.maximumConsecutiveHistoryStarvedTicks
                    ),
                ]
            }
            if let renderTelemetry {
                fields += [
                    ("canvas_draw_count", renderTelemetry.canvasDrawCount),
                    ("canvas_draw_total_ms", renderTelemetry.canvasDrawTotalDuration * 1_000),
                    ("canvas_draw_average_ms", renderTelemetry.canvasDrawAverageDuration * 1_000),
                    ("canvas_draw_maximum_ms", renderTelemetry.canvasDrawMaximumDuration * 1_000),
                    ("row_raster_count", renderTelemetry.rowRasterCount),
                    ("row_raster_total_ms", renderTelemetry.rowRasterTotalDuration * 1_000),
                    ("row_raster_average_ms", renderTelemetry.rowRasterAverageDuration * 1_000),
                    ("row_raster_maximum_ms", renderTelemetry.rowRasterMaximumDuration * 1_000),
                    ("row_raster_maximum_height_points", renderTelemetry.rowRasterMaximumHeight),
                    ("row_bitmap_cache_hit_count", renderTelemetry.rowBitmapCacheHitCount),
                    ("live_scroll_direct_paint_count", renderTelemetry.liveScrollDirectPaintCount),
                ]
            }
            if let mainThreadCPUTime {
                fields.append(("main_thread_cpu_ms", mainThreadCPUTime * 1_000))
            }
            if let timelineUpdates {
                fields += [
                    ("timeline_update_count", timelineUpdates.count),
                    ("timeline_update_total_ms", timelineUpdates.milliseconds),
                ]
            }
            return fields
        }
    }
}

/// The signpost interval, resource window and scroll-work gate activity of
/// one native auto-scroll benchmark run.
struct NativeScrollBenchmarkMeasurement {
    enum Surface {
        case memberList
        case messageTimeline

        var name: StaticString {
            switch self {
            case .memberList: "MemberListAutoScrollBenchmark"
            case .messageTimeline: "MessageTimelineAutoScrollBenchmark"
            }
        }

        func event(for outcome: NativeTimelineBenchmarkFinishOutcome) -> StaticString? {
            switch (self, outcome) {
            case (.memberList, .completed): "MemberListAutoScrollBenchmarkCompleted"
            case (.memberList, .insufficientHistory): "MemberListAutoScrollBenchmarkInsufficientHistory"
            case (.memberList, .cancelled): "MemberListAutoScrollBenchmarkCancelled"
            // The member list never paginates.
            case (.memberList, .paginationFailed): nil
            case (.messageTimeline, .completed): "MessageTimelineAutoScrollBenchmarkCompleted"
            case (.messageTimeline, .insufficientHistory): "MessageTimelineAutoScrollBenchmarkInsufficientHistory"
            case (.messageTimeline, .cancelled): "MessageTimelineAutoScrollBenchmarkCancelled"
            case (.messageTimeline, .paginationFailed): "MessageTimelineAutoScrollBenchmarkPaginationFailed"
            }
        }
    }

    let surface: Surface
    private let gatesScrollWork: Bool
    private let interval: OSSignpostIntervalState

    init(_ surface: Surface, gatesScrollWork: Bool) {
        self.surface = surface
        self.gatesScrollWork = gatesScrollWork
        interval = AppPerformanceSignposts.signposter.beginInterval(surface.name)
        AppPerformanceSignposts.beginResourceWindow(named: surface.name.description)
        // Programmatic benchmark motion bypasses AppKit's live-scroll
        // notifications. Exercise the same loading-isolation gate as a real
        // trackpad gesture so scheduling regressions remain observable.
        if gatesScrollWork { AppScrollWorkGate.beginActivity() }
    }

    private func emitEvent(for outcome: NativeTimelineBenchmarkFinishOutcome) {
        if let event = surface.event(for: outcome) {
            AppPerformanceSignposts.signposter.emitEvent(event)
        }
    }

    private func endInterval() {
        AppPerformanceSignposts.signposter.endInterval(surface.name, interval)
    }

    private func endResourceWindow(after outcome: NativeTimelineBenchmarkFinishOutcome) {
        AppPerformanceSignposts.endResourceWindow(
            named: surface.name.description,
            nominalDuration: outcome == .completed
                ? NativeTimelineBenchmarkScrollPolicy.duration
                : nil
        )
    }

    /// Ends the scroll work, reports the outcome and closes the measurement
    /// around the run's artifact.
    func finish(
        outcome: NativeTimelineBenchmarkFinishOutcome,
        writeArtifact: () -> Void
    ) {
        if gatesScrollWork { AppScrollWorkGate.endActivity() }
        emitEvent(for: outcome)
        endInterval()
        writeArtifact()
        endResourceWindow(after: outcome)
    }
}

@MainActor
final class NativeTimelinePerformanceBenchmarkGate {
    static let shared = NativeTimelinePerformanceBenchmarkGate()

    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func begin() {
        guard !didStart else { return }
        didStart = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
    }
}
