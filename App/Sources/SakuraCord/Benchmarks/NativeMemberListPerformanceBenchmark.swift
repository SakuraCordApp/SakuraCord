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
        let interval = beginPerformanceScrollMeasurement()
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
                AppScrollWorkGate.endActivity()
                ticker?.stop()
                performanceTicker = nil
                let outcome: NativeTimelineBenchmarkFinishOutcome =
                    elapsed >= NativeTimelineBenchmarkScrollPolicy.duration
                        ? .completed : .insufficientHistory
                switch outcome {
                case .completed:
                    AppPerformanceSignposts.signposter.emitEvent(
                        "MemberListAutoScrollBenchmarkCompleted"
                    )
                case .insufficientHistory:
                    AppPerformanceSignposts.signposter.emitEvent(
                        "MemberListAutoScrollBenchmarkInsufficientHistory"
                    )
                case .cancelled, .paginationFailed:
                    break
                }
                AppPerformanceSignposts.signposter.endInterval(
                    "MemberListAutoScrollBenchmark",
                    interval
                )
                performanceInterval = nil
                NativeTimelineBenchmarkArtifact.write(
                    outcome: outcome,
                    completedDistance: completedDistance,
                    elapsed: elapsed,
                    ticks: ticks
                )
                AppPerformanceSignposts.endResourceWindow(
                    named: "MemberListAutoScrollBenchmark",
                    nominalDuration:
                        outcome == .completed
                            ? NativeTimelineBenchmarkScrollPolicy.duration : nil
                )
            }
        }
    }

    private func beginPerformanceScrollMeasurement() -> OSSignpostIntervalState {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "MemberListAutoScrollBenchmark"
        )
        performanceInterval = interval
        // Programmatic benchmark motion bypasses AppKit's live-scroll
        // notifications. Exercise the same loading-isolation gate as a real
        // trackpad gesture so cross-surface regressions remain observable.
        AppScrollWorkGate.beginActivity()
        AppPerformanceSignposts.beginResourceWindow(
            named: "MemberListAutoScrollBenchmark"
        )
        return interval
    }

    func cancelPerformanceBenchmark() {
        if let performanceInterval {
            AppScrollWorkGate.endActivity()
            AppPerformanceSignposts.signposter.emitEvent(
                "MemberListAutoScrollBenchmarkCancelled"
            )
            AppPerformanceSignposts.signposter.endInterval(
                "MemberListAutoScrollBenchmark",
                performanceInterval
            )
            NativeTimelineBenchmarkArtifact.write(
                outcome: .cancelled,
                completedDistance: 0,
                elapsed: 0
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "MemberListAutoScrollBenchmark"
            )
        }
        performanceTicker?.stop()
        performanceTicker = nil
        performanceInterval = nil
    }
}
