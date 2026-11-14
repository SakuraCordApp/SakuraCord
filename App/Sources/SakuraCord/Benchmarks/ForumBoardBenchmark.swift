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
            PerformanceBenchmarkHarness.nearestRankPercentile(sorted, fraction) * 1_000
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

/// Offline forum benchmark: after the first page loads, scrolls the board at a
/// steady speed on the display link, then writes frame timing and layout
/// stability.
@MainActor
enum ForumBoardBenchmark {
    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "ForumBenchmark")
    private static let scrollSpeed: CGFloat = 2_000
    private static let scrollDuration: TimeInterval = 15

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

    static func run(model: AppModel) async {
        ForumLayoutStabilityProbe.shared.reset()
        NSApp.activate(ignoringOtherApps: true)
        guard await PerformanceBenchmarkHarness.waitUntil(
            { model.hasLoadedForumPosts && !model.forumPosts.isEmpty }, seconds: 30
        ),
              let scrollView = await findScrollView()
        else {
            logger.error("ForumBenchmark: the forum did not load or has no scroll view")
            return
        }
        if AppLaunchConfiguration.current.runsForumGalleryResize {
            await resizeGallery(model: model, scrollView: scrollView)
            return
        }
        var result = Result(postsAtStart: model.forumPosts.count)
        await scroll(scrollView, model: model, into: &result)
        result.postsAtEnd = model.forumPosts.count
        result.layout = ForumLayoutStabilityProbe.shared.summary
        report(result)
    }

    private static func findScrollView() async -> NSScrollView? {
        var found: NSScrollView?
        _ = await PerformanceBenchmarkHarness.waitUntil({
            found = PerformanceBenchmarkHarness.tallestScrollView(
                in: PerformanceBenchmarkHarness.mainWindow?.contentView, where: { $0 is ForumBoardScrollView }
            )
            return found.map { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height } ?? false
        }, seconds: 15)
        return found
    }

    private static func scroll(_ scrollView: NSScrollView, model: AppModel, into result: inout Result) async {
        var distance: CGFloat = 0
        var framesAtEnd = 0
        result.frames = await sampledRun(on: scrollView, seconds: scrollDuration) { frame in
            let clip = scrollView.contentView
            let maximumY = PerformanceBenchmarkHarness.scrollRange(of: scrollView).upperBound
            // An interval is capped so one long hitch cannot skip the
            // posts that pagination is about to deliver.
            let proposedY = clip.bounds.minY + scrollSpeed * CGFloat(min(frame.interval, 0.1))
            let offsetY = min(proposedY, maximumY)
            if proposedY > maximumY { framesAtEnd += 1 }
            distance += offsetY - clip.bounds.minY
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offsetY))
            scrollView.reflectScrolledClipView(clip)
        }
        result.scrollDistance = Double(distance)
        result.nominalScrollDistance = Double(scrollSpeed) * scrollDuration
        result.framesAtEndOfContent = framesAtEnd
    }

    private struct ResizeResult: Codable {
        var window = ForumFrameTimingSampler.Summary()
        var pane = ForumFrameTimingSampler.Summary()
    }

    /// Gallery mode while the window narrows by up to 700 points and widens
    /// back twice, then while the sidebar hides and shows twice; both cross
    /// column counts each way.
    private static func resizeGallery(model: AppModel, scrollView: NSScrollView) async {
        model.setForumLayout(.gallery)
        try? await Task.sleep(for: .seconds(2))
        guard let window = scrollView.window, let screen = window.screen else { return }
        let original = window.frame
        // Start from the screen's width, so narrowing crosses column counts.
        let frame = screen.visibleFrame
        window.setFrame(frame, display: true)
        try? await Task.sleep(for: .seconds(1))
        var result = ResizeResult()
        result.window = await oscillate(on: scrollView, seconds: 8) { progress in
            var resized = frame
            resized.size.width -= 700 * progress
            window.setFrame(resized, display: true)
        }
        var toggles = 0
        let paneStart = ProcessInfo.processInfo.systemUptime
        result.pane = await oscillate(on: scrollView, seconds: 8) { _ in
            // The sidebar hides and shows every two seconds, sliding the board wider and back.
            let due = Int((ProcessInfo.processInfo.systemUptime - paneStart) / 2) + 1
            guard toggles < min(due, 4) else { return }
            toggles += 1
            NotificationCenter.default.post(name: .sakuracordToggleChannelSidebar, object: nil)
        }
        window.setFrame(original, display: true)
        PerformanceBenchmarkHarness.writeResult(
            result, fileName: "sakuracord-forum-resize-benchmark.json", logPrefix: "FORUM_RESIZE_BENCHMARK", logger: logger
        )
    }

    /// Calls `step` each frame with a progress that eases 0 → 1 → 0 every
    /// four seconds, sampling frame intervals.
    private static func oscillate(
        on view: NSView,
        seconds: TimeInterval,
        step: @escaping (CGFloat) -> Void
    ) async -> ForumFrameTimingSampler.Summary {
        await sampledRun(on: view, seconds: seconds) { frame in
            step(CGFloat(0.5 - 0.5 * cos(frame.elapsed * .pi / 2)))
        }
    }

    /// Calls `step` on each display-link frame for `seconds`, sampling frame
    /// intervals against the display's nominal one.
    private static func sampledRun(
        on view: NSView,
        seconds: TimeInterval,
        step: @escaping (PerformanceBenchmarkHarness.Frame) -> Void
    ) async -> ForumFrameTimingSampler.Summary {
        let nominalInterval = 1 / Double(max(view.window?.screen?.maximumFramesPerSecond ?? 60, 1))
        var sampler = ForumFrameTimingSampler()
        let start = ProcessInfo.processInfo.systemUptime
        // The display link stops firing if the board leaves the window,
        // so a wall-clock deadline also ends the run.
        await PerformanceBenchmarkHarness.runDisplayLink(on: view, seconds: seconds, endsByDeadline: true) { frame in
            sampler.record(interval: frame.interval)
            step(frame)
        }
        return sampler.summary(nominalInterval: nominalInterval, duration: ProcessInfo.processInfo.systemUptime - start)
    }

    private static func report(_ result: Result) {
        let path = PerformanceBenchmarkHarness.writeResult(
            result, fileName: "sakuracord-forum-benchmark.json", logPrefix: "FORUM_BENCHMARK", logger: logger
        )
        let frames = result.frames
        let layout = result.layout
        let line = String(
            format: "ForumBenchmark: frames=%d mean=%.2fms p95=%.2fms p99=%.2fms max=%.2fms hitches=%d "
                + "duration=%.1fs distance=%.0fpt cards=%d jumps=%d jumpedCards=%d maxJumpDelta=%.1fpt "
                + "posts=%d->%d artifact=%@",
            frames.frameCount, frames.meanIntervalMS, frames.p95IntervalMS, frames.p99IntervalMS,
            frames.maxIntervalMS, frames.hitchCount, frames.durationSeconds, result.scrollDistance,
            layout.cardsMeasured, layout.layoutJumps, layout.cardsThatJumped, layout.maxHeightDelta,
            result.postsAtStart, result.postsAtEnd, path ?? "unwritten"
        )
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        logger.notice("\(line, privacy: .public)")
    }
}
#endif
