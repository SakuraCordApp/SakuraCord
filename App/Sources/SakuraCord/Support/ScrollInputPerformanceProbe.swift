import AppKit
import OSLog
import SwiftUI

enum ScrollPerformanceSurface: String {
    case timeline
    case memberList = "member-list"
    case channelList = "channel-list"
    case serverList = "server-list"
}

/// Benchmark-only instrumentation for the latency unique to a new trackpad
/// gesture. The continuous auto-scroll benchmarks intentionally bypass
/// `NSEvent`, so they cannot expose work performed at `.began` boundaries.
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
        guard Self.isEnabled else { return }
        guard self.scrollView !== scrollView || eventMonitor == nil else {
            return
        }
        invalidate()
        self.scrollView = scrollView
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.observe(event)
            }
            return event
        }
        emitInstalledEvent()
        Self.logger.debug(
            "Installed gesture probe for \(self.surface.rawValue, privacy: .public)"
        )
    }

    func invalidate() {
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

    private func observe(_ event: NSEvent) {
        guard let scrollView,
              event.window === scrollView.window,
              event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
        else { return }
        let location = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(location) else { return }

        let priorInputTimestamp = lastInputTimestamp
        let startsGesture = event.phase.contains(.began)
        let startsMomentum = event.momentumPhase.contains(.began)
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
        private let probe: ScrollInputPerformanceProbe
        private weak var installedScrollView: NSScrollView?

        init(surface: ScrollPerformanceSurface) {
            probe = ScrollInputPerformanceProbe(surface: surface)
        }

        func install(from view: NSView) {
            guard let scrollView = Self.findScrollView(from: view),
                  scrollView !== installedScrollView
            else { return }
            installedScrollView = scrollView
            probe.install(on: scrollView)
        }

        func invalidate() {
            installedScrollView = nil
            probe.invalidate()
        }

        private static func findScrollView(from view: NSView) -> NSScrollView? {
            if let scrollView = view.enclosingScrollView {
                return scrollView
            }
            var ancestor = view.superview
            for _ in 0 ..< 8 {
                guard let candidate = ancestor else { return nil }
                if let scrollView = candidate as? NSScrollView {
                    return scrollView
                }
                if let scrollView = firstScrollView(in: candidate) {
                    return scrollView
                }
                ancestor = candidate.superview
            }
            return nil
        }

        private static func firstScrollView(in view: NSView) -> NSScrollView? {
            for subview in view.subviews {
                if let scrollView = subview as? NSScrollView {
                    return scrollView
                }
                if let scrollView = firstScrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
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
