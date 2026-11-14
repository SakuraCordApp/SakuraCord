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

nonisolated enum NativeTimelineBenchmarkScrollPolicy {
    // Keep the authenticated workload continuously moving at reading or
    // skimming speed. Much faster runs exhaust live history sooner than a
    // person could read it, which hides account-scale costs.
    /// Run for one fixed wall-clock interval at a refresh-independent target
    /// speed. Delayed frames remain part of the result: the step cap avoids
    /// measuring a stall twice, while the artifact records the resulting
    /// spatial deficit instead of censoring the run.
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

@MainActor
enum NativeTimelineBenchmarkArtifact {
    struct DelayedTick {
        let offset: TimeInterval
        let interval: TimeInterval
    }

    static func write(
        outcome: NativeTimelineBenchmarkFinishOutcome,
        completedDistance: CGFloat,
        elapsed: TimeInterval,
        completedTicks: Int? = nil,
        delayedTicks: Int? = nil,
        tickIntervals: [TimeInterval]? = nil,
        delayedTickSamples: [DelayedTick]? = nil,
        maximumTickInterval: TimeInterval? = nil,
        maximumScrollWork: TimeInterval? = nil,
        historyStarvedTicks: Int? = nil,
        maximumConsecutiveHistoryStarvedTicks: Int? = nil,
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
            if let completedTicks,
               let delayedTicks,
               let tickIntervals,
               let delayedTickSamples,
               let maximumTickInterval,
               let maximumScrollWork,
               let historyStarvedTicks,
               let maximumConsecutiveHistoryStarvedTicks
            {
                let sortedTickIntervals = tickIntervals.sorted()
                func percentile(_ fraction: Double) -> Double {
                    PerformanceBenchmarkHarness.nearestRankPercentile(sortedTickIntervals, fraction)
                }
                let delayedTickRate = completedTicks > 0
                    ? Double(delayedTicks) / Double(completedTicks)
                    : 0
                let delayedTickSampleText = delayedTickSamples.map { sample in
                    "\(sample.offset * 1_000):\(sample.interval * 1_000)"
                }.joined(separator: ",")
                fields += [
                    ("completed_ticks", completedTicks),
                    ("delayed_ticks_over_33ms", delayedTicks),
                    ("delayed_tick_rate", delayedTickRate),
                    ("median_tick_interval_ms", percentile(0.50) * 1_000),
                    ("p95_tick_interval_ms", percentile(0.95) * 1_000),
                    ("p99_tick_interval_ms", percentile(0.99) * 1_000),
                    ("maximum_tick_interval_ms", maximumTickInterval * 1_000),
                    ("delayed_tick_samples_offset_ms_interval_ms", delayedTickSampleText),
                    ("maximum_scroll_work_ms", maximumScrollWork * 1_000),
                    ("history_starved_ticks", historyStarvedTicks),
                    ("maximum_consecutive_history_starved_ticks", maximumConsecutiveHistoryStarvedTicks),
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
