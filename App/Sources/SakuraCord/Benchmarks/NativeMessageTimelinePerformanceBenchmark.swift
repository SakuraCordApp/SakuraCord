import AppKit
import OSLog
import SakuraCordModels

extension NativeMessageTimelineCoordinator {
    func startPerformanceAutoScrollIfNeeded() {
        // History pages are viewport-sized, as Discord's are, so a
        // settled timeline holds about a screenful and the run pages in
        // the rest itself. One with no more history, such as the launch
        // conversation, has nothing to measure.
        guard parent.runsPerformanceAutoScroll,
              !didStartPerformanceAutoScroll,
              parent.hasMoreMessages || parent.hasMoreLaterMessages,
              initialPositionConversation == parent.conversation,
              let canvas
        else { return }
        didStartPerformanceAutoScroll = true
        isPreparingOrRunningPerformanceBenchmark = true
        let startup = NativeTimelineBenchmarkStartupState()
        startup.ticker.start(on: canvas) { [weak startup] in
            guard let startup else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            let interval = startup.recordTick(at: uptime)
            if interval > 0.033 {
                Self.performanceLogger.notice(
                    "SakuraCord delayed benchmark startup tick: \(interval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; phase \(startup.phase, privacy: .public)"
                )
            }
        }
        // Enter the scrolling presentation before warm-up. Warming up as
        // an ordinary interactive timeline installs tracking and
        // accessibility proxies beneath the stationary pointer that the
        // first measured scroll frame tears down, which shows a
        // hover/highlight phase and makes the start of every run
        // materially colder than the rest.
        //
        // Do not eagerly rasterize rows here. During active scrolling
        // the canvas deliberately paints uncached rows directly; a
        // prewarm would defeat that fallback and make the first cold
        // AppKit/CoreText bitmap block the main thread before motion.
        // An idle run measures the ordinary stationary timeline.
        if !NativeTimelineBenchmarkScrollPolicy.isIdle {
            canvas.dismissHoverPresentationForScroll()
            noteScrollActivity()
        }
        startup.phase = "launch-stabilization"
        performanceAutoScrollTask = Task { @MainActor [weak self, weak canvas] in
            guard let self, let canvas else { return }
            await preparePerformanceBenchmark(startup: startup, canvas: canvas)
        }
    }

    func preparePerformanceBenchmark(
        startup: NativeTimelineBenchmarkStartupState,
        canvas: NativeTimelineCanvasView
    ) async {
        do {
            // Gate on frames actually delivered by this view, then
            // require a brief responsive interval: starting before
            // AppKit presents a timeline frame leaves the ordinary
            // hover/tracking presentation installed and the bottom
            // overlay clipped until the first real display transaction.
            let startupDeadline =
                ProcessInfo.processInfo.systemUptime + 3
            while !NativeTimelineBenchmarkStartupPolicy.isReady(
                completedTicks: startup.ticks.completedTicks,
                uptime: ProcessInfo.processInfo.systemUptime,
                lastDelayedTickUptime: startup.lastDelayedTickUptime
            ),
                ProcessInfo.processInfo.systemUptime < startupDeadline
            {
                try await Task.sleep(for: .milliseconds(16))
            }
        } catch {
            startup.ticker.stop()
            return
        }
        guard let scrollView = self.scrollView,
              self.canvas === canvas
        else { return }
        // The bottom spacer deliberately keeps the newest message
        // above the floating composer. Move past it before telemetry
        // and live-arrival stress begin, so the first frames already
        // carry rows beneath the overlay instead of looking clipped
        // at a hard footer line.
        startup.phase = "position-shift"
        let initialRect = scrollView.contentView.bounds
        let scrollsTowardLater =
            parent.conversation.loaderKind == .pins
        let positionShift = min(160, initialRect.height * 0.25)
        // An idle run stays where the conversation opened, pinned
        // to its newest message.
        if !NativeTimelineBenchmarkScrollPolicy.isIdle {
            scroll(
                toDocumentY:
                scrollsTowardLater
                    ? initialRect.minY + (bottomInset + positionShift)
                    : materializedHistoryMaximumY(viewportHeight: initialRect.height) - initialRect.height - positionShift,
                scrollView: scrollView
            )
        }
        startup.phase = "settling"
        let ticksBeforePositionShift = startup.ticks.completedTicks
        let positionShiftDeadline =
            ProcessInfo.processInfo.systemUptime + 0.250
        do {
            // Do not switch to measured motion until AppKit has
            // presented the position shift that moves rows beneath the
            // floating composer.
            while startup.ticks.completedTicks <= ticksBeforePositionShift,
                  ProcessInfo.processInfo.systemUptime
                  < positionShiftDeadline
            {
                try await Task.sleep(for: .milliseconds(8))
            }
        } catch {
            startup.ticker.stop()
            return
        }
        startup.ticker.stop()
        Self.performanceLogger.notice(
            """
            SakuraCord timeline benchmark startup: \
            max handoff tick \(startup.ticks.maximumTickInterval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
            max canvas draw \(canvas.maximumDrawDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
            max row raster \(canvas.maximumRowRasterDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms \
            over \(startup.ticks.completedTicks, privacy: .public) ticks (\(startup.ticks.delayedTicks, privacy: .public) above 33 ms)
            """
        )
        startMeasuredPerformanceBenchmark(
            canvas: canvas,
            scrollView: scrollView,
            scrollsTowardLater: scrollsTowardLater
        )
    }

    func startMeasuredPerformanceBenchmark(
        canvas: NativeTimelineCanvasView,
        scrollView: NSScrollView,
        scrollsTowardLater: Bool
    ) {
        canvas.resetDrawTelemetry()
        performanceUpdateCount = 0
        performanceUpdateTotalDuration = 0
        // Exercise native pagination directly. This synthetic workload
        // must never invoke the user-interaction callback: that callback
        // deliberately unblocks read acknowledgements for real input.
        beginPerformanceBenchmarkPaginationIntent(
            towardLater: scrollsTowardLater
        )
        // An idle run measures a still timeline, which a real gesture would
        // never gate.
        let measurement = NativeScrollBenchmarkMeasurement(
            .messageTimeline,
            gatesScrollWork: !NativeTimelineBenchmarkScrollPolicy.isIdle
        )
        let state = NativeTimelineBenchmarkRunState(
            scrollsTowardLater: scrollsTowardLater,
            initialItemCount: items.count,
            measurement: measurement
        )
        self.performanceDisplayLinkTicker = state.ticker
        let finish: (NativeTimelineBenchmarkFinishOutcome) -> Void = { [weak self, weak canvas, state] outcome in
            guard let elapsed = state.finish(outcome: outcome, writeArtifact: { elapsed in
                Self.writePerformanceBenchmarkArtifact(
                    outcome: outcome,
                    elapsed: elapsed,
                    state: state,
                    canvas: canvas,
                    timelineUpdates: (
                        self?.performanceUpdateCount ?? 0,
                        self?.performanceUpdateTotalDuration ?? 0
                    )
                )
            }) else { return }
            Self.logPerformanceBenchmarkSummary(
                elapsed: elapsed,
                state: state,
                canvas: canvas
            )
            self?.finishPerformanceBenchmarkCoordinatorState(
                scrollsTowardLater: state.scrollsTowardLater
            )
        }
        self.performanceBenchmarkFinish = finish
        state.ticker.start(on: canvas) { [weak self, weak scrollView, weak state] in
            guard let self, let scrollView, let state else {
                finish(.cancelled)
                return
            }
            handlePerformanceBenchmarkTick(
                state: state,
                scrollView: scrollView,
                finish: finish
            )
        }
        NativeTimelinePerformanceBenchmarkGate.shared.begin()
    }

    func handlePerformanceBenchmarkTick(
        state: NativeTimelineBenchmarkRunState,
        scrollView: NSScrollView,
        finish: (NativeTimelineBenchmarkFinishOutcome) -> Void
    ) {
        let tickUptime = ProcessInfo.processInfo.systemUptime
        let visibleRect = scrollView.contentView.bounds
        let tickInterval = state.recordTick(
            at: tickUptime,
            itemCount: items.count,
            documentY: visibleRect.minY
        )
        logDelayedPerformanceTickIfNeeded(tickInterval)
        let workStart = ProcessInfo.processInfo.systemUptime
        let scrollDistance = NativeTimelineBenchmarkScrollPolicy.distance(
            tickInterval: tickInterval
        )
        let targetDocumentY = state.scrollsTowardLater
            ? visibleRect.minY + scrollDistance
            : visibleRect.minY - scrollDistance
        // A real gesture that pushes past the loaded edge enters the
        // provisional reserve, which an unread conversation needs before
        // it loads; this scroll is clamped short of it, so it crosses on
        // the gesture's behalf.
        let direction: TimelineHistoryDirection = state.scrollsTowardLater ? .later : .earlier
        let boundaryY = materializedHistoryScrollBoundaryY(direction, viewportHeight: visibleRect.height)
        if state.scrollsTowardLater ? targetDocumentY > boundaryY : targetDocumentY < boundaryY {
            setFollowsMaterializedHistoryBoundary(true, direction: direction)
        }
        if !NativeTimelineBenchmarkScrollPolicy.isIdle {
            scroll(toDocumentY: targetDocumentY, scrollView: scrollView)
            reportScrollState()
        }
        let currentDocumentY = scrollView.contentView.bounds.minY
        let didAdvance = state.scrollsTowardLater
            ? currentDocumentY > visibleRect.minY + 0.5
            : currentDocumentY < visibleRect.minY - 0.5
        let hasMoreHistory = state.scrollsTowardLater
            ? parent.hasMoreLaterMessages
            : parent.hasMoreMessages
        // A still timeline is not starved of history.
        if !NativeTimelineBenchmarkScrollPolicy.isIdle {
            state.ticks.recordHistoryProgress(
                didAdvance: didAdvance,
                hasMoreHistory: hasMoreHistory
            )
        }
        state.ticks.maximumScrollWork = max(
            state.ticks.maximumScrollWork,
            ProcessInfo.processInfo.systemUptime - workStart
        )
        let outcome = state.controller.recordTick(
            uptime: tickUptime,
            previousDocumentY: state.scrollsTowardLater
                ? -visibleRect.minY : visibleRect.minY,
            currentDocumentY: state.scrollsTowardLater
                ? -currentDocumentY : currentDocumentY,
            hasMoreMessages: hasMoreHistory,
            paginationFailed: state.scrollsTowardLater
                ? parent.laterHistoryLoadFailed
                : parent.earlierHistoryLoadFailed
        )
        if let outcome { finish(outcome) }
    }

    func logDelayedPerformanceTickIfNeeded(_ interval: TimeInterval) {
        guard interval >= 0.080 else { return }
        Self.performanceLogger.notice(
            """
            SakuraCord delayed timeline tick: \
            \(interval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
            last update \(self.performanceUpdatePath, privacy: .public) \
            \(self.lastPerformanceUpdateDuration, format: .fixed(precision: 2), privacy: .public) ms; \
            items \(self.items.count, privacy: .public); revision \(self.rowsRevision, privacy: .public)
            """
        )
    }

    func finishPerformanceBenchmarkCoordinatorState(
        scrollsTowardLater: Bool
    ) {
        isPreparingOrRunningPerformanceBenchmark = false
        endPerformanceBenchmarkPaginationIntent(
            towardLater: scrollsTowardLater
        )
        performanceDisplayLinkTicker = nil
        performanceBenchmarkFinish = nil
        finishScrollActivity()
    }

    static func writePerformanceBenchmarkArtifact(
        outcome: NativeTimelineBenchmarkFinishOutcome,
        elapsed: TimeInterval,
        state: NativeTimelineBenchmarkRunState,
        canvas: NativeTimelineCanvasView?,
        timelineUpdates: (count: Int, milliseconds: Double)
    ) {
        NativeTimelineBenchmarkArtifact.write(
            outcome: outcome,
            completedDistance: state.controller.completedDistance,
            elapsed: elapsed,
            ticks: state.ticks,
            renderTelemetry: canvas?.renderTelemetry,
            mainThreadCPUTime: PerformanceBenchmarkHarness.currentThreadCPUTime()
                - state.mainThreadCPUTimeAtStart,
            timelineUpdates: timelineUpdates
        )
    }

    static func logPerformanceBenchmarkSummary(
        elapsed: TimeInterval,
        state: NativeTimelineBenchmarkRunState,
        canvas: NativeTimelineCanvasView?
    ) {
        let summary = String(
            format:
            "SakuraCord timeline benchmark: max main-thread tick interval %.2f ms; "
                + "max scroll work %.2f ms; max canvas draw %.2f ms; "
                + "max row raster %.2f ms (height %.0f) over %d ticks "
                + "(%d above 33 ms; max at %d items, y %.0f); "
                + "history-starved %d ticks (max %d consecutive); "
                + "spatial work %.0f / %.0f nominal points in %.2f s",
            state.ticks.maximumTickInterval * 1_000,
            state.ticks.maximumScrollWork * 1_000,
            (canvas?.maximumDrawDuration ?? 0) * 1_000,
            (canvas?.maximumRowRasterDuration ?? 0) * 1_000,
            canvas?.maximumRowRasterHeight ?? 0,
            state.ticks.completedTicks,
            state.ticks.delayedTicks,
            state.maximumTickItemCount,
            state.maximumTickDocumentY,
            state.ticks.historyStarvedTicks,
            state.ticks.maximumConsecutiveHistoryStarvedTicks,
            state.controller.completedDistance,
            NativeTimelineBenchmarkScrollPolicy.nominalDistance,
            elapsed
        )
        Self.performanceLogger.notice("\(summary, privacy: .public)")
    }

}

@MainActor
final class NativeTimelineBenchmarkStartupState {
    let ticker = DisplayLinkTicker()
    private(set) var ticks = NativeTimelineBenchmarkTickStats()
    var phase = "initial-render"
    private(set) var lastDelayedTickUptime = ProcessInfo.processInfo.systemUptime

    func recordTick(at uptime: TimeInterval) -> TimeInterval {
        let interval = ticks.recordTick(at: uptime)
        if interval > 0.033 {
            lastDelayedTickUptime = uptime
        }
        return interval
    }
}

@MainActor
final class NativeTimelineBenchmarkRunState {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let mainThreadCPUTimeAtStart = PerformanceBenchmarkHarness.currentThreadCPUTime()
    let ticker = DisplayLinkTicker()
    let scrollsTowardLater: Bool
    private let measurement: NativeScrollBenchmarkMeasurement
    var controller: NativeTimelineBenchmarkScrollController
    var ticks: NativeTimelineBenchmarkTickStats
    var maximumTickItemCount: Int
    var maximumTickDocumentY = 0.0
    var didFinish = false

    init(
        scrollsTowardLater: Bool,
        initialItemCount: Int,
        measurement: NativeScrollBenchmarkMeasurement
    ) {
        self.scrollsTowardLater = scrollsTowardLater
        self.measurement = measurement
        controller = NativeTimelineBenchmarkScrollController(startedAt: startedAt)
        ticks = NativeTimelineBenchmarkTickStats(startedAt: startedAt)
        maximumTickItemCount = initialItemCount
    }

    func recordTick(at uptime: TimeInterval, itemCount: Int, documentY: CGFloat) -> TimeInterval {
        let previousMaximum = ticks.maximumTickInterval
        let interval = ticks.recordTick(at: uptime)
        if interval > previousMaximum {
            maximumTickItemCount = itemCount
            maximumTickDocumentY = documentY
        }
        return interval
    }

    @discardableResult
    func finish(
        outcome: NativeTimelineBenchmarkFinishOutcome,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        writeArtifact: (_ elapsed: TimeInterval) -> Void
    ) -> TimeInterval? {
        guard !didFinish else { return nil }
        didFinish = true
        ticker.stop()
        let elapsed = now() - startedAt
        measurement.finish(outcome: outcome) { writeArtifact(elapsed) }
        return elapsed
    }
}

extension NativeMessageTimelineCoordinator {
    func beginPerformanceBenchmarkPaginationIntent(towardLater: Bool) {
        if towardLater {
            isLaterHistoryScrollGestureActive = true
            hasLaterHistoryScrollIntent = true
            hasIssuedLaterHistoryRequest = parent.isLoadingLater
        } else {
            isEarlierHistoryScrollGestureActive = true
            hasEarlierHistoryScrollIntent = true
            hasIssuedEarlierHistoryRequest = parent.isLoadingEarlier
        }
    }

    func endPerformanceBenchmarkPaginationIntent(towardLater: Bool) {
        if towardLater {
            isLaterHistoryScrollGestureActive = false
            hasLaterHistoryScrollIntent = false
        } else {
            isEarlierHistoryScrollGestureActive = false
            hasEarlierHistoryScrollIntent = false
        }
    }
}
