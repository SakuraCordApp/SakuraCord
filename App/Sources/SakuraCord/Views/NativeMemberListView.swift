import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

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
        coordinator.stop()
        scrollView.documentView = nil
    }

    typealias Coordinator = NativeMemberListCoordinator
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
    var didStartPerformanceBenchmark = false
    var performanceInterval: OSSignpostIntervalState?

    init(parent: NativeMemberListView) {
        self.parent = parent
    }

    func makeScrollView() -> NSScrollView {
        let canvas = NativeMemberListCanvasView(frame: .zero)
        canvas.selectMember = { [weak self] member in
            self?.parent.selectMember(member)
        }
        let scrollView = NSScrollView()
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
        canvas.update(
            sections: parent.sections,
            customEmojiURLsByID: parent.customEmojiURLsByID,
            profilePresentation: parent.profilePresentation,
            isProfilePresented: parent.isProfilePresented,
            dismissProfile: parent.dismissProfile
        )
        let width = max(1, scrollView.contentSize.width)
        let height = max(1, canvas.contentHeight)
        if canvas.frame.size != NSSize(width: width, height: height) {
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
            canvas.updateVisibleOverlaysAndPrewarming(force: true)
        }
        reportViewport(debounced: false)
        startPerformanceBenchmarkIfReady()
    }

    func viewportDidScroll() {
        guard let canvas else { return }
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
        scrollIdleTask?.cancel()
        viewportTask?.cancel()
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
        let ticker = NativeTimelineDisplayLinkTicker()
        performanceTicker = ticker
        ticker.start(on: canvas) { [weak self, weak ticker] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - startedAt
            let delta = NativeTimelineBenchmarkScrollPolicy.distance(
                tickInterval: now - previousTick
            )
            previousTick = now
            let previousY = scrollView.contentView.bounds.minY
            let maximumY = max(
                0,
                canvas.contentHeight - scrollView.contentSize.height
            )
            let nextY = min(maximumY, previousY + delta)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            completedDistance += max(0, nextY - previousY)
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
                    elapsed: elapsed
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
final class NativeMemberListCanvasView: NSView {
    enum ItemID: Hashable {
        case header(MemberSection.SectionIdentifier)
        case member(UserID)
        case placeholder(Int)
    }

    enum Item: Equatable {
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

    struct ActivityEmojiOverlayID: Hashable {
        let itemID: ItemID
        let ordinal: Int
    }

    struct ActivityEmojiOverlayConfiguration: Equatable {
        let url: URL
        let opacity: CGFloat
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
    var imageRequestItemIDs: [URL: Set<ItemID>] = [:]
    var images: [URL: CGImage] = [:]
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
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    func update(
        sections: [MemberSection],
        customEmojiURLsByID: [String: URL] = [:],
        profilePresentation: ProfilePresentationState?,
        isProfilePresented: Bool,
        dismissProfile: @escaping () -> Void
    ) {
        let previousItems = items
        let previousSelectedMemberID = selectedMemberID
        let previousCustomEmojiURLsByID = self.customEmojiURLsByID
        self.customEmojiURLsByID = customEmojiURLsByID
        self.profilePresentation = profilePresentation
        self.isProfilePresented = isProfilePresented
        self.dismissProfile = dismissProfile
        selectedMemberID = isProfilePresented
            ? profilePresentation?.member.id
            : nil
        let documentChanged = updateDocumentIfNeeded(
            sections: sections,
            previousItems: previousItems
        )
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
            force: documentChanged || previousCustomEmojiURLsByID != customEmojiURLsByID
        )
    }

    @discardableResult
    func updateDocumentIfNeeded(
        sections: [MemberSection],
        previousItems: [Item]? = nil
    ) -> Bool {
        guard sections != presentedSections else { return false }
        let previousItems = previousItems ?? items
        presentedSections = sections
        items = Self.makeItems(sections: sections)
        itemIndexesByID.removeAll(keepingCapacity: true)
        itemIndexesByID.reserveCapacity(items.count)
        for index in items.indices {
            itemIndexesByID[items[index].id] = index
        }
        if let hoveredIndex,
           !items.indices.contains(hoveredIndex) ||
           !previousItems.indices.contains(hoveredIndex) ||
           items[hoveredIndex].id != previousItems[hoveredIndex].id
        {
            self.hoveredIndex = nil
        }
        rebuildOrigins()
        prepareRows()
        if previousItems.count == items.count {
            for index in items.indices where items[index] != previousItems[index] {
                setNeedsDisplay(itemRect(at: index))
            }
        } else {
            needsDisplay = true
        }
        reconciledVisibleRange = nil
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

    static func makeItems(sections: [MemberSection]) -> [Item] {
        var result: [Item] = []
        result.reserveCapacity(sections.reduce(0) { $0 + $1.totalCount + 1 })
        for section in sections {
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

    func rebuildOrigins() {
        origins.removeAll(keepingCapacity: true)
        origins.reserveCapacity(items.count)
        var cursorY = NativeMemberListMetrics.verticalInset
        for item in items {
            origins.append(cursorY)
            cursorY += item.height
        }
        contentHeight = cursorY + NativeMemberListMetrics.verticalInset
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    func prepareRows() {
        let nameFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .semibold
        )
        let activityFont = NSFont.systemFont(ofSize: 12)
        var prepared: [ItemID: PreparedText] = [:]
        for item in items {
            guard case .member(let member, _) = item else { continue }
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
            prepared[item.id] = PreparedText(
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
        preparedText = prepared
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
            requestImageIfNeeded(url: nameplate.staticURL, index: index, priority: .visible)
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
                    requestImageIfNeeded(url: url, index: index, priority: .visible)
                }
            }
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
            requestImageIfNeeded(url: badgeURL, index: itemIndex, priority: .visible)
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
        guard !isScrolling else { return }
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
        guard let index = index(at: convert(event.locationInWindow, from: nil)),
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
        var visibleIDs: Set<ItemID> = []
        for index in range {
            guard case .member(let member, _) = items[index] else { continue }
            let id = items[index].id
            visibleIDs.insert(id)
            let host = avatarOverlays[id] ?? {
                let value = NSHostingView(rootView: AnyView(EmptyView()))
                value.sizingOptions = []
                value.wantsLayer = true
                addSubview(value)
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
                y: origins[index] + 1 + (NativeMemberListMetrics.paintedRowHeight - NativeMemberListMetrics.avatarContainerSize) / 2,
                width: NativeMemberListMetrics.avatarContainerSize,
                height: NativeMemberListMetrics.avatarContainerSize
            )
            host.layer?.zPosition = 11
            host.setAccessibilityHidden(true)
        }
        for (id, host) in avatarOverlays where !visibleIDs.contains(id) {
            host.removeFromSuperview()
            avatarOverlays[id] = nil
            avatarOverlayMembers[id] = nil
        }
    }

    func installActivityEmojiOverlays(in range: Range<Int>) {
        var visibleIDs: Set<ActivityEmojiOverlayID> = []
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
                visibleIDs.insert(id)
                let host = activityEmojiOverlays[id] ?? {
                    let value = NSHostingView(rootView: AnyView(EmptyView()))
                    value.sizingOptions = []
                    value.wantsLayer = true
                    addSubview(value)
                    activityEmojiOverlays[id] = value
                    return value
                }()
                let configuration = ActivityEmojiOverlayConfiguration(
                    url: url,
                    opacity: member.isOnline ? 1 : 0.55
                )
                if activityEmojiOverlayConfigurations[id] != configuration {
                    host.rootView = AnyView(
                        AnimatedRemoteImage(
                            url: url,
                            maximumPixelDimension: 64
                        )
                        .opacity(configuration.opacity)
                        .allowsHitTesting(false)
                    )
                    activityEmojiOverlayConfigurations[id] = configuration
                }
                host.frame = region.frame
                host.layer?.zPosition = 11
                host.setAccessibilityHidden(true)
            }
        }
        for (id, host) in activityEmojiOverlays where !visibleIDs.contains(id) {
            host.removeFromSuperview()
            activityEmojiOverlays[id] = nil
            activityEmojiOverlayConfigurations[id] = nil
        }
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
            let urls = [
                member.guildAvatarURL ?? member.user.avatarURL,
                member.user.avatarDecorationURL,
                member.user.nameplate?.staticURL,
                member.user.primaryGuild?.badgeURL,
            ].compactMap(\.self) + NativeMemberActivityPresentation.references(
                in: member.activityText
            ).compactMap(activityEmojiURL)
            wanted.formUnion(urls)
            let priority: MediaLoadPriority = visible.contains(index) ? .visible : .prefetch
            for url in urls { requestImageIfNeeded(url: url, index: index, priority: priority) }
        }
        for (url, task) in imageTasks where !wanted.contains(url) {
            task.cancel()
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            imageRequestItemIDs[url] = nil
        }
        // The shared loader owns the bounded decoded cache. Retaining every
        // image encountered by a long member-list scroll here would defeat
        // that budget, so the canvas keeps only its visible/prewarmed window.
        for url in images.keys.filter({ !wanted.contains($0) }) {
            images[url] = nil
        }
    }

    func requestImageIfNeeded(url: URL?, index: Int, priority: MediaLoadPriority) {
        guard let url,
              items.indices.contains(index),
              images[url] == nil
        else { return }
        imageRequestItemIDs[url, default: []].insert(items[index].id)
        guard imageTasks[url] == nil else {
            guard priority == .visible,
                  imageTaskPriorities[url] == .prefetch
            else { return }
            imageTaskPriorities[url] = .visible
            let imageLoadPromotion = imageLoadPromotion
            Task {
                await imageLoadPromotion(url, 512)
            }
            return
        }
        imageTaskPriorities[url] = priority
        imageTasks[url] = Task { [weak self] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url,
                maximumPixelDimension: 512,
                priority: priority
            )
            guard !Task.isCancelled, let self else { return }
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            let requestedItemIDs = imageRequestItemIDs.removeValue(forKey: url)
                ?? []
            guard let image else { return }
            images[url] = image
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
        imageRequestItemIDs.removeAll()
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
