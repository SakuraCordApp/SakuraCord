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
    private var animatesShimmer: Bool?
    var contentIdentity: String?
    var contentPreparations: [String: NativeMemberListCanvasView.PreparationSnapshot] = [:]
    var performanceTicker: DisplayLinkTicker?
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

    func makeScrollView() -> NativeMemberListScrollView {
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
        let contentChanged = contentIdentity != parent.contentIdentity
        if contentChanged, let contentIdentity, let canvas {
            if contentPreparations.count >= 4 { contentPreparations.removeAll(keepingCapacity: true) }
            contentPreparations[contentIdentity] = canvas.preparationSnapshot()
        }
        if viewportIdentity != parent.viewportIdentity || contentChanged {
            canvas?.dismissServerTagCard()
            canvas?.clearServerTagHover()
            viewportTask?.cancel()
            viewportTask = nil
            lastViewportRange = nil
            pendingViewportRange = nil
            viewportIdentity = parent.viewportIdentity
            contentIdentity = parent.contentIdentity
            scrollView.contentView.scroll(to: NSPoint(
                x: -scrollView.contentInsets.left, y: -scrollView.contentInsets.top
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        self.parent = parent
        guard let canvas else { return }
        // The loading shimmer starts or stops with the motion settings, not
        // only when members change.
        let animatesShimmer = !parent.reduceMotion && !parent.disablesAllAnimations
        if self.animatesShimmer != animatesShimmer {
            self.animatesShimmer = animatesShimmer
            canvas.reconcilePlaceholderShimmer()
        }
        canvas.selectMember = { [weak self] member in
            guard let self else { return }
            let original = self.parent.sections.lazy.flatMap(\.members).first { $0.id == member.id } ?? member
            self.parent.selectMember(original)
        }
        let cosmeticsChanged = canvas.cosmeticPolicy != parent.cosmeticPolicy
        canvas.cosmeticPolicy = parent.cosmeticPolicy
        let serverTagModelChanged = canvas.serverTagCardModel !== parent.serverTagCardModel
        canvas.serverTagCardModel = parent.serverTagCardModel
        canvas.openProfile = parent.openProfile
        canvas.sendProfileMessage = parent.sendProfileMessage
        canvas.rowAccessory = parent.rowAccessory
        canvas.rowMenu = parent.rowMenu
        canvas.rowAccessibilityActions = parent.rowAccessibilityActions
        canvas.modalInputDidChange()
        AppPerformanceSignposts.measureSync("MemberListCanvasUpdate") {
            canvas.updatePresentation(
                customEmojiURLsByID: parent.customEmojiURLsByID,
                profilePresentation: parent.profilePresentation,
                isProfilePresented: parent.isProfilePresented,
                dismissProfile: parent.dismissProfile
            )
        }
        if cosmeticsChanged || serverTagModelChanged {
            canvas.updateVisibleOverlaysAndPrewarming(force: true)
        }
        requestDocumentUpdate(
            sections: parent.sections,
            presentation: parent.presentation,
            scrollView: scrollView,
            canvas: canvas,
            isNavigation: contentChanged
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
        cancelPerformanceBenchmark()
    }

    func requestDocumentUpdate(
        sections: [MemberSection],
        presentation: NativeMemberListPresentation,
        scrollView: NSScrollView,
        canvas: NativeMemberListCanvasView,
        isNavigation: Bool = false
    ) {
        var resolvedPresentation = presentation
        resolvedPresentation.isDark = scrollView.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let presentation = resolvedPresentation
        let sections = sections.map { section in
            MemberSection(id: section.id, title: section.title, colorHex: section.colorHex,
                          totalCount: section.totalCount, members: section.members.map(parent.cosmeticPolicy.member),
                          gatewayStartIndex: section.gatewayStartIndex, isLoadingSkeleton: section.isLoadingSkeleton,
                          role: section.role)
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
        let preparationSnapshot = isNavigation
            ? contentIdentity.flatMap { contentPreparations[$0] } ?? canvas.preparationSnapshot()
            : canvas.preparationSnapshot()
        let preparationPriority: TaskPriority =
            !isNavigation && (canvas.isScrolling || AppScrollWorkGate.isActive)
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
        // Every changed section/presentation advances this generation before
        // starting work; avoid repeating full-list equality on the main actor.
        guard documentPreparationGeneration == generation else { return }
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
}
