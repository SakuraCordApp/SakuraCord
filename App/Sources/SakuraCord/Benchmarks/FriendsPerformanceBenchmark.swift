#if DEBUG
import AppKit
import Foundation
import OSLog
import SakuraCordModels

/// Friends benchmark: a 20-second display-link scroll through All while the
/// simulator's `presence-churn` script changes friends' presence, then
/// repeated section switches, each timed until a display-link tick after the
/// requested rows have been published. Read-only; run on the simulator's
/// `friends-performance` scenario.
@MainActor
enum FriendsPerformanceBenchmark {
    static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "FriendsPerformanceBenchmark")

    struct Result: Codable {
        var scrollFrames = 0
        var scrollDistance: Double = 0
        var frameIntervalsMS: PerformanceBenchmarkHarness.Summary?
        var scrollWorkMS: PerformanceBenchmarkHarness.Summary?
        var delayedFrames = 0
        var switchLatenciesMS: PerformanceBenchmarkHarness.Summary?
        var switchCount = 0
        var switchTimeouts = 0
    }

    static func run(model: AppModel) async {
        model.openFriends()
        try? await Task.sleep(for: .seconds(1))
        model.selectFriendsSection(.all)
        try? await Task.sleep(for: .seconds(3))
        guard let window = PerformanceBenchmarkHarness.mainWindow,
              let scrollView = PerformanceBenchmarkHarness.tallestScrollView(
                  in: window.contentView, where: { $0.frame.width > 400 }
              ) else {
            logger.error("Friends benchmark could not find the list")
            return
        }
        // Churn lasts through the scroll and the section switches after it.
        await SimulatorBenchmarkControl.startScript("presence-churn", params: ["rate": 20, "duration_s": 35])
        var result = Result()
        await scroll(scrollView, seconds: 20, into: &result)
        await switchSections(model: model, view: scrollView, cycles: 20, into: &result)
        PerformanceBenchmarkHarness.writeResult(
            result, fileName: "sakuracord-friends-benchmark.json", logPrefix: "FRIENDS_BENCHMARK", logger: logger
        )
    }

    private static func scroll(_ scrollView: NSScrollView, seconds: Double, into result: inout Result) async {
        let speed: CGFloat = 2_400
        var intervals: [Double] = [], work: [Double] = []
        var direction: CGFloat = 1
        var distance: CGFloat = 0
        await PerformanceBenchmarkHarness.runDisplayLink(on: scrollView, seconds: seconds) { frame in
            if frame.elapsed > 0.2 { intervals.append(frame.interval * 1_000) }
            let workStart = ProcessInfo.processInfo.systemUptime
            let clip = scrollView.contentView
            let range = PerformanceBenchmarkHarness.scrollRange(of: scrollView)
            var offsetY = clip.bounds.minY + direction * speed * CGFloat(min(frame.interval, 0.05))
            if offsetY >= range.upperBound {
                offsetY = range.upperBound
                direction = -1
            } else if offsetY <= range.lowerBound {
                offsetY = range.lowerBound
                direction = 1
            }
            distance += abs(offsetY - clip.bounds.minY)
            clip.scroll(to: NSPoint(x: 0, y: offsetY))
            scrollView.reflectScrolledClipView(clip)
            scrollView.layoutSubtreeIfNeeded()
            work.append((ProcessInfo.processInfo.systemUptime - workStart) * 1_000)
        }
        result.scrollFrames = intervals.count
        result.scrollDistance = Double(distance)
        result.frameIntervalsMS = PerformanceBenchmarkHarness.Summary(intervals)
        result.scrollWorkMS = PerformanceBenchmarkHarness.Summary(work)
        result.delayedFrames = intervals.count { $0 > 25 }
    }

    private static func switchSections(model: AppModel, view: NSView, cycles: Int, into result: inout Result) async {
        let order: [FriendsSection] = [.online, .all, .pending, .all]
        var latencies: [Double] = []
        for step in 0 ..< cycles * order.count {
            try? await Task.sleep(for: .milliseconds(120))
            let start = ProcessInfo.processInfo.systemUptime
            model.selectFriendsSection(order[step % order.count])
            let expectedSections = model.friendsProjection.displaySections.map(\.id)
            let ticker = DisplayLinkTicker()
            var timedOut = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ticker.start(on: view) {
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    if let scrollView = view as? NSScrollView,
                       let canvas = scrollView.documentView as? NativeMemberListCanvasView,
                       canvas.presentedSections.map(\.id) != expectedSections {
                        guard elapsed > 5 else { return }
                        timedOut = true
                    }
                    ticker.stop()
                    continuation.resume()
                }
            }
            if timedOut { result.switchTimeouts += 1 }
            latencies.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        result.switchCount = latencies.count
        result.switchLatenciesMS = PerformanceBenchmarkHarness.Summary(latencies)
    }
}
#endif
