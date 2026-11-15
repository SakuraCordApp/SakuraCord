import AppKit
import OSLog

extension NativeMemberListCoordinator {
    func startPerformanceBenchmarkIfReady() {
        guard parent.runsPerformanceAutoScroll,
              !didStartPerformanceBenchmark,
              performanceStartTask == nil,
              documentPreparationTask == nil,
              let scrollView,
              let canvas,
              canvas.contentHeight
                >= NativeTimelineBenchmarkScrollPolicy.nominalDistance
                    + scrollView.contentSize.height
        else { return }
        // Server selection, accessibility inspection by the benchmark driver,
        // initial range delivery, and member-document preparation are separate
        // loading paths. Require three seconds with no replacement document,
        // rather than three seconds after the first tall document, so this idle
        // scenario never silently turns into a loading-overlap measurement.
        performanceStartGeneration &+= 1
        let startGeneration = performanceStartGeneration
        performanceStartTask = Task { [weak self, weak scrollView, weak canvas] in
            defer {
                if let self,
                   self.performanceStartGeneration == startGeneration
                {
                    self.performanceStartTask = nil
                }
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  let self,
                  self.performanceStartGeneration == startGeneration,
                  self.documentPreparationTask == nil,
                  let scrollView,
                  let canvas,
                  canvas.contentHeight
                    >= NativeTimelineBenchmarkScrollPolicy.nominalDistance
                        + scrollView.contentSize.height
            else { return }
            didStartPerformanceBenchmark = true
            runPerformanceBenchmark(scrollView: scrollView, canvas: canvas)
        }
    }

    func runPerformanceBenchmark(
        scrollView: NSScrollView,
        canvas: NativeMemberListCanvasView
    ) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let measurement = NativeScrollBenchmarkMeasurement(
            .memberList,
            gatesScrollWork: true
        )
        performanceMeasurement = measurement
        var ticks = NativeTimelineBenchmarkTickStats()
        var completedDistance: CGFloat = 0
        let ticker = DisplayLinkTicker()
        performanceTicker = ticker
        ticker.start(on: canvas) { [weak self, weak ticker] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - ticks.startedAt
            let delta = NativeTimelineBenchmarkScrollPolicy.distance(
                tickInterval: ticks.recordTick(at: now)
            )
            let workStart = ProcessInfo.processInfo.systemUptime
            let previousY = scrollView.contentView.bounds.minY
            let maximumY = max(
                0,
                canvas.contentHeight - scrollView.contentSize.height
            )
            let nextY = min(maximumY, previousY + delta)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            completedDistance += max(0, nextY - previousY)
            ticks.maximumScrollWork = max(
                ticks.maximumScrollWork,
                ProcessInfo.processInfo.systemUptime - workStart
            )
            if elapsed >= NativeTimelineBenchmarkScrollPolicy.duration
                || nextY >= maximumY - 0.5
            {
                ticker?.stop()
                performanceTicker = nil
                performanceMeasurement = nil
                let outcome: NativeTimelineBenchmarkFinishOutcome =
                    elapsed >= NativeTimelineBenchmarkScrollPolicy.duration
                        ? .completed : .insufficientHistory
                measurement.finish(outcome: outcome) {
                    NativeTimelineBenchmarkArtifact.write(
                        outcome: outcome,
                        completedDistance: completedDistance,
                        elapsed: elapsed,
                        ticks: ticks
                    )
                }
            }
        }
    }

    func cancelPerformanceBenchmark() {
        if let performanceMeasurement {
            performanceMeasurement.finish(outcome: .cancelled) {
                NativeTimelineBenchmarkArtifact.write(
                    outcome: .cancelled,
                    completedDistance: 0,
                    elapsed: 0
                )
            }
        }
        performanceTicker?.stop()
        performanceTicker = nil
        performanceMeasurement = nil
    }
}
