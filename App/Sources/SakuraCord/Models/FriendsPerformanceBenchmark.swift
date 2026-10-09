import AppKit
import DiscordProtocol
import Foundation
import OSLog
import SakuraCordModels

/// Offline Friends benchmark: a 20-second display-link scroll through All
/// while presence changes arrive, then repeated section switches, each timed
/// until a display-link tick after the requested rows have been published. Read-only against the offline fixture.
@MainActor
enum FriendsPerformanceBenchmark {
    static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "FriendsPerformanceBenchmark")

    struct Result: Codable {
        var scrollFrames = 0
        var scrollDistance: Double = 0
        var frameIntervalsMS: Summary?
        var scrollWorkMS: Summary?
        var delayedFrames = 0
        var switchLatenciesMS: Summary?
        var switchCount = 0
        var switchTimeouts = 0
    }

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

    static func run(model: AppModel, provider: MockChatProvider?) async {
        NSApp.activate(ignoringOtherApps: true)
        model.openFriends()
        try? await Task.sleep(for: .seconds(1))
        model.selectFriendsSection(.all)
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let scrollView = friendsScrollView(in: window.contentView) else {
            logger.error("Friends benchmark could not find the list")
            return
        }
        await provider?.startRelationshipPresenceChurn(updatesPerSecond: 20)
        var result = Result()
        await scroll(scrollView, seconds: 20, into: &result)
        await switchSections(model: model, view: scrollView, cycles: 20, into: &result)
        await provider?.stopRelationshipPresenceChurn()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(result)) ?? Data()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sakuracord-friends-benchmark.json")
        try? data.write(to: url, options: .atomic)
        logger.notice("FRIENDS_BENCHMARK \(String(bytes: data, encoding: .utf8) ?? "", privacy: .public)")
    }

    /// The tallest scroll view in the detail area: the Friends list.
    private static func friendsScrollView(in root: NSView?) -> NSScrollView? {
        guard let root else { return nil }
        var candidates: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView, scrollView.frame.width > 400 { candidates.append(scrollView) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return candidates.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private static func scroll(_ scrollView: NSScrollView, seconds: Double, into result: inout Result) async {
        let ticker = NativeTimelineDisplayLinkTicker()
        let speed: CGFloat = 2_400
        var intervals: [Double] = [], work: [Double] = []
        var previous = ProcessInfo.processInfo.systemUptime
        let start = previous
        var direction: CGFloat = 1
        var distance: CGFloat = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ticker.start(on: scrollView) {
                let now = ProcessInfo.processInfo.systemUptime
                let interval = now - previous
                previous = now
                if now - start > 0.2 { intervals.append(interval * 1_000) }
                let workStart = ProcessInfo.processInfo.systemUptime
                let clip = scrollView.contentView
                let minimumY = -scrollView.contentInsets.top
                let maximumY = max(minimumY, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height + scrollView.contentInsets.bottom)
                var offsetY = clip.bounds.minY + direction * speed * CGFloat(min(interval, 0.05))
                if offsetY >= maximumY { offsetY = maximumY; direction = -1 } else if offsetY <= minimumY { offsetY = minimumY; direction = 1 }
                distance += abs(offsetY - clip.bounds.minY)
                clip.scroll(to: NSPoint(x: 0, y: offsetY))
                scrollView.reflectScrolledClipView(clip)
                scrollView.layoutSubtreeIfNeeded()
                work.append((ProcessInfo.processInfo.systemUptime - workStart) * 1_000)
                if now - start >= seconds {
                    ticker.stop()
                    continuation.resume()
                }
            }
        }
        result.scrollFrames = intervals.count
        result.scrollDistance = Double(distance)
        result.frameIntervalsMS = Summary(intervals)
        result.scrollWorkMS = Summary(work)
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
            let ticker = NativeTimelineDisplayLinkTicker()
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
        result.switchLatenciesMS = Summary(latencies)
    }
}
