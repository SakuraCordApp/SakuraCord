import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
final class NativeMemberListCoordinator: NSObject {
    nonisolated struct PerformanceLayoutSection: Equatable, Sendable {
        let id: MemberSection.SectionIdentifier
        let totalCount: Int
        let gatewayStartIndex: Int?
        let isLoadingSkeleton: Bool

        init(_ section: MemberSection) {
            id = section.id
            totalCount = section.totalCount
            gatewayStartIndex = section.gatewayStartIndex
            isLoadingSkeleton = section.isLoadingSkeleton
        }
    }

    var parent: NativeMemberListView
    weak var scrollView: NSScrollView?
    weak var canvas: NativeMemberListCanvasView?
    var observations: [NSObjectProtocol] = []
    var scrollIdleTask: Task<Void, Never>?
    var scrollIdleDeadline = ContinuousClock.now
    var viewportTask: Task<Void, Never>?
    var lastViewportRange: ClosedRange<Int>?
    var pendingViewportRange: ClosedRange<Int>?
    var viewportIdentity: ChannelID?
    var performanceTicker: NativeTimelineDisplayLinkTicker?
    var performanceStartTask: Task<Void, Never>?
    var performanceStartGeneration: UInt64 = 0
    var performanceLayoutSections: [PerformanceLayoutSection]?
    var didStartPerformanceBenchmark = false
    var performanceInterval: OSSignpostIntervalState?
    var documentPreparationTask: Task<Void, Never>?
    var requestedSections: [MemberSection]?
    var requestedPresentation: NativeMemberListPresentation?
    var documentPreparationGeneration: UInt64 = 0
    let animatedImageScrollSource = AnimatedImageInteractiveScrollSource.memberList(UUID())
    var animatedImageScrollRevision: UInt64 = 0
    var defersAnimatedImageDecoding = false

    init(parent: NativeMemberListView) {
        self.parent = parent
    }

    func makeScrollView() -> NSScrollView {
        let canvas = NativeMemberListCanvasView(frame: .zero)
        canvas.selectMember = { [weak self] member in
            guard let self else { return }
            let original = self.parent.sections.lazy.flatMap(\.members).first { $0.id == member.id } ?? member
            self.parent.selectMember(original)
        }
        let scrollView = NativeMemberListScrollView()
        scrollView.appearanceDidChange = { [weak self, weak scrollView, weak canvas] in
            guard let self, let scrollView, let canvas else { return }
            self.requestDocumentUpdate(
                sections: self.parent.sections,
                presentation: self.parent.presentation,
                scrollView: scrollView,
                canvas: canvas
            )
        }
        scrollView.inputPerformanceProbe.install(on: scrollView)
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let center = NotificationCenter.default
        observations.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidScroll() }
        })
        observations.append(center.addObserver(
            forName: .sakuraCordThemeDidCommit,
            object: nil,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            MainActor.assumeIsolated {
                scrollView?.needsDisplay = true
                scrollView?.contentView.needsDisplay = true
                self?.canvas?.needsDisplay = true
            }
        })
        observations.append(center.addObserver(
            forName: ProfileNameFontLoader.didLoadFonts,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let ids = notification.userInfo?["fontIDs"] as? Set<Int> else { return }
            MainActor.assumeIsolated {
                guard let self, let canvas = self.canvas, let scrollView = self.scrollView,
                      self.parent.sections.contains(where: { section in
                          section.members.contains { $0.user.displayNameStyle.map { ids.contains($0.fontID) } == true }
                      }) else { return }
                self.requestedSections = nil
                self.requestDocumentUpdate(sections: self.parent.sections, presentation: self.parent.presentation,
                                           scrollView: scrollView, canvas: canvas)
            }
        })
        self.scrollView = scrollView
        self.canvas = canvas
        update(parent: parent, scrollView: scrollView)
        return scrollView
    }

    func update(parent: NativeMemberListView, scrollView: NSScrollView) {
        if viewportIdentity != parent.viewportIdentity {
            viewportTask?.cancel()
            viewportTask = nil
            lastViewportRange = nil
            pendingViewportRange = nil
            viewportIdentity = parent.viewportIdentity
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        self.parent = parent
        guard let canvas else { return }
        canvas.selectMember = { [weak self] member in
            guard let self else { return }
            let original = self.parent.sections.lazy.flatMap(\.members).first { $0.id == member.id } ?? member
            self.parent.selectMember(original)
        }
        let cosmeticsChanged = canvas.cosmeticPolicy != parent.cosmeticPolicy
        canvas.cosmeticPolicy = parent.cosmeticPolicy
        canvas.openProfile = parent.openProfile
        canvas.modalInputDidChange()
        AppPerformanceSignposts.measureSync("MemberListCanvasUpdate") {
            canvas.updatePresentation(
                customEmojiURLsByID: parent.customEmojiURLsByID,
                profilePresentation: parent.profilePresentation,
                isProfilePresented: parent.isProfilePresented,
                dismissProfile: parent.dismissProfile
            )
        }
        if cosmeticsChanged { canvas.updateVisibleOverlaysAndPrewarming(force: true) }
        requestDocumentUpdate(
            sections: parent.sections,
            presentation: parent.presentation,
            scrollView: scrollView,
            canvas: canvas
        )
        (scrollView as? NativeMemberListScrollView)?.synchronizeCanvasFrame()
        reportViewport(debounced: false)
        startPerformanceBenchmarkIfReady()
    }

    func viewportDidScroll() {
        guard let canvas else { return }
        reportAnimatedImageScrolling(true)
        canvas.setScrolling(true)
        let clock = ContinuousClock()
        scrollIdleDeadline = clock.now.advanced(by: .milliseconds(180))
        if scrollIdleTask == nil {
            scrollIdleTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let deadline = scrollIdleDeadline
                    try? await Task.sleep(until: deadline, clock: clock)
                    guard !Task.isCancelled else { return }
                    guard scrollIdleDeadline <= clock.now else { continue }
                    scrollIdleTask = nil
                    canvas.setScrolling(false)
                    reportAnimatedImageScrolling(false)
                    return
                }
            }
        }
        reportViewport(debounced: true)
        canvas.updateVisibleOverlaysAndPrewarming(reconcileInteraction: false)
    }

    func reportViewport(debounced: Bool) {
        guard let scrollView, let canvas,
              let range = canvas.gatewayRange(intersecting: scrollView.documentVisibleRect)
        else { return }
        pendingViewportRange = range
        if !debounced {
            viewportTask?.cancel()
            viewportTask = nil
            deliverPendingViewport()
            return
        }
        guard viewportTask == nil else { return }
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            viewportTask = nil
            deliverPendingViewport()
        }
    }

    func deliverPendingViewport() {
        guard let range = pendingViewportRange, range != lastViewportRange else { return }
        lastViewportRange = range
        parent.onViewportRange(range)
    }

    func stop() {
        (scrollView as? NativeMemberListScrollView)?.appearanceDidChange = nil
        documentPreparationTask?.cancel()
        documentPreparationTask = nil
        scrollIdleTask?.cancel()
        viewportTask?.cancel()
        performanceStartTask?.cancel()
        performanceStartTask = nil
        reportAnimatedImageScrolling(false)
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll()
        canvas?.tearDown()
        if let performanceInterval {
            endPerformanceScrollIsolation()
            AppPerformanceSignposts.signposter.emitEvent(
                "MemberListAutoScrollBenchmarkCancelled"
            )
            AppPerformanceSignposts.signposter.endInterval(
                "MemberListAutoScrollBenchmark",
                performanceInterval
            )
            NativeTimelineBenchmarkArtifact.write(
                outcome: .cancelled,
                completedDistance: 0,
                elapsed: 0
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "MemberListAutoScrollBenchmark"
            )
        }
        performanceTicker?.stop()
        performanceTicker = nil
        performanceInterval = nil
    }

    func requestDocumentUpdate(
        sections: [MemberSection],
        presentation: NativeMemberListPresentation,
        scrollView: NSScrollView,
        canvas: NativeMemberListCanvasView
    ) {
        let presentation = NativeMemberListPresentation(
            roleColorDisplay: presentation.roleColorDisplay,
            isDark: scrollView.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
        )
        let sections = sections.map { section in
            MemberSection(id: section.id, title: section.title, colorHex: section.colorHex,
                          totalCount: section.totalCount, members: section.members.map(parent.cosmeticPolicy.member),
                          gatewayStartIndex: section.gatewayStartIndex, isLoadingSkeleton: section.isLoadingSkeleton)
        }
        guard requestedSections != sections
            || requestedPresentation != presentation
        else { return }
        if parent.runsPerformanceAutoScroll {
            let layoutSections = sections.map(PerformanceLayoutSection.init)
            if performanceLayoutSections != layoutSections {
                performanceLayoutSections = layoutSections
                performanceStartGeneration &+= 1
                performanceStartTask?.cancel()
                performanceStartTask = nil
            }
        }
        for id in Set(sections.flatMap { $0.members.compactMap { $0.user.displayNameStyle?.fontID } }) {
            ProfileNameFontLoader.shared.request(id: id)
        }
        requestedSections = sections
        requestedPresentation = presentation
        documentPreparationGeneration &+= 1
        let generation = documentPreparationGeneration
        documentPreparationTask?.cancel()
        let preparationSnapshot = canvas.preparationSnapshot()
        let preparationPriority: TaskPriority =
            canvas.isScrolling || AppScrollWorkGate.isActive
            ? .background
            : .userInitiated
        if preparationPriority == .background {
            AppPerformanceSignposts.signposter.emitEvent(
                "MemberListDocumentPreparationDeprioritized"
            )
        }

        if sections.isEmpty || sections.allSatisfy(\.isLoadingSkeleton) {
            documentPreparationTask = nil
            guard let document = NativeMemberListCanvasView.prepareDocument(
                sections: sections,
                presentation: presentation,
                reusing: preparationSnapshot
            ) else { return }
            applyPreparedDocument(
                document,
                generation: generation,
                scrollView: scrollView,
                canvas: canvas
            )
            return
        }

        documentPreparationTask = Task { @MainActor [weak self, weak scrollView, weak canvas] in
            let worker = Task.detached(priority: preparationPriority) {
                AppPerformanceSignposts.measureSync(
                    "MemberListDocumentPreparation"
                ) {
                    NativeMemberListCanvasView.prepareDocument(
                        sections: sections,
                        presentation: presentation,
                        reusing: preparationSnapshot,
                        cancelsCooperatively: true
                    )
                }
            }
            let document = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.documentPreparationGeneration == generation,
                  self.requestedSections == sections,
                  self.requestedPresentation == presentation,
                  let document,
                  let scrollView,
                  let canvas
            else { return }
            self.documentPreparationTask = nil
            self.applyPreparedDocument(
                document,
                generation: generation,
                scrollView: scrollView,
                canvas: canvas
            )
        }
    }

    private func applyPreparedDocument(
        _ document: NativeMemberListCanvasView.PreparedDocument,
        generation: UInt64,
        scrollView: NSScrollView,
        canvas: NativeMemberListCanvasView
    ) {
        guard documentPreparationGeneration == generation,
              requestedSections == document.sections,
              requestedPresentation == document.presentation
        else { return }
        _ = AppPerformanceSignposts.measureSync("MemberListDocumentPublication") {
            canvas.applyPreparedDocument(document)
        }
        (scrollView as? NativeMemberListScrollView)?.synchronizeCanvasFrame()
        reportViewport(debounced: false)
        startPerformanceBenchmarkIfReady()
    }

    func reportAnimatedImageScrolling(_ isScrolling: Bool) {
        guard defersAnimatedImageDecoding != isScrolling else { return }
        defersAnimatedImageDecoding = isScrolling
        animatedImageScrollRevision &+= 1
        let source = animatedImageScrollSource
        let revision = animatedImageScrollRevision
        Task {
            await SharedAnimatedImageDecodeScheduler.shared
                .setInteractiveScrolling(
                    isScrolling,
                    source: source,
                    revision: revision
                )
        }
    }

    func startPerformanceBenchmarkIfReady() {
        guard parent.runsPerformanceAutoScroll,
              !didStartPerformanceBenchmark,
              performanceStartTask == nil,
              documentPreparationTask == nil,
              let scrollView,
              let canvas,
              canvas.contentHeight
                >= NativeTimelineBenchmarkScrollPolicy.nominalDistance
                    + scrollView.contentSize.height
        else { return }
        // Server selection, accessibility inspection by the benchmark driver,
        // initial range delivery, and member-document preparation are separate
        // loading paths. Require three seconds with no replacement document,
        // rather than three seconds after the first tall document, so this idle
        // scenario never silently turns into a loading-overlap measurement.
        performanceStartGeneration &+= 1
        let startGeneration = performanceStartGeneration
        performanceStartTask = Task { [weak self, weak scrollView, weak canvas] in
            defer {
                if let self,
                   self.performanceStartGeneration == startGeneration
                {
                    self.performanceStartTask = nil
                }
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  let self,
                  self.performanceStartGeneration == startGeneration,
                  self.documentPreparationTask == nil,
                  let scrollView,
                  let canvas,
                  canvas.contentHeight
                    >= NativeTimelineBenchmarkScrollPolicy.nominalDistance
                        + scrollView.contentSize.height
            else { return }
            didStartPerformanceBenchmark = true
            runPerformanceBenchmark(scrollView: scrollView, canvas: canvas)
        }
    }

    func runPerformanceBenchmark(
        scrollView: NSScrollView,
        canvas: NativeMemberListCanvasView
    ) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let interval = beginPerformanceScrollMeasurement()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var previousTick = startedAt
        var completedDistance: CGFloat = 0
        var completedTicks = 0
        var delayedTicks = 0
        var tickIntervals: [TimeInterval] = []
        tickIntervals.reserveCapacity(1_500)
        var delayedTickSamples: [NativeTimelineBenchmarkArtifact.DelayedTick] = []
        delayedTickSamples.reserveCapacity(64)
        var maximumTickInterval = 0.0
        var maximumScrollWork = 0.0
        let ticker = NativeTimelineDisplayLinkTicker()
        performanceTicker = ticker
        ticker.start(on: canvas) { [weak self, weak ticker] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - startedAt
            let tickInterval = now - previousTick
            completedTicks += 1
            tickIntervals.append(tickInterval)
            maximumTickInterval = max(maximumTickInterval, tickInterval)
            if tickInterval > 0.033 {
                delayedTicks += 1
                delayedTickSamples.append(
                    .init(offset: now - startedAt, interval: tickInterval)
                )
            }
            let delta = NativeTimelineBenchmarkScrollPolicy.distance(
                tickInterval: tickInterval
            )
            previousTick = now
            let workStart = ProcessInfo.processInfo.systemUptime
            let previousY = scrollView.contentView.bounds.minY
            let maximumY = max(
                0,
                canvas.contentHeight - scrollView.contentSize.height
            )
            let nextY = min(maximumY, previousY + delta)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            completedDistance += max(0, nextY - previousY)
            maximumScrollWork = max(
                maximumScrollWork,
                ProcessInfo.processInfo.systemUptime - workStart
            )
            if elapsed >= NativeTimelineBenchmarkScrollPolicy.duration
                || nextY >= maximumY - 0.5
            {
                endPerformanceScrollIsolation()
                ticker?.stop()
                performanceTicker = nil
                let outcome: NativeTimelineBenchmarkFinishOutcome =
                    elapsed >= NativeTimelineBenchmarkScrollPolicy.duration
                        ? .completed : .insufficientHistory
                switch outcome {
                case .completed:
                    AppPerformanceSignposts.signposter.emitEvent(
                        "MemberListAutoScrollBenchmarkCompleted"
                    )
                case .insufficientHistory:
                    AppPerformanceSignposts.signposter.emitEvent(
                        "MemberListAutoScrollBenchmarkInsufficientHistory"
                    )
                case .cancelled, .paginationFailed:
                    break
                }
                AppPerformanceSignposts.signposter.endInterval(
                    "MemberListAutoScrollBenchmark",
                    interval
                )
                performanceInterval = nil
                NativeTimelineBenchmarkArtifact.write(
                    outcome: outcome,
                    completedDistance: completedDistance,
                    elapsed: elapsed,
                    completedTicks: completedTicks,
                    delayedTicks: delayedTicks,
                    tickIntervals: tickIntervals,
                    delayedTickSamples: delayedTickSamples,
                    maximumTickInterval: maximumTickInterval,
                    maximumScrollWork: maximumScrollWork,
                    historyStarvedTicks: 0,
                    maximumConsecutiveHistoryStarvedTicks: 0
                )
                AppPerformanceSignposts.endResourceWindow(
                    named: "MemberListAutoScrollBenchmark",
                    nominalDuration:
                        outcome == .completed
                            ? NativeTimelineBenchmarkScrollPolicy.duration : nil
                )
            }
        }
    }

    private func beginPerformanceScrollIsolation() {
        AppScrollWorkGate.beginActivity()
    }

    private func beginPerformanceScrollMeasurement() -> OSSignpostIntervalState {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "MemberListAutoScrollBenchmark"
        )
        performanceInterval = interval
        // Programmatic benchmark motion bypasses AppKit's live-scroll
        // notifications. Exercise the same loading-isolation gate as a real
        // trackpad gesture so cross-surface regressions remain observable.
        beginPerformanceScrollIsolation()
        AppPerformanceSignposts.beginResourceWindow(
            named: "MemberListAutoScrollBenchmark"
        )
        return interval
    }

    private func endPerformanceScrollIsolation() {
        AppScrollWorkGate.endActivity()
    }
}
