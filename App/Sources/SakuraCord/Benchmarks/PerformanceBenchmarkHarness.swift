import AppKit
import Darwin
import OSLog

/// What the performance benchmarks share: display-link runs, frame
/// summaries, main-thread CPU time, finding the scroll view under test and
/// writing results. Each benchmark keeps its own scenario, output and gating.
@MainActor
enum PerformanceBenchmarkHarness {
    /// p50, p95, p99 and maximum of a set of samples.
    struct Summary: Codable {
        var p50: Double
        var p95: Double
        var p99: Double
        var max: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func percentile(_ fraction: Double) -> Double {
                sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
            }
            p50 = percentile(0.5)
            p95 = percentile(0.95)
            p99 = percentile(0.99)
            max = sorted.last ?? 0
        }
    }

    /// Frame timing and main-thread CPU time of one measured phase.
    struct Phase {
        var frames = 0
        var frameIntervalsMS: Summary?
        var delayedFrames = 0
        var mainThreadCPUMS: Double = 0
    }

    /// One display-link frame of a run.
    struct Frame {
        /// System uptime at the frame.
        let now: TimeInterval
        /// Since the previous frame, or the run's start for the first.
        let interval: TimeInterval
        /// Since the run started.
        let elapsed: TimeInterval
    }

    /// Calls `tick` on every display-link frame until `seconds` have passed.
    /// `endsByDeadline` also ends it on a wall-clock deadline, for a view
    /// whose display link stops firing when it leaves the window.
    static func runDisplayLink(
        on view: NSView,
        seconds: TimeInterval,
        endsByDeadline: Bool = false,
        tick: @escaping (Frame) -> Void
    ) async {
        let ticker = DisplayLinkTicker()
        let start = ProcessInfo.processInfo.systemUptime
        var previous = start
        let completion = DisplayLinkRunCompletion()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.continuation = continuation
            if endsByDeadline {
                completion.deadline = Task { @MainActor in
                    guard (try? await Task.sleep(for: .seconds(seconds + 5))) != nil else { return }
                    ticker.stop()
                    completion.finish()
                }
            }
            ticker.start(on: view) {
                let now = ProcessInfo.processInfo.systemUptime
                tick(Frame(now: now, interval: now - previous, elapsed: now - start))
                previous = now
                if now - start >= seconds {
                    ticker.stop()
                    completion.finish()
                }
            }
        }
    }

    /// Runs `tick` on every frame for `seconds`, recording frame intervals
    /// and the main thread's CPU time. `settles` first waits half a second
    /// and leaves out the first 0.2 seconds of frames.
    static func measure(
        _ view: NSView,
        seconds: TimeInterval,
        settles: Bool,
        endsByDeadline: Bool = false,
        tick: @escaping (Frame) -> Void
    ) async -> Phase {
        if settles { try? await Task.sleep(for: .milliseconds(500)) }
        var intervals: [Double] = []
        let cpuStart = currentThreadCPUTime()
        await runDisplayLink(on: view, seconds: seconds, endsByDeadline: endsByDeadline) { frame in
            if !settles || frame.elapsed > 0.2 { intervals.append(frame.interval * 1_000) }
            tick(frame)
        }
        return Phase(
            frames: intervals.count,
            frameIntervalsMS: Summary(intervals),
            delayedFrames: intervals.count { $0 > 25 },
            mainThreadCPUMS: (currentThreadCPUTime() - cpuStart) * 1_000
        )
    }

    /// CPU time the calling thread has used, user and system.
    nonisolated static func currentThreadCPUTime() -> TimeInterval {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let seconds = info.user_time.seconds + info.system_time.seconds
        let microseconds = info.user_time.microseconds + info.system_time.microseconds
        return TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000
    }

    /// The nearest-rank percentile of sorted samples; 0 without any.
    nonisolated static func nearestRankPercentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int(ceil(fraction * Double(sorted.count)))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    /// The visible window that can become main.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    /// Whether `condition` held within `seconds`, checking every 100 ms;
    /// false once the task is cancelled.
    static func waitUntil(_ condition: () -> Bool, seconds: Double) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return true
    }

    /// The clip view origins `scrollView` can scroll between, insets included.
    static func scrollRange(of scrollView: NSScrollView) -> ClosedRange<CGFloat> {
        let minimumY = -scrollView.contentInsets.top
        let maximumY = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
            + scrollView.contentInsets.bottom
        return minimumY ... max(minimumY, maximumY)
    }

    /// The scroll view under `root` that `matches` accepts holding the
    /// tallest document.
    static func tallestScrollView(in root: NSView?, where matches: (NSScrollView) -> Bool) -> NSScrollView? {
        guard let root else { return nil }
        var candidates: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView, matches(scrollView) { candidates.append(scrollView) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return candidates.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    /// Where a script asked a benchmark to write its result, if it did.
    nonisolated static let resultPath = ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_RESULT_PATH"]
    /// The resource window a script asked to be timed, and where to write it.
    nonisolated static let resourceWindowName = ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_WINDOW_NAME"]
    nonisolated static let resourceWindowPath = ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_WINDOW_PATH"]
    /// Which scroll surfaces a script measures in an authenticated scroll benchmark.
    nonisolated static let scrollSurface =
        ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_SCROLL_SURFACE"] ?? "all"
    /// Whether a script asked for scroll input-to-frame telemetry.
    nonisolated static let recordsScrollInputTelemetry =
        ProcessInfo.processInfo.environment["SAKURACORD_SCROLL_INPUT_TELEMETRY"] == "1"
    /// Whether a script asked for media-viewer presentation telemetry.
    nonisolated static let recordsMediaViewerPresentation =
        ProcessInfo.processInfo.environment["SAKURACORD_MEDIA_VIEWER_BENCHMARK"] == "1"
    /// The account a script asked an authenticated benchmark to restore.
    nonisolated static let accountID = ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_ACCOUNT_ID"]

    /// Writes the fields `makeFields` returns to `resultPath`, one
    /// tab-separated name and value per line, when a script asked for them.
    static func writeResultFields(_ makeFields: () -> [(String, Any)]) {
        guard let path = resultPath else { return }
        let contents = makeFields().map { "\($0)\t\($1)\n" }.joined()
        try? contents.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    /// Encodes JSON results as sorted, pretty-printed JSON.
    static let resultEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Writes `result` as JSON to `resultPath`, or without one to `fileName`
    /// in the temporary directory, logs it after `logPrefix`, and returns the
    /// path it wrote. The sandboxed app can only write beneath its own
    /// container, so scripts pass a `resultPath` under it.
    @discardableResult
    static func writeResult(
        _ result: some Encodable,
        fileName: String,
        logPrefix: String,
        logger: Logger
    ) -> String? {
        let data: Data
        do {
            data = try resultEncoder.encode(result)
        } catch {
            logger.error("\(logPrefix, privacy: .public) could not encode its result: \(error, privacy: .public)")
            return nil
        }
        let path = resultPath ?? FileManager.default.temporaryDirectory.appendingPathComponent(fileName).path
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("\(logPrefix, privacy: .public) could not write \(path, privacy: .public): \(error, privacy: .public)")
            return nil
        }
        logger.notice("\(logPrefix, privacy: .public) \(String(bytes: data, encoding: .utf8) ?? "", privacy: .public)")
        return path
    }
}

/// Resumes a benchmark run exactly once, from its last frame or its deadline.
@MainActor
final class DisplayLinkRunCompletion {
    var continuation: CheckedContinuation<Void, Never>?
    var deadline: Task<Void, Never>?

    func finish() {
        deadline?.cancel()
        deadline = nil
        continuation?.resume()
        continuation = nil
    }
}
