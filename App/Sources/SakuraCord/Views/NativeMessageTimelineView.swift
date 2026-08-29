import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
private final class NativeTimelineInputShieldScrollView: NSScrollView {
    weak var model: AppModel?
    let inputPerformanceProbe = ScrollInputPerformanceProbe(
        surface: .timeline
    )

    override func scrollWheel(with event: NSEvent) {
        guard model?.mediaViewerPresentation == nil,
              model?.forwardingMessage == nil,
              model?.workspaceNavigationOverlay == nil
        else { return }
        super.scrollWheel(with: event)
    }
}

struct NativeMessageTimelineView: NSViewRepresentable {
    let model: AppModel
    let conversation: NativeTimelineConversation
    let beginning: NativeTimelineBeginning?
    let firstMessageStartsDayOverride: Bool?
    let hasMoreMessages: Bool
    let hasMoreLaterMessages: Bool
    let isLoadingEarlier: Bool
    let isLoadingLater: Bool
    let earlierHistoryLoadFailed: Bool
    let laterHistoryLoadFailed: Bool
    let bottomContentInset: CGFloat
    let unreadMessageID: MessageID?
    let highlightedMessageID: MessageID?
    let selectedMessageID: MessageID?
    let initialScrollTarget: MessageTimelineScrollRequest.Target?
    let scrollRequest: MessageTimelineScrollRequest?
    let editRequest: MessageTimelineEditRequest?
    let runsPerformanceAutoScroll: Bool
    let loadEarlier: () -> Void
    let loadLater: () -> Void
    let openReply: (MessageID) -> Void
    let onScrollActivityChange: (Bool) -> Void
    let onScrollStateChange: (TimelineScrollState) -> Void
    let onInitialPositionEstablished: (TimelineScrollState) -> Void
    let onUserScrollBegan: () -> Void
    let onUserScrollEnded: (TimelineScrollState) -> Void

    init(
        model: AppModel,
        conversation: NativeTimelineConversation,
        beginning: NativeTimelineBeginning?,
        firstMessageStartsDayOverride: Bool?,
        hasMoreMessages: Bool,
        hasMoreLaterMessages: Bool = false,
        isLoadingEarlier: Bool,
        isLoadingLater: Bool = false,
        earlierHistoryLoadFailed: Bool = false,
        laterHistoryLoadFailed: Bool = false,
        bottomContentInset: CGFloat,
        unreadMessageID: MessageID?,
        highlightedMessageID: MessageID?,
        selectedMessageID: MessageID? = nil,
        initialScrollTarget: MessageTimelineScrollRequest.Target? = nil,
        scrollRequest: MessageTimelineScrollRequest?,
        editRequest: MessageTimelineEditRequest? = nil,
        runsPerformanceAutoScroll: Bool,
        loadEarlier: @escaping () -> Void,
        loadLater: @escaping () -> Void = {},
        openReply: @escaping (MessageID) -> Void,
        onScrollActivityChange: @escaping (Bool) -> Void,
        onScrollStateChange: @escaping (TimelineScrollState) -> Void,
        onInitialPositionEstablished:
            @escaping (TimelineScrollState) -> Void = { _ in },
        onUserScrollBegan: @escaping () -> Void,
        onUserScrollEnded: @escaping (TimelineScrollState) -> Void
    ) {
        self.model = model
        self.conversation = conversation
        self.beginning = beginning
        self.firstMessageStartsDayOverride =
            firstMessageStartsDayOverride
        self.hasMoreMessages = hasMoreMessages
        self.hasMoreLaterMessages = hasMoreLaterMessages
        self.isLoadingEarlier = isLoadingEarlier
        self.isLoadingLater = isLoadingLater
        self.earlierHistoryLoadFailed = earlierHistoryLoadFailed
        self.laterHistoryLoadFailed = laterHistoryLoadFailed
        self.bottomContentInset = bottomContentInset
        self.unreadMessageID = unreadMessageID
        self.highlightedMessageID = highlightedMessageID
        self.selectedMessageID = selectedMessageID
        self.initialScrollTarget = initialScrollTarget
        self.scrollRequest = scrollRequest
        self.editRequest = editRequest
        self.runsPerformanceAutoScroll = runsPerformanceAutoScroll
        self.loadEarlier = loadEarlier
        self.loadLater = loadLater
        self.openReply = openReply
        self.onScrollActivityChange = onScrollActivityChange
        self.onScrollStateChange = onScrollStateChange
        self.onInitialPositionEstablished =
            onInitialPositionEstablished
        self.onUserScrollBegan = onUserScrollBegan
        self.onUserScrollEnded = onUserScrollEnded
    }

    var rowsRevision: UInt64 {
        conversation.rowsRevision(in: model)
    }

    var presentationRevision: UInt64 {
        model.timelinePresentationRevision
    }

    var rowsUpdateHint: MessageRowsUpdateHint? {
        conversation.rowsUpdateHint(in: model)
    }

    var rowsUpdateJournal: MessageRowsUpdateJournal {
        conversation.rowsUpdateJournal(in: model)
    }

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
        (scrollView as? NativeTimelineInputShieldScrollView)?
            .inputPerformanceProbe.invalidate()
        coordinator.stopObserving()
        scrollView.documentView = nil
    }

    typealias Coordinator = NativeMessageTimelineCoordinator
}

@MainActor
final class NativeMessageTimelineCoordinator: NSObject {
        struct CachedItemLayout {
            let item: NativeMessageTimelineItem
            let layout: NativeTimelineRowLayout
        }

        struct CachedItemLayoutKey: Hashable {
            let identifier: NativeMessageTimelineItem.Identifier
            let roundedWidth: Int
            let presentationRevision: UInt64
        }

        struct VisibleAnchor {
            let messageID: MessageID
            let offsetFromViewportTop: CGFloat

            var topPinnedForWidthChange: Self {
                Self(
                    messageID: messageID,
                    offsetFromViewportTop:
                        NativeMessageTimelineLayoutPolicy
                        .widthChangeAnchorOffset(
                            from: offsetFromViewportTop
                        )
                )
            }
        }

        /// Start the next bounded history request before a fast gesture can
        /// consume the current headroom and visually pin at the loaded top.
        static let prefetchDistance: CGFloat = 8_000
        static let historyReserveChunk: CGFloat = 65_536
        static let leadingHistoryReserveChunk = historyReserveChunk
        static let maximumCachedItemLayouts = 750
        static let cachedItemLayoutsPerConversation = 256
        static let performanceSignposter = OSSignposter(
            subsystem: "dev.sakuracord.SakuraCord",
            category: "PointsOfInterest"
        )
        static let performanceLogger = Logger(
            subsystem: "dev.sakuracord.SakuraCord",
            category: "TimelinePerformance"
        )
        static let readStateLogger = Logger(
            subsystem: "dev.sakuracord.SakuraCord",
            category: "UnreadState"
        )

        var parent: NativeMessageTimelineView
        var actions: NativeTimelineRowActions
        let storage = NativeTimelineCanvasStorage()
        var items: [NativeMessageTimelineItem] {
            _read { yield storage.items }
            _modify { yield &storage.items }
        }
        var layouts: [NativeTimelineRowLayout] {
            _read { yield storage.layouts }
            _modify { yield &storage.layouts }
        }
        var rowHeights: [CGFloat] {
            _read { yield storage.rowHeights }
            _modify { yield &storage.rowHeights }
        }
        var rowOrigins: [CGFloat] {
            _read { yield storage.rowOrigins }
            _modify { yield &storage.rowOrigins }
        }
        var contentHeight: CGFloat {
            get { storage.contentHeight }
            set { storage.contentHeight = newValue }
        }
        var rowCount = 0
        var appliedSourceRows: [MessageRowPresentation] = []
        var messageIDs: [MessageID] = []
        var firstRowID: MessageID?
        var lastRowID: MessageID?
        var rowsRevision: UInt64 = 0
        var presentationRevision: UInt64 = 0
        var layoutWidth: CGFloat = 0
        var didMutateItems = false
        var dirtyItemIndexes = IndexSet()
        var requiresVisibleRedraw = false
        var requiresAnchorRestore = false
        var requiresFullOriginRebuild = false
        var appendedLayoutCount = 0
        var didPrependItems = false
        var leadingHistoryReserve: CGFloat = 0
        var trailingHistoryReserve: CGFloat = 0
        var followsMaterializedHistoryBoundary = false
        var followsMaterializedLaterHistoryBoundary = false
        var performanceUpdatePath = "none"
        var performanceFallbackReason = "none"
        var lastPerformanceUpdateDuration = 0.0
        var lastLoggedPerformanceFallbackReason: String?
        var recentLayoutCacheHits = 0
        var cachedItemLayouts:
            [CachedItemLayoutKey: CachedItemLayout] = [:]
        var cachedItemLayoutOrder:
            [CachedItemLayoutKey] = []
        var cachedItemLayoutEvictionIndex = 0

        weak var canvas: NativeTimelineCanvasView?
        weak var documentView: NativeTimelineDocumentView?
        weak var scrollView: NSScrollView?
        var observations: [NSObjectProtocol] = []
        var lastScrollRequestID: UUID?
        var lastEditRequestID: UUID?
        var lastReportedState: TimelineScrollState?
        var pendingScrollState: TimelineScrollState?
        var scrollStateCallbackTask: Task<Void, Never>?
        var isEarlierHistoryScrollGestureActive = false
        var hasEarlierHistoryScrollIntent = false
        var hasIssuedEarlierHistoryRequest = false
        var isLaterHistoryScrollGestureActive = false
        var hasLaterHistoryScrollIntent = false
        var hasIssuedLaterHistoryRequest = false
        var lastReportedScrollActivity: Bool?
        var scrollActivityCallbackGeneration: UInt64 = 0
        var initialPositionCallbackGeneration: UInt64 = 0
        var initialPositionConversation:
            NativeTimelineConversation?
        var lastViewportSize = CGSize.zero
        var isApplyingUpdate = false
        var pendingModelRowsUpdateTask: Task<Void, Never>?
        var scrollIdleTask: Task<Void, Never>?
        var lastScrollActivityUptime = 0.0
        var widthRelayoutTask: Task<Void, Never>?
        var pendingLayoutWidth: CGFloat?
        var widthRelayoutGeneration: UInt64 = 0
        var performanceAutoScrollTask: Task<Void, Never>?
        var performanceDisplayLinkTicker:
            NativeTimelineDisplayLinkTicker?
        var performanceBenchmarkFinish:
            ((NativeTimelineBenchmarkFinishOutcome) -> Void)?
        var didStartPerformanceAutoScroll = false
        var isPreparingOrRunningPerformanceBenchmark = false

        init(parent: NativeMessageTimelineView) {
            self.parent = parent
            actions = Self.makeActions(from: parent)
        }
}

extension NativeMessageTimelineCoordinator {
        func makeScrollView() -> NSScrollView {
            let canvas = NativeTimelineCanvasView(frame: .zero)
            canvas.usesViewportSizedBacking = true
            canvas.setAccessibilityElement(true)
            canvas.setAccessibilityRole(.group)
            canvas.onWidthChange = { [weak self] width in
                self?.relayoutForWidthChange(width)
            }
            canvas.onDocumentSizeChange = { [weak self] size in
                self?.updateDocumentSize(size)
            }
            let documentView = NativeTimelineDocumentView(frame: .zero)
            documentView.addSubview(canvas)

            let scrollView = NativeTimelineInputShieldScrollView()
            scrollView.model = parent.model
            scrollView.inputPerformanceProbe.install(on: scrollView)
            scrollView.documentView = documentView
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            // The timeline has no horizontal navigation. AppKit's automatic
            // policy enables sideways rubber-banding whenever a relayout
            // briefly leaves the document wider than the viewport.
            scrollView.horizontalScrollElasticity = .none
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            scrollView.automaticallyAdjustsContentInsets = false
            // The shared canvas owns the footer spacer. Leaving the same
            // value on NSScrollView creates an otherwise invisible scroll
            // range below short conversations.
            scrollView.contentInsets = NSEdgeInsets()

            self.canvas = canvas
            self.documentView = documentView
            self.scrollView = scrollView
            positionViewportCanvas()
            beginObserving(scrollView)
            update(parent: parent, scrollView: scrollView)
            return scrollView
        }

        var timelineUpdateOperation:
            (NativeMessageTimelineView, NSScrollView) -> Void
        {
            { [self] parent, scrollView in
            guard let canvas else { return }
            let conversationChanged =
                parent.conversation != self.parent.conversation
            let presentationChanged =
                parent.presentationRevision != presentationRevision
            // Capture reaction counts before mutating the shared timeline
            // storage. Capturing inside canvas.apply is too late because both
            // objects reference this same storage instance.
            if parent.rowsRevision != rowsRevision
                || conversationChanged
            {
                canvas.captureReactionCountsBeforeStorageMutation()
            }
            let oldItemCount = items.count
            let oldRowCount = rowCount
            let oldContentHeight = contentHeight
            let oldParent = self.parent
            if conversationChanged {
                cacheBoundedCurrentItemLayouts()
            }
            let wasNearBottom = scrollState().isNearBottom
            let bottomInsetChanged =
                abs(
                    oldParent.bottomContentInset
                        - parent.bottomContentInset
                ) >= 0.5
            if conversationChanged {
                widthRelayoutGeneration &+= 1
                widthRelayoutTask?.cancel()
                widthRelayoutTask = nil
                pendingLayoutWidth = nil
                leadingHistoryReserve = 0
                trailingHistoryReserve = 0
                followsMaterializedHistoryBoundary = false
                followsMaterializedLaterHistoryBoundary = false
                isEarlierHistoryScrollGestureActive = false
                hasEarlierHistoryScrollIntent = false
                hasIssuedEarlierHistoryRequest = false
                isLaterHistoryScrollGestureActive = false
                hasLaterHistoryScrollIntent = false
                hasIssuedLaterHistoryRequest = false
                initialPositionConversation = nil
                initialPositionCallbackGeneration &+= 1
                scrollStateCallbackTask?.cancel()
                scrollStateCallbackTask = nil
                pendingScrollState = nil
            }
            self.parent = parent
            if parent.isLoadingEarlier {
                hasIssuedEarlierHistoryRequest = true
            } else if oldParent.isLoadingEarlier {
                // Re-arm only after the previous bounded request has
                // completed. If the user's requested viewport is still in
                // provisional history, the scroll-state report at the end of
                // this update may immediately request the next page.
                hasIssuedEarlierHistoryRequest = false
            }
            if parent.isLoadingLater {
                hasIssuedLaterHistoryRequest = true
            } else if oldParent.isLoadingLater {
                hasIssuedLaterHistoryRequest = false
            }
            let newRows = parent.conversation.rows(in: parent.model)
            let hasUnpublishedRows =
                (parent.rowsUpdateJournal.latestRevision
                    ?? parent.rowsRevision)
                > parent.rowsRevision
            let acceptsNewRows =
                NativeMessageTimelineLayoutPolicy.acceptsRowSnapshot(
                    itemsAreEmpty: items.isEmpty,
                    conversationChanged: conversationChanged,
                    publishedRevision: parent.rowsRevision,
                    appliedRevision: rowsRevision
                )
            actions = Self.makeActions(from: parent)
            self.scrollView = scrollView

            let startUptime = ProcessInfo.processInfo.systemUptime
            let signpost = Self.performanceSignposter.beginInterval(
                "MessageTimelineReload"
            )
            isApplyingUpdate = true
            let measuredWidth = max(
                220,
                scrollView.contentView.bounds.width.rounded()
            )
            if layoutWidth > 0 {
                scheduleRelayoutForWidthChange(measuredWidth)
            }
            let width = pendingLayoutWidth == nil
                ? measuredWidth
                : max(220, layoutWidth)
            let widthChanged = abs(width - layoutWidth) >= 1
            let anchor = visibleAnchor(
                preferringVisibleMessageBeginning:
                    widthChanged
                    && NativeMessageTimelineLayoutPolicy
                    .prefersVisibleMessageBeginning(
                        from: layoutWidth,
                        to: width
                    )
            )
            let restoreAnchor =
                widthChanged ? anchor?.topPinnedForWidthChange : anchor
            didMutateItems = false
            dirtyItemIndexes.removeAll()
            requiresVisibleRedraw =
                widthChanged || presentationChanged || items.isEmpty
            requiresAnchorRestore = widthChanged || presentationChanged
            requiresFullOriginRebuild =
                widthChanged || presentationChanged
            appendedLayoutCount = 0
            didPrependItems = false
            performanceUpdatePath = "none"
            performanceFallbackReason = "none"
            recentLayoutCacheHits = 0
            let reconcileStartUptime = ProcessInfo.processInfo.systemUptime
            AppPerformanceSignposts.measureSync("TimelineReconcile") {
                if conversationChanged {
                    canvas.invalidateConversationTransientCaches()
                } else if presentationChanged {
                    canvas.invalidatePresentationCaches()
                }
                if conversationChanged, presentationChanged {
                    canvas.invalidatePresentationCaches()
                }
                if oldParent.highlightedMessageID
                    != parent.highlightedMessageID
                    || conversationChanged
                    || oldItemCount == 0,
                   let highlightedMessageID = parent.highlightedMessageID
                {
                    canvas.startMessageJumpHighlight(highlightedMessageID)
                }
                if widthChanged || presentationChanged {
                    layoutWidth = width
                    if acceptsNewRows, !hasUnpublishedRows {
                        rebuildAll(
                            from: parent,
                            rows: newRows,
                            width: width,
                            force: true
                        )
                    } else {
                        layouts = items.map { layout(for: $0, width: width) }
                        rowHeights = layouts.map(\.height)
                        didMutateItems = true
                        performanceUpdatePath =
                            presentationChanged
                            ? "presentation-only"
                            : "width-only"
                    }
                } else if hasUnpublishedRows {
                    // Row storage can advance while its observable revision is
                    // being coalesced to one display-frame publication. Never
                    // reconcile that future storage under an older revision:
                    // doing so corrupts the journal's index basis and forces
                    // repeated full rebuilds. Metadata is applied with the next
                    // atomic row/revision snapshot, at most one frame later.
                    performanceUpdatePath = "awaiting-row-publication"
                } else if !applyFastUpdate(
                    from: oldParent,
                    to: parent,
                    rows: newRows,
                    width: width
                ) {
                    if !applyJournalUpdate(
                        from: oldParent,
                        to: parent,
                        rows: newRows,
                        width: width
                    ) {
                        let fallbackItemCount = items.count
                        let fallbackOldRowCount = rowCount
                        let fallbackOldLeadingCount = items.count - rowCount
                        rebuildAll(from: parent, rows: newRows, width: width)
                        if parent.runsPerformanceAutoScroll,
                           lastLoggedPerformanceFallbackReason
                            != performanceFallbackReason
                        {
                            lastLoggedPerformanceFallbackReason =
                                performanceFallbackReason
                            Self.performanceLogger.notice(
                                """
                                SakuraCord timeline fallback: \(self.performanceFallbackReason, privacy: .public); \
                                coordinator \(String(describing: ObjectIdentifier(self)), privacy: .public); \
                                items \(fallbackItemCount); old rows \(fallbackOldRowCount); new rows \(newRows.count); \
                                old revision \(self.rowsRevision); new revision \(parent.rowsRevision); \
                                old leading \(fallbackOldLeadingCount); new leading \(self.makeLeadingItems(from: parent).count)
                                """
                            )
                        }
                    }
                }
            }
            let reconcileEndUptime = ProcessInfo.processInfo.systemUptime
            if acceptsNewRows, !hasUnpublishedRows {
                rowCount = newRows.count
                appliedSourceRows = newRows
                firstRowID = newRows.first?.id
                lastRowID = newRows.last?.id
                rowsRevision = parent.rowsRevision
            }
            presentationRevision = parent.presentationRevision
            let metadataEndUptime = ProcessInfo.processInfo.systemUptime
            if didMutateItems {
                AppPerformanceSignposts.measureSync("TimelineOrigins") {
                    if requiresFullOriginRebuild {
                        rebuildOrigins()
                    } else if appendedLayoutCount > 0 {
                        appendOrigins(count: appendedLayoutCount)
                    }
                }
                let establishesLeadingHistoryBoundary =
                    oldItemCount == 0
                        || conversationChanged
                        || !oldParent.hasMoreMessages
                if didPrependItems, parent.hasMoreMessages {
                    let reserveUpdate =
                        NativeMessageTimelineLayoutPolicy
                        .consumingHistoryReserve(
                            leadingHistoryReserve,
                            materializedHeight:
                                max(0, contentHeight - oldContentHeight),
                            chunk: Self.historyReserveChunk
                        )
                    leadingHistoryReserve = reserveUpdate.reserve
                    if !reserveUpdate.grew {
                        // Consuming reserved coordinates means every
                        // previously visible row keeps the same document Y.
                        // Only the newly materialized rows above the old head
                        // need backing content; a viewport redraw would undo
                        // the benefit and recreate the pagination hitch.
                        requiresVisibleRedraw = false
                        let leadingCount = items.count - rowCount
                        let prependedCount = max(
                            0,
                            rowCount - oldRowCount
                        )
                        dirtyItemIndexes.insert(
                            integersIn:
                                leadingCount
                                    ..< min(
                                        items.count,
                                        leadingCount + prependedCount + 1
                                    )
                        )
                    }
                } else if establishesLeadingHistoryBoundary,
                    parent.hasMoreMessages,
                    leadingHistoryReserve == 0
                {
                    leadingHistoryReserve =
                        Self.historyReserveChunk
                }
                let didAppendItems = appendedLayoutCount > 0
                    && !didPrependItems
                let establishesTrailingHistoryBoundary =
                    oldItemCount == 0
                        || conversationChanged
                        || !oldParent.hasMoreLaterMessages
                if didAppendItems, parent.hasMoreLaterMessages {
                    let reserveUpdate =
                        NativeMessageTimelineLayoutPolicy
                        .consumingHistoryReserve(
                            trailingHistoryReserve,
                            materializedHeight:
                                max(0, contentHeight - oldContentHeight),
                            chunk: Self.historyReserveChunk
                        )
                    trailingHistoryReserve = reserveUpdate.reserve
                    if reserveUpdate.grew {
                        requiresAnchorRestore = true
                    }
                } else if establishesTrailingHistoryBoundary,
                    parent.hasMoreLaterMessages,
                    trailingHistoryReserve == 0
                {
                    trailingHistoryReserve = Self.historyReserveChunk
                }
                let originsEndUptime = ProcessInfo.processInfo.systemUptime
                AppPerformanceSignposts.measureSync("TimelineSnapshot") {
                    applySnapshot(
                        to: canvas,
                        in: scrollView,
                        redrawsMovedShortContentSynchronously:
                            NativeTimelineShortContentRedrawPolicy
                            .redrawsSynchronously(
                                conversationChanged: conversationChanged,
                                appendedAtTail: didAppendItems
                            )
                    )
                }
                let snapshotEndUptime = ProcessInfo.processInfo.systemUptime
                if requiresVisibleRedraw {
                    canvas.invalidateVisibleContent()
                } else {
                    canvas.invalidateRows(dirtyItemIndexes)
                }
                if parent.runsPerformanceAutoScroll {
                    let updateMilliseconds =
                        (snapshotEndUptime - startUptime) * 1_000
                    if updateMilliseconds >= 4 {
                        NSLog(
                            "SakuraCord timeline phases: %@ (%@) reconcile %.2f ms; metadata %.2f ms; origins %.2f ms; snapshot %.2f ms",
                            performanceUpdatePath,
                            performanceFallbackReason,
                            (reconcileEndUptime - reconcileStartUptime) * 1_000,
                            (metadataEndUptime - reconcileEndUptime) * 1_000,
                            (originsEndUptime - metadataEndUptime) * 1_000,
                            (snapshotEndUptime - originsEndUptime) * 1_000
                        )
                    }
                }
            } else {
                canvas.model = parent.model
                canvas.messageInteractionContext =
                    parent.conversation.messageInteractionContext
                canvas.actions = actions
            }
            if canvas.accessibilitySettingsSnapshot
                != parent.model.accessibilitySettings
            {
                canvas.accessibilitySettingsSnapshot =
                    parent.model.accessibilitySettings
                canvas.removeAccessibilityProxies()
                canvas.reconcileAccessibilityProxiesIfActive()
                canvas.reconcileAnimatedMedia(allowsScrolling: true)
            }
            if parent.hasMoreMessages,
               leadingHistoryReserve == 0,
               conversationChanged || !oldParent.hasMoreMessages
            {
                leadingHistoryReserve = Self.historyReserveChunk
            }
            if parent.hasMoreLaterMessages,
               trailingHistoryReserve == 0,
               conversationChanged || !oldParent.hasMoreLaterMessages
            {
                trailingHistoryReserve = Self.historyReserveChunk
            }
            let collapsesLeadingReserve =
                !parent.hasMoreMessages && leadingHistoryReserve > 0
            let collapsesTrailingReserve =
                !parent.hasMoreLaterMessages && trailingHistoryReserve > 0
            let reserveCollapseAnchor: VisibleAnchor? =
                (collapsesLeadingReserve || collapsesTrailingReserve)
                    ? visibleAnchor()
                    : nil
            if !parent.hasMoreMessages {
                followsMaterializedHistoryBoundary = false
                leadingHistoryReserve = 0
            }
            if !parent.hasMoreLaterMessages {
                followsMaterializedLaterHistoryBoundary = false
                trailingHistoryReserve = 0
            }
            updateInsets()
            updateHistorySkeletonPresentation()
            if let reserveCollapseAnchor {
                restore(reserveCollapseAnchor)
            }
            if wasNearBottom,
               bottomInsetChanged || (didMutateItems && !didPrependItems)
            {
                scroll(
                    toDocumentY: .greatestFiniteMagnitude,
                    scrollView: scrollView
                )
            } else if didMutateItems, requiresAnchorRestore, let restoreAnchor {
                restore(restoreAnchor)
            }
            Self.performanceSignposter.endInterval("MessageTimelineReload", signpost)

            if parent.runsPerformanceAutoScroll {
                let milliseconds =
                    (ProcessInfo.processInfo.systemUptime - startUptime) * 1_000
                lastPerformanceUpdateDuration = milliseconds
                if milliseconds >= 4 {
                    NSLog(
                        "SakuraCord timeline reload: %.2f ms (%d -> %d items)",
                        milliseconds,
                        oldItemCount,
                        items.count
                    )
                }
            }
            let establishedInitialPosition =
                applyInitialPositionIfNeeded()
            if recentLayoutCacheHits > 0 {
                Self.performanceSignposter.emitEvent(
                    "ConversationRowLayoutCacheUsed"
                )
            }
            applyScrollRequestIfNeeded()
            applyEditRequestIfNeeded()
            if establishedInitialPosition {
                publishInitialPosition(scrollState())
            }
            reportScrollState(
                force:
                    NativeTimelineAutomaticHistoryPolicy
                    .shouldReevaluateAfterUpdate(
                        wasLoading: oldParent.isLoadingEarlier,
                        isLoading: parent.isLoadingEarlier,
                        previousRowCount: oldRowCount,
                        currentRowCount: rowCount
                    )
                    || NativeTimelineAutomaticHistoryPolicy
                    .shouldReevaluateAfterUpdate(
                        wasLoading: oldParent.isLoadingLater,
                        isLoading: parent.isLoadingLater,
                        previousRowCount: oldRowCount,
                        currentRowCount: rowCount
                    )
            )
            startPerformanceAutoScrollIfNeeded()
            isApplyingUpdate = false
                lastViewportSize = scrollView.contentView.bounds.size
            }
        }

        func update(parent: NativeMessageTimelineView, scrollView: NSScrollView) {
            pendingModelRowsUpdateTask?.cancel()
            pendingModelRowsUpdateTask = nil
            applyUpdate(parent: parent, scrollView: scrollView)
        }

        func applyUpdate(
            parent: NativeMessageTimelineView,
            scrollView: NSScrollView
        ) {
            parent.model.timelineSpoilerRevealStore.revealMode =
                parent.model.chatSettings.spoilerRevealMode
            canvas?.spoilerRevealStore.revealMode =
                parent.model.chatSettings.spoilerRevealMode
            (scrollView as? NativeTimelineInputShieldScrollView)?.model = parent.model
            canvas?.setOverlayInteractionBlocked(
                parent.model.mediaViewerPresentation != nil
                    || parent.model.forwardingMessage != nil
                    || parent.model.workspaceNavigationOverlay != nil,
                mediaViewerHighlightedMessageID:
                    parent.model.mediaViewerPresentation?.messageID
            )
            timelineUpdateOperation(parent, scrollView)
        }

        func scheduleModelRowsUpdate() {
            guard pendingModelRowsUpdateTask == nil else { return }
            pendingModelRowsUpdateTask = Task { @MainActor [weak self] in
                // NotificationCenter delivers model publications inline. A
                // cold timeline can require tens of milliseconds of layout
                // and raster work, so doing that work inside `post` couples
                // network completion to an input-blocking render transaction.
                // Give SwiftUI's observation transaction the first chance to
                // publish an up-to-date parent and coalesce repeated model
                // changes into one timeline reconciliation.
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.pendingModelRowsUpdateTask = nil
                guard !self.isApplyingUpdate,
                      let scrollView = self.scrollView
                else {
                    self.scheduleModelRowsUpdate()
                    return
                }
                self.applyUpdate(
                    parent: self.parent,
                    scrollView: scrollView
                )
            }
        }

        func stopObserving() {
            pendingModelRowsUpdateTask?.cancel()
            pendingModelRowsUpdateTask = nil
            scrollStateCallbackTask?.cancel()
            scrollStateCallbackTask = nil
            pendingScrollState = nil
            isEarlierHistoryScrollGestureActive = false
            hasEarlierHistoryScrollIntent = false
            hasIssuedEarlierHistoryRequest = false
            scrollIdleTask?.cancel()
            scrollIdleTask = nil
            widthRelayoutTask?.cancel()
            widthRelayoutTask = nil
            pendingLayoutWidth = nil
            widthRelayoutGeneration &+= 1
            performanceAutoScrollTask?.cancel()
            performanceAutoScrollTask = nil
            performanceBenchmarkFinish?(.cancelled)
            performanceBenchmarkFinish = nil
            performanceDisplayLinkTicker?.stop()
            performanceDisplayLinkTicker = nil
            publishScrollActivity(false)
            for observation in observations {
                NotificationCenter.default.removeObserver(observation)
            }
            observations.removeAll()
        }

#if DEBUG
        var hasAppliedInitialPositionForTesting: Bool {
            initialPositionConversation == parent.conversation
        }

        var initialPositionConversationForTesting:
            NativeTimelineConversation?
        {
            initialPositionConversation
        }

        var scrollStateForTesting: TimelineScrollState {
            scrollState()
        }

        var contentOriginYForTesting: CGFloat {
            guard let scrollView else { return 0 }
            return contentOriginY(
                viewportHeight: scrollView.contentView.bounds.height
            )
        }

        var contentHeightForTesting: CGFloat {
            contentHeight
        }

        var performanceUpdatePathForTesting: String {
            performanceUpdatePath
        }

        var pendingLayoutWidthForTesting: CGFloat? {
            pendingLayoutWidth
        }

        var widthRelayoutGenerationForTesting: UInt64 {
            widthRelayoutGeneration
        }

        var cachedItemLayoutCountForTesting: Int {
            cachedItemLayouts.count
        }

        func applyPendingWidthRelayoutForTesting() {
            applyPendingWidthRelayout()
        }

        func messageOffsetFromViewportTopForTesting(
            _ messageID: MessageID
        ) -> CGFloat? {
            guard let scrollView,
                  let index = items.firstIndex(where: {
                      $0.messageID == messageID
                  }),
                  rowOrigins.indices.contains(index)
            else {
                return nil
            }
            return contentOriginY(
                viewportHeight: scrollView.contentView.bounds.height
            )
                + rowOrigins[index]
                - scrollView.contentView.bounds.minY
        }

        func messageHeightForTesting(
            _ messageID: MessageID
        ) -> CGFloat? {
            guard let index = items.firstIndex(where: {
                $0.messageID == messageID
            }),
                  layouts.indices.contains(index)
            else {
                return nil
            }
            return layouts[index].height
        }

        func reconcileViewportGeometryForTesting() {
            _ = reconcileViewportGeometryIfNeeded()
        }

        func updateDocumentHeightForTesting(_ height: CGFloat) {
            guard let scrollView else { return }
            updateDocumentSize(
                NSSize(
                    width: scrollView.contentView.bounds.width,
                    height: height
                )
            )
        }
#endif

        static func makeActions(
            from parent: NativeMessageTimelineView
        ) -> NativeTimelineRowActions {
            return NativeTimelineRowActions(
                loadEarlier: parent.loadEarlier,
                openMessage: parent.conversation.activatesMessageOnClick
                    ? { [weak model = parent.model] message in
                        model?.navigateToSearchResult(message)
                    }
                    : nil,
                openReply: parent.openReply,
                reply: parent.conversation.supportsReply
                    ? { [weak model = parent.model] message in
                        model?.reply(to: message)
                    }
                    : nil,
                forward: parent.model.supportedCapabilities.contains(.messageForwarding)
                    ? { [weak model = parent.model] message in
                        model?.presentForwarding(message)
                    }
                    : nil,
                retry: { [weak model = parent.model] message in
                    guard let model else { return }
                    Task { await model.retrySending(message) }
                },
                edit: { [weak model = parent.model] message, content in
                    guard let model else { return }
                    Task { await model.edit(message, content: content) }
                },
                markUnread: { [weak model = parent.model] message in
                    guard let model else { return }
                    model.markMessageAndFollowingUnread(message)
                },
                delete: { [weak model = parent.model] message in
                    guard let model else { return }
                    Task { await model.delete(message) }
                },
                react: { [weak model = parent.model] emoji, message in
                    guard let model else { return }
                    Task { await model.toggleReaction(emoji, on: message) }
                },
                openThread: { [weak model = parent.model] thread in
                    model?.open(thread)
                },
                submitComponent: { [weak model = parent.model] message, customID, kind, values in
                    guard let model else { return }
                    Task {
                        await model.submitComponent(
                            on: message,
                            customID: customID,
                            kind: kind,
                            values: values
                        )
                    }
                },
                discardFailed: { [weak model = parent.model] message in
                    model?.discardFailedOutgoingMessage(message)
                },
                checkForUpdates: {
                    (NSApp.delegate as? AppDelegate)?
                        .updateController.checkForUpdates()
                },
                applyTheme: { [weak model = parent.model] sharedTheme in
                    SakuraCordThemeStore.shared.apply(sharedTheme.theme)
                    guard let model else { return }
                    var appearance = model.appearanceSettings
                    appearance.colorScheme = sharedTheme.appearance
                    model.applyAppearanceSettings(appearance)
                }
            )
        }

        func rebuildAll(
            from parent: NativeMessageTimelineView,
            rows: [MessageRowPresentation],
            width: CGFloat,
            force: Bool = false
        ) {
            let newItems = makeItems(from: parent, rows: rows)
            if force
                || items != newItems
                || layouts.count != newItems.count
                || messageIDs.count != rows.count
            {
                items = newItems
                messageIDs = rows.map(\.id)
                layouts = items.map {
                    layoutUsingRecentConversationCache(
                        for: $0,
                        width: width,
                        presentationRevision: parent.presentationRevision
                    )
                }
                rowHeights = layouts.map(\.height)
                didMutateItems = true
                requiresVisibleRedraw = true
                requiresAnchorRestore = true
                requiresFullOriginRebuild = true
                performanceUpdatePath = "rebuild"
            }
        }

        func cacheBoundedCurrentItemLayouts() {
            guard !items.isEmpty, items.count == layouts.count else { return }
            let count = min(
                Self.cachedItemLayoutsPerConversation,
                items.count
            )
            let centerIndex = canvas.flatMap {
                $0.rowIndex(at: $0.visibleRect.midY)
            } ?? (items.count - 1)
            let lowerBound = min(
                max(0, centerIndex - count / 2),
                items.count - count
            )
            for index in lowerBound ..< lowerBound + count {
                cacheItemLayout(items[index], layout: layouts[index])
            }
        }

        func cacheItemLayout(
            _ item: NativeMessageTimelineItem,
            layout: NativeTimelineRowLayout
        ) {
            let key = CachedItemLayoutKey(
                identifier: item.identifier,
                roundedWidth: Int(layoutWidth.rounded()),
                presentationRevision: presentationRevision
            )
            let inserted = cachedItemLayouts.updateValue(
                CachedItemLayout(item: item, layout: layout),
                forKey: key
            ) == nil
            if inserted {
                cachedItemLayoutOrder.append(key)
            }
            while cachedItemLayouts.count > Self.maximumCachedItemLayouts,
                  cachedItemLayoutEvictionIndex
                    < cachedItemLayoutOrder.count
            {
                let evicted = cachedItemLayoutOrder[
                    cachedItemLayoutEvictionIndex
                ]
                cachedItemLayoutEvictionIndex += 1
                cachedItemLayouts[evicted] = nil
            }
            if cachedItemLayoutEvictionIndex > 1_024,
               cachedItemLayoutEvictionIndex * 2
                > cachedItemLayoutOrder.count
            {
                cachedItemLayoutOrder.removeFirst(
                    cachedItemLayoutEvictionIndex
                )
                cachedItemLayoutEvictionIndex = 0
            }
        }

        func layoutUsingRecentConversationCache(
            for item: NativeMessageTimelineItem,
            width: CGFloat,
            presentationRevision: UInt64
        ) -> NativeTimelineRowLayout {
            let key = CachedItemLayoutKey(
                identifier: item.identifier,
                roundedWidth: Int(width.rounded()),
                presentationRevision: presentationRevision
            )
            if let cached = cachedItemLayouts[key],
               cached.item == item
            {
                recentLayoutCacheHits += 1
                return cached.layout
            }
            return layout(for: item, width: width)
        }

        var fastUpdateOperation:
            (
                NativeMessageTimelineView,
                NativeMessageTimelineView,
                [MessageRowPresentation],
                CGFloat
            ) -> Bool
        {
            { [self] oldParent, newParent, newRows, width in
            guard oldParent.conversation == newParent.conversation else {
                performanceFallbackReason = "conversation-changed"
                return false
            }
            guard !NativeMessageTimelineLayoutPolicy
                .requiresFirstMessageBoundaryRebuild(
                    from: oldParent.firstMessageStartsDayOverride,
                    to: newParent.firstMessageStartsDayOverride
                )
            else {
                performanceFallbackReason = "first-message-boundary"
                return false
            }
            if newParent.rowsRevision > rowsRevision &+ 1 {
                if let coalescedRecords =
                    newParent.rowsUpdateJournal.records(
                        after: rowsRevision,
                        through: newParent.rowsRevision
                    ),
                   coalescedRecords.contains(where: {
                    !$0.changedMessageIDs.isEmpty
                        || !$0.removedMessageIDs.isEmpty
                   })
                {
                    performanceFallbackReason =
                        "coalesced-structural-mutations"
                    return false
                }
            }
            guard !items.isEmpty, items.count >= rowCount else {
                performanceFallbackReason = "empty-or-invalid-count"
                return false
            }
            let oldLeadingCount = items.count - rowCount
            let newLeading = makeLeadingItems(from: newParent)

            if rowsRevision == newParent.rowsRevision {
                performanceUpdatePath = "metadata"
                guard oldLeadingCount == newLeading.count else {
                    performanceFallbackReason = "metadata-leading-count"
                    return false
                }
                for index in newLeading.indices where items[index] != newLeading[index] {
                    replaceItem(at: index, with: newLeading[index], width: width)
                }
                var affectedIDs = Set<MessageID>()
                if oldParent.unreadMessageID != newParent.unreadMessageID {
                    if let id = oldParent.unreadMessageID {
                        affectedIDs.insert(id)
                    }
                    if let id = newParent.unreadMessageID {
                        affectedIDs.insert(id)
                    }
                }
                if oldParent.selectedMessageID != newParent.selectedMessageID {
                    if let id = oldParent.selectedMessageID {
                        affectedIDs.insert(id)
                    }
                    if let id = newParent.selectedMessageID {
                        affectedIDs.insert(id)
                    }
                }
                for id in affectedIDs {
                    guard let index = items.firstIndex(where: {
                        $0.messageID == id
                    }),
                          let row = items[index].messageRow
                    else { continue }
                    let item = messageItem(row, from: newParent)
                    if items[index] != item {
                        replaceItem(at: index, with: item, width: width)
                    }
                }
                return true
            }

            guard oldLeadingCount == newLeading.count else {
                performanceFallbackReason = "leading-count"
                return false
            }
            for index in newLeading.indices where items[index] != newLeading[index] {
                replaceItem(at: index, with: newLeading[index], width: width)
            }

            let delta = newRows.count - rowCount
            if delta == 0 {
                if let records = newParent.rowsUpdateJournal.records(
                    after: rowsRevision,
                    through: newParent.rowsRevision
                ),
                    records.contains(where: {
                        $0.change == nil && !$0.changedMessageIDs.isEmpty
                    })
                {
                    // A member/mention presentation can change while the
                    // immutable message row remains equal. The journal path
                    // knows the exact dependent IDs and deliberately forces
                    // their derived layout and bitmap to refresh.
                    performanceFallbackReason =
                        "journal-presentation-change"
                    return false
                }
                if case let .replace(changedIndexes)? =
                    newParent.rowsUpdateHint?.change,
                   newParent.rowsUpdateHint?.revision == newParent.rowsRevision,
                   newParent.rowsRevision == rowsRevision &+ 1
                {
                    guard changedIndexes.allSatisfy({
                        newRows.indices.contains($0)
                            && items.indices.contains(oldLeadingCount + $0)
                            && items[oldLeadingCount + $0].identifier
                                == messageItem(
                                    newRows[$0],
                                    from: newParent
                                ).identifier
                    }) else {
                        performanceFallbackReason = "invalid-replace-hint"
                        return false
                    }
                    for rowIndex in changedIndexes {
                        replaceItem(
                            at: oldLeadingCount + rowIndex,
                            with: messageItem(
                                newRows[rowIndex],
                                from: newParent
                            ),
                            width: width
                        )
                        messageIDs[rowIndex] = newRows[rowIndex].id
                    }
                    performanceUpdatePath = "replace-bounded"
                    return true
                }
                guard rowCount == newRows.count,
                      newRows.indices.allSatisfy({
                          items[oldLeadingCount + $0].identifier
                              == messageItem(
                                  newRows[$0],
                                  from: newParent
                              ).identifier
                      })
                else {
                    performanceFallbackReason = "same-count-identity-change"
                    return false
                }
                for rowIndex in newRows.indices {
                    replaceItem(
                        at: oldLeadingCount + rowIndex,
                        with: messageItem(newRows[rowIndex], from: newParent),
                        width: width
                    )
                    messageIDs[rowIndex] = newRows[rowIndex].id
                }
                performanceUpdatePath = "replace"
                return true
            }
            if delta < 0 {
                let removals: IndexSet
                let changedIndexes: IndexSet?
                if case let .remove(hintedRemovals, hintedChanges)? =
                    newParent.rowsUpdateHint?.change,
                   newParent.rowsUpdateHint?.revision == newParent.rowsRevision,
                   newParent.rowsRevision == rowsRevision &+ 1
                {
                    removals = hintedRemovals
                    changedIndexes = hintedChanges
                } else {
                    let oldMessageIDs = items
                        .dropFirst(oldLeadingCount)
                        .compactMap(\.messageID)
                    guard oldMessageIDs.count == rowCount else {
                        performanceFallbackReason = "invalid-message-items"
                        return false
                    }
                    let newMessageIDs = newRows.map(\.id)
                    guard let inferredRemovals =
                    NativeMessageTimelineLayoutPolicy.removalIndexes(
                        preserving: newMessageIDs,
                        in: oldMessageIDs
                    ),
                          inferredRemovals.count == -delta
                    else {
                        performanceFallbackReason = "unsupported-removal"
                        return false
                    }
                    removals = inferredRemovals
                    changedIndexes = nil
                }
                guard removals.count == -delta else {
                    performanceFallbackReason = "invalid-removal-hint"
                    return false
                }
                let removalItemIndexes = removals.map {
                    oldLeadingCount + $0
                }
                guard removalItemIndexes.allSatisfy({
                    items.indices.contains($0)
                        && layouts.indices.contains($0)
                }) else {
                    performanceFallbackReason = "invalid-removal-index"
                    return false
                }
                for itemIndex in removalItemIndexes.reversed() {
                    items.remove(at: itemIndex)
                    layouts.remove(at: itemIndex)
                    rowHeights.remove(at: itemIndex)
                }
                for rowIndex in removals.reversed() {
                    messageIDs.remove(at: rowIndex)
                }
                didMutateItems = true
                let removalAffectsVisibleCoordinates =
                    removalItemIndexes.contains {
                        itemAffectsVisibleCoordinates(at: $0)
                    }
                if removalAffectsVisibleCoordinates {
                    requiresVisibleRedraw = true
                    requiresAnchorRestore = true
                }
                requiresFullOriginRebuild = true
                for rowIndex in changedIndexes ?? IndexSet(newRows.indices) {
                    guard newRows.indices.contains(rowIndex) else {
                        performanceFallbackReason = "invalid-removal-change"
                        return false
                    }
                    replaceItem(
                        at: oldLeadingCount + rowIndex,
                        with: messageItem(newRows[rowIndex], from: newParent),
                        width: width
                    )
                }
                performanceUpdatePath =
                    changedIndexes == nil ? "remove" : "remove-bounded"
                return true
            }

            guard rowCount > 0, let firstRowID, let lastRowID else {
                performanceFallbackReason = "missing-old-boundaries"
                return false
            }
            let maximumPrefixCount = min(delta, newRows.count)
            guard let prefixCount = (0 ... maximumPrefixCount).first(where: {
                newRows.indices.contains($0) && newRows[$0].id == firstRowID
            }) else {
                performanceFallbackReason = "missing-old-first"
                return false
            }
            let oldLastIndex = prefixCount + rowCount - 1
            guard newRows.indices.contains(oldLastIndex),
                  newRows[oldLastIndex].id == lastRowID
            else {
                performanceFallbackReason = "old-sequence-changed"
                return false
            }
            let suffixCount = newRows.count - oldLastIndex - 1
            guard prefixCount + suffixCount == delta else {
                performanceFallbackReason = "invalid-two-ended-delta"
                return false
            }

            if prefixCount > 0 {
                didPrependItems = true
                let insertedItems = newRows.prefix(prefixCount).map {
                    messageItem($0, from: newParent)
                }
                let insertedLayouts = insertedItems.map {
                    layout(for: $0, width: width)
                }
                items.insert(contentsOf: insertedItems, at: oldLeadingCount)
                layouts.insert(contentsOf: insertedLayouts, at: oldLeadingCount)
                rowHeights.insert(
                    contentsOf: insertedLayouts.map(\.height),
                    at: oldLeadingCount
                )
                messageIDs.insert(
                    contentsOf: newRows.prefix(prefixCount).map(\.id),
                    at: 0
                )
                didMutateItems = true
                requiresVisibleRedraw = true
                requiresAnchorRestore = true
                requiresFullOriginRebuild = true
                replaceItem(
                    at: oldLeadingCount + prefixCount,
                    with: messageItem(newRows[prefixCount], from: newParent),
                    width: width
                )
            }
            if suffixCount > 0 {
                let firstInsertedIndex = items.count
                let insertedItems = newRows.suffix(suffixCount).map {
                    messageItem($0, from: newParent)
                }
                let insertedLayouts = insertedItems.map {
                    layout(for: $0, width: width)
                }
                items.append(contentsOf: insertedItems)
                layouts.append(contentsOf: insertedLayouts)
                rowHeights.append(contentsOf: insertedLayouts.map(\.height))
                messageIDs.append(
                    contentsOf: newRows.suffix(suffixCount).map(\.id)
                )
                didMutateItems = true
                if prefixCount == 0, !requiresFullOriginRebuild {
                    appendedLayoutCount = suffixCount
                }
                dirtyItemIndexes.insert(
                    integersIn: firstInsertedIndex ..< items.count
                )
            }
            performanceUpdatePath =
                prefixCount > 0 && suffixCount > 0
                ? "prepend+append"
                : prefixCount > 0
                ? "prepend"
                : "append"
                return true
            }
        }

        func applyFastUpdate(
            from oldParent: NativeMessageTimelineView,
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            width: CGFloat
        ) -> Bool {
            fastUpdateOperation(oldParent, newParent, newRows, width)
        }

        var journalUpdateOperation:
            (
                NativeMessageTimelineView,
                NativeMessageTimelineView,
                [MessageRowPresentation],
                CGFloat
            ) -> Bool
        {
            { [self] oldParent, newParent, newRows, width in
            guard oldParent.conversation == newParent.conversation,
                  newParent.rowsRevision > rowsRevision
            else { return false }
            guard !NativeMessageTimelineLayoutPolicy
                .requiresFirstMessageBoundaryRebuild(
                    from: oldParent.firstMessageStartsDayOverride,
                    to: newParent.firstMessageStartsDayOverride
                )
            else {
                performanceFallbackReason = "journal-first-message-boundary"
                return false
            }
            guard let records = newParent.rowsUpdateJournal.records(
                after: rowsRevision,
                through: newParent.rowsRevision
            ) else {
                performanceFallbackReason = "journal-unavailable"
                return false
            }
            let expectedCount = Int(newParent.rowsRevision - rowsRevision)
            guard records.count == expectedCount,
                  records.first?.revision == rowsRevision &+ 1,
                  records.last?.revision == newParent.rowsRevision,
                  !records.contains(where: \.invalidatesAllRows)
            else {
                let hasReload = records.contains(
                    where: \.invalidatesAllRows
                )
                performanceFallbackReason =
                    "journal old=\(rowsRevision) new=\(newParent.rowsRevision) records=\(records.count) expected=\(expectedCount) reload=\(hasReload)"
                return false
            }

            var changedMessageIDs = Set<MessageID>()
            for record in records {
                changedMessageIDs.formUnion(record.changedMessageIDs)
            }
            if oldParent.unreadMessageID != newParent.unreadMessageID {
                if let id = oldParent.unreadMessageID {
                    changedMessageIDs.insert(id)
                }
                if let id = newParent.unreadMessageID {
                    changedMessageIDs.insert(id)
                }
            }
            if oldParent.selectedMessageID
                != newParent.selectedMessageID
            {
                if let id = oldParent.selectedMessageID {
                    changedMessageIDs.insert(id)
                }
                if let id = newParent.selectedMessageID {
                    changedMessageIDs.insert(id)
                }
            }
            let oldLeadingCount = items.count - rowCount
            guard oldLeadingCount >= 0 else { return false }
            let leadingItems = makeLeadingItems(from: newParent)
            guard leadingItems.count == oldLeadingCount else {
                performanceFallbackReason = "journal-leading-count"
                return false
            }
            guard items.count - oldLeadingCount == rowCount else {
                performanceFallbackReason = "journal-invalid-row-count"
                return false
            }
            guard messageIDs.count == rowCount else {
                performanceFallbackReason = "journal-invalid-id-count"
                return false
            }

            var journalInsertedMessageIDs = Set<MessageID>()
            var journalRemovedMessageIDs = Set<MessageID>()
            for record in records {
                switch record.change {
                case let .some(.insert(indexes)):
                    guard indexes.count
                            == record.insertedMessageIDs.count,
                          record.removedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason = "journal-invalid-insert"
                        return false
                    }
                    journalInsertedMessageIDs.formUnion(
                        record.insertedMessageIDs
                    )
                case let .some(.remove(removedIndexes, _)):
                    guard removedIndexes.count
                            == record.removedMessageIDs.count,
                          record.insertedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason = "journal-invalid-remove"
                        return false
                    }
                    journalRemovedMessageIDs.formUnion(
                        record.removedMessageIDs
                    )
                case .some(.replace):
                    guard record.insertedMessageIDs.isEmpty,
                          record.removedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason =
                            "journal-invalid-replace"
                        return false
                    }
                case .none:
                    guard record.insertedMessageIDs.isEmpty,
                          record.removedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason = "journal-missing-change"
                        return false
                    }
                }
            }
            let currentIdentities = items
                .dropFirst(oldLeadingCount)
                .compactMap { $0.messageRow?.identity }
            let finalIdentities = newRows.map(\.identity)
            let currentIdentitySet = Set(currentIdentities)
            let finalIdentitySet = Set(finalIdentities)
            guard currentIdentities.count == messageIDs.count,
                  currentIdentitySet.count == currentIdentities.count,
                  finalIdentitySet.count == finalIdentities.count
            else {
                performanceFallbackReason =
                    "journal-duplicate-message-identity"
                return false
            }
            let finalMessageIDs = newRows.map(\.id)
            let removalRowIndexes = currentIdentities.indices.filter { rowIndex in
                !finalIdentitySet.contains(currentIdentities[rowIndex])
            }
            guard removalRowIndexes.allSatisfy({
                journalRemovedMessageIDs.contains(messageIDs[$0])
            }) else {
                performanceFallbackReason = "journal-remove-identity"
                return false
            }
            let insertionRowIndexes =
                finalIdentities.indices.filter { rowIndex in
                    !currentIdentitySet.contains(finalIdentities[rowIndex])
                }
            guard insertionRowIndexes.allSatisfy({
                journalInsertedMessageIDs.contains(finalMessageIDs[$0])
            }) else {
                performanceFallbackReason = "journal-insert-identity"
                return false
            }
            var appliedIdentities = currentIdentities
            for rowIndex in removalRowIndexes.reversed() {
                appliedIdentities.remove(at: rowIndex)
            }
            for rowIndex in insertionRowIndexes {
                appliedIdentities.insert(
                    finalIdentities[rowIndex],
                    at: rowIndex
                )
            }
            guard appliedIdentities == finalIdentities else {
                performanceFallbackReason =
                    "journal-applied-identity"
                return false
            }

            // All identity/count checks happen above this point. Build the
            // final journal state only after validation so a message inserted
            // and deleted between two SwiftUI updates never leaves a partial
            // mutation behind.
            for index in leadingItems.indices
            where items[index] != leadingItems[index] {
                replaceItem(at: index, with: leadingItems[index], width: width)
            }

            let previousFirstMessageID = messageIDs.first
            for rowIndex in removalRowIndexes.reversed() {
                let itemIndex = oldLeadingCount + rowIndex
                items.remove(at: itemIndex)
                layouts.remove(at: itemIndex)
                rowHeights.remove(at: itemIndex)
            }
            for rowIndex in insertionRowIndexes {
                let item = messageItem(
                    newRows[rowIndex],
                    from: newParent
                )
                let insertedLayout = layout(for: item, width: width)
                let itemIndex = oldLeadingCount + rowIndex
                items.insert(item, at: itemIndex)
                layouts.insert(insertedLayout, at: itemIndex)
                rowHeights.insert(
                    insertedLayout.height,
                    at: itemIndex
                )
            }
            for rowIndex in newRows.indices
            where changedMessageIDs.contains(newRows[rowIndex].id) {
                refreshItemPresentation(
                    at: oldLeadingCount + rowIndex,
                    with: messageItem(
                        newRows[rowIndex],
                        from: newParent
                    ),
                    width: width
                )
            }
            if let firstMessageID = finalMessageIDs.first {
                didPrependItems =
                    previousFirstMessageID != firstMessageID
                    && insertionRowIndexes.contains(0)
            } else {
                didPrependItems = false
            }
            messageIDs = finalMessageIDs
            didMutateItems = true
            requiresVisibleRedraw = true
            requiresAnchorRestore = true
            requiresFullOriginRebuild = true
            performanceUpdatePath = "bounded-journal-merge"
                return true
            }
        }

        func applyJournalUpdate(
            from oldParent: NativeMessageTimelineView,
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            width: CGFloat
        ) -> Bool {
            journalUpdateOperation(oldParent, newParent, newRows, width)
        }
}
