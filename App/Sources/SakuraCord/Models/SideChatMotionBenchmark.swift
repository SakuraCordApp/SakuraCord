import AppKit
import OSLog
import QuartzCore
import SakuraCordModels
import SwiftUI

/// Offline side chat motion benchmark: opens, closes and widens fixture
/// threads and toggles the member list while recording every display-link
/// frame with the geometry of the workspace columns, the toolbar and the
/// timelines. `script/motion_benchmark_analyze.py` turns the recording into
/// frame pacing, hitch and geometry-continuity metrics. Read-only against
/// the offline fixture.
@MainActor
enum SideChatMotionBenchmark {
    static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "SideChatMotionBenchmark")
    /// Brackets each action so Instruments captures can be split per action.
    static let signposter = OSSignposter(subsystem: "dev.sakuracord.SakuraCord", category: .pointsOfInterest)

    struct Options {
        var cycles = 6
        var historyDelayMilliseconds = 0
        var threadMessageCount = 150
        var settleSeconds = 1.2
        /// Cycles that open a forum post beside its forum, and cycles that
        /// open a thread while the member list is shown.
        var forumCycles = 2
        var memberListCycles = 2
        /// Opens a forum post and follows it, pausing for screenshots,
        /// instead of running the cycles.
        var showsFollowShowcase = false
        /// Opens the first fixture thread in the pane and leaves the window
        /// to the tester, for checks driven from outside.
        var holdsPane = false
        /// Cycles that resize the window on every frame: bare, beside the
        /// member list and beside a thread pane.
        var windowResizeCycles = 0
        /// Seconds to record after the cycles while the window is resized
        /// from outside, as a pointer drag of its corner does.
        var liveResizeSeconds = 0

        init(arguments: [String]) {
            func value(_ name: String) -> Int? {
                arguments.lazy.compactMap { argument -> Int? in
                    guard argument.hasPrefix("\(name)=") else { return nil }
                    return Int(argument.dropFirst(name.count + 1))
                }.first
            }
            cycles = value("--motion-cycles") ?? cycles
            historyDelayMilliseconds = value("--motion-history-delay-ms") ?? historyDelayMilliseconds
            threadMessageCount = value("--motion-thread-messages") ?? threadMessageCount
            forumCycles = value("--motion-forum-cycles") ?? forumCycles
            memberListCycles = value("--motion-member-list-cycles") ?? memberListCycles
            showsFollowShowcase = arguments.contains("--motion-follow-showcase")
            holdsPane = arguments.contains("--motion-hold-pane")
            windowResizeCycles = value("--motion-window-resize-cycles") ?? windowResizeCycles
            liveResizeSeconds = value("--motion-live-resize-seconds") ?? liveResizeSeconds
        }
    }

    static func run(model: AppModel, options: Options) async {
        NSApp.activate(ignoringOtherApps: true)
        if options.showsFollowShowcase {
            await showFollowShowcase(model: model)
            return
        }
        model.selectedChannelID = ChannelID(rawValue: 210)
        if options.holdsPane, let thread = await motionThreads(model: model, count: 1)?.first {
            model.showInspector = false
            model.open(thread)
            logger.notice("SIDE_CHAT_MOTION_HOLDING_PANE")
            return
        }
        guard let threads = await motionThreads(model: model, count: options.cycles + 1),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let contentView = window.contentView
        else {
            logger.error("Side chat motion benchmark could not find its fixture threads")
            return
        }
        model.showInspector = false
        // Every run measures the same layout, whatever size the window was
        // restored to.
        if let screen = window.screen?.visibleFrame {
            let size = CGSize(width: min(1440, screen.width), height: min(794, screen.height))
            window.setFrame(CGRect(origin: CGPoint(x: screen.minX, y: screen.maxY - size.height), size: size), display: true)
        }
        try? await Task.sleep(for: .seconds(2))

        let recorder = SideChatMotionRecorder(window: window, options: options)
        recorder.start(on: contentView)
        await recorder.idle(seconds: 4, label: "panels-hidden")

        // Static layouts for each state, reached without animation.
        let referenceThread = threads[options.cycles]
        WorkspaceLayoutMotion.isSuppressedForBenchmark = true
        for step in cycleSteps(thread: referenceThread, variant: "reference") {
            step.perform(model)
            try? await Task.sleep(for: .seconds(options.settleSeconds))
            recorder.captureReference(for: step.name)
        }
        // With the member list shown, the same names settle elsewhere: these
        // are kept under their variant too, as "name [variant]".
        for step in memberListSteps(thread: referenceThread) {
            step.perform(model)
            try? await Task.sleep(for: .seconds(options.settleSeconds))
            recorder.captureReference(for: step.variant.map { "\(step.name) [\($0)]" } ?? step.name)
        }
        WorkspaceLayoutMotion.isSuppressedForBenchmark = false
        await recorder.idle(seconds: 1, label: nil)

        logger.notice("SIDE_CHAT_MOTION_CYCLES_BEGIN")
        func perform(_ steps: [Step], cycle: Int) async {
            for step in steps {
                recorder.recordAction(step, cycle: cycle)
                let interval = signposter.beginInterval(
                    "SideChatMotionAction", id: signposter.makeSignpostID(),
                    "\(step.name, privacy: .public) \(step.variant ?? "-", privacy: .public) \(cycle, privacy: .public)"
                )
                step.perform(model)
                try? await Task.sleep(for: .seconds(options.settleSeconds))
                signposter.endInterval("SideChatMotionAction", interval)
            }
        }
        for cycle in 0 ..< options.cycles {
            await perform(cycleSteps(thread: threads[cycle], variant: nil), cycle: cycle)
        }
        for cycle in 0 ..< options.memberListCycles {
            await perform(memberListSteps(thread: threads[cycle % threads.count]), cycle: cycle)
        }
        if threads.count > 1 {
            await perform(swapSteps(threads[0], threads[1]), cycle: 0)
        }
        if options.forumCycles > 0, let posts = await forumPosts(model: model) {
            for cycle in 0 ..< options.forumCycles {
                await perform(forumSteps(post: posts[cycle % posts.count]), cycle: cycle)
            }
            model.selectedChannelID = ChannelID(rawValue: 210)
            try? await Task.sleep(for: .seconds(2))
        }

        await runWindowResize(model: model, thread: threads[0], window: window, recorder: recorder, options: options)

        let membersOpen = Step(name: "members-open", variant: "idle", movingProbe: "members", edge: "minX") {
            $0.toggleMemberInspector()
        }
        recorder.recordAction(membersOpen, cycle: options.cycles)
        membersOpen.perform(model)
        try? await Task.sleep(for: .seconds(options.settleSeconds))
        await recorder.idle(seconds: 4, label: "members-shown")
        model.toggleMemberInspector()
        try? await Task.sleep(for: .seconds(options.settleSeconds))

        recorder.stop()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sakuracord-motion-benchmark.json")
        do {
            try recorder.encoded().write(to: url, options: .atomic)
            logger.notice("SIDE_CHAT_MOTION_BENCHMARK_DONE \(url.path, privacy: .public)")
        } catch {
            logger.error("SIDE_CHAT_MOTION_BENCHMARK_FAILED \(error.localizedDescription, privacy: .public)")
        }
    }

    struct Step {
        let name: String
        let variant: String?
        let movingProbe: String?
        let edge: String?
        let perform: (AppModel) -> Void
    }

    /// Window resizes: on every frame by the benchmark, then by hand or by
    /// a script dragging the window's corner.
    private static func runWindowResize(
        model: AppModel,
        thread: MessageThreadSummary,
        window: NSWindow,
        recorder: SideChatMotionRecorder,
        options: Options
    ) async {
        for cycle in 0 ..< options.windowResizeCycles {
            for variant in ["bare", "members", "pane"] {
                WorkspaceLayoutMotion.isSuppressedForBenchmark = true
                model.closeSideConversations()
                model.showInspector = variant == "members"
                if variant == "pane" { model.open(thread) }
                WorkspaceLayoutMotion.isSuppressedForBenchmark = false
                try? await Task.sleep(for: .seconds(options.settleSeconds))
                let step = Step(name: "window-resize", variant: variant, movingProbe: nil, edge: nil) { _ in }
                recorder.recordAction(step, cycle: cycle)
                let interval = signposter.beginInterval(
                    "SideChatMotionAction", id: signposter.makeSignpostID(),
                    "window-resize \(variant, privacy: .public) \(cycle, privacy: .public)"
                )
                await WindowResizeDriver(window: window).run(narrowing: 440, seconds: 1.6)
                signposter.endInterval("SideChatMotionAction", interval)
                try? await Task.sleep(for: .seconds(options.settleSeconds))
            }
        }
        if options.windowResizeCycles > 0 {
            WorkspaceLayoutMotion.isSuppressedForBenchmark = true
            model.closeSideConversations()
            model.showInspector = false
            WorkspaceLayoutMotion.isSuppressedForBenchmark = false
            try? await Task.sleep(for: .seconds(options.settleSeconds))
        }
        if options.liveResizeSeconds > 0 {
            logger.notice("SIDE_CHAT_MOTION_LIVE_RESIZE_BEGIN")
            recorder.recordsLiveResize = true
            await recorder.idle(seconds: Double(options.liveResizeSeconds), label: nil)
            recorder.recordsLiveResize = false
        }
    }

    /// One cycle: the member list as the reference motion, a cold and a warm
    /// pane open, the pane close, widening and leaving full width.
    private static func cycleSteps(thread: MessageThreadSummary, variant: String?) -> [Step] {
        [
            Step(name: "members-open", variant: variant, movingProbe: "members", edge: "minX") {
                $0.toggleMemberInspector()
            },
            Step(name: "members-close", variant: variant, movingProbe: "members", edge: "minX") {
                $0.toggleMemberInspector()
            },
            Step(name: "pane-open", variant: variant ?? "cold", movingProbe: "pane", edge: "minX") {
                $0.open(thread)
            },
            Step(name: "pane-close", variant: variant, movingProbe: "pane", edge: "minX") {
                $0.closeSideConversation()
            },
            Step(name: "pane-open", variant: variant ?? "warm", movingProbe: "pane", edge: "minX") {
                $0.open(thread)
            },
            Step(name: "full-width", variant: variant, movingProbe: "pane", edge: "minX") {
                $0.presentOpenThreadFullWidth()
            },
            Step(name: "full-width-close", variant: variant, movingProbe: nil, edge: nil) {
                $0.closeSideConversation()
            },
        ]
    }

    /// One thread replacing another in the open pane, in place.
    private static func swapSteps(_ first: MessageThreadSummary, _ second: MessageThreadSummary) -> [Step] {
        [
            Step(name: "pane-open", variant: "before-swap", movingProbe: "pane", edge: "minX") { $0.open(first) },
            Step(name: "pane-swap", variant: nil, movingProbe: nil, edge: nil) { $0.open(second) },
            Step(name: "pane-swap", variant: "back", movingProbe: nil, edge: nil) { $0.open(first) },
            Step(name: "pane-close", variant: "after-swap", movingProbe: "pane", edge: "minX") {
                $0.closeSideConversation()
            },
        ]
    }

    /// A thread opened, widened and closed while the member list is shown.
    private static func memberListSteps(thread: MessageThreadSummary) -> [Step] {
        [
            Step(name: "members-open", variant: "before-pane", movingProbe: "members", edge: "minX") {
                $0.toggleMemberInspector()
            },
            Step(name: "pane-open", variant: "over-members", movingProbe: "pane", edge: "minX") { $0.open(thread) },
            Step(name: "full-width", variant: "with-members", movingProbe: "pane", edge: "minX") {
                $0.presentOpenThreadFullWidth()
            },
            Step(name: "full-width-close", variant: "with-members", movingProbe: nil, edge: nil) {
                $0.closeSideConversation()
            },
            Step(name: "members-close", variant: "after-pane", movingProbe: "members", edge: "minX") {
                $0.toggleMemberInspector()
            },
        ]
    }

    /// A forum post opened beside its forum, widened and closed.
    private static func forumSteps(post: ForumPost) -> [Step] {
        [
            Step(name: "post-open", variant: nil, movingProbe: "pane", edge: "minX") { $0.open(post) },
            Step(name: "post-close", variant: nil, movingProbe: "pane", edge: "minX") { $0.closeSideConversation() },
            Step(name: "post-open", variant: "again", movingProbe: "pane", edge: "minX") { $0.open(post) },
            Step(name: "post-full-width", variant: nil, movingProbe: "pane", edge: "minX") {
                $0.presentOpenThreadFullWidth()
            },
            Step(name: "post-full-width-close", variant: nil, movingProbe: nil, edge: nil) {
                $0.closeSideConversation()
            },
        ]
    }

    /// A forum post in the pane, first not followed and then followed, with
    /// a log line naming the window to capture at each step.
    private static func showFollowShowcase(model: AppModel) async {
        guard let post = await forumPosts(model: model)?.first,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        else { return }
        model.open(post)
        try? await Task.sleep(for: .seconds(3))
        logger.notice("SIDE_CHAT_MOTION_SHOWCASE unfollowed \(window.windowNumber, privacy: .public)")
        try? await Task.sleep(for: .seconds(3))
        model.setThreadMembership(model.currentThreadSummary(post.thread), isJoined: true, surface: .forumPostHeader)
        try? await Task.sleep(for: .seconds(3))
        logger.notice("SIDE_CHAT_MOTION_SHOWCASE followed \(window.windowNumber, privacy: .public)")
        try? await Task.sleep(for: .seconds(3))
        logger.notice("SIDE_CHAT_MOTION_SHOWCASE done")
    }

    /// The offline forum's posts, once the forum is selected and loaded.
    private static func forumPosts(model: AppModel) async -> [ForumPost]? {
        model.selectedChannelID = ChannelID(rawValue: 220)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !model.forumPosts.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                return model.forumPosts
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The fixture's motion threads, once their starters reached the channel.
    private static func motionThreads(model: AppModel, count: Int) async -> [MessageThreadSummary]? {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            var seen = Set<ChannelID>()
            let threads = model.messages
                .compactMap(\.thread)
                .filter { $0.name.hasPrefix("Motion thread") && seen.insert($0.id).inserted }
            if threads.count >= count { return Array(threads.prefix(count)) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

/// Records each display-link frame and the main thread's busy periods.
@MainActor
private final class SideChatMotionRecorder: NSObject {
    struct Frame: Encodable {
        let time: Double
        let target: Double
        let callback: Double
        let probes: [String: [Double]]
        let timelines: [WorkspaceMotionProbes.TimelineSample]
        let toolbar: Int
        /// Each visible toolbar item: its index in `toolbarItemIdentifiers`
        /// and its window frame.
        let toolbarItems: [[Double]]
        let windowWidth: Double
    }

    struct Action: Encodable {
        let id: Int
        let name: String
        let cycle: Int
        let time: Double
        let variant: String?
        let movingProbe: String?
        let edge: String?
    }

    struct Busy: Encodable {
        let start: Double
        let durationMS: Double
    }

    struct Idle: Encodable {
        let start: Double
        let end: Double
        let label: String
    }

    struct Reference: Encodable {
        let probes: [String: [Double]]
    }

    struct Recording: Encodable {
        let schema = "sakuracord-motion-benchmark/1"
        let configuration: String
        let refreshIntervalMS: Double
        let scenario: [String: Double]
        let spring: [String: Double]
        let window: [String: Double]
        let actions: [Action]
        let frames: [Frame]
        let toolbarSignatures: [String]
        let toolbarItemIdentifiers: [String]
        let mainThreadBusy: [Busy]
        let idle: [Idle]
        let references: [String: Reference]
    }

    private let window: NSWindow
    private let options: SideChatMotionBenchmark.Options
    private var displayLink: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var busyStart: Double?
    private var refreshInterval: Double = 1.0 / 60
    private var frames: [Frame] = []
    private var actions: [Action] = []
    private var busy: [Busy] = []
    private var idleWindows: [Idle] = []
    private var references: [String: Reference] = [:]
    private var toolbarSignatures: [String] = []
    private var toolbarSignatureIndex: [String: Int] = [:]
    private var toolbarItemIdentifiers: [String] = []
    private var toolbarItemIndex: [String: Int] = [:]

    /// Records each live resize of the window, as a pointer drag makes, as
    /// a "window-drag" action.
    var recordsLiveResize = false {
        didSet {
            if recordsLiveResize {
                liveResizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.recordAction(
                            .init(name: "window-drag", variant: nil, movingProbe: nil, edge: nil) { _ in },
                            cycle: 0
                        )
                    }
                }
            } else if let liveResizeObserver {
                NotificationCenter.default.removeObserver(liveResizeObserver)
                self.liveResizeObserver = nil
            }
        }
    }

    private var liveResizeObserver: NSObjectProtocol?

    init(window: NSWindow, options: SideChatMotionBenchmark.Options) {
        self.window = window
        self.options = options
    }

    func start(on view: NSView) {
        frames.reserveCapacity(8_000)
        let link = view.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0
        ) { [weak self] _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                self?.noteRunLoop(CFRunLoopActivity(rawValue: activity), at: now)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
    }

    func idle(seconds: Double, label: String?) async {
        let start = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(seconds))
        if let label {
            idleWindows.append(Idle(start: start, end: CACurrentMediaTime(), label: label))
        }
    }

    func recordAction(_ step: SideChatMotionBenchmark.Step, cycle: Int) {
        actions.append(
            Action(
                id: actions.count,
                name: step.name,
                cycle: cycle,
                time: CACurrentMediaTime(),
                variant: step.variant,
                movingProbe: step.movingProbe,
                edge: step.edge
            )
        )
    }

    func captureReference(for name: String) {
        references[name] = Reference(probes: WorkspaceMotionProbes.shared.probeFrames(in: window))
    }

    func encoded() throws -> Data {
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        let recording = Recording(
            configuration: configuration,
            refreshIntervalMS: refreshInterval * 1_000,
            scenario: [
                "cycles": Double(options.cycles),
                "historyDelayMS": Double(options.historyDelayMilliseconds),
                "threadMessageCount": Double(options.threadMessageCount),
                "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0,
            ],
            spring: [
                "durationS": ChatChromeMetrics.sidebarSpring.duration,
                "bounce": ChatChromeMetrics.sidebarSpring.bounce,
            ],
            window: ["width": window.frame.width, "height": window.frame.height],
            actions: actions,
            frames: frames,
            toolbarSignatures: toolbarSignatures,
            toolbarItemIdentifiers: toolbarItemIdentifiers,
            mainThreadBusy: busy,
            idle: idleWindows,
            references: references
        )
        return try JSONEncoder().encode(recording)
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        let callback = CACurrentMediaTime()
        let duration = link.targetTimestamp - link.timestamp
        if duration > 0 { refreshInterval = duration }
        frames.append(
            Frame(
                time: link.timestamp,
                target: link.targetTimestamp,
                callback: callback,
                probes: WorkspaceMotionProbes.shared.probeFrames(in: window),
                timelines: WorkspaceMotionProbes.shared.timelineSamples(in: window),
                toolbar: toolbarSignature(),
                toolbarItems: toolbarItemFrames(),
                windowWidth: window.frame.width
            )
        )
    }

    /// Where each toolbar item is drawn, so the analyzer can follow items
    /// that move, appear or disappear frame by frame.
    private func toolbarItemFrames() -> [[Double]] {
        (window.toolbar?.items ?? []).compactMap { item -> [Double]? in
            guard let view = item.view, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  view.alphaValue > 0.01
            else { return nil }
            let identifier = item.itemIdentifier.rawValue
            let index: Int
            if let known = toolbarItemIndex[identifier] {
                index = known
            } else {
                index = toolbarItemIdentifiers.count
                toolbarItemIdentifiers.append(identifier)
                toolbarItemIndex[identifier] = index
            }
            let frame = view.convert(view.bounds, to: nil)
            return [Double(index), frame.minX, frame.minY, frame.width, frame.height].map {
                ($0 * 100).rounded() / 100
            }
        }
    }

    private func toolbarSignature() -> Int {
        let signature = (window.toolbar?.visibleItems ?? [])
            .map(\.itemIdentifier.rawValue)
            .joined(separator: ",")
        if let index = toolbarSignatureIndex[signature] { return index }
        toolbarSignatures.append(signature)
        toolbarSignatureIndex[signature] = toolbarSignatures.count - 1
        return toolbarSignatures.count - 1
    }

    private func noteRunLoop(_ activity: CFRunLoopActivity, at now: Double) {
        if activity == .afterWaiting {
            busyStart = now
        } else if let start = busyStart {
            busyStart = nil
            let duration = (now - start) * 1_000
            if duration >= 4 { busy.append(Busy(start: start, durationMS: duration)) }
        }
    }
}

/// Resizes a window on every display frame, narrowing it and widening it
/// back with its top-left corner fixed, as dragging its trailing edge does.
@MainActor
private final class WindowResizeDriver: NSObject {
    private let window: NSWindow
    private var link: CADisplayLink?
    private var start: CFTimeInterval?
    private var narrowing: CGFloat = 0
    private var duration: CFTimeInterval = 1
    private var origin = CGRect.zero
    private var finished: CheckedContinuation<Void, Never>?

    init(window: NSWindow) {
        self.window = window
    }

    func run(narrowing: CGFloat, seconds: CFTimeInterval) async {
        guard let view = window.contentView else { return }
        self.narrowing = narrowing
        duration = seconds
        origin = window.frame
        await withCheckedContinuation { continuation in
            finished = continuation
            let link = view.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let start = start ?? link.timestamp
        self.start = start
        let progress = min(1, (link.targetTimestamp - start) / duration)
        // Narrows over the first half and widens back over the second.
        let fraction = progress < 0.5 ? progress * 2 : (1 - progress) * 2
        let width = (origin.width - narrowing * fraction).rounded()
        window.setFrame(
            CGRect(x: origin.minX, y: origin.maxY - origin.height, width: width, height: origin.height),
            display: true
        )
        guard progress >= 1 else { return }
        link.invalidate()
        self.link = nil
        finished?.resume()
        finished = nil
    }
}
