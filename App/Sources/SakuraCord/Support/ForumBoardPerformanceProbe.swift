import SakuraCordModels

#if DEBUG
import AppKit
import OSLog

/// Counts post cards that change size after they were first measured while the
/// board width stayed the same: the layout jumps a reader sees when content
/// such as late previews resizes cards under the viewport. The native forum
/// board reports its measured card sizes here.
@MainActor
final class ForumLayoutStabilityProbe {
    static let shared = ForumLayoutStabilityProbe()

    struct Summary: Codable {
        var cardsMeasured = 0
        var layoutJumps = 0
        var cardsThatJumped = 0
        var maxHeightDelta: Double = 0
    }

    /// Recording is off outside the forum performance scenes.
    var isEnabled = false

    private struct Measurement {
        var size: CGSize
        var containerWidth: CGFloat
    }

    private static let tolerance: CGFloat = 0.5

    private var measurements: [ChannelID: Measurement] = [:]
    private var jumpedPostIDs: Set<ChannelID> = []
    private var layoutJumps = 0
    private var maxHeightDelta: CGFloat = 0

    var summary: Summary {
        Summary(
            cardsMeasured: measurements.count,
            layoutJumps: layoutJumps,
            cardsThatJumped: jumpedPostIDs.count,
            maxHeightDelta: Double(maxHeightDelta)
        )
    }

    func record(postID: ChannelID, size: CGSize, containerWidth: CGFloat) {
        guard isEnabled else { return }
        guard let previous = measurements.updateValue(
            Measurement(size: size, containerWidth: containerWidth), forKey: postID
        ) else { return }
        // A new board width legitimately reflows every card.
        guard previous.containerWidth == containerWidth else { return }
        let heightDelta = abs(size.height - previous.size.height)
        guard heightDelta > Self.tolerance || abs(size.width - previous.size.width) > Self.tolerance
        else { return }
        layoutJumps += 1
        maxHeightDelta = max(maxHeightDelta, heightDelta)
        jumpedPostIDs.insert(postID)
    }

    func reset() {
        measurements.removeAll()
        jumpedPostIDs.removeAll()
        layoutJumps = 0
        maxHeightDelta = 0
    }
}

/// Display-link frame intervals of one scroll run.
struct ForumFrameTimingSampler {
    struct Summary: Codable {
        var frameCount = 0
        var meanIntervalMS: Double = 0
        var p95IntervalMS: Double = 0
        var p99IntervalMS: Double = 0
        var maxIntervalMS: Double = 0
        var nominalIntervalMS: Double = 0
        /// Intervals longer than 1.5 times the display's nominal frame interval.
        var hitchCount = 0
        var durationSeconds: Double = 0
    }

    private var intervals: [Double] = []

    mutating func record(interval: TimeInterval) {
        intervals.append(interval)
    }

    func summary(nominalInterval: TimeInterval, duration: TimeInterval) -> Summary {
        let sorted = intervals.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((fraction * Double(sorted.count)).rounded(.up))
            return sorted[min(max(rank - 1, 0), sorted.count - 1)] * 1_000
        }
        return Summary(
            frameCount: sorted.count,
            meanIntervalMS: sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count) * 1_000,
            p95IntervalMS: percentile(0.95),
            p99IntervalMS: percentile(0.99),
            maxIntervalMS: (sorted.last ?? 0) * 1_000,
            nominalIntervalMS: nominalInterval * 1_000,
            hitchCount: sorted.count { $0 > nominalInterval * 1.5 },
            durationSeconds: duration
        )
    }
}

/// Resumes a benchmark run exactly once, from its last frame or its deadline.
@MainActor
private final class ForumBenchmarkCompletion {
    var continuation: CheckedContinuation<Void, Never>?
    var deadline: Task<Void, Never>?

    func finish() {
        deadline?.cancel()
        deadline = nil
        continuation?.resume()
        continuation = nil
    }
}

/// Offline forum benchmark: after the first page loads, scrolls the board at a
/// steady speed on the display link, then writes frame timing and layout
/// stability. The board registers its scroll view with `register(scrollView:)`.
@MainActor
enum ForumBoardBenchmark {
    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "ForumBenchmark")
    private static let scrollSpeed: CGFloat = 2_000
    private static let scrollDuration: TimeInterval = 15
    private static weak var registeredScrollView: NSScrollView?

    private struct Result: Codable {
        var scrollDistance: Double = 0
        var nominalScrollDistance: Double = 0
        /// Frames spent pinned at the end of the loaded posts, waiting on pagination.
        var framesAtEndOfContent = 0
        var postsAtStart = 0
        var postsAtEnd = 0
        var frames = ForumFrameTimingSampler.Summary()
        var layout = ForumLayoutStabilityProbe.Summary()
    }

    static func register(scrollView: NSScrollView) {
        registeredScrollView = scrollView
    }

    static func run(model: AppModel) async {
        ForumLayoutStabilityProbe.shared.reset()
        NSApp.activate(ignoringOtherApps: true)
        guard await waitUntil({ model.hasLoadedForumPosts && !model.forumPosts.isEmpty }, seconds: 30),
              let scrollView = await findScrollView()
        else {
            logger.error("ForumBenchmark: the forum did not load or has no scroll view")
            return
        }
        var result = Result(postsAtStart: model.forumPosts.count)
        await scroll(scrollView, model: model, into: &result)
        result.postsAtEnd = model.forumPosts.count
        result.layout = ForumLayoutStabilityProbe.shared.summary
        report(result)
    }

    private static func waitUntil(_ condition: () -> Bool, seconds: Double) async -> Bool {
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

    private static func findScrollView() async -> NSScrollView? {
        var found: NSScrollView?
        _ = await waitUntil({
            found = registeredScrollView
            return found.map { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height } ?? false
        }, seconds: 15)
        return found
    }

    private static func scroll(_ scrollView: NSScrollView, model: AppModel, into result: inout Result) async {
        let ticker = NativeTimelineDisplayLinkTicker()
        let framesPerSecond = scrollView.window?.screen?.maximumFramesPerSecond ?? 60
        let nominalInterval = 1 / Double(max(framesPerSecond, 1))
        var sampler = ForumFrameTimingSampler()
        var distance: CGFloat = 0
        var framesAtEnd = 0
        let start = ProcessInfo.processInfo.systemUptime
        var previous = start
        let completion = ForumBenchmarkCompletion()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.continuation = continuation
            // The display link stops firing if the board leaves the window,
            // so a wall-clock deadline also ends the run.
            completion.deadline = Task { @MainActor in
                guard (try? await Task.sleep(for: .seconds(scrollDuration + 5))) != nil else { return }
                ticker.stop()
                completion.finish()
            }
            ticker.start(on: scrollView) {
                let now = ProcessInfo.processInfo.systemUptime
                let interval = now - previous
                previous = now
                sampler.record(interval: interval)
                let clip = scrollView.contentView
                let maximumY = max(
                    -scrollView.contentInsets.top,
                    (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height
                        + scrollView.contentInsets.bottom
                )
                // An interval is capped so one long hitch cannot skip the
                // posts that pagination is about to deliver.
                let proposedY = clip.bounds.minY + scrollSpeed * CGFloat(min(interval, 0.1))
                let offsetY = min(proposedY, maximumY)
                if proposedY > maximumY { framesAtEnd += 1 }
                distance += offsetY - clip.bounds.minY
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offsetY))
                scrollView.reflectScrolledClipView(clip)
                if now - start >= scrollDuration {
                    ticker.stop()
                    completion.finish()
                }
            }
        }
        let duration = ProcessInfo.processInfo.systemUptime - start
        result.scrollDistance = Double(distance)
        result.nominalScrollDistance = Double(scrollSpeed) * scrollDuration
        result.framesAtEndOfContent = framesAtEnd
        result.frames = sampler.summary(nominalInterval: nominalInterval, duration: duration)
    }

    private static func report(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(result)) ?? Data()
        // The sandboxed app can only write beneath its own container, so
        // scripts pass a path under it, as the other offline benchmarks do.
        let path = ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_RESULT_PATH"]
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("sakuracord-forum-benchmark.json").path
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("ForumBenchmark: could not write \(path, privacy: .public): \(error, privacy: .public)")
        }
        let frames = result.frames
        let layout = result.layout
        let line = String(
            format: "ForumBenchmark: frames=%d mean=%.2fms p95=%.2fms p99=%.2fms max=%.2fms hitches=%d "
                + "duration=%.1fs distance=%.0fpt cards=%d jumps=%d jumpedCards=%d maxJumpDelta=%.1fpt "
                + "posts=%d->%d artifact=%@",
            frames.frameCount, frames.meanIntervalMS, frames.p95IntervalMS, frames.p99IntervalMS,
            frames.maxIntervalMS, frames.hitchCount, frames.durationSeconds, result.scrollDistance,
            layout.cardsMeasured, layout.layoutJumps, layout.cardsThatJumped, layout.maxHeightDelta,
            result.postsAtStart, result.postsAtEnd, path
        )
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        logger.notice("\(line, privacy: .public)")
    }
}
#endif
