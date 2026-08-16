import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

// The canvas keeps painting, overlays, accessibility proxies, and image
// scheduling together because they reconcile one shared virtual viewport.
// swiftlint:disable file_length

nonisolated enum NativeMemberListMetrics {
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 10
    static let sectionHeaderHeight: CGFloat = 34
    static let memberRowHeight: CGFloat = 46
    static let paintedRowHeight: CGFloat = 44
    static let avatarSize: CGFloat = 34
    static let avatarContainerSize: CGFloat = 38.08
    static let rowCornerRadius: CGFloat = 9
    static let prewarmItemCount = 8
    static let activityEmojiSize: CGFloat = 15
    static let maximumVisibleAnimatedEmojiCount = 64
}

nonisolated enum MemberListSkeletonLayout {
    enum Item: Hashable {
        case header(Int)
        case member(section: Int, row: Int)

        var height: CGFloat {
            switch self {
            case .header: NativeMemberListMetrics.sectionHeaderHeight
            case .member: NativeMemberListMetrics.memberRowHeight
            }
        }
    }

    static func itemsFitting(height: CGFloat, memberCounts: [Int]) -> [Item] {
        let availableHeight = max(
            0,
            height - NativeMemberListMetrics.verticalInset * 2
        )
        var result: [Item] = []
        var usedHeight: CGFloat = 0
        for (section, count) in memberCounts.enumerated() {
            let header = Item.header(section)
            guard usedHeight + header.height <= availableHeight else { break }
            result.append(header)
            usedHeight += header.height
            for row in 0 ..< count {
                let member = Item.member(section: section, row: row)
                guard usedHeight + member.height <= availableHeight else {
                    return result
                }
                result.append(member)
                usedHeight += member.height
            }
        }
        return result
    }
}

struct MemberListSkeletonRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                SkeletonShape(
                    cornerRadius: NativeMemberListMetrics.avatarSize / 2
                )
                .frame(
                    width: NativeMemberListMetrics.avatarSize,
                    height: NativeMemberListMetrics.avatarSize
                )

                SkeletonShape(cornerRadius: 5.5)
                    .frame(width: 11, height: 11)
                    .overlay {
                        Circle().stroke(
                            Color(nsColor: .controlBackgroundColor),
                            lineWidth: 2
                        )
                    }
                    .offset(x: 1, y: 1)
            }
            .frame(
                width: NativeMemberListMetrics.avatarContainerSize,
                height: NativeMemberListMetrics.avatarContainerSize
            )

            VStack(alignment: .leading, spacing: 9) {
                SkeletonShape(cornerRadius: 5)
                    .frame(width: 104, height: 10)
                SkeletonShape(cornerRadius: 4)
                    .frame(width: 138, height: 8)
                    .opacity(0.7)
            }
            .offset(y: -2.5)

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MemberListSkeletonHeader: View {
    var body: some View {
        SkeletonShape(cornerRadius: 5)
            .frame(width: 96, height: 10)
            .padding(.leading, NativeMemberListMetrics.horizontalInset + 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

nonisolated enum NativeMemberNameLayout {
    struct Result: Equatable {
        let nameWidth: CGFloat
        let accessoryFrames: [CGRect]
    }

    static let accessorySpacing: CGFloat = 5

    static func layout(
        measuredNameWidth: CGFloat,
        availableWidth: CGFloat,
        accessoryWidths: [CGFloat]
    ) -> Result {
        let availableWidth = max(0, availableWidth)
        let accessoryWidths = accessoryWidths.map { max(0, $0) }
        let totalAccessoryWidth = accessoryWidths.reduce(0, +)
        let totalSpacing = accessorySpacing * CGFloat(accessoryWidths.count)
        let nameWidth = min(
            max(0, measuredNameWidth),
            max(0, availableWidth - totalAccessoryWidth - totalSpacing)
        )
        var cursor = nameWidth
        let frames = accessoryWidths.map { width in
            cursor += accessorySpacing
            let remainingWidth = max(0, availableWidth - cursor)
            let visibleWidth = min(width, remainingWidth)
            let frame = CGRect(x: cursor, y: 0, width: visibleWidth, height: 0)
            cursor += visibleWidth
            return frame
        }
        return Result(nameWidth: nameWidth, accessoryFrames: frames)
    }
}

struct NativeMemberListView: NSViewRepresentable {
    let sections: [MemberSection]
    let customEmojiURLsByID: [String: URL]
    let profilePresentation: ProfilePresentationState?
    let isProfilePresented: Bool
    let interactionsBlocked: Bool
    let selectMember: (Member) -> Void
    let dismissProfile: () -> Void
    let runsPerformanceAutoScroll: Bool
    let viewportIdentity: ChannelID?
    var onViewportRange: (ClosedRange<Int>) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self, scrollView: scrollView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView as? NativeMemberListScrollView)?
            .inputPerformanceProbe.invalidate()
        coordinator.stop()
        scrollView.documentView = nil
    }

    typealias Coordinator = NativeMemberListCoordinator
}

@MainActor
final class NativeMemberListScrollView: NSScrollView {
    let inputPerformanceProbe = ScrollInputPerformanceProbe(
        surface: .memberList
    )

    override func layout() {
        super.layout()
        synchronizeCanvasFrame()
    }

    func synchronizeCanvasFrame() {
        guard let canvas = documentView as? NativeMemberListCanvasView else { return }
        let targetSize = NSSize(
            width: max(0, contentSize.width),
            height: max(1, canvas.contentHeight)
        )
        guard canvas.frame.size != targetSize else { return }
        canvas.frame.size = targetSize
        canvas.needsDisplay = true
        canvas.updateVisibleOverlaysAndPrewarming(force: true)
    }
}

@MainActor
final class NativeMemberListCoordinator: NSObject {
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
    var didStartPerformanceBenchmark = false
    var performanceInterval: OSSignpostIntervalState?
    var documentPreparationTask: Task<Void, Never>?
    var requestedSections: [MemberSection]?
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
            self?.parent.selectMember(member)
        }
        let scrollView = NativeMemberListScrollView()
        scrollView.inputPerformanceProbe.install(on: scrollView)
        scrollView.documentView = canvas
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45)
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
            self?.parent.selectMember(member)
        }
        canvas.setInteractionsBlocked(parent.interactionsBlocked)
        AppPerformanceSignposts.measureSync("MemberListCanvasUpdate") {
            canvas.updatePresentation(
                customEmojiURLsByID: parent.customEmojiURLsByID,
                profilePresentation: parent.profilePresentation,
                isProfilePresented: parent.isProfilePresented,
                dismissProfile: parent.dismissProfile
            )
        }
        requestDocumentUpdate(
            sections: parent.sections,
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
        scrollView: NSScrollView,
        canvas: NativeMemberListCanvasView
    ) {
        guard requestedSections != sections else { return }
        requestedSections = sections
        documentPreparationGeneration &+= 1
        let generation = documentPreparationGeneration
        documentPreparationTask?.cancel()

        if sections.isEmpty || sections.allSatisfy(\.isLoadingSkeleton) {
            documentPreparationTask = nil
            guard let document = NativeMemberListCanvasView.prepareDocument(
                sections: sections
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
            let worker = Task.detached(priority: .userInitiated) {
                AppPerformanceSignposts.measureSync(
                    "MemberListDocumentPreparation"
                ) {
                    NativeMemberListCanvasView.prepareDocument(
                        sections: sections,
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
              requestedSections == document.sections
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
              let scrollView,
              let canvas,
              canvas.contentHeight
                >= NativeTimelineBenchmarkScrollPolicy.nominalDistance
                    + scrollView.contentSize.height
        else { return }
        didStartPerformanceBenchmark = true
        // Server selection, accessibility inspection by the benchmark driver,
        // initial range delivery, and image prewarming are separate loading
        // paths. Let them settle before the exact scrolling resource window so
        // this scenario measures list motion rather than its manual setup.
        performanceStartTask = Task { [weak self, weak scrollView, weak canvas] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  let self,
                  let scrollView,
                  let canvas,
                  canvas.contentHeight
                    >= NativeTimelineBenchmarkScrollPolicy.nominalDistance
                        + scrollView.contentSize.height
            else { return }
            performanceStartTask = nil
            runPerformanceBenchmark(scrollView: scrollView, canvas: canvas)
        }
    }

    func runPerformanceBenchmark(
        scrollView: NSScrollView,
        canvas: NativeMemberListCanvasView
    ) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "MemberListAutoScrollBenchmark"
        )
        performanceInterval = interval
        AppPerformanceSignposts.beginResourceWindow(
            named: "MemberListAutoScrollBenchmark"
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        var previousTick = startedAt
        var completedDistance: CGFloat = 0
        var completedTicks = 0
        var delayedTicks = 0
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
            maximumTickInterval = max(maximumTickInterval, tickInterval)
            if tickInterval > 0.033 {
                delayedTicks += 1
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
}

@MainActor
// swiftlint:disable:next type_body_length
final class NativeMemberListCanvasView: NSView {
    nonisolated enum ItemID: Hashable, Sendable {
        case header(MemberSection.SectionIdentifier)
        case member(UserID)
        case placeholder(Int)
    }

    nonisolated enum Item: Equatable, Sendable {
        case header(MemberSection)
        case member(Member, gatewayIndex: Int?)
        case placeholder(gatewayIndex: Int)

        var id: ItemID {
            switch self {
            case .header(let section): .header(section.id)
            case .member(let member, _): .member(member.id)
            case .placeholder(let index): .placeholder(index)
            }
        }

        var gatewayIndex: Int? {
            switch self {
            case .header(let section): section.gatewayStartIndex
            case .member(_, let index): index
            case .placeholder(let index): index
            }
        }

        var height: CGFloat {
            switch self {
            case .header: NativeMemberListMetrics.sectionHeaderHeight
            case .member, .placeholder: NativeMemberListMetrics.memberRowHeight
            }
        }
    }

    struct PreparedText {
        let name: CTLine
        let nameTruncationToken: CTLine
        let nameWidth: CGFloat
        let activity: CTLine?
        let activityTruncationToken: CTLine?
        let activityWidth: CGFloat
    }

    nonisolated struct PreparedDocument: Sendable {
        let sections: [MemberSection]
        let items: [Item]
        let itemIndexesByID: [ItemID: Int]
        let origins: [CGFloat]
        let contentHeight: CGFloat
    }

    struct ActivityEmojiOverlayID: Hashable {
        let itemID: ItemID
        let ordinal: Int
    }

    struct ActivityEmojiOverlayConfiguration: Equatable {
        let url: URL
        let opacity: CGFloat
    }

    struct AvatarOverlayPresentation {
        let id: ItemID
        let member: Member
        let index: Int
    }

    struct ActivityEmojiOverlayPresentation {
        let id: ActivityEmojiOverlayID
        let configuration: ActivityEmojiOverlayConfiguration
        let frame: CGRect
    }

    struct GuildTagPresentation {
        let line: CTLine
        let width: CGFloat
        let iconWidth: CGFloat
        let image: CGImage?
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var items: [Item] = []
    var presentedSections: [MemberSection] = []
    var itemIndexesByID: [ItemID: Int] = [:]
    var customEmojiURLsByID: [String: URL] = [:]
    var origins: [CGFloat] = []
    var contentHeight: CGFloat = 1
    var preparedText: [ItemID: PreparedText] = [:]
    var selectedMemberID: UserID?
    var profilePresentation: ProfilePresentationState?
    var isProfilePresented = false
    var dismissProfile: () -> Void = {}
    var selectMember: (Member) -> Void = { _ in }
    var hoveredIndex: Int?
    var isScrolling = false
    var interactionsBlocked = false
    var trackingArea: NSTrackingArea?
    var rowOverlay: NSHostingView<AnyView>?
    var rowForegroundOverlay: NativeMemberForegroundOverlayView?
    var rowOverlayIndex: Int?
    var profileAnchorIndex: Int?
    let profilePopoverCoordinator =
        StableAnchoredPopoverPresenter<AnyView>.Coordinator()
    lazy var profilePopoverAnchor = StablePopoverAnchor(
        sourceView: self,
        sourceRect: { [weak self] in
            guard let self,
                  let index = self.profileAnchorIndex,
                  self.items.indices.contains(index)
            else { return nil }
            return self.paintedRowRect(at: index)
        }
    )
    var avatarOverlays: [ItemID: NSHostingView<AnyView>] = [:]
    var avatarOverlayMembers: [ItemID: Member] = [:]
    var placeholderOverlays: [ItemID: NSHostingView<AnyView>] = [:]
    var activityEmojiOverlays: [ActivityEmojiOverlayID: NSHostingView<AnyView>] = [:]
    var activityEmojiOverlayConfigurations: [
        ActivityEmojiOverlayID: ActivityEmojiOverlayConfiguration
    ] = [:]
    var accessibilityRows: [ItemID: NativeMemberAccessibilityProxyView] = [:]
    var imageTasks: [URL: Task<Void, Never>] = [:]
    var imageTaskPriorities: [URL: MediaLoadPriority] = [:]
    var imageTaskPixelDimensions: [URL: Int] = [:]
    var imageRequestItemIDs: [URL: Set<ItemID>] = [:]
    var images: [URL: CGImage] = [:]
    var imagePixelDimensions: [URL: Int] = [:]
    var reconciledVisibleRange: Range<Int>?
    var reconciledViewportWidth: CGFloat?
    var imageLoadPromotion: @Sendable (URL, Int) async -> Void = { url, dimension in
        await SharedDecodedImageLoader.shared.promoteImageLoad(
            for: url,
            maximumPixelDimension: dimension
        )
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard !interactionsBlocked else {
            trackingArea = nil
            super.updateTrackingAreas()
            return
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    func updatePresentation(
        customEmojiURLsByID: [String: URL] = [:],
        profilePresentation: ProfilePresentationState?,
        isProfilePresented: Bool,
        dismissProfile: @escaping () -> Void
    ) {
        let previousSelectedMemberID = selectedMemberID
        let previousCustomEmojiURLsByID = self.customEmojiURLsByID
        self.customEmojiURLsByID = customEmojiURLsByID
        self.profilePresentation = profilePresentation
        self.isProfilePresented = isProfilePresented
        self.dismissProfile = dismissProfile
        selectedMemberID = isProfilePresented
            ? profilePresentation?.member.id
            : nil
        if previousCustomEmojiURLsByID != customEmojiURLsByID {
            needsDisplay = true
        }
        for index in selectionInvalidationIndexes(
            previous: previousSelectedMemberID,
            current: selectedMemberID
        ) {
            setNeedsDisplay(itemRect(at: index))
        }
        updateVisibleOverlaysAndPrewarming(
            force: previousCustomEmojiURLsByID != customEmojiURLsByID
        )
    }

    func setInteractionsBlocked(_ blocked: Bool) {
        guard interactionsBlocked != blocked else { return }
        interactionsBlocked = blocked
        if blocked {
            if let old = hoveredIndex {
                hoveredIndex = nil
                setNeedsDisplay(itemRect(at: old))
            }
            removeRowOverlay()
            profilePopoverCoordinator.close()
        }
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    @discardableResult
    func updateDocumentIfNeeded(
        sections: [MemberSection],
        previousItems: [Item]? = nil
    ) -> Bool {
        guard sections != presentedSections else { return false }
        guard let document = Self.prepareDocument(sections: sections) else {
            return false
        }
        return applyPreparedDocument(document, previousItems: previousItems)
    }

    @discardableResult
    func applyPreparedDocument(
        _ document: PreparedDocument,
        previousItems suppliedPreviousItems: [Item]? = nil
    ) -> Bool {
        guard document.sections != presentedSections else { return false }
        let previousItems = suppliedPreviousItems ?? items
        let previousItemIndexesByID = itemIndexesByID
        presentedSections = document.sections
        items = document.items
        itemIndexesByID = document.itemIndexesByID
        if let hoveredIndex,
           !items.indices.contains(hoveredIndex) ||
           !previousItems.indices.contains(hoveredIndex) ||
           items[hoveredIndex].id != previousItems[hoveredIndex].id
        {
            self.hoveredIndex = nil
        }
        origins = document.origins
        contentHeight = document.contentHeight
        invalidateIntrinsicContentSize()
        retainPreparedRows(
            previousItems: previousItems,
            previousItemIndexesByID: previousItemIndexesByID
        )
        if previousItems.count == items.count {
            for index in items.indices where items[index] != previousItems[index] {
                setNeedsDisplay(itemRect(at: index))
            }
        } else {
            needsDisplay = true
        }
        reconciledVisibleRange = nil
        updateVisibleOverlaysAndPrewarming(force: true)
        return true
    }

    func selectionInvalidationIndexes(
        previous: UserID?,
        current: UserID?
    ) -> [Int] {
        guard previous != current else { return [] }
        var indexes: [Int] = []
        if let previous,
           let index = itemIndexesByID[.member(previous)]
        {
            indexes.append(index)
        }
        if let current,
           let index = itemIndexesByID[.member(current)],
           !indexes.contains(index)
        {
            indexes.append(index)
        }
        return indexes.sorted()
    }

    nonisolated static func prepareDocument(
        sections: [MemberSection],
        cancelsCooperatively: Bool = false
    ) -> PreparedDocument? {
        guard let items = makeItems(
            sections: sections,
            cancelsCooperatively: cancelsCooperatively
        ) else { return nil }
        var itemIndexesByID: [ItemID: Int] = [:]
        itemIndexesByID.reserveCapacity(items.count)
        var origins: [CGFloat] = []
        origins.reserveCapacity(items.count)
        var cursorY = NativeMemberListMetrics.verticalInset
        for index in items.indices {
            if cancelsCooperatively,
               index.isMultiple(of: 128),
               Task.isCancelled
            {
                return nil
            }
            itemIndexesByID[items[index].id] = index
            origins.append(cursorY)
            cursorY += items[index].height
        }
        return PreparedDocument(
            sections: sections,
            items: items,
            itemIndexesByID: itemIndexesByID,
            origins: origins,
            contentHeight: cursorY + NativeMemberListMetrics.verticalInset
        )
    }

    private nonisolated static func makeItems(
        sections: [MemberSection],
        cancelsCooperatively: Bool
    ) -> [Item]? {
        var result: [Item] = []
        result.reserveCapacity(sections.reduce(0) { $0 + $1.totalCount + 1 })
        for (sectionOffset, section) in sections.enumerated() {
            if cancelsCooperatively,
               sectionOffset.isMultiple(of: 8),
               Task.isCancelled
            {
                return nil
            }
            result.append(.header(section))
            let visibleMembers = section.members.prefix(max(0, section.totalCount))
            guard let sectionStart = section.gatewayStartIndex else {
                result.append(contentsOf: visibleMembers.map { member in
                    .member(member, gatewayIndex: member.memberListIndex)
                })
                continue
            }
            guard section.totalCount > 0 else { continue }

            let gatewayRange = (sectionStart + 1) ... (sectionStart + section.totalCount)
            var indexedMembers: [Int: Member] = [:]
            var inferredMembers: [Member] = []
            inferredMembers.reserveCapacity(visibleMembers.count)
            for member in visibleMembers {
                if let index = member.memberListIndex, gatewayRange.contains(index) {
                    indexedMembers[index] = indexedMembers[index] ?? member
                } else {
                    inferredMembers.append(member)
                }
            }
            var inferredIndex = inferredMembers.startIndex
            for gatewayIndex in gatewayRange {
                if cancelsCooperatively,
                   gatewayIndex.isMultiple(of: 128),
                   Task.isCancelled
                {
                    return nil
                }
                if let member = indexedMembers[gatewayIndex] {
                    result.append(.member(member, gatewayIndex: gatewayIndex))
                } else if inferredIndex < inferredMembers.endIndex {
                    result.append(.member(
                        inferredMembers[inferredIndex], gatewayIndex: gatewayIndex
                    ))
                    inferredMembers.formIndex(after: &inferredIndex)
                } else {
                    result.append(.placeholder(gatewayIndex: gatewayIndex))
                }
            }
        }
        return result
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    private func retainPreparedRows(
        previousItems: [Item],
        previousItemIndexesByID: [ItemID: Int]
    ) {
        var retained: [ItemID: PreparedText] = [:]
        retained.reserveCapacity(min(preparedText.count, items.count))
        for item in items {
            guard case .member = item,
                  let previousIndex = previousItemIndexesByID[item.id],
                  previousItems.indices.contains(previousIndex),
                  previousItems[previousIndex] == item,
                  let existing = preparedText[item.id]
            else { continue }
            retained[item.id] = existing
        }
        preparedText = retained
    }

    func prepareRows(in range: Range<Int>) {
        guard !range.isEmpty else { return }
        AppPerformanceSignposts.measureSync(
            "MemberListTextPreparation"
        ) {
            prepareRowsUnmeasured(in: range)
        }
    }

    private func prepareRowsUnmeasured(in range: Range<Int>) {
        let nameFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold
        )
        let activityFont = NSFont.systemFont(ofSize: 12)
        for index in range where items.indices.contains(index) {
            let item = items[index]
            guard case .member(let member, _) = item else { continue }
            guard preparedText[item.id] == nil else { continue }
            let nameColor = MessageAuthorPresentation.topRoleColor(in: member.roles)
                .map(Self.color(hex:)) ?? .labelColor
            let alpha: CGFloat = member.isOnline ? 1 : 0.55
            let name = Self.line(
                member.user.displayName,
                font: nameFont,
                color: nameColor.withAlphaComponent(alpha)
            )
            let activity = member.activityText.flatMap { text -> CTLine? in
                guard !text.isEmpty else { return nil }
                return NativeMemberActivityPresentation.line(
                    text,
                    font: activityFont,
                    color: Self.memberActivityColor.withAlphaComponent(alpha)
                )
            }
            let activityTruncationToken = activity.map { _ in
                Self.line(
                    "…",
                    font: activityFont,
                    color: Self.memberActivityColor.withAlphaComponent(alpha)
                )
            }
            preparedText[item.id] = PreparedText(
                name: name,
                nameTruncationToken: Self.line(
                    "…",
                    font: nameFont,
                    color: nameColor.withAlphaComponent(alpha)
                ),
                nameWidth: CGFloat(CTLineGetTypographicBounds(name, nil, nil, nil)),
                activity: activity,
                activityTruncationToken: activityTruncationToken,
                activityWidth: activity.map {
                    CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil))
                } ?? 0
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let range = itemRange(intersecting: dirtyRect)
        for index in range {
            draw(item: items[index], at: index, context: context)
        }
    }

    func draw(item: Item, at index: Int, context: CGContext) {
        switch item {
        case .header(let section):
            if !section.isLoadingSkeleton {
                let label = "\(section.title) — \(section.totalCount)"
                let font = NSFont.systemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                    weight: .semibold
                )
                let color = section.colorHex.map(Self.color(hex:)) ?? .secondaryLabelColor
                Self.draw(
                    line: Self.line(label, font: font, color: color),
                    at: CGPoint(
                        x: NativeMemberListMetrics.horizontalInset + 10,
                        y: origins[index] + 12
                    ),
                    context: context
                )
            }
        case .placeholder:
            break
        case .member(let member, _):
            drawMember(member, at: index, context: context)
        }
    }

    func drawMember(_ member: Member, at index: Int, context: CGContext) {
        guard rowOverlayIndex != index else { return }
        let row = paintedRowRect(at: index)
        let isSelected = selectedMemberID == member.id
        if let nameplate = member.user.nameplate {
            context.saveGState()
            context.addPath(CGPath(
                roundedRect: row,
                cornerWidth: NativeMemberListMetrics.rowCornerRadius,
                cornerHeight: NativeMemberListMetrics.rowCornerRadius,
                transform: nil
            ))
            context.clip()
            if let colors = NameplatePresentationPolicy.colors(for: nameplate.palette) {
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let color = Self.color(hex: isDark ? colors.dark : colors.light)
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [
                        color.withAlphaComponent(0.05).cgColor,
                        color.withAlphaComponent(0.20).cgColor,
                    ] as CFArray,
                    locations: [0, 1]
                )
                if let gradient {
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: row.minX, y: row.midY),
                        end: CGPoint(x: row.maxX, y: row.midY),
                        options: []
                    )
                }
            }
            if let url = nameplate.staticURL, let image = images[url] {
                context.setAlpha(CGFloat(NameplatePresentationPolicy.opacity(isHovered: false)))
                Self.draw(image: image, in: row, context: context, fills: true)
                context.setAlpha(1)
            }
            context.restoreGState()
            requestImageIfNeeded(
                url: nameplate.staticURL,
                index: index,
                priority: .visible,
                maximumPixelDimension: 512
            )
            if isSelected {
                Self.fillRounded(row, color: .labelColor.withAlphaComponent(0.07), context: context)
            }
        } else if isSelected {
            Self.fillRounded(row, color: .labelColor.withAlphaComponent(0.07), context: context)
        }

        drawMemberForeground(member, at: index, context: context)
    }

    func drawMemberForeground(_ member: Member, at index: Int, context: CGContext) {
        let row = paintedRowRect(at: index)
        guard let prepared = preparedText[items[index].id] else { return }
        context.saveGState()
        context.clip(to: row)
        defer { context.restoreGState() }

        drawMemberAvatar(member, at: index, context: context)

        let textX = row.minX + 4 + NativeMemberListMetrics.avatarContainerSize + 8
        let nameY = member.activityText?.isEmpty == false ? row.minY + 5 : row.minY + 13
        let botBadgeWidth: CGFloat = 30
        let tagPresentation = member.user.primaryGuild.flatMap(guildTagPresentation)
        let accessoryWidths = (member.user.isBot ? [botBadgeWidth] : [])
            + (tagPresentation.map { [$0.width] } ?? [])
        let nameLayout = NativeMemberNameLayout.layout(
            measuredNameWidth: prepared.nameWidth,
            availableWidth: max(0, row.maxX - 4 - textX),
            accessoryWidths: accessoryWidths
        )
        if nameLayout.nameWidth > 0 {
            let visibleName = Self.truncatedLine(
                prepared.name,
                token: prepared.nameTruncationToken,
                maximumWidth: nameLayout.nameWidth
            )
            Self.draw(line: visibleName, at: CGPoint(x: textX, y: nameY), context: context)
        }

        var accessoryIndex = 0
        if member.user.isBot, nameLayout.accessoryFrames.indices.contains(accessoryIndex) {
            let accessory = nameLayout.accessoryFrames[accessoryIndex]
            if accessory.width >= botBadgeWidth {
                drawBotBadge(at: textX + accessory.minX, nameY: nameY, context: context)
            }
            accessoryIndex += 1
        }
        if let identity = member.user.primaryGuild,
           let tagPresentation,
           nameLayout.accessoryFrames.indices.contains(accessoryIndex)
        {
            drawGuildTag(
                tagPresentation,
                identity: identity,
                accessoryFrame: nameLayout.accessoryFrames[accessoryIndex],
                textX: textX,
                nameY: nameY,
                itemIndex: index,
                context: context
            )
        }
        if let activity = prepared.activity,
           let truncationToken = prepared.activityTruncationToken
        {
            let maximumWidth = max(0, row.maxX - textX - 4)
            let visibleActivity = Self.truncatedLine(
                activity,
                token: truncationToken,
                maximumWidth: maximumWidth
            )
            let origin = CGPoint(x: textX, y: row.minY + 24)
            Self.draw(line: visibleActivity, at: origin, context: context)
            for region in NativeMemberActivityPresentation.emojiRegions(
                in: visibleActivity,
                origin: origin
            ) {
                guard let url = activityEmojiURL(for: region.reference) else { continue }
                if let image = images[url] {
                    Self.draw(
                        image: image,
                        aspectFitIn: region.frame,
                        context: context
                    )
                } else {
                    requestImageIfNeeded(
                        url: url,
                        index: index,
                        priority: .visible,
                        maximumPixelDimension: 64
                    )
                }
            }
        }
    }

    func drawMemberAvatar(
        _ member: Member,
        at index: Int,
        context: CGContext
    ) {
        let container = CGRect(
            x: NativeMemberListMetrics.horizontalInset + 4,
            y: origins[index] + 1
                + (NativeMemberListMetrics.paintedRowHeight
                    - NativeMemberListMetrics.avatarContainerSize) / 2,
            width: NativeMemberListMetrics.avatarContainerSize,
            height: NativeMemberListMetrics.avatarContainerSize
        )
        let avatar = CGRect(
            x: container.midX - NativeMemberListMetrics.avatarSize / 2,
            y: container.midY - NativeMemberListMetrics.avatarSize / 2,
            width: NativeMemberListMetrics.avatarSize,
            height: NativeMemberListMetrics.avatarSize
        )
        let opacity: CGFloat = member.isOnline ? 1 : 0.55
        context.saveGState()
        context.setAlpha(opacity)

        let avatarURL = member.guildAvatarURL ?? member.user.avatarURL
        context.saveGState()
        context.addEllipse(in: avatar)
        context.clip()
        if let avatarURL, let image = images[avatarURL] {
            Self.draw(
                image: image,
                in: avatar,
                context: context,
                fills: true
            )
        } else {
            drawAvatarFallback(
                name: member.user.displayName,
                in: avatar,
                context: context
            )
        }
        context.restoreGState()
        requestImageIfNeeded(
            url: avatarURL,
            index: index,
            priority: .visible,
            maximumPixelDimension: 96
        )

        if let decorationURL = member.user.avatarDecorationURL {
            if let decoration = images[decorationURL] {
                let decorationSize = NativeMemberListMetrics.avatarSize * 1.22
                Self.draw(
                    image: decoration,
                    aspectFitIn: CGRect(
                        x: container.midX - decorationSize / 2,
                        y: container.midY - decorationSize / 2,
                        width: decorationSize,
                        height: decorationSize
                    ),
                    context: context
                )
            }
            requestImageIfNeeded(
                url: decorationURL,
                index: index,
                priority: .visible,
                maximumPixelDimension: 96
            )
        }

        drawPresenceIndicator(
            member.status,
            in: CGRect(
                x: container.maxX - 10,
                y: container.maxY - 10,
                width: 11,
                height: 11
            ),
            context: context
        )
        context.restoreGState()
    }

    func drawAvatarFallback(
        name: String,
        in rect: CGRect,
        context: CGContext
    ) {
        let accent = NSColor.controlAccentColor
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                accent.blended(withFraction: 0.18, of: .white)?.cgColor
                    ?? accent.cgColor,
                accent.blended(withFraction: 0.16, of: .black)?.cgColor
                    ?? accent.cgColor,
            ] as CFArray,
            locations: [0, 1]
        )
        if let gradient {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        } else {
            context.setFillColor(accent.cgColor)
            context.fill(rect)
        }
        guard let initial = name.first.map({ String($0).uppercased() }) else {
            return
        }
        let line = Self.line(
            initial,
            font: .systemFont(
                ofSize: NativeMemberListMetrics.avatarSize * 0.42,
                weight: .semibold
            ),
            color: .white
        )
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        Self.draw(
            line: line,
            at: CGPoint(
                x: rect.midX - bounds.width / 2 - bounds.minX,
                y: rect.midY - bounds.height / 2 - bounds.minY
            ),
            context: context
        )
    }

    func drawPresenceIndicator(
        _ status: PresenceStatus,
        in rect: CGRect,
        context: CGContext
    ) {
        let color: NSColor = switch status {
        case .online: Self.color(hex: 0x23A55A)
        case .idle: Self.color(hex: 0xF0B232)
        case .dnd: Self.color(hex: 0xF23F43)
        case .invisible, .offline: Self.color(hex: 0x80848E)
        }
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.controlBackgroundColor.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
        if status == .dnd {
            let bar = CGRect(
                x: rect.midX - rect.width * 0.275,
                y: rect.midY - 1,
                width: rect.width * 0.55,
                height: 2
            )
            Self.fillRounded(
                bar,
                radius: 1,
                color: .white,
                context: context
            )
        } else if status == .idle {
            let size = rect.width * 0.62
            context.setFillColor(NSColor.controlBackgroundColor.cgColor)
            context.fillEllipse(in: CGRect(
                x: rect.midX - size / 2 - rect.width * 0.18,
                y: rect.midY - size / 2 - rect.height * 0.18,
                width: size,
                height: size
            ))
        }
    }

    func guildTagPresentation(for identity: PrimaryGuildIdentity) -> GuildTagPresentation? {
        guard let tag = identity.tag else { return nil }
        let image = identity.badgeURL.flatMap { images[$0] }
        let line = Self.line(
            tag,
            font: .systemFont(ofSize: 11, weight: .bold),
            color: .labelColor
        )
        let iconWidth: CGFloat = image == nil ? 0 : 17
        return GuildTagPresentation(
            line: line,
            width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 10 + iconWidth,
            iconWidth: iconWidth,
            image: image
        )
    }

    func drawGuildTag(
        _ presentation: GuildTagPresentation,
        identity: PrimaryGuildIdentity,
        accessoryFrame: CGRect,
        textX: CGFloat,
        nameY: CGFloat,
        itemIndex: Int,
        context: CGContext
    ) {
        let badge = CGRect(
            x: textX + accessoryFrame.minX,
            y: nameY - 1,
            width: accessoryFrame.width,
            height: 17
        )
        Self.fillRounded(
            badge,
            radius: 5,
            color: .black.withAlphaComponent(0.32),
            context: context
        )
        if let image = presentation.image, accessoryFrame.width >= 24 {
            Self.draw(
                image: image,
                in: CGRect(x: badge.minX + 5, y: badge.minY + 1.5, width: 14, height: 14),
                context: context,
                fills: false
            )
        }
        Self.draw(
            line: presentation.line,
            at: CGPoint(x: badge.minX + 5 + presentation.iconWidth, y: badge.minY + 2),
            context: context
        )
        if let badgeURL = identity.badgeURL {
            requestImageIfNeeded(
                url: badgeURL,
                index: itemIndex,
                priority: .visible,
                maximumPixelDimension: 32
            )
        }
    }

    func drawBotBadge(at badgeX: CGFloat, nameY: CGFloat, context: CGContext) {
        let badge = CGRect(x: badgeX, y: nameY - 1, width: 30, height: 17)
        Self.fillRounded(badge, radius: 4, color: .systemIndigo, context: context)
        let line = Self.line(
            "APP",
            font: .systemFont(ofSize: 10, weight: .bold),
            color: .white
        )
        Self.draw(line: line, at: CGPoint(x: badge.minX + 5, y: badge.minY + 2), context: context)
    }

    func itemRange(intersecting rect: CGRect) -> Range<Int> {
        guard !items.isEmpty else { return 0 ..< 0 }
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if origins[mid] + items[mid].height > rect.minY {
                high = mid
            } else {
                low = mid + 1
            }
        }
        let first = low
        var last = first
        while last < items.count, origins[last] < rect.maxY { last += 1 }
        return min(first, items.count) ..< min(last, items.count)
    }

    func index(at point: CGPoint) -> Int? {
        guard point.y >= NativeMemberListMetrics.verticalInset else { return nil }
        var low = 0
        var high = origins.count
        while low < high {
            let mid = (low + high) / 2
            if origins[mid] <= point.y { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard items.indices.contains(index), itemRect(at: index).contains(point) else { return nil }
        return index
    }

    func itemRect(at index: Int) -> CGRect {
        CGRect(x: 0, y: origins[index], width: bounds.width, height: items[index].height)
    }

    func paintedRowRect(at index: Int) -> CGRect {
        CGRect(
            x: NativeMemberListMetrics.horizontalInset,
            y: origins[index] + 1,
            width: max(0, bounds.width - NativeMemberListMetrics.horizontalInset * 2),
            height: NativeMemberListMetrics.paintedRowHeight
        )
    }

    func gatewayRange(intersecting visibleRect: CGRect) -> ClosedRange<Int>? {
        let indexes = itemRange(intersecting: visibleRect)
        let values = indexes.compactMap { items[$0].gatewayIndex }
        guard let first = values.min(), let last = values.max() else { return nil }
        return first ... last
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isScrolling, !interactionsBlocked else { return }
        let newIndex = index(at: convert(event.locationInWindow, from: nil))
        guard newIndex != hoveredIndex else { return }
        let old = hoveredIndex
        hoveredIndex = newIndex
        if let old { setNeedsDisplay(itemRect(at: old)) }
        if let newIndex { setNeedsDisplay(itemRect(at: newIndex)) }
        updateVisibleOverlaysAndPrewarming()
    }

    override func mouseExited(with event: NSEvent) {
        guard let old = hoveredIndex else { return }
        hoveredIndex = nil
        setNeedsDisplay(itemRect(at: old))
        updateVisibleOverlaysAndPrewarming()
    }

    override func mouseDown(with event: NSEvent) {
        guard !interactionsBlocked,
              let index = index(at: convert(event.locationInWindow, from: nil)),
              case .member(let member, _) = items[index]
        else { return }
        selectMember(member)
    }

    func setScrolling(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        if scrolling {
            hoveredIndex = nil
            removeRowOverlay()
        } else if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hoveredIndex = index(at: point)
        }
        updateVisibleOverlaysAndPrewarming()
    }

    @discardableResult
    func updateVisibleOverlaysAndPrewarming(
        force: Bool = false,
        reconcileInteraction: Bool = true
    ) -> Bool {
        guard let scrollView = enclosingScrollView else { return false }
        let visible = itemRange(intersecting: scrollView.documentVisibleRect)
        let viewportChanged = visible != reconciledVisibleRange
            || bounds.width != reconciledViewportWidth
        if reconcileInteraction || viewportChanged || force {
            installRowOverlayIfNeeded()
        }
        guard force || viewportChanged else { return false }
        reconciledVisibleRange = visible
        reconciledViewportWidth = bounds.width
        let prewarmLower = max(0, visible.lowerBound - NativeMemberListMetrics.prewarmItemCount)
        let prewarmUpper = min(items.count, visible.upperBound + NativeMemberListMetrics.prewarmItemCount)
        let prewarmRange = prewarmLower ..< prewarmUpper
        prepareRows(in: prewarmRange)
        installPlaceholderOverlays(in: visible)
        installAvatarOverlays(in: visible)
        installActivityEmojiOverlays(in: visible)
        installAccessibilityRows(in: visible)
        prewarmImages(in: prewarmRange, visible: visible)
        return true
    }

    func installPlaceholderOverlays(in range: Range<Int>) {
        var visibleIDs: Set<ItemID> = []
        for index in range {
            let rootView: AnyView
            let frame: CGRect
            switch items[index] {
            case .header(let section) where section.isLoadingSkeleton:
                rootView = AnyView(
                    SkeletonShimmerTimeline {
                        MemberListSkeletonHeader()
                    }
                )
                frame = itemRect(at: index)
            case .placeholder:
                rootView = AnyView(
                    SkeletonShimmerTimeline {
                        MemberListSkeletonRow()
                    }
                )
                frame = paintedRowRect(at: index)
            default:
                continue
            }

            let id = items[index].id
            visibleIDs.insert(id)
            let host = placeholderOverlays[id] ?? {
                let value = NSHostingView(rootView: rootView)
                value.sizingOptions = []
                value.wantsLayer = true
                addSubview(value)
                placeholderOverlays[id] = value
                return value
            }()
            host.frame = frame
            host.layer?.zPosition = 11
            host.setAccessibilityHidden(true)
        }
        for (id, host) in placeholderOverlays where !visibleIDs.contains(id) {
            host.removeFromSuperview()
            placeholderOverlays[id] = nil
        }
    }

    func installAvatarOverlays(in range: Range<Int>) {
        let visibleMembers: [AvatarOverlayPresentation] = range
            .compactMap { index in
                guard case .member(let member, _) = items[index] else {
                    return nil
                }
                return AvatarOverlayPresentation(
                    id: items[index].id,
                    member: member,
                    index: index
                )
            }
        let visibleIDs = Set(visibleMembers.map(\.id))
        var reusableHosts: [NSHostingView<AnyView>] = []
        for id in Array(avatarOverlays.keys) where !visibleIDs.contains(id) {
            guard let host = avatarOverlays.removeValue(forKey: id) else {
                continue
            }
            avatarOverlayMembers[id] = nil
            reusableHosts.append(host)
        }

        for presentation in visibleMembers {
            let id = presentation.id
            let member = presentation.member
            let index = presentation.index
            let host = avatarOverlays[id] ?? {
                let value = reusableHosts.popLast()
                    ?? NSHostingView(rootView: AnyView(EmptyView()))
                value.sizingOptions = []
                value.wantsLayer = true
                if value.superview == nil {
                    addSubview(value)
                }
                avatarOverlays[id] = value
                return value
            }()
            if avatarOverlayMembers[id] != member {
                host.rootView = AnyView(
                    MemberAvatar(member: member)
                        .opacity(member.isOnline ? 1 : 0.55)
                        .allowsHitTesting(false)
                )
                avatarOverlayMembers[id] = member
            }
            host.frame = CGRect(
                x: NativeMemberListMetrics.horizontalInset + 4,
                y: origins[index] + 1
                    + (NativeMemberListMetrics.paintedRowHeight
                        - NativeMemberListMetrics.avatarContainerSize) / 2,
                width: NativeMemberListMetrics.avatarContainerSize,
                height: NativeMemberListMetrics.avatarContainerSize
            )
            host.layer?.zPosition = 11
            host.setAccessibilityHidden(true)
        }
        for host in reusableHosts {
            host.removeFromSuperview()
        }
    }

    func removeAvatarOverlays() {
        for host in avatarOverlays.values { host.removeFromSuperview() }
        avatarOverlays.removeAll(keepingCapacity: true)
        avatarOverlayMembers.removeAll(keepingCapacity: true)
    }

    func installActivityEmojiOverlays(in range: Range<Int>) {
        var visibleOverlays: [ActivityEmojiOverlayPresentation] = []
        var overlayCount = 0
        for index in range {
            guard overlayCount < NativeMemberListMetrics.maximumVisibleAnimatedEmojiCount,
                  case .member(let member, _) = items[index],
                  let prepared = preparedText[items[index].id],
                  let activity = prepared.activity,
                  let truncationToken = prepared.activityTruncationToken
            else { continue }
            let row = paintedRowRect(at: index)
            let textX = row.minX + 4 + NativeMemberListMetrics.avatarContainerSize + 8
            let visibleActivity = Self.truncatedLine(
                activity,
                token: truncationToken,
                maximumWidth: max(0, row.maxX - textX - 4)
            )
            let origin = CGPoint(x: textX, y: row.minY + 24)
            for (ordinal, region) in NativeMemberActivityPresentation.emojiRegions(
                in: visibleActivity,
                origin: origin
            ).enumerated() {
                guard overlayCount < NativeMemberListMetrics.maximumVisibleAnimatedEmojiCount,
                      region.reference.isAnimated,
                      let url = activityEmojiURL(for: region.reference)
                else { continue }
                overlayCount += 1
                let id = ActivityEmojiOverlayID(
                    itemID: items[index].id,
                    ordinal: ordinal
                )
                let configuration = ActivityEmojiOverlayConfiguration(
                    url: url,
                    opacity: member.isOnline ? 1 : 0.55
                )
                visibleOverlays.append(ActivityEmojiOverlayPresentation(
                    id: id,
                    configuration: configuration,
                    frame: region.frame
                ))
            }
        }

        let visibleIDs = Set(visibleOverlays.map(\.id))
        var reusableHosts: [NSHostingView<AnyView>] = []
        for id in Array(activityEmojiOverlays.keys)
            where !visibleIDs.contains(id)
        {
            guard let host = activityEmojiOverlays.removeValue(forKey: id)
            else { continue }
            activityEmojiOverlayConfigurations[id] = nil
            reusableHosts.append(host)
        }

        for presentation in visibleOverlays {
            let id = presentation.id
            let configuration = presentation.configuration
            let host = activityEmojiOverlays[id] ?? {
                let value = reusableHosts.popLast()
                    ?? NSHostingView(rootView: AnyView(EmptyView()))
                value.sizingOptions = []
                value.wantsLayer = true
                if value.superview == nil {
                    addSubview(value)
                }
                activityEmojiOverlays[id] = value
                return value
            }()
            if activityEmojiOverlayConfigurations[id] != configuration {
                host.rootView = AnyView(
                    AnimatedRemoteImage(
                        url: configuration.url,
                        maximumPixelDimension: 64
                    )
                    .opacity(configuration.opacity)
                    .allowsHitTesting(false)
                )
                activityEmojiOverlayConfigurations[id] = configuration
            }
            host.frame = presentation.frame
            host.layer?.zPosition = 11
            host.setAccessibilityHidden(true)
        }
        for host in reusableHosts {
            host.removeFromSuperview()
        }
    }

    func removeActivityEmojiOverlays() {
        for host in activityEmojiOverlays.values { host.removeFromSuperview() }
        activityEmojiOverlays.removeAll(keepingCapacity: true)
        activityEmojiOverlayConfigurations.removeAll(keepingCapacity: true)
    }

    func installAccessibilityRows(in range: Range<Int>) {
        var visibleIDs: Set<ItemID> = []
        for index in range {
            guard case .member(let member, _) = items[index] else { continue }
            let id = items[index].id
            visibleIDs.insert(id)
            let proxy = accessibilityRows[id] ?? {
                let value = NativeMemberAccessibilityProxyView()
                addSubview(value)
                accessibilityRows[id] = value
                return value
            }()
            proxy.member = member
            proxy.activation = { [weak self] member in self?.selectMember(member) }
            proxy.frame = paintedRowRect(at: index)
        }
        for (id, proxy) in accessibilityRows where !visibleIDs.contains(id) {
            proxy.removeFromSuperview()
            accessibilityRows[id] = nil
        }
        setAccessibilityChildren(range.compactMap { index in
            accessibilityRows[items[index].id]
        })
    }

    func installRowOverlayIfNeeded() {
        installProfileAnchorIfNeeded()
        let requestedIndex: Int? = if isScrolling {
            nil
        } else if let hoveredIndex,
                  items.indices.contains(hoveredIndex),
                  case .member = items[hoveredIndex]
        {
            hoveredIndex
        } else if let selectedMemberID {
            itemIndexesByID[.member(selectedMemberID)]
        } else {
            nil
        }
        guard let index = requestedIndex,
              case .member(let member, _) = items[index],
              enclosingScrollView?.documentVisibleRect.intersects(itemRect(at: index)) == true
        else {
            removeRowOverlay()
            return
        }
        let host = rowOverlay ?? {
            let value = NSHostingView(rootView: AnyView(EmptyView()))
            value.sizingOptions = []
            value.wantsLayer = true
            addSubview(value)
            rowOverlay = value
            return value
        }()
        let previousIndex = rowOverlayIndex
        rowOverlayIndex = index
        if let previousIndex, previousIndex != index, items.indices.contains(previousIndex) {
            setNeedsDisplay(itemRect(at: previousIndex))
        }
        setNeedsDisplay(itemRect(at: index))
        let isSelected = selectedMemberID == member.id
        host.rootView = AnyView(MemberRow(
            member: member,
            isSelected: isSelected,
            isProfilePresented: false,
            profilePresentation: nil,
            showsContents: false,
            select: { [weak self] in self?.selectMember(member) },
            dismissProfile: {}
        ))
        host.frame = CGRect(
            x: NativeMemberListMetrics.horizontalInset,
            y: origins[index],
            width: max(0, bounds.width - NativeMemberListMetrics.horizontalInset * 2),
            height: NativeMemberListMetrics.memberRowHeight
        )
        host.layer?.zPosition = 10
        let foreground = rowForegroundOverlay ?? {
            let value = NativeMemberForegroundOverlayView()
            addSubview(value)
            rowForegroundOverlay = value
            return value
        }()
        foreground.canvas = self
        foreground.itemIndex = index
        foreground.frame = host.frame
        foreground.layer?.zPosition = 12
        foreground.needsDisplay = true
    }

    func installProfileAnchorIfNeeded() {
        guard isProfilePresented,
              let presentation = profilePresentation,
              let index = itemIndexesByID[.member(presentation.member.id)],
              enclosingScrollView?.documentVisibleRect.intersects(itemRect(at: index)) == true
        else {
            removeProfileAnchor()
            return
        }
        profileAnchorIndex = index
        profilePopoverCoordinator.update(
            anchor: profilePopoverAnchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .memberProfile,
            onDismiss: { [weak self] in
                self?.dismissProfile(ifCurrent: presentation.requestID)
            },
            presentationIdentity: AnyHashable(presentation.member.id),
            content: AnyView(ProfilePresentationContent(presentation: presentation))
        )
    }

    func removeProfileAnchor(immediately: Bool = false) {
        if immediately {
            profilePopoverCoordinator.close()
        } else {
            profilePopoverCoordinator.scheduleClose()
        }
        profileAnchorIndex = nil
    }

    func dismissProfile(ifCurrent requestID: UUID) {
        guard profilePresentation?.requestID == requestID else { return }
        dismissProfile()
    }

    func removeRowOverlay() {
        let previousIndex = rowOverlayIndex
        rowOverlay?.removeFromSuperview()
        rowOverlay = nil
        rowForegroundOverlay?.removeFromSuperview()
        rowForegroundOverlay = nil
        rowOverlayIndex = nil
        if let previousIndex, items.indices.contains(previousIndex) {
            setNeedsDisplay(itemRect(at: previousIndex))
        }
    }

    func prewarmImages(in range: Range<Int>, visible: Range<Int>) {
        var wanted: Set<URL> = []
        for index in range {
            guard case .member(let member, _) = items[index] else { continue }
            var requests: [(url: URL, maximumPixelDimension: Int)] = []
            if let url = member.guildAvatarURL ?? member.user.avatarURL {
                requests.append((url, 96))
            }
            if let url = member.user.avatarDecorationURL {
                requests.append((url, 96))
            }
            if let url = member.user.nameplate?.staticURL {
                requests.append((url, 512))
            }
            if let url = member.user.primaryGuild?.badgeURL {
                requests.append((url, 32))
            }
            requests.append(contentsOf: NativeMemberActivityPresentation.references(
                in: member.activityText
            ).compactMap(activityEmojiURL).map {
                (url: $0, maximumPixelDimension: 64)
            })
            wanted.formUnion(requests.map(\.url))
            let priority: MediaLoadPriority = visible.contains(index) ? .visible : .prefetch
            for request in requests {
                requestImageIfNeeded(
                    url: request.url,
                    index: index,
                    priority: priority,
                    maximumPixelDimension: request.maximumPixelDimension
                )
            }
        }
        for (url, task) in imageTasks where !wanted.contains(url) {
            task.cancel()
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            imageTaskPixelDimensions[url] = nil
            imageRequestItemIDs[url] = nil
        }
        // The shared loader owns the bounded decoded cache. Retaining every
        // image encountered by a long member-list scroll here would defeat
        // that budget, so the canvas keeps only its visible/prewarmed window.
        for url in images.keys.filter({ !wanted.contains($0) }) {
            images[url] = nil
            imagePixelDimensions[url] = nil
        }
    }

    func requestImageIfNeeded(
        url: URL?,
        index: Int,
        priority: MediaLoadPriority,
        maximumPixelDimension: Int
    ) {
        guard let url,
              items.indices.contains(index),
              imagePixelDimensions[url, default: 0]
                < maximumPixelDimension
        else { return }
        imageRequestItemIDs[url, default: []].insert(items[index].id)
        if let task = imageTasks[url],
           imageTaskPixelDimensions[url, default: 0]
            < maximumPixelDimension
        {
            task.cancel()
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            imageTaskPixelDimensions[url] = nil
        }
        guard imageTasks[url] == nil else {
            guard priority == .visible,
                  imageTaskPriorities[url] == .prefetch
            else { return }
            imageTaskPriorities[url] = .visible
            let pixelDimension = imageTaskPixelDimensions[url]
                ?? maximumPixelDimension
            let imageLoadPromotion = imageLoadPromotion
            Task {
                await imageLoadPromotion(url, pixelDimension)
            }
            return
        }
        imageTaskPriorities[url] = priority
        imageTaskPixelDimensions[url] = maximumPixelDimension
        imageTasks[url] = Task { [weak self] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url,
                maximumPixelDimension: maximumPixelDimension,
                priority: priority
            )
            guard !Task.isCancelled, let self else { return }
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            imageTaskPixelDimensions[url] = nil
            let requestedItemIDs = imageRequestItemIDs.removeValue(forKey: url)
                ?? []
            guard let image else { return }
            images[url] = image
            imagePixelDimensions[url] = maximumPixelDimension
            for itemID in requestedItemIDs {
                guard let requestedIndex = itemIndexesByID[itemID] else { continue }
                setNeedsDisplay(itemRect(at: requestedIndex))
                if rowOverlayIndex == requestedIndex {
                    rowForegroundOverlay?.needsDisplay = true
                }
            }
        }
    }

    func activityEmojiURL(for reference: EmojiReference) -> URL? {
        reference.id.flatMap { customEmojiURLsByID[$0] }
            ?? reference.imageURL(size: 64)
    }

    func tearDown() {
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
        imageTaskPriorities.removeAll()
        imageTaskPixelDimensions.removeAll()
        imageRequestItemIDs.removeAll()
        imagePixelDimensions.removeAll()
        reconciledVisibleRange = nil
        reconciledViewportWidth = nil
        removeRowOverlay()
        removeProfileAnchor(immediately: true)
        for host in placeholderOverlays.values { host.removeFromSuperview() }
        for host in avatarOverlays.values { host.removeFromSuperview() }
        for host in activityEmojiOverlays.values { host.removeFromSuperview() }
        avatarOverlayMembers.removeAll()
        activityEmojiOverlayConfigurations.removeAll()
        for proxy in accessibilityRows.values { proxy.removeFromSuperview() }
        placeholderOverlays.removeAll()
        avatarOverlays.removeAll()
        activityEmojiOverlays.removeAll()
        accessibilityRows.removeAll()
    }

    static func line(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        ))
    }

    static func draw(line: CTLine, at point: CGPoint, context: CGContext) {
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func truncatedLine(
        _ line: CTLine,
        token: CTLine,
        maximumWidth: CGFloat
    ) -> CTLine {
        guard maximumWidth > 0,
              CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maximumWidth,
              let truncated = CTLineCreateTruncatedLine(
                  line,
                  Double(maximumWidth),
                  .end,
                  token
              )
        else { return line }
        return truncated
    }

    static let memberActivityColor = NSColor(
        srgbRed: 122 / 255,
        green: 123 / 255,
        blue: 131 / 255,
        alpha: 1
    )

    static func fillRounded(
        _ rect: CGRect,
        radius: CGFloat = NativeMemberListMetrics.rowCornerRadius,
        color: NSColor,
        context: CGContext
    ) {
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.fillPath()
    }

    static func draw(image: CGImage, in rect: CGRect, context: CGContext, fills: Bool) {
        let imageRatio = CGFloat(image.width) / CGFloat(image.height)
        let rectRatio = rect.width / rect.height
        let destination: CGRect
        if fills {
            if imageRatio > rectRatio {
                let width = rect.height * imageRatio
                destination = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
            } else {
                let height = rect.width / imageRatio
                destination = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
            }
        } else {
            destination = rect
        }
        context.saveGState()
        context.translateBy(x: 0, y: destination.minY * 2 + destination.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: destination)
        context.restoreGState()
    }

    static func draw(image: CGImage, aspectFitIn rect: CGRect, context: CGContext) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        draw(
            image: image,
            in: CGRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            context: context,
            fills: false
        )
    }

    static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

@MainActor
final class NativeMemberForegroundOverlayView: NSView {
    weak var canvas: NativeMemberListCanvasView?
    var itemIndex = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas,
              canvas.items.indices.contains(itemIndex),
              case .member(let member, _) = canvas.items[itemIndex],
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        context.saveGState()
        context.translateBy(x: -frame.minX, y: -frame.minY)
        canvas.drawMemberForeground(member, at: itemIndex, context: context)
        context.restoreGState()
    }
}

@MainActor
final class NativeMemberAccessibilityProxyView: NSButton {
    var member: Member? {
        didSet {
            guard let member else { return }
            setAccessibilityLabel(member.user.displayName)
            setAccessibilityHelp(member.user.username)
            let activity = member.activityText.flatMap {
                $0.isEmpty ? nil : NativeMemberActivityPresentation.accessibilityText($0)
            }
            setAccessibilityValue(activity)
            toolTip = member.user.username
        }
    }
    var activation: ((Member) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.backgroundColor = .clear
        setAccessibilityRole(.button)
        target = self
        action = #selector(activateMember)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func activateMember() {
        guard let member else { return }
        activation?(member)
    }
}
