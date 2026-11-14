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
    // Keep the authenticated workload continuously moving at a speed that is
    // representative of reading/skim scrolling. The former 9,600 pt/s target
    // crossed roughly 160 points per 60 Hz frame, exhausting live history far
    // faster than a person could inspect it and obscuring account-scale costs.
    /// Run for one fixed wall-clock interval at a refresh-independent target
    /// speed. Delayed frames remain part of the result: the step cap avoids
    /// measuring a stall twice, while the artifact records the resulting
    /// spatial deficit instead of censoring the run.
    static let pointsPerSecond: CGFloat = 1_200
    static let maximumStep: CGFloat = 40
    static let duration: TimeInterval = 20
    static let nominalDistance = pointsPerSecond * duration
    /// Measures live updates on a still timeline instead of a scrolling one.
    static let isIdle = ProcessInfo.processInfo.arguments.contains("--offline-chat-performance-idle")

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
    enum Outcome: Equatable {
        case continueBenchmark
        case completed
        case insufficientHistory
        case paginationFailed
    }

    let startedAt: TimeInterval
    private(set) var completedDistance: CGFloat = 0

    mutating func recordTick(
        uptime: TimeInterval,
        previousDocumentY: CGFloat,
        currentDocumentY: CGFloat,
        hasMoreMessages: Bool,
        paginationFailed: Bool = false
    ) -> Outcome {
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
        return .continueBenchmark
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
        guard let path = ProcessInfo.processInfo.environment[
            "SAKURACORD_PERFORMANCE_RESULT_PATH"
        ] else { return }
        let duration = NativeTimelineBenchmarkScrollPolicy.duration
        let overshoot = max(0, elapsed - duration)
        var contents = """
        outcome\t\(outcome.rawValue)
        elapsed_seconds\t\(elapsed)
        nominal_duration_seconds\t\(duration)
        elapsed_overshoot_seconds\t\(overshoot)

        """
        // A still timeline covers no distance by design.
        if !NativeTimelineBenchmarkScrollPolicy.isIdle {
            contents += """
            completed_distance_points\t\(completedDistance)
            nominal_distance_points\t\(NativeTimelineBenchmarkScrollPolicy.nominalDistance)
            distance_deficit_points\t\(NativeTimelineBenchmarkScrollPolicy.distanceDeficit(completedDistance: completedDistance))
            spatial_quality_ratio\t\(NativeTimelineBenchmarkScrollPolicy.spatialQuality(completedDistance: completedDistance))

            """
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
            let medianTickInterval = PerformanceBenchmarkHarness.nearestRankPercentile(sortedTickIntervals, 0.50)
            let p95TickInterval = PerformanceBenchmarkHarness.nearestRankPercentile(sortedTickIntervals, 0.95)
            let p99TickInterval = PerformanceBenchmarkHarness.nearestRankPercentile(sortedTickIntervals, 0.99)
            let delayedTickRate = completedTicks > 0
                ? Double(delayedTicks) / Double(completedTicks)
                : 0
            let delayedTickSampleText = delayedTickSamples.map { sample in
                "\(sample.offset * 1_000):\(sample.interval * 1_000)"
            }.joined(separator: ",")
            contents += """
            completed_ticks\t\(completedTicks)
            delayed_ticks_over_33ms\t\(delayedTicks)
            delayed_tick_rate\t\(delayedTickRate)
            median_tick_interval_ms\t\(medianTickInterval * 1_000)
            p95_tick_interval_ms\t\(p95TickInterval * 1_000)
            p99_tick_interval_ms\t\(p99TickInterval * 1_000)
            maximum_tick_interval_ms\t\(maximumTickInterval * 1_000)
            delayed_tick_samples_offset_ms_interval_ms\t\(delayedTickSampleText)
            maximum_scroll_work_ms\t\(maximumScrollWork * 1_000)
            history_starved_ticks\t\(historyStarvedTicks)
            maximum_consecutive_history_starved_ticks\t\(maximumConsecutiveHistoryStarvedTicks)

            """
        }
        if let renderTelemetry {
            contents += """
            canvas_draw_count\t\(renderTelemetry.canvasDrawCount)
            canvas_draw_total_ms\t\(renderTelemetry.canvasDrawTotalDuration * 1_000)
            canvas_draw_average_ms\t\(renderTelemetry.canvasDrawAverageDuration * 1_000)
            canvas_draw_maximum_ms\t\(renderTelemetry.canvasDrawMaximumDuration * 1_000)
            row_raster_count\t\(renderTelemetry.rowRasterCount)
            row_raster_total_ms\t\(renderTelemetry.rowRasterTotalDuration * 1_000)
            row_raster_average_ms\t\(renderTelemetry.rowRasterAverageDuration * 1_000)
            row_raster_maximum_ms\t\(renderTelemetry.rowRasterMaximumDuration * 1_000)
            row_raster_maximum_height_points\t\(renderTelemetry.rowRasterMaximumHeight)
            row_bitmap_cache_hit_count\t\(renderTelemetry.rowBitmapCacheHitCount)
            live_scroll_direct_paint_count\t\(renderTelemetry.liveScrollDirectPaintCount)

            """
        }
        if let mainThreadCPUTime {
            contents += "main_thread_cpu_ms\t\(mainThreadCPUTime * 1_000)\n"
        }
        if let timelineUpdates {
            contents += """
            timeline_update_count\t\(timelineUpdates.count)
            timeline_update_total_ms\t\(timelineUpdates.milliseconds)

            """
        }
        try? contents.write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
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
