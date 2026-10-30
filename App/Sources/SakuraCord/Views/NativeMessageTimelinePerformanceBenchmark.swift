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
            // Benchmark launch used to spend its warm-up interval as an
            // ordinary interactive timeline. That installed tracking and
            // accessibility proxies beneath a stationary pointer, then
            // tore them down on the first measured scroll frame. Besides
            // producing a visible hover/highlight phase, the transition
            // made the beginning of every run materially colder than the
            // rest. Enter the scrolling presentation before warm-up.
            //
            // Do not eagerly rasterize rows here. During active scrolling
            // the canvas deliberately paints uncached rows directly; a
            // prewarm would defeat that fallback and make the first cold
            // AppKit/CoreText bitmap block the main thread before motion.
            canvas.dismissHoverPresentationForScroll()
            noteScrollActivity()
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
                    // A fixed delay can expire before AppKit has presented even
                    // one timeline frame. Starting in that state leaves the
                    // ordinary hover/tracking presentation installed and the
                    // bottom overlay clipped until the first real display
                    // transaction arrives. Gate on frames actually delivered
                    // by this view, then require a brief responsive interval.
                    let startupDeadline =
                        ProcessInfo.processInfo.systemUptime + 3
                    while !NativeTimelineBenchmarkStartupPolicy.isReady(
                        completedTicks: startup.completedTicks,
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
                // above the floating composer. Starting the benchmark at that
                // exact edge made its first frames look clipped at a hard
                // footer line; only after consuming the spacer did rows travel
                // beneath the overlay like the rest of the run. Move past the
                // spacer before telemetry and live-arrival stress begin.
                startup.phase = "position-shift"
                let initialRect = scrollView.contentView.bounds
                let scrollsTowardLater =
                    parent.conversation.loaderKind == .pins
                let positionShift =
                    bottomInset + min(160, initialRect.height * 0.25)
                scroll(
                    toDocumentY:
                        scrollsTowardLater
                            ? initialRect.minY + positionShift
                            : materializedHistoryMaximumY(viewportHeight: initialRect.height) - initialRect.height - min(160, initialRect.height * 0.25),
                    scrollView: scrollView
                )
                startup.phase = "settling"
                let ticksBeforePositionShift = startup.completedTicks
                let positionShiftDeadline =
                    ProcessInfo.processInfo.systemUptime + 0.250
                do {
                    // Do not switch to measured motion until AppKit has
                    // presented the position shift that moves rows beneath the
                    // floating composer.
                    while startup.completedTicks <= ticksBeforePositionShift,
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
                    max handoff tick \(startup.maximumTickInterval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
                    max canvas draw \(canvas.maximumDrawDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
                    max row raster \(canvas.maximumRowRasterDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms \
                    over \(startup.completedTicks, privacy: .public) ticks (\(startup.delayedTicks, privacy: .public) above 33 ms)
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
                // Exercise native pagination directly. This synthetic workload
                // must never invoke the user-interaction callback: that callback
                // deliberately unblocks read acknowledgements for real input.
                beginPerformanceBenchmarkPaginationIntent(
                    towardLater: scrollsTowardLater
                )
                let signpost = Self.performanceSignposter.beginInterval(
                    "MessageTimelineAutoScrollBenchmark"
                )
                AppPerformanceSignposts.beginResourceWindow(
                    named: "MessageTimelineAutoScrollBenchmark"
                )
                let state = NativeTimelineBenchmarkRunState(
                    scrollsTowardLater: scrollsTowardLater,
                    initialItemCount: items.count,
                    closeMeasurement: {
                        Self.performanceSignposter.endInterval(
                            "MessageTimelineAutoScrollBenchmark",
                            signpost
                        )
                    }
                )
                self.performanceDisplayLinkTicker = state.ticker
                let finish: (NativeTimelineBenchmarkFinishOutcome) -> Void = { [weak self, weak canvas, state] outcome in
                    guard let elapsed = state.finish(
                        beforeMeasurementClose: {
                            Self.emitPerformanceBenchmarkOutcome(outcome)
                        },
                        performBookkeeping: { elapsed in
                            Self.writePerformanceBenchmarkArtifact(
                                outcome: outcome,
                                elapsed: elapsed,
                                state: state,
                                canvas: canvas
                            )
                        }
                    ) else { return }
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
                // The deterministic workload bypasses NSEvent, but production
                // loading isolation keys off the same cross-surface gate as a
                // real gesture. Exercise that scheduling policy here so the
                // permanent benchmark catches priority regressions.
                AppScrollWorkGate.beginActivity()
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
            scroll(toDocumentY: targetDocumentY, scrollView: scrollView)
            reportScrollState()
            let currentDocumentY = scrollView.contentView.bounds.minY
            let didAdvance = state.scrollsTowardLater
                ? currentDocumentY > visibleRect.minY + 0.5
                : currentDocumentY < visibleRect.minY - 0.5
            let hasMoreHistory = state.scrollsTowardLater
                ? parent.hasMoreLaterMessages
                : parent.hasMoreMessages
            state.recordHistoryProgress(
                didAdvance: didAdvance,
                hasMoreHistory: hasMoreHistory
            )
            state.maximumScrollWork = max(
                state.maximumScrollWork,
                ProcessInfo.processInfo.systemUptime - workStart
            )
            let result = state.controller.recordTick(
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
            switch result {
            case .continueBenchmark:
                break
            case .completed:
                finish(.completed)
            case .insufficientHistory:
                finish(.insufficientHistory)
            case .paginationFailed:
                finish(.paginationFailed)
            }
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

        static func emitPerformanceBenchmarkOutcome(
            _ outcome: NativeTimelineBenchmarkFinishOutcome
        ) {
            let event: StaticString = switch outcome {
            case .completed:
                "MessageTimelineAutoScrollBenchmarkCompleted"
            case .insufficientHistory:
                "MessageTimelineAutoScrollBenchmarkInsufficientHistory"
            case .cancelled:
                "MessageTimelineAutoScrollBenchmarkCancelled"
            case .paginationFailed:
                "MessageTimelineAutoScrollBenchmarkPaginationFailed"
            }
            Self.performanceSignposter.emitEvent(event)
        }

        static func writePerformanceBenchmarkArtifact(
            outcome: NativeTimelineBenchmarkFinishOutcome,
            elapsed: TimeInterval,
            state: NativeTimelineBenchmarkRunState,
            canvas: NativeTimelineCanvasView?
        ) {
            NativeTimelineBenchmarkArtifact.write(
                outcome: outcome,
                completedDistance: state.controller.completedDistance,
                elapsed: elapsed,
                completedTicks: state.completedTicks,
                delayedTicks: state.delayedTicks,
                tickIntervals: state.tickIntervals,
                delayedTickSamples: state.delayedTickSamples,
                maximumTickInterval: state.maximumTickInterval,
                maximumScrollWork: state.maximumScrollWork,
                historyStarvedTicks: state.historyStarvedTicks,
                maximumConsecutiveHistoryStarvedTicks:
                    state.maximumHistoryStarvedTicks,
                renderTelemetry: canvas?.renderTelemetry
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "MessageTimelineAutoScrollBenchmark",
                nominalDuration: outcome == .completed
                    ? NativeTimelineBenchmarkScrollPolicy.duration
                    : nil
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
                state.maximumTickInterval * 1_000,
                state.maximumScrollWork * 1_000,
                (canvas?.maximumDrawDuration ?? 0) * 1_000,
                (canvas?.maximumRowRasterDuration ?? 0) * 1_000,
                canvas?.maximumRowRasterHeight ?? 0,
                state.completedTicks,
                state.delayedTicks,
                state.maximumTickItemCount,
                state.maximumTickDocumentY,
                state.historyStarvedTicks,
                state.maximumHistoryStarvedTicks,
                state.controller.completedDistance,
                NativeTimelineBenchmarkScrollPolicy.nominalDistance,
                elapsed
            )
            Self.performanceLogger.notice("\(summary, privacy: .public)")
        }

}
