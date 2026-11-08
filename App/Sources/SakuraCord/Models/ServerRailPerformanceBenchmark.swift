import AppKit
import Foundation
import OSLog
import SakuraCordModels

/// Offline server rail benchmark over a 150-server fixture: display-link
/// scrolling with and without mention badge churn, badge churn on a still
/// rail, a pointer sweep over the icons and repeated server selection.
/// Read-only against the offline fixture.
@MainActor
enum ServerRailPerformanceBenchmark {
    static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "ServerRailPerformanceBenchmark")

    struct Phase: Codable {
        var frames = 0
        var frameIntervalsMS: FriendsPerformanceBenchmark.Summary?
        var delayedFrames = 0
        var mainThreadCPUMS: Double = 0
        var badgeUpdates = 0
    }

    struct Result: Codable {
        var guilds = 0
        var scroll = Phase()
        var scrollWithBadges = Phase()
        var badgesIdle = Phase()
        var pointerSweep = Phase()
        var selection = Phase()
        var selectionLatenciesMS: FriendsPerformanceBenchmark.Summary?
    }

    static func run(model: AppModel) async {
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(4))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let scrollView = railScrollView(in: window.contentView) else {
            logger.error("Server rail benchmark could not find the rail")
            return
        }
        let guildIDs = model.serverRailPresentation.orderedNavigationGuildIDs
        var result = Result(guilds: guildIDs.count)
        var churn = BadgeChurn(model: model, guildIDs: guildIDs)
        // The pointer rests over the rail, as when scrolling it.
        pointPointer(at: 0.5, in: scrollView)
        result.scroll = await measure(scrollView, seconds: 20) { scroll(scrollView, interval: $0) }
        endScroll(scrollView)
        result.scrollWithBadges = await measure(scrollView, seconds: 20) {
            scroll(scrollView, interval: $0)
            churn.advance()
        }
        endScroll(scrollView)
        result.scrollWithBadges.badgeUpdates = churn.takeCount()
        result.badgesIdle = await measure(scrollView, seconds: 10) { _ in churn.advance() }
        result.badgesIdle.badgeUpdates = churn.takeCount()
        churn.clear()
        result.pointerSweep = await measure(scrollView, seconds: 10) { _ in sweepPointer(over: scrollView) }

        var latencies: [Double] = []
        var pending: (id: GuildID, start: TimeInterval)?
        var step = 0
        var lastSelection: TimeInterval = 0
        result.selection = await measure(scrollView, seconds: 15) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            if let selection = pending, model.selectedGuildID == selection.id {
                latencies.append((now - selection.start) * 1_000)
                pending = nil
            }
            guard pending == nil, now - lastSelection >= 0.15 else { return }
            let id = guildIDs[(step * 7) % guildIDs.count]
            step += 1
            lastSelection = now
            pending = (id, now)
            model.selectGuild(id)
        }
        result.selectionLatenciesMS = FriendsPerformanceBenchmark.Summary(latencies)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(result)) ?? Data()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sakuracord-server-rail-benchmark.json")
        try? data.write(to: url, options: .atomic)
        logger.notice("SERVER_RAIL_BENCHMARK \(String(bytes: data, encoding: .utf8) ?? "", privacy: .public)")
    }

    /// Mention changes in a fixed rotation, as a busy account receives them:
    /// a badge appears, counts up, then clears.
    private struct BadgeChurn {
        let model: AppModel
        let guildIDs: [GuildID]
        private var step = 0
        private var count = 0
        private var lastUpdate: TimeInterval = 0
        private var touched: Set<GuildID> = []

        init(model: AppModel, guildIDs: [GuildID]) {
            self.model = model
            self.guildIDs = guildIDs
        }

        /// Ten updates a second.
        mutating func advance() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastUpdate >= 0.1, !guildIDs.isEmpty else { return }
            lastUpdate = now
            step += 1
            let id = guildIDs[(step * 37) % guildIDs.count]
            guard var guild = model.serverRailGuildsByID[id] else { return }
            guild.mentionCount = [1, 2, 9, 12, 0][(step / guildIDs.count + step) % 5]
            guild.unreadCount = max(guild.unreadCount, guild.mentionCount)
            touched.insert(id)
            update(guild)
            count += 1
        }

        mutating func takeCount() -> Int {
            defer { count = 0 }
            return count
        }

        func clear() {
            for id in touched {
                guard var guild = model.serverRailGuildsByID[id] else { continue }
                guild.mentionCount = 0
                update(guild)
            }
        }

        /// Updates the rail's entry alone. The account-wide unread
        /// publication that delivers counts in use is not the rail's cost.
        private func update(_ guild: Guild) {
            model.serverRailPresentation.updateGuild(
                guild,
                id: guild.id,
                notificationSettings: model.guildNotificationSettings,
                isMutationPending: model.isGuildNotificationMutationPending
            )
        }
    }

    /// The narrow scroll view holding the most content: the server rail.
    private static func railScrollView(in root: NSView?) -> NSScrollView? {
        guard let root else { return nil }
        var candidates: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView,
               abs(scrollView.frame.width - ChatChromeMetrics.serverRailWidth) < 1 {
                candidates.append(scrollView)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return candidates.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private static var scrollDirection: CGFloat = 1
    private static var scrollPhase = CGScrollPhase.began

    /// Scrolls with trackpad scroll events, so the rail sees a gesture as
    /// it does in use, turning at either end.
    private static func scroll(_ scrollView: NSScrollView, interval: TimeInterval) {
        let clip = scrollView.contentView
        let minimumY = -scrollView.contentInsets.top
        let maximumY = max(minimumY, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height + scrollView.contentInsets.bottom)
        if clip.bounds.minY >= maximumY - 1 {
            scrollDirection = -1
        } else if clip.bounds.minY <= minimumY + 1 {
            scrollDirection = 1
        }
        sendScroll(-scrollDirection * 2_400 * CGFloat(min(interval, 0.05)), phase: scrollPhase, to: scrollView)
        scrollPhase = .changed
    }

    private static func endScroll(_ scrollView: NSScrollView) {
        sendScroll(0, phase: .ended, to: scrollView)
        scrollPhase = .began
    }

    private static func sendScroll(_ deltaY: CGFloat, phase: CGScrollPhase, to scrollView: NSScrollView) {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(deltaY.rounded()), wheel2: 0, wheel3: 0
        ) else { return }
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let event = NSEvent(cgEvent: cgEvent) { scrollView.scrollWheel(with: event) }
    }

    private static var sweepStep = 0

    /// Moves the pointer down and up the visible icons over four seconds.
    private static func sweepPointer(over scrollView: NSScrollView) {
        sweepStep += 1
        let phase = CGFloat(sweepStep % 240) / 120
        pointPointer(at: phase <= 1 ? phase : 2 - phase, in: scrollView)
    }

    /// Moves the pointer to `fraction` of the way down the visible rail.
    private static func pointPointer(at fraction: CGFloat, in scrollView: NSScrollView) {
        guard let window = scrollView.window, let screen = window.screen else { return }
        let offset = 20 + (scrollView.frame.height - 40) * fraction
        let pointInWindow = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: offset), to: nil)
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
        CGWarpMouseCursorPosition(CGPoint(x: pointOnScreen.x, y: screen.frame.maxY - pointOnScreen.y))
        if let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: pointInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) {
            window.sendEvent(event)
        }
    }

    /// Runs `tick` on every display-link frame for `seconds`, recording frame
    /// intervals and the main thread's CPU time.
    private static func measure(
        _ view: NSView,
        seconds: Double,
        tick: @escaping (TimeInterval) -> Void
    ) async -> Phase {
        try? await Task.sleep(for: .milliseconds(500))
        let ticker = NativeTimelineDisplayLinkTicker()
        var intervals: [Double] = []
        var previous = ProcessInfo.processInfo.systemUptime
        let start = previous
        let cpuStart = NativeTimelineBenchmarkArtifact.currentThreadCPUTime()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ticker.start(on: view) {
                let now = ProcessInfo.processInfo.systemUptime
                let interval = now - previous
                previous = now
                if now - start > 0.2 { intervals.append(interval * 1_000) }
                tick(interval)
                if now - start >= seconds {
                    ticker.stop()
                    continuation.resume()
                }
            }
        }
        var phase = Phase()
        phase.frames = intervals.count
        phase.frameIntervalsMS = FriendsPerformanceBenchmark.Summary(intervals)
        phase.delayedFrames = intervals.count { $0 > 25 }
        phase.mainThreadCPUMS = (NativeTimelineBenchmarkArtifact.currentThreadCPUTime() - cpuStart) * 1_000
        return phase
    }
}
