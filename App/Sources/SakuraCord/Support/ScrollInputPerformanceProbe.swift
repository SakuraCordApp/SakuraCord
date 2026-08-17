import AppKit
import OSLog
import SwiftUI
import Synchronization

enum ScrollPerformanceSurface: String {
    case timeline
    case memberList = "member-list"
    case channelList = "channel-list"
    case serverList = "server-list"

    var liveScrollSignpostName: StaticString {
        switch self {
        case .timeline: "TimelineLiveScrollActivity"
        case .memberList: "MemberListLiveScrollActivity"
        case .channelList: "ChannelListLiveScrollActivity"
        case .serverList: "ServerListLiveScrollActivity"
        }
    }
}

/// A lock-backed mirror lets cooperative workers stop between bounded batches
/// without hopping to the main actor. It carries no content or cross-launch
/// state; the main-actor tracker below remains the source of truth.
nonisolated enum AppScrollWorkGate {
    private struct State: Sendable {
        var activityCount = 0
        var revision: UInt64 = 0
    }

    fileprivate struct Snapshot: Sendable {
        let isActive: Bool
        let revision: UInt64
    }

    private static let state = Mutex(State())
    private static let suspension = AppScrollWorkGateSuspension()

    static var isActive: Bool {
        state.withLock { $0.activityCount > 0 }
    }

    /// Adds one independently owned scroll transaction. Callers must balance
    /// this with `endActivity()`; overlapping surfaces and deterministic
    /// benchmarks intentionally acquire separate ownership.
    static func beginActivity() {
        let revision = state.withLock { state -> UInt64? in
            state.activityCount += 1
            guard state.activityCount == 1 else { return nil }
            state.revision &+= 1
            return state.revision
        }
        guard let revision else { return }
        Task {
            await suspension.stateDidChange(revision: revision)
        }
    }

    static func endActivity() {
        let revision = state.withLock { state -> UInt64? in
            guard state.activityCount > 0 else { return nil }
            state.activityCount -= 1
            guard state.activityCount == 0 else { return nil }
            state.revision &+= 1
            return state.revision
        }
        guard let revision else { return }
        Task {
            await suspension.stateDidChange(revision: revision)
        }
    }

    /// Suspends optional background work without polling while a native scroll
    /// transaction owns the input lane. The lock-backed state is checked again
    /// after every wake so reordered executor hops cannot start work under a
    /// newer gesture.
    static func waitUntilInactive() async {
        while !Task.isCancelled, isActive {
            await suspension.waitUntilInactive()
        }
    }

    fileprivate static var snapshot: Snapshot {
        state.withLock {
            Snapshot(
                isActive: $0.activityCount > 0,
                revision: $0.revision
            )
        }
    }
}

private actor AppScrollWorkGateSuspension {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var appliedRevision: UInt64 = 0

    func stateDidChange(revision: UInt64) {
        let snapshot = AppScrollWorkGate.snapshot
        guard snapshot.revision == revision,
              revision >= appliedRevision
        else { return }
        appliedRevision = revision
        guard !snapshot.isActive else { return }
        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitUntilInactive() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let snapshot = AppScrollWorkGate.snapshot
                guard snapshot.isActive else {
                    continuation.resume()
                    return
                }
                appliedRevision = max(appliedRevision, snapshot.revision)
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    private func cancel(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume()
    }
}

/// Shares only whether a native scroll transaction is active. Rendering and
/// preparation code uses this to avoid work that can block an unrelated
/// scrolling surface. It retains no content and has no cross-launch state.
@MainActor
enum AppScrollActivity {
    private struct ActiveScroll {
        let surface: ScrollPerformanceSurface
        let interval: OSSignpostIntervalState
    }

    private static var activeByScrollView: [ObjectIdentifier: ActiveScroll] = [:]

    static var isActive: Bool { !activeByScrollView.isEmpty }

    static func begin(
        surface: ScrollPerformanceSurface,
        scrollView: NSScrollView
    ) {
        let identifier = ObjectIdentifier(scrollView)
        guard activeByScrollView[identifier] == nil else { return }
        let wasInactive = activeByScrollView.isEmpty
        let name = surface.liveScrollSignpostName
        activeByScrollView[identifier] = ActiveScroll(
            surface: surface,
            interval: AppPerformanceSignposts.signposter.beginInterval(
                name,
                id: AppPerformanceSignposts.signposter.makeSignpostID()
            )
        )
        if wasInactive {
            AppScrollWorkGate.beginActivity()
        }
    }

    static func end(scrollView: NSScrollView) {
        let identifier = ObjectIdentifier(scrollView)
        guard let active = activeByScrollView.removeValue(forKey: identifier)
        else { return }
        AppPerformanceSignposts.signposter.endInterval(
            active.surface.liveScrollSignpostName,
            active.interval
        )
        if activeByScrollView.isEmpty {
            AppScrollWorkGate.endActivity()
        }
    }
}

/// Tracks native live-scroll transactions in every build. The raw gesture
/// boundary marks activity before AppKit dispatches its first scroll tick;
/// detailed input-to-frame telemetry remains benchmark-only because the
/// continuous auto-scroll benchmarks bypass `NSEvent`.
@MainActor
final class ScrollInputPerformanceProbe {
    private static let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "ScrollInputPerformance"
    )
    private static let signposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )
    private static let isEnabled =
        ProcessInfo.processInfo.environment[
            "SAKURACORD_SCROLL_INPUT_TELEMETRY"
        ] == "1"
    private static let boundaryGap: TimeInterval = 0.120
    private static let maximumFrameTicks = 2

    private let surface: ScrollPerformanceSurface
    private weak var scrollView: NSScrollView?
    private var eventMonitor: Any?
    private var liveScrollObservers: [NSObjectProtocol] = []
    private var liveScrollEndTask: Task<Void, Never>?
    private var displayLinkTicker: NativeTimelineDisplayLinkTicker?
    private var pendingInterval: OSSignpostIntervalState?
    private var pendingInputTimestamp: TimeInterval = 0
    private var pendingDispatchUptime: TimeInterval = 0
    private var pendingOrigin = NSPoint.zero
    private var pendingTickCount = 0
    private var pendingBoundaryKind = "unknown"
    private var pendingDelta = CGVector.zero
    private var pendingVelocity: Double = 0
    private var pendingEventPhase: UInt = 0
    private var pendingMomentumPhase: UInt = 0
    private var pendingHasPreciseDeltas = false
    private var lastInputTimestamp: TimeInterval = 0

    init(surface: ScrollPerformanceSurface) {
        self.surface = surface
    }

    func install(on scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        invalidate()
        self.scrollView = scrollView
        installLiveScrollObservers(on: scrollView)
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.observe(event)
            }
            return event
        }
        guard Self.isEnabled else { return }
        emitInstalledEvent()
        Self.logger.debug(
            "Installed gesture probe for \(self.surface.rawValue, privacy: .public)"
        )
    }

    func invalidate() {
        liveScrollEndTask?.cancel()
        liveScrollEndTask = nil
        for observer in liveScrollObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        liveScrollObservers.removeAll(keepingCapacity: true)
        if let scrollView {
            AppScrollActivity.end(scrollView: scrollView)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        finishPendingBoundary(outcome: "cancelled")
        displayLinkTicker?.stop()
        displayLinkTicker = nil
        scrollView = nil
        lastInputTimestamp = 0
    }

    private func installLiveScrollObservers(on scrollView: NSScrollView) {
        let center = NotificationCenter.default
        liveScrollObservers = [
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.liveScrollEndTask?.cancel()
                    AppScrollActivity.begin(
                        surface: self.surface,
                        scrollView: scrollView
                    )
                    self.scheduleLiveScrollFallbackEnd(for: scrollView)
                }
            },
            center.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    AppScrollActivity.begin(
                        surface: self.surface,
                        scrollView: scrollView
                    )
                    self.scheduleLiveScrollFallbackEnd(for: scrollView)
                }
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.liveScrollEndTask?.cancel()
                    self.liveScrollEndTask = nil
                    AppScrollActivity.end(scrollView: scrollView)
                }
            },
        ]
    }

    private func scheduleLiveScrollFallbackEnd(for scrollView: NSScrollView) {
        liveScrollEndTask?.cancel()
        liveScrollEndTask = Task { [weak scrollView] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let scrollView else { return }
            AppScrollActivity.end(scrollView: scrollView)
        }
    }

    private func observe(_ event: NSEvent) {
        guard let scrollView,
              event.window === scrollView.window,
              event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
        else { return }
        let location = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(location) else { return }

        let startsGesture = event.phase.contains(.began)
        let startsMomentum = event.momentumPhase.contains(.began)
        if startsGesture || startsMomentum {
            AppScrollActivity.begin(
                surface: surface,
                scrollView: scrollView
            )
            scheduleLiveScrollFallbackEnd(for: scrollView)
        }
        guard Self.isEnabled else { return }

        let priorInputTimestamp = lastInputTimestamp
        let inputInterval = event.timestamp - priorInputTimestamp
        let followsInputGap = priorInputTimestamp > 0
            && inputInterval >= Self.boundaryGap
        lastInputTimestamp = event.timestamp
        guard startsGesture || startsMomentum || followsInputGap else { return }

        let kind = startsGesture
            ? "gesture-began"
            : (startsMomentum ? "momentum-began" : "input-gap")
        beginBoundary(
            event: event,
            kind: kind,
            inputInterval: inputInterval
        )
    }

    private func beginBoundary(
        event: NSEvent,
        kind: String,
        inputInterval: TimeInterval
    ) {
        guard let scrollView else { return }
        finishPendingBoundary(outcome: "superseded")
        pendingInputTimestamp = event.timestamp
        pendingDispatchUptime = ProcessInfo.processInfo.systemUptime
        pendingOrigin = scrollView.contentView.bounds.origin
        pendingTickCount = 0
        pendingBoundaryKind = kind
        pendingDelta = CGVector(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY
        )
        let magnitude = hypot(
            event.scrollingDeltaX,
            event.scrollingDeltaY
        )
        pendingVelocity = inputInterval > 0
            ? magnitude / inputInterval
            : 0
        pendingEventPhase = event.phase.rawValue
        pendingMomentumPhase = event.momentumPhase.rawValue
        pendingHasPreciseDeltas = event.hasPreciseScrollingDeltas
        pendingInterval = beginSignpostInterval(kind: kind)

        let ticker = NativeTimelineDisplayLinkTicker()
        displayLinkTicker = ticker
        ticker.start(on: scrollView.contentView) { [weak self] in
            self?.displayLinkDidFire()
        }
    }

    private func displayLinkDidFire() {
        guard pendingInterval != nil, let scrollView else { return }
        pendingTickCount += 1
        let didMove = scrollView.contentView.bounds.origin != pendingOrigin
        guard didMove || pendingTickCount >= Self.maximumFrameTicks else {
            return
        }
        finishPendingBoundary(outcome: didMove ? "moved" : "no-movement")
    }

    private func finishPendingBoundary(outcome: String) {
        guard let interval = pendingInterval else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let eventToFrameMilliseconds =
            max(0, now - pendingInputTimestamp) * 1_000
        let dispatchDelayMilliseconds =
            max(0, pendingDispatchUptime - pendingInputTimestamp) * 1_000
        endSignpostInterval(interval)
        Self.logger.info(
            """
            Gesture boundary \
            surface=\(self.surface.rawValue, privacy: .public) \
            outcome=\(outcome, privacy: .public) \
            kind=\(self.pendingBoundaryKind, privacy: .public) \
            event_to_frame_ms=\(eventToFrameMilliseconds, format: .fixed(precision: 3)) \
            dispatch_delay_ms=\(dispatchDelayMilliseconds, format: .fixed(precision: 3)) \
            delta_x=\(self.pendingDelta.dx, format: .fixed(precision: 3)) \
            delta_y=\(self.pendingDelta.dy, format: .fixed(precision: 3)) \
            velocity=\(self.pendingVelocity, format: .fixed(precision: 3)) \
            phase=\(self.pendingEventPhase) \
            momentum_phase=\(self.pendingMomentumPhase) \
            precise=\(self.pendingHasPreciseDeltas) \
            ticks=\(self.pendingTickCount)
            """
        )
        pendingInterval = nil
        displayLinkTicker?.stop()
        displayLinkTicker = nil
    }

    private func beginSignpostInterval(
        kind: String
    ) -> OSSignpostIntervalState {
        switch surface {
        case .timeline:
            Self.signposter.beginInterval(
                "TimelineGestureInputToDisplay",
                "kind=\(kind, privacy: .public) phase=\(self.pendingEventPhase) momentum=\(self.pendingMomentumPhase) velocity=\(self.pendingVelocity)"
            )
        case .memberList:
            Self.signposter.beginInterval(
                "MemberListGestureInputToDisplay",
                "kind=\(kind, privacy: .public) phase=\(self.pendingEventPhase) momentum=\(self.pendingMomentumPhase) velocity=\(self.pendingVelocity)"
            )
        case .channelList:
            Self.signposter.beginInterval(
                "ChannelListGestureInputToDisplay",
                "kind=\(kind, privacy: .public) phase=\(self.pendingEventPhase) momentum=\(self.pendingMomentumPhase) velocity=\(self.pendingVelocity)"
            )
        case .serverList:
            Self.signposter.beginInterval(
                "ServerListGestureInputToDisplay",
                "kind=\(kind, privacy: .public) phase=\(self.pendingEventPhase) momentum=\(self.pendingMomentumPhase) velocity=\(self.pendingVelocity)"
            )
        }
    }

    private func endSignpostInterval(_ interval: OSSignpostIntervalState) {
        switch surface {
        case .timeline:
            Self.signposter.endInterval(
                "TimelineGestureInputToDisplay",
                interval
            )
        case .memberList:
            Self.signposter.endInterval(
                "MemberListGestureInputToDisplay",
                interval
            )
        case .channelList:
            Self.signposter.endInterval(
                "ChannelListGestureInputToDisplay",
                interval
            )
        case .serverList:
            Self.signposter.endInterval(
                "ServerListGestureInputToDisplay",
                interval
            )
        }
    }

    private func emitInstalledEvent() {
        switch surface {
        case .timeline:
            Self.signposter.emitEvent("TimelineGestureProbeInstalled")
        case .memberList:
            Self.signposter.emitEvent("MemberListGestureProbeInstalled")
        case .channelList:
            Self.signposter.emitEvent("ChannelListGestureProbeInstalled")
        case .serverList:
            Self.signposter.emitEvent("ServerListGestureProbeInstalled")
        }
    }
}

/// Locates the AppKit scroll view backing a SwiftUI `ScrollView` or `List`
/// without replacing either native container.
struct ScrollInputPerformanceProbeAttachment: NSViewRepresentable {
    let surface: ScrollPerformanceSurface

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: surface)
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.didMove = { [weak coordinator = context.coordinator] view in
            coordinator?.install(from: view)
        }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.install(from: view)
    }

    static func dismantleNSView(
        _ view: AttachmentView,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
        view.didMove = nil
    }

    @MainActor
    final class Coordinator {
        private static let recordsInputTelemetry =
            ProcessInfo.processInfo.environment[
                "SAKURACORD_SCROLL_INPUT_TELEMETRY"
            ] == "1"

        private let surface: ScrollPerformanceSurface
        private let probe: ScrollInputPerformanceProbe
        private weak var installedScrollView: NSScrollView?
        private var resolutionTask: Task<Void, Never>?
        private var didReportResolutionFailure = false

        init(surface: ScrollPerformanceSurface) {
            self.surface = surface
            probe = ScrollInputPerformanceProbe(surface: surface)
        }

        func install(from view: NSView) {
            guard view.window != nil else {
                invalidate()
                return
            }
            guard let scrollView = Self.findScrollView(from: view) else {
                scheduleResolutionRetry(from: view)
                return
            }
            install(scrollView)
        }

        private func install(_ scrollView: NSScrollView) {
            resolutionTask?.cancel()
            resolutionTask = nil
            guard scrollView !== installedScrollView else { return }
            didReportResolutionFailure = false
            installedScrollView = scrollView
            probe.install(on: scrollView)
        }

        func invalidate() {
            resolutionTask?.cancel()
            resolutionTask = nil
            installedScrollView = nil
            probe.invalidate()
        }

        private func scheduleResolutionRetry(from view: NSView) {
            guard resolutionTask == nil else { return }
            resolutionTask = Task { [weak self, weak view] in
                guard let self else { return }
                for _ in 0 ..< 12 {
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled,
                          let view,
                          view.window != nil
                    else { return }
                    if let scrollView = Self.findScrollView(from: view) {
                        install(scrollView)
                        return
                    }
                }
                resolutionTask = nil
                guard Self.recordsInputTelemetry,
                      !didReportResolutionFailure,
                      let view
                else { return }
                didReportResolutionFailure = true
                NSLog(
                    "SakuraCord gesture probe resolution failed: %@ %@",
                    surface.rawValue,
                    Self.resolutionDiagnostics(from: view)
                )
            }
        }

        private static func findScrollView(from view: NSView) -> NSScrollView? {
            if let scrollView = view.enclosingScrollView {
                return scrollView
            }
            var ancestor = view.superview
            for _ in 0 ..< 8 {
                guard let candidate = ancestor else { break }
                if let scrollView = candidate as? NSScrollView {
                    return scrollView
                }
                ancestor = candidate.superview
            }

            guard let window = view.window,
                  let contentView = window.contentView
            else { return nil }
            guard let attachmentFrame = attachmentWindowFrame(from: view)
            else { return nil }
            let attachmentCenter = NSPoint(
                x: attachmentFrame.midX,
                y: attachmentFrame.midY
            )
            return scrollViews(in: contentView)
                .compactMap { scrollView -> (NSScrollView, CGFloat)? in
                    guard scrollView.window === window,
                          !scrollView.isHidden,
                          scrollView.alphaValue > 0
                    else { return nil }
                    let frame = scrollView.convert(
                        scrollView.bounds,
                        to: nil
                    )
                    guard frame.contains(attachmentCenter) else { return nil }
                    let area = frame.width * frame.height
                    guard area.isFinite, area > 0 else { return nil }
                    return (scrollView, area)
                }
                .min { $0.1 < $1.1 }?
                .0
        }

        private static func resolutionDiagnostics(from view: NSView) -> String {
            var hierarchy: [String] = []
            var candidate: NSView? = view
            for _ in 0 ..< 12 {
                guard let current = candidate else { break }
                hierarchy.append(
                    "\(type(of: current))="
                        + NSStringFromRect(
                            current.convert(current.bounds, to: nil)
                        )
                )
                candidate = current.superview
            }
            let scrollFrames = view.window?.contentView.map { contentView in
                scrollViews(in: contentView).map { scrollView in
                    "\(type(of: scrollView))="
                        + NSStringFromRect(
                            scrollView.convert(scrollView.bounds, to: nil)
                        )
                }
            } ?? []
            return "hierarchy=[\(hierarchy.joined(separator: ";"))] "
                + "scrolls=[\(scrollFrames.joined(separator: ";"))]"
        }

        private static func attachmentWindowFrame(
            from view: NSView
        ) -> CGRect? {
            var candidate: NSView? = view
            for _ in 0 ..< 12 {
                guard let current = candidate else { return nil }
                let bounds = current.bounds
                if bounds.width > 1, bounds.height > 1 {
                    let frame = current.convert(bounds, to: nil)
                    if frame.width.isFinite,
                       frame.height.isFinite,
                       frame.width > 1,
                       frame.height > 1
                    {
                        return frame
                    }
                }
                candidate = current.superview
            }
            return nil
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            var result: [NSScrollView] = []
            for subview in view.subviews {
                if let scrollView = subview as? NSScrollView {
                    result.append(scrollView)
                }
                result.append(contentsOf: scrollViews(in: subview))
            }
            return result
        }
    }

    @MainActor
    final class AttachmentView: NSView {
        var didMove: ((NSView) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            didMove?(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            didMove?(self)
        }
    }
}
