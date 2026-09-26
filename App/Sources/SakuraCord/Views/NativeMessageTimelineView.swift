import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
private final class NativeTimelineInputShieldScrollView: NSScrollView {
    let inputPerformanceProbe = ScrollInputPerformanceProbe(
        surface: .timeline
    )

    override func scrollWheel(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        super.scrollWheel(with: event)
    }
}

struct NativeMessageTimelineView: NSViewRepresentable {
    @Environment(\.openSettings) fileprivate var openSettings
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

        struct TimelineUpdatePreparation {
            let oldParent: NativeMessageTimelineView
            let oldItemCount: Int
            let oldRowCount: Int
            let oldContentHeight: CGFloat
            let conversationChanged: Bool
            let presentationChanged: Bool
            let wasNearBottom: Bool
            let bottomInsetChanged: Bool
            let newRows: [MessageRowPresentation]
            let hasUnpublishedRows: Bool
            let acceptsNewRows: Bool
            let width: CGFloat
            let widthChanged: Bool
            let restoreAnchor: VisibleAnchor?
        }

        struct TimelineReloadMeasurement {
            let startUptime: TimeInterval
            let signpost: OSSignpostIntervalState
        }

        struct JournalMutationIDs {
            let inserted: Set<MessageID>
            let removed: Set<MessageID>
        }

        struct JournalIdentityChanges {
            let removals: [Int]
            let insertions: [Int]
            let finalMessageIDs: [MessageID]
        }

        struct JournalMutationPlan {
            let leadingItems: [NativeMessageTimelineItem]
            let oldLeadingCount: Int
            let changedMessageIDs: Set<MessageID>
            let identityChanges: JournalIdentityChanges
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
        var timestampDay = Calendar.autoupdatingCurrent.startOfDay(for: .now)

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
        var layoutPreparationTask: Task<Void, Never>?
        var layoutPreparation: LayoutPreparation?
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
            canvas.onMediaDimensionsChange = { [weak self] identifiers in
                self?.refreshLinkedImageLayouts(for: identifiers)
            }
            canvas.onDocumentSizeChange = { [weak self] size in
                self?.updateDocumentSize(size)
            }
            let documentView = NativeTimelineDocumentView(frame: .zero)
            documentView.addSubview(canvas)

            let scrollView = NativeTimelineInputShieldScrollView()
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

        func updateTimeline(
            parent: NativeMessageTimelineView,
            scrollView: NSScrollView
        ) {
            guard let canvas else { return }
            let (preparation, measurement) = prepareTimelineUpdate(
                parent: parent,
                scrollView: scrollView,
                canvas: canvas
            )
            let conversationChanged = preparation.conversationChanged
            let newRows = preparation.newRows
            let hasUnpublishedRows = preparation.hasUnpublishedRows
            let acceptsNewRows = preparation.acceptsNewRows
            let reconcileStartUptime = ProcessInfo.processInfo.systemUptime
            AppPerformanceSignposts.measureSync("TimelineReconcile") {
                reconcileTimelineRows(
                    parent: parent,
                    canvas: canvas,
                    preparation: preparation
                )
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
                let didAppendItems = updateTimelineOriginsAndReserves(
                    parent: parent,
                    preparation: preparation
                )
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
                        (snapshotEndUptime - measurement.startUptime) * 1_000
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
            finalizeTimelineViewport(
                parent: parent,
                canvas: canvas,
                scrollView: scrollView,
                preparation: preparation
            )
            Self.performanceSignposter.endInterval(
                "MessageTimelineReload",
                measurement.signpost
            )
            finishTimelineUpdate(
                parent: parent,
                scrollView: scrollView,
                preparation: preparation,
                startUptime: measurement.startUptime
            )
        }

        func prepareTimelineUpdate(
            parent: NativeMessageTimelineView,
            scrollView: NSScrollView,
            canvas: NativeTimelineCanvasView
        ) -> (TimelineUpdatePreparation, TimelineReloadMeasurement) {
            let oldParent = self.parent
            let conversationChanged = parent.conversation != oldParent.conversation
            let currentTimestampDay = Calendar.autoupdatingCurrent.startOfDay(for: .now)
            let timestampDayChanged = currentTimestampDay != timestampDay
            let presentationChanged = parent.presentationRevision != presentationRevision
                || timestampDayChanged
            if parent.rowsRevision != rowsRevision || conversationChanged {
                canvas.captureReactionCountsBeforeStorageMutation()
            }
            let oldItemCount = items.count
            let oldRowCount = rowCount
            let oldContentHeight = contentHeight
            if conversationChanged {
                cacheBoundedCurrentItemLayouts()
                resetConversationUpdateState()
            }
            if timestampDayChanged {
                timestampDay = currentTimestampDay
                cachedItemLayouts.removeAll(keepingCapacity: true)
                cachedItemLayoutOrder.removeAll(keepingCapacity: true)
                cachedItemLayoutEvictionIndex = 0
            }
            let wasNearBottom = scrollState().isNearBottom
            let bottomInsetChanged = abs(
                oldParent.bottomContentInset - parent.bottomContentInset
            ) >= 0.5
            self.parent = parent
            updateHistoryLoadingState(from: oldParent, to: parent)
            let newRows = parent.conversation.rows(in: parent.model)
            let hasUnpublishedRows = (
                parent.rowsUpdateJournal.latestRevision ?? parent.rowsRevision
            ) > parent.rowsRevision
            let acceptsNewRows = NativeMessageTimelineLayoutPolicy.acceptsRowSnapshot(
                itemsAreEmpty: items.isEmpty,
                conversationChanged: conversationChanged,
                publishedRevision: parent.rowsRevision,
                appliedRevision: rowsRevision
            )
            actions = Self.makeActions(from: parent)
            self.scrollView = scrollView
            let measurement = TimelineReloadMeasurement(
                startUptime: ProcessInfo.processInfo.systemUptime,
                signpost: Self.performanceSignposter.beginInterval(
                    "MessageTimelineReload"
                )
            )
            isApplyingUpdate = true
            let measuredWidth = max(220, scrollView.contentView.bounds.width.rounded())
            if layoutWidth > 0 { scheduleRelayoutForWidthChange(measuredWidth) }
            let width = pendingLayoutWidth == nil ? measuredWidth : max(220, layoutWidth)
            let widthChanged = abs(width - layoutWidth) >= 1
            let anchor = visibleAnchor(
                preferringVisibleMessageBeginning: widthChanged
                    && NativeMessageTimelineLayoutPolicy.prefersVisibleMessageBeginning(
                        from: layoutWidth,
                        to: width
                    )
            )
            resetTimelineMutationState(
                widthChanged: widthChanged,
                presentationChanged: presentationChanged
            )
            let preparation = TimelineUpdatePreparation(
                oldParent: oldParent,
                oldItemCount: oldItemCount,
                oldRowCount: oldRowCount,
                oldContentHeight: oldContentHeight,
                conversationChanged: conversationChanged,
                presentationChanged: presentationChanged,
                wasNearBottom: wasNearBottom,
                bottomInsetChanged: bottomInsetChanged,
                newRows: newRows,
                hasUnpublishedRows: hasUnpublishedRows,
                acceptsNewRows: acceptsNewRows,
                width: width,
                widthChanged: widthChanged,
                restoreAnchor: widthChanged ? anchor?.topPinnedForWidthChange : anchor
            )
            return (preparation, measurement)
        }

        func resetConversationUpdateState() {
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

        func updateHistoryLoadingState(
            from oldParent: NativeMessageTimelineView,
            to parent: NativeMessageTimelineView
        ) {
            if parent.isLoadingEarlier {
                hasIssuedEarlierHistoryRequest = true
            } else if oldParent.isLoadingEarlier {
                hasIssuedEarlierHistoryRequest = false
            }
            if parent.isLoadingLater {
                hasIssuedLaterHistoryRequest = true
            } else if oldParent.isLoadingLater {
                hasIssuedLaterHistoryRequest = false
            }
        }

        func resetTimelineMutationState(
            widthChanged: Bool,
            presentationChanged: Bool
        ) {
            didMutateItems = false
            dirtyItemIndexes.removeAll()
            requiresVisibleRedraw = widthChanged || presentationChanged || items.isEmpty
            requiresAnchorRestore = widthChanged || presentationChanged
            requiresFullOriginRebuild = widthChanged || presentationChanged
            appendedLayoutCount = 0
            didPrependItems = false
            performanceUpdatePath = "none"
            performanceFallbackReason = "none"
            recentLayoutCacheHits = 0
        }

        func reconcileTimelineRows(
            parent: NativeMessageTimelineView,
            canvas: NativeTimelineCanvasView,
            preparation: TimelineUpdatePreparation
        ) {
            if preparation.conversationChanged {
                canvas.invalidateConversationTransientCaches()
            } else if preparation.presentationChanged {
                canvas.invalidatePresentationCaches()
            }
            if preparation.conversationChanged, preparation.presentationChanged {
                canvas.invalidatePresentationCaches()
            }
            if preparation.oldParent.highlightedMessageID != parent.highlightedMessageID
                || preparation.conversationChanged
                || preparation.oldItemCount == 0,
               let highlightedMessageID = parent.highlightedMessageID {
                canvas.startMessageJumpHighlight(highlightedMessageID)
            }
            if preparation.widthChanged || preparation.presentationChanged {
                layoutWidth = preparation.width
                if preparation.acceptsNewRows, !preparation.hasUnpublishedRows {
                    rebuildAll(
                        from: parent,
                        rows: preparation.newRows,
                        width: preparation.width,
                        force: true
                    )
                } else {
                    layouts = items.map { layout(for: $0, width: preparation.width) }
                    rowHeights = layouts.map(\.height)
                    didMutateItems = true
                    performanceUpdatePath = preparation.presentationChanged
                        ? "presentation-only" : "width-only"
                }
                return
            }
            if preparation.hasUnpublishedRows {
                performanceUpdatePath = "awaiting-row-publication"
                return
            }
            if parent.conversation != .inbox(.unread), applyFastUpdate(
                from: preparation.oldParent,
                to: parent,
                rows: preparation.newRows,
                width: preparation.width
            ) { return }
            if applyJournalUpdate(
                from: preparation.oldParent,
                to: parent,
                rows: preparation.newRows,
                width: preparation.width
            ) { return }
            let fallbackItemCount = items.count
            let fallbackOldRowCount = rowCount
            let fallbackOldLeadingCount = items.count - rowCount
            rebuildAll(from: parent, rows: preparation.newRows, width: preparation.width)
            logTimelineFallbackIfNeeded(
                parent: parent,
                rows: preparation.newRows,
                itemCount: fallbackItemCount,
                oldRowCount: fallbackOldRowCount,
                oldLeadingCount: fallbackOldLeadingCount
            )
        }

        func logTimelineFallbackIfNeeded(
            parent: NativeMessageTimelineView,
            rows: [MessageRowPresentation],
            itemCount: Int,
            oldRowCount: Int,
            oldLeadingCount: Int
        ) {
            guard parent.runsPerformanceAutoScroll,
                  lastLoggedPerformanceFallbackReason != performanceFallbackReason
            else { return }
            lastLoggedPerformanceFallbackReason = performanceFallbackReason
            Self.performanceLogger.notice(
                """
                SakuraCord timeline fallback: \(self.performanceFallbackReason, privacy: .public); \
                coordinator \(String(describing: ObjectIdentifier(self)), privacy: .public); \
                items \(itemCount); old rows \(oldRowCount); new rows \(rows.count); \
                old revision \(self.rowsRevision); new revision \(parent.rowsRevision); \
                old leading \(oldLeadingCount); new leading \(self.makeLeadingItems(from: parent).count)
                """
            )
        }

        func updateTimelineOriginsAndReserves(
            parent: NativeMessageTimelineView,
            preparation: TimelineUpdatePreparation
        ) -> Bool {
            AppPerformanceSignposts.measureSync("TimelineOrigins") {
                if requiresFullOriginRebuild {
                    rebuildOrigins()
                } else if appendedLayoutCount > 0 {
                    appendOrigins(count: appendedLayoutCount)
                }
            }
            updateLeadingHistoryReserve(parent: parent, preparation: preparation)
            let didAppendItems = appendedLayoutCount > 0 && !didPrependItems
            updateTrailingHistoryReserve(
                parent: parent,
                preparation: preparation,
                didAppendItems: didAppendItems
            )
            return didAppendItems
        }

        func updateLeadingHistoryReserve(
            parent: NativeMessageTimelineView,
            preparation: TimelineUpdatePreparation
        ) {
            let establishesBoundary = preparation.oldItemCount == 0
                || preparation.conversationChanged
                || !preparation.oldParent.hasMoreMessages
            if didPrependItems, parent.hasMoreMessages {
                let update = NativeMessageTimelineLayoutPolicy.consumingHistoryReserve(
                    leadingHistoryReserve,
                    materializedHeight: max(0, contentHeight - preparation.oldContentHeight),
                    chunk: Self.historyReserveChunk
                )
                leadingHistoryReserve = update.reserve
                if !update.grew {
                    requiresVisibleRedraw = false
                    let leadingCount = items.count - rowCount
                    let prependedCount = max(0, rowCount - preparation.oldRowCount)
                    dirtyItemIndexes.insert(
                        integersIn: leadingCount
                            ..< min(items.count, leadingCount + prependedCount + 1)
                    )
                }
            } else if establishesBoundary,
                      parent.hasMoreMessages,
                      leadingHistoryReserve == 0 {
                leadingHistoryReserve = Self.historyReserveChunk
            }
        }

        func updateTrailingHistoryReserve(
            parent: NativeMessageTimelineView,
            preparation: TimelineUpdatePreparation,
            didAppendItems: Bool
        ) {
            if parent.conversation.isInbox {
                trailingHistoryReserve = parent.hasMoreLaterMessages ? 160 : 0
                return
            }
            let establishesBoundary = preparation.oldItemCount == 0
                || preparation.conversationChanged
                || !preparation.oldParent.hasMoreLaterMessages
            if didAppendItems, parent.hasMoreLaterMessages {
                let update = NativeMessageTimelineLayoutPolicy.consumingHistoryReserve(
                    trailingHistoryReserve,
                    materializedHeight: max(0, contentHeight - preparation.oldContentHeight),
                    chunk: Self.historyReserveChunk
                )
                trailingHistoryReserve = update.reserve
                if update.grew { requiresAnchorRestore = true }
            } else if establishesBoundary,
                      parent.hasMoreLaterMessages,
                      trailingHistoryReserve == 0 {
                trailingHistoryReserve = Self.historyReserveChunk
            }
        }

        func finalizeTimelineViewport(
            parent: NativeMessageTimelineView,
            canvas: NativeTimelineCanvasView,
            scrollView: NSScrollView,
            preparation: TimelineUpdatePreparation
        ) {
            if canvas.accessibilitySettingsSnapshot != parent.model.accessibilitySettings {
                canvas.accessibilitySettingsSnapshot = parent.model.accessibilitySettings
                canvas.removeAccessibilityProxies()
                canvas.reconcileAccessibilityProxiesIfActive()
                canvas.reconcileAnimatedMedia(allowsScrolling: true)
            }
            if parent.hasMoreMessages,
               leadingHistoryReserve == 0,
               preparation.conversationChanged || !preparation.oldParent.hasMoreMessages {
                leadingHistoryReserve = Self.historyReserveChunk
            }
            if parent.hasMoreLaterMessages,
               trailingHistoryReserve == 0,
               preparation.conversationChanged || !preparation.oldParent.hasMoreLaterMessages {
                trailingHistoryReserve = parent.conversation.isInbox ? 160 : Self.historyReserveChunk
            }
            let collapsesReserve = (!parent.hasMoreMessages && leadingHistoryReserve > 0)
                || (!parent.hasMoreLaterMessages && trailingHistoryReserve > 0)
            let collapseAnchor = collapsesReserve ? visibleAnchor() : nil
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
            if let collapseAnchor { restore(collapseAnchor) }
            if !parent.conversation.isInbox, preparation.wasNearBottom,
               preparation.bottomInsetChanged || (didMutateItems && !didPrependItems) {
                scroll(toDocumentY: .greatestFiniteMagnitude, scrollView: scrollView)
            } else if didMutateItems,
                      requiresAnchorRestore,
                      let restoreAnchor = preparation.restoreAnchor {
                restore(restoreAnchor)
            }
        }

        func finishTimelineUpdate(
            parent: NativeMessageTimelineView,
            scrollView: NSScrollView,
            preparation: TimelineUpdatePreparation,
            startUptime: TimeInterval
        ) {
            if parent.runsPerformanceAutoScroll {
                let milliseconds = (ProcessInfo.processInfo.systemUptime - startUptime) * 1_000
                lastPerformanceUpdateDuration = milliseconds
                if milliseconds >= 4 {
                    NSLog(
                        "SakuraCord timeline reload: %.2f ms (%d -> %d items)",
                        milliseconds,
                        preparation.oldItemCount,
                        items.count
                    )
                }
            }
            let establishedInitialPosition = applyInitialPositionIfNeeded()
            if recentLayoutCacheHits > 0 {
                Self.performanceSignposter.emitEvent("ConversationRowLayoutCacheUsed")
            }
            applyScrollRequestIfNeeded()
            applyEditRequestIfNeeded()
            if establishedInitialPosition { publishInitialPosition(scrollState()) }
            reportScrollState(force: shouldReevaluateHistory(after: preparation, parent: parent))
            startPerformanceAutoScrollIfNeeded()
            isApplyingUpdate = false
            lastViewportSize = scrollView.contentView.bounds.size
        }

        func shouldReevaluateHistory(
            after preparation: TimelineUpdatePreparation,
            parent: NativeMessageTimelineView
        ) -> Bool {
            NativeTimelineAutomaticHistoryPolicy.shouldReevaluateAfterUpdate(
                wasLoading: preparation.oldParent.isLoadingEarlier,
                isLoading: parent.isLoadingEarlier,
                previousRowCount: preparation.oldRowCount,
                currentRowCount: rowCount
            ) || NativeTimelineAutomaticHistoryPolicy.shouldReevaluateAfterUpdate(
                wasLoading: preparation.oldParent.isLoadingLater,
                isLoading: parent.isLoadingLater,
                previousRowCount: preparation.oldRowCount,
                currentRowCount: rowCount
            )
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
            canvas?.setOverlayInteractionBlocked(
                !WindowModalCoordinator.allowsInput(for: scrollView),
                mediaViewerHighlightedMessageID:
                    parent.model.mediaViewerPresentation?.messageID
            )
            guard !prepareLayoutsIfNeeded(parent: parent, scrollView: scrollView) else {
                return
            }
            updateTimeline(parent: parent, scrollView: scrollView)
            layoutPreparation = nil
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
            cancelLayoutPreparation()
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
                        guard let model else { return }
                        switch parent.conversation {
                        case .search:
                            model.navigateToSearchResult(message)
                        case .pins:
                            model.dismissPinnedMessages()
                            model.navigateToPinnedResult(message)
                        case .inbox:
                            model.navigateToInboxResult(message)
                        case .channel, .thread, .resource:
                            break
                        }
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
                togglePin: { [weak model = parent.model] message in
                    model?.togglePinnedState(for: message)
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
                openSettings: { destination in
                    SettingsNavigationRouter.shared.open(
                        page: destination.page,
                        section: destination.section,
                        controlID: destination.controlID
                    )
                    parent.openSettings()
                },
                applyTheme: { [weak model = parent.model] sharedTheme in
                    SakuraCordThemeStore.shared.apply(sharedTheme.theme)
                    guard let model else { return }
                    var appearance = model.appearanceSettings
                    appearance.colorScheme = sharedTheme.appearance
                    appearance.windowOpacity = sharedTheme.windowOpacity
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
            if let cached = cachedItemLayout(
                for: item, width: width, presentationRevision: presentationRevision
            ) {
                recentLayoutCacheHits += 1
                return cached
            }
            return layout(for: item, width: width)
        }

        func cachedItemLayout(
            for item: NativeMessageTimelineItem,
            width: CGFloat,
            presentationRevision: UInt64
        ) -> NativeTimelineRowLayout? {
            let key = CachedItemLayoutKey(
                identifier: item.identifier,
                roundedWidth: Int(width.rounded()),
                presentationRevision: presentationRevision
            )
            guard let cached = cachedItemLayouts[key],
                  cached.item == item,
                  cached.layout.fontRevision == ProfileNameFontCache.revision
            else { return nil }
            return cached.layout
        }

        func applyFastUpdate(
            from oldParent: NativeMessageTimelineView,
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            width: CGFloat
        ) -> Bool {
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
                return applyMetadataUpdate(
                    from: oldParent,
                    to: newParent,
                    leadingItems: newLeading,
                    oldLeadingCount: oldLeadingCount,
                    width: width
                )
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
                return applySameCountUpdate(
                    to: newParent,
                    rows: newRows,
                    oldLeadingCount: oldLeadingCount,
                    width: width
                )
            }
            if delta < 0 {
                return applyRemovalUpdate(
                    to: newParent,
                    rows: newRows,
                    oldLeadingCount: oldLeadingCount,
                    delta: delta,
                    width: width
                )
            }

            return applyInsertionUpdate(
                to: newParent,
                rows: newRows,
                oldLeadingCount: oldLeadingCount,
                delta: delta,
                width: width
            )
        }

        func applyMetadataUpdate(
            from oldParent: NativeMessageTimelineView,
            to newParent: NativeMessageTimelineView,
            leadingItems: [NativeMessageTimelineItem],
            oldLeadingCount: Int,
            width: CGFloat
        ) -> Bool {
            performanceUpdatePath = "metadata"
            guard oldLeadingCount == leadingItems.count else {
                performanceFallbackReason = "metadata-leading-count"
                return false
            }
            for index in leadingItems.indices where items[index] != leadingItems[index] {
                replaceItem(at: index, with: leadingItems[index], width: width)
            }
            var affectedIDs = Set<MessageID>()
            if oldParent.unreadMessageID != newParent.unreadMessageID {
                affectedIDs.formUnion([oldParent.unreadMessageID, newParent.unreadMessageID].compactMap { $0 })
            }
            if oldParent.selectedMessageID != newParent.selectedMessageID {
                affectedIDs.formUnion([oldParent.selectedMessageID, newParent.selectedMessageID].compactMap { $0 })
            }
            for id in affectedIDs {
                guard let index = items.firstIndex(where: { $0.messageID == id }),
                      let row = items[index].messageRow
                else { continue }
                let item = messageItem(row, from: newParent)
                if items[index] != item {
                    replaceItem(at: index, with: item, width: width)
                }
            }
            return true
        }

        func applySameCountUpdate(
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            oldLeadingCount: Int,
            width: CGFloat
        ) -> Bool {
            if let records = newParent.rowsUpdateJournal.records(
                after: rowsRevision,
                through: newParent.rowsRevision
            ), records.contains(where: { $0.change == nil && !$0.changedMessageIDs.isEmpty }) {
                performanceFallbackReason = "journal-presentation-change"
                return false
            }
            if case let .replace(changedIndexes)? = newParent.rowsUpdateHint?.change,
               newParent.rowsUpdateHint?.revision == newParent.rowsRevision,
               newParent.rowsRevision == rowsRevision &+ 1 {
                guard changedIndexes.allSatisfy({
                    newRows.indices.contains($0)
                        && items.indices.contains(oldLeadingCount + $0)
                        && items[oldLeadingCount + $0].identifier
                            == messageItem(newRows[$0], from: newParent).identifier
                }) else {
                    performanceFallbackReason = "invalid-replace-hint"
                    return false
                }
                for rowIndex in changedIndexes {
                    replaceItem(
                        at: oldLeadingCount + rowIndex,
                        with: messageItem(newRows[rowIndex], from: newParent),
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
                          == messageItem(newRows[$0], from: newParent).identifier
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

        func applyRemovalUpdate(
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            oldLeadingCount: Int,
            delta: Int,
            width: CGFloat
        ) -> Bool {
            guard let plan = removalUpdatePlan(
                for: newParent,
                rows: newRows,
                delta: delta
            ) else { return false }
            let itemIndexes = plan.removals.map { oldLeadingCount + $0 }
            guard itemIndexes.allSatisfy({
                items.indices.contains($0) && layouts.indices.contains($0)
            }) else {
                performanceFallbackReason = "invalid-removal-index"
                return false
            }
            for index in itemIndexes.reversed() {
                items.remove(at: index)
                layouts.remove(at: index)
                rowHeights.remove(at: index)
            }
            for index in plan.removals.reversed() { messageIDs.remove(at: index) }
            didMutateItems = true
            if itemIndexes.contains(where: { itemAffectsVisibleCoordinates(at: $0) }) {
                requiresVisibleRedraw = true
                requiresAnchorRestore = true
            }
            requiresFullOriginRebuild = true
            for rowIndex in plan.changedIndexes ?? IndexSet(newRows.indices) {
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
            performanceUpdatePath = plan.changedIndexes == nil ? "remove" : "remove-bounded"
            return true
        }

        func removalUpdatePlan(
            for newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            delta: Int
        ) -> (removals: IndexSet, changedIndexes: IndexSet?)? {
            let removals: IndexSet
            let changedIndexes: IndexSet?
            if case let .remove(hintedRemovals, hintedChanges)? = newParent.rowsUpdateHint?.change,
               newParent.rowsUpdateHint?.revision == newParent.rowsRevision,
               newParent.rowsRevision == rowsRevision &+ 1 {
                removals = hintedRemovals
                changedIndexes = hintedChanges
            } else {
                let oldMessageIDs = items.dropFirst(items.count - rowCount).compactMap(\.messageID)
                guard oldMessageIDs.count == rowCount else {
                    performanceFallbackReason = "invalid-message-items"
                    return nil
                }
                guard let inferred = NativeMessageTimelineLayoutPolicy.removalIndexes(
                    preserving: newRows.map(\.id),
                    in: oldMessageIDs
                ), inferred.count == -delta else {
                    performanceFallbackReason = "unsupported-removal"
                    return nil
                }
                removals = inferred
                changedIndexes = nil
            }
            guard removals.count == -delta else {
                performanceFallbackReason = "invalid-removal-hint"
                return nil
            }
            return (removals, changedIndexes)
        }

        func applyInsertionUpdate(
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            oldLeadingCount: Int,
            delta: Int,
            width: CGFloat
        ) -> Bool {
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
            guard newRows.indices.contains(oldLastIndex), newRows[oldLastIndex].id == lastRowID else {
                performanceFallbackReason = "old-sequence-changed"
                return false
            }
            let suffixCount = newRows.count - oldLastIndex - 1
            guard prefixCount + suffixCount == delta else {
                performanceFallbackReason = "invalid-two-ended-delta"
                return false
            }
            if prefixCount > 0 {
                prependRows(
                    newRows.prefix(prefixCount),
                    boundaryRow: newRows[prefixCount],
                    to: newParent,
                    oldLeadingCount: oldLeadingCount,
                    width: width
                )
            }
            if suffixCount > 0 {
                guard appendRows(
                    newRows.suffix(suffixCount),
                    boundaryRow: newRows[oldLastIndex],
                    to: newParent,
                    boundaryItemIndex: oldLeadingCount + oldLastIndex,
                    prefixCount: prefixCount,
                    width: width
                ) else { return false }
            }
            performanceUpdatePath = prefixCount > 0 && suffixCount > 0
                ? "prepend+append" : prefixCount > 0 ? "prepend" : "append"
            return true
        }

        func prependRows(
            _ rows: ArraySlice<MessageRowPresentation>,
            boundaryRow: MessageRowPresentation,
            to parent: NativeMessageTimelineView,
            oldLeadingCount: Int,
            width: CGFloat
        ) {
            didPrependItems = true
            let insertedItems = rows.map { messageItem($0, from: parent) }
            let insertedLayouts = insertedItems.map {
                layoutUsingRecentConversationCache(
                    for: $0, width: width,
                    presentationRevision: parent.presentationRevision
                )
            }
            items.insert(contentsOf: insertedItems, at: oldLeadingCount)
            layouts.insert(contentsOf: insertedLayouts, at: oldLeadingCount)
            rowHeights.insert(contentsOf: insertedLayouts.map(\.height), at: oldLeadingCount)
            messageIDs.insert(contentsOf: rows.map(\.id), at: 0)
            didMutateItems = true
            requiresVisibleRedraw = true
            requiresAnchorRestore = true
            requiresFullOriginRebuild = true
            replaceItem(
                at: oldLeadingCount + rows.count,
                with: messageItem(boundaryRow, from: parent),
                width: width
            )
        }

        func appendRows(
            _ rows: ArraySlice<MessageRowPresentation>,
            boundaryRow: MessageRowPresentation,
            to parent: NativeMessageTimelineView,
            boundaryItemIndex: Int,
            prefixCount: Int,
            width: CGFloat
        ) -> Bool {
            guard items.indices.contains(boundaryItemIndex) else {
                performanceFallbackReason = "invalid-append-boundary"
                return false
            }
            replaceItem(
                at: boundaryItemIndex,
                with: messageItem(boundaryRow, from: parent),
                width: width
            )
            let firstInsertedIndex = items.count
            let insertedItems = rows.map { messageItem($0, from: parent) }
            let insertedLayouts = insertedItems.map { layout(for: $0, width: width) }
            items.append(contentsOf: insertedItems)
            layouts.append(contentsOf: insertedLayouts)
            rowHeights.append(contentsOf: insertedLayouts.map(\.height))
            messageIDs.append(contentsOf: rows.map(\.id))
            didMutateItems = true
            if prefixCount == 0, !requiresFullOriginRebuild { appendedLayoutCount = rows.count }
            dirtyItemIndexes.insert(integersIn: firstInsertedIndex ..< items.count)
            return true
        }

}
