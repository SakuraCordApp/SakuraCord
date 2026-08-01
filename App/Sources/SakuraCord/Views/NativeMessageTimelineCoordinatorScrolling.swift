import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

extension NativeMessageTimelineCoordinator {
        func replaceItem(
            at index: Int,
            with item: NativeMessageTimelineItem,
            width: CGFloat
        ) {
            guard items.indices.contains(index), layouts.indices.contains(index) else {
                return
            }
            guard items[index] != item else { return }
            let previousHeight = layouts[index].height
            let updatedLayout = layout(for: item, width: width)
            items[index] = item
            layouts[index] = updatedLayout
            rowHeights[index] = updatedLayout.height
            didMutateItems = true
            dirtyItemIndexes.insert(index)
            if abs(previousHeight - updatedLayout.height) >= 0.5 {
                requiresFullOriginRebuild = true
                if itemAffectsVisibleCoordinates(at: index) {
                    requiresVisibleRedraw = true
                    requiresAnchorRestore = true
                }
            }
        }

        func itemAffectsVisibleCoordinates(at index: Int) -> Bool {
            guard let scrollView,
                  rowOrigins.indices.contains(index)
            else { return true }
            let viewport = scrollView.contentView.bounds
            let documentOrigin =
                contentOriginY(viewportHeight: viewport.height)
                    + rowOrigins[index]
            return documentOrigin < viewport.maxY
        }

        func layout(
            for item: NativeMessageTimelineItem,
            width: CGFloat
        ) -> NativeTimelineRowLayout {
            NativeTimelineRowLayout.make(
                item: item,
                width: width,
                model: parent.model
            )
        }

        func rebuildOrigins() {
            rowOrigins = Array(repeating: 0, count: rowHeights.count)
            var verticalOffset: CGFloat = 0
            rowHeights.withUnsafeBufferPointer { buffer in
                for index in buffer.indices {
                    rowOrigins[index] = verticalOffset
                    verticalOffset += buffer[index]
                }
            }
            contentHeight = verticalOffset
        }

        func appendOrigins(count: Int) {
            guard count > 0, count <= rowHeights.count else { return }
            rowOrigins.reserveCapacity(rowHeights.count)
            var verticalOffset = contentHeight
            for index in rowHeights.count - count ..< rowHeights.count {
                rowOrigins.append(verticalOffset)
                verticalOffset += rowHeights[index]
            }
            contentHeight = verticalOffset
        }

        func applySnapshot(
            to canvas: NativeTimelineCanvasView,
            in scrollView: NSScrollView
        ) {
            let viewportHeight = max(1, scrollView.contentView.bounds.height)
            updateDocumentSize(
                NSSize(
                    width: layoutWidth,
                    height: effectiveContentHeight
                )
            )
            canvas.apply(
                storage: storage,
                model: parent.model,
                actions: actions,
                viewportWidth: layoutWidth,
                minimumHeight: viewportHeight,
                bottomSpacerHeight: bottomInset,
                contentOriginY: contentOriginY(
                    viewportHeight: viewportHeight
                ),
                historySkeleton:
                    historySkeletonPresentation(
                        viewportHeight: viewportHeight
                    )
            )
        }

        func updateDocumentSize(_ proposedSize: NSSize) {
            guard let documentView, let scrollView else { return }
            let preservesEstablishedPosition =
                !isApplyingUpdate
                && initialPositionConversation == parent.conversation
            let wasNearBottom =
                preservesEstablishedPosition
                && (
                    lastReportedState?.isNearBottom
                        ?? scrollState().isNearBottom
                )
            let anchor =
                preservesEstablishedPosition && !wasNearBottom
                ? visibleAnchor()
                : nil
            if preservesEstablishedPosition {
                isApplyingUpdate = true
            }
            let viewport = scrollView.contentView.bounds
            let size = NSSize(
                width: max(1, max(proposedSize.width, viewport.width)),
                height: max(1, max(proposedSize.height, viewport.height))
            )
            if documentView.frame.size != size {
                documentView.setFrameSize(size)
            }
            let showsVerticalScroller =
                size.height > viewport.height + 0.5
            if scrollView.hasVerticalScroller
                != showsVerticalScroller
            {
                scrollView.hasVerticalScroller =
                    showsVerticalScroller
            }
            positionViewportCanvas()
            guard preservesEstablishedPosition else { return }
            if wasNearBottom {
                scroll(
                    toDocumentY: .greatestFiniteMagnitude,
                    scrollView: scrollView
                )
            } else if let anchor {
                restore(anchor)
            }
            isApplyingUpdate = false
            reportScrollState(force: true)
        }

        func positionViewportCanvas() {
            guard let documentView, let canvas, let scrollView else {
                return
            }
            let viewport = scrollView.contentView.bounds
            let documentSize = documentView.frame.size
            let overscan: CGFloat = 320
            let canvasHeight = min(
                max(1, documentSize.height),
                max(1, viewport.height + overscan * 2)
            )
            let maximumOriginY = max(0, documentSize.height - canvasHeight)
            let originY = min(
                maximumOriginY,
                max(0, viewport.minY - overscan)
            )
            let frame = NSRect(
                x: 0,
                y: originY,
                width: max(1, viewport.width),
                height: canvasHeight
            )
            let bounds = NSRect(
                x: 0,
                y: originY,
                width: frame.width,
                height: frame.height
            )
            canvas.installViewportGeometry(frame: frame, bounds: bounds)
        }

        @discardableResult
        func clampToMaterializedHistoryBoundary() -> Bool {
            guard parent.hasMoreMessages,
                  leadingHistoryReserve > 0,
                  let scrollView
            else {
                followsMaterializedHistoryBoundary = false
                return false
            }
            let clipView = scrollView.contentView
            if !isApplyingUpdate,
               clipView.bounds.minY > leadingHistoryReserve + 1
            {
                followsMaterializedHistoryBoundary = false
            }
            let attemptedProvisionalHistory =
                clipView.bounds.minY < leadingHistoryReserve - 0.5
            if attemptedProvisionalHistory {
                followsMaterializedHistoryBoundary = true
            }
            let minimumY = provisionalHistoryMinimumY(
                viewportHeight: clipView.bounds.height
            )
            guard clipView.bounds.minY < minimumY - 0.5 else {
                return attemptedProvisionalHistory
            }
            clipView.scroll(
                to: NSPoint(
                    x: clipView.bounds.minX,
                    y: minimumY
                )
            )
            scrollView.reflectScrolledClipView(clipView)
            return true
        }

        var allowsProvisionalHistory: Bool {
            parent.isLoadingEarlier
                || followsMaterializedHistoryBoundary
        }

        func provisionalHistoryMinimumY(
            viewportHeight: CGFloat
        ) -> CGFloat {
            NativeMessageTimelineLayoutPolicy
                .provisionalHistoryMinimumY(
                    reserve: leadingHistoryReserve,
                    viewportHeight: viewportHeight,
                    allowsProvisionalHistory:
                        parent.hasMoreMessages
                        && allowsProvisionalHistory
                )
        }

        func historySkeletonPresentation(
            viewportHeight: CGFloat
        ) -> TimelineHistorySkeletonPresentation? {
            guard NativeMessageTimelineLayoutPolicy.showsHistorySkeleton(
                hasMoreMessages: parent.hasMoreMessages,
                isLoadingEarlier: parent.isLoadingEarlier,
                followsMaterializedHistoryBoundary:
                    followsMaterializedHistoryBoundary
            ),
                  leadingHistoryReserve > 0
            else {
                return nil
            }
            let minimumY =
                NativeMessageTimelineLayoutPolicy
                .provisionalHistoryMinimumY(
                    reserve: leadingHistoryReserve,
                    viewportHeight: viewportHeight,
                    allowsProvisionalHistory: true
                )
            let maximumY = contentOriginY(
                viewportHeight: viewportHeight
            )
            guard maximumY > minimumY else { return nil }
            return TimelineHistorySkeletonPresentation(
                frame: CGRect(
                    x: 0,
                    y: minimumY,
                    width: max(1, layoutWidth),
                    height: maximumY - minimumY
                ),
                kind: parent.conversation.loaderKind,
                conversationID: parent.conversation.id
            )
        }

        func updateHistorySkeletonPresentation() {
            guard let canvas, let scrollView else { return }
            canvas.updateHistorySkeleton(
                historySkeletonPresentation(
                    viewportHeight:
                        max(1, scrollView.contentView.bounds.height)
                )
            )
        }

        @discardableResult
        func reconcileViewportGeometryIfNeeded(
            proposedWidth: CGFloat? = nil
        ) -> Bool {
            guard let canvas, let scrollView else { return false }
            let viewportSize = scrollView.contentView.bounds.size
            let width = max(
                220,
                (proposedWidth ?? viewportSize.width).rounded()
            )
            let sizeChanged =
                abs(viewportSize.width - lastViewportSize.width) >= 0.5
                || abs(viewportSize.height - lastViewportSize.height) >= 0.5
            let widthChanged = abs(width - layoutWidth) >= 1
            guard sizeChanged || widthChanged else { return false }
            lastViewportSize = viewportSize
            guard !isApplyingUpdate else { return true }

            let preservesEstablishedPosition =
                initialPositionConversation == parent.conversation
            let wasNearBottom =
                preservesEstablishedPosition
                && (
                    lastReportedState?.isNearBottom
                        ?? scrollState().isNearBottom
                )
            let visiblePosition =
                preservesEstablishedPosition && !wasNearBottom
                ? visibleAnchor(
                    preferringVisibleMessageBeginning:
                        widthChanged
                        && NativeMessageTimelineLayoutPolicy
                        .prefersVisibleMessageBeginning(
                            from: layoutWidth,
                            to: width
                        )
                )
                : nil
            let anchor =
                widthChanged
                ? visiblePosition?.topPinnedForWidthChange
                : visiblePosition

            isApplyingUpdate = true
            if widthChanged {
                layoutWidth = width
                layouts = items.map { layout(for: $0, width: width) }
                rowHeights = layouts.map(\.height)
                rebuildOrigins()
                applySnapshot(to: canvas, in: scrollView)
                canvas.invalidateVisibleContent()
            }
            updateInsets()
            updateHistorySkeletonPresentation()
            if wasNearBottom {
                scroll(
                    toDocumentY: .greatestFiniteMagnitude,
                    scrollView: scrollView
                )
            } else if let anchor {
                restore(anchor)
            }
            positionViewportCanvas()
            let establishedInitialPosition =
                applyInitialPositionIfNeeded()
            applyScrollRequestIfNeeded()
            applyEditRequestIfNeeded()
            if establishedInitialPosition {
                publishInitialPosition(scrollState())
            }
            isApplyingUpdate = false
            reportScrollState(force: true)
            return true
        }

        func relayoutForWidthChange(_ proposedWidth: CGFloat) {
            _ = reconcileViewportGeometryIfNeeded(
                proposedWidth: proposedWidth
            )
        }

        func makeItems(
            from parent: NativeMessageTimelineView,
            rows: [MessageRowPresentation]
        ) -> [NativeMessageTimelineItem] {
            var result = makeLeadingItems(from: parent)
            result.reserveCapacity(rows.count + 2)
            result.append(contentsOf: rows.map {
                messageItem($0, from: parent)
            })
            return result
        }

        func makeLeadingItems(
            from parent: NativeMessageTimelineView
        ) -> [NativeMessageTimelineItem] {
            var result: [NativeMessageTimelineItem] = []
            result.reserveCapacity(2)
            if let beginning = parent.beginning {
                result.append(.beginning(beginning))
            }
            if NativeTimelineEarlierLoaderPolicy.includesLoader(
                hasMoreMessages: parent.hasMoreMessages,
                isLoadingEarlier: parent.isLoadingEarlier
            ) {
                result.append(
                    .loader(
                        // Automatic pagination stays silent while idle, but a
                        // slow in-flight page must remain visible. The loader
                        // layout is zero-height when idle, preserving document
                        // geometry between requests.
                        isLoading: parent.isLoadingEarlier,
                        kind: parent.conversation.loaderKind
                    )
                )
            }
            return result
        }

        func messageItem(
            _ row: MessageRowPresentation,
            from parent: NativeMessageTimelineView
        ) -> NativeMessageTimelineItem {
            let resolvedRow: MessageRowPresentation
            if let startsDay = parent.firstMessageStartsDayOverride,
               parent.conversation.rows(in: parent.model).first?.id == row.id,
               startsDay != row.startsDay
            {
                resolvedRow = MessageRowPresentation(
                    message: row.message,
                    startsGroup: row.startsGroup,
                    startsDay: startsDay,
                    replyPreview: row.replyPreview,
                    isReplyAvailable: row.isReplyAvailable,
                    textPlan: row.textPlan
                )
            } else {
                resolvedRow = row
            }
            return .message(
                resolvedRow,
                isUnreadBoundary: parent.unreadMessageID == row.id,
                isHighlighted: parent.highlightedMessageID == row.id
            )
        }

        func beginObserving(_ scrollView: NSScrollView) {
            stopObserving()
            let center = NotificationCenter.default
            observations = [
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.reconcileViewportGeometryIfNeeded() {
                            return
                        }
                        let didClamp =
                            self.clampToMaterializedHistoryBoundary()
                        self.positionViewportCanvas()
                        self.updateHistorySkeletonPresentation()
                        guard !self.isApplyingUpdate else { return }
                        self.canvas?.dismissHoverPresentationForScroll()
                        self.noteScrollActivity()
                        // Once the clip view is pinned to the loaded-history
                        // boundary, its logical near-top state no longer
                        // changes. A further upward wheel delta can still
                        // briefly move into the reserved coordinates before
                        // this clamp restores it. Force that attempted
                        // crossing through the callback so a completed or
                        // failed slow request cannot leave pagination
                        // permanently stuck at the current oldest row.
                        self.reportScrollState(force: didClamp)
                    }
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        _ = self?.reconcileViewportGeometryIfNeeded()
                    }
                },
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.canvas?.dismissHoverPresentationForScroll()
                        self.noteScrollActivity()
                        if self.scrollState().isNearTop {
                            // Trackpad gestures may begin while AppKit is
                            // already constrained at the materialized top and
                            // therefore produce no bounds notification at all.
                            // Re-arm automatic pagination from the gesture
                            // itself in that case.
                            self.reportScrollState(force: true)
                        }
                        self.parent.onUserScrollBegan()
                    }
                },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.finishScrollActivity()
                        self.parent.onUserScrollEnded(self.scrollState())
                    }
                },
                center.addObserver(
                    forName: .sakuracordMessageRowsDidChange,
                    object: parent.model,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self,
                              !self.isApplyingUpdate,
                              let scrollView = self.scrollView
                        else { return }
                        self.update(
                            parent: self.parent,
                            scrollView: scrollView
                        )
                    }
                },
            ]
        }

        func noteScrollActivity() {
            lastScrollActivityUptime = ProcessInfo.processInfo.systemUptime
            publishScrollActivity(true)
            // Programmatic benchmark scrolling is continuous even if the main
            // thread misses a display-link callback. Never interpret that gap
            // as scroll idle: re-enabling hover here installs tracking areas,
            // synchronizes the stationary pointer, and can turn one delayed
            // frame into a much larger feedback-loop stall.
            if isPreparingOrRunningPerformanceBenchmark {
                scrollIdleTask?.cancel()
                scrollIdleTask = nil
                return
            }
            guard scrollIdleTask == nil else { return }
            scrollIdleTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled {
                    let remaining =
                        self.lastScrollActivityUptime + 0.350
                        - ProcessInfo.processInfo.systemUptime
                    if remaining <= 0 {
                        self.finishScrollActivity()
                        return
                    }
                    do {
                        try await Task.sleep(
                            for: .milliseconds(max(1, Int(ceil(remaining * 1_000))))
                        )
                    } catch {
                        return
                    }
                }
            }
        }

        func finishScrollActivity() {
            guard !isPreparingOrRunningPerformanceBenchmark else { return }
            scrollIdleTask?.cancel()
            scrollIdleTask = nil
            publishScrollActivity(false)
            if let canvas, let scrollView {
                canvas.allowHoverPresentationAfterScroll()
                canvas.prewarmRows(
                    above: scrollView.contentView.bounds,
                    count: 48
                )
            }
        }

        func updateInsets() {
            guard let scrollView, let canvas else { return }
            let viewportHeight = scrollView.contentView.bounds.height
            canvas.updateContentOriginY(
                contentOriginY(viewportHeight: viewportHeight),
                minimumHeight: max(1, viewportHeight),
                bottomSpacerHeight: bottomInset
            )
            let contentInsets = scrollView.contentInsets
            if contentInsets.top != 0
                || contentInsets.left != 0
                || contentInsets.bottom != 0
                || contentInsets.right != 0
            {
                scrollView.contentInsets = NSEdgeInsets()
            }
            let showsVerticalScroller =
                scrollableDocumentHeight > viewportHeight + 0.5
            if scrollView.hasVerticalScroller != showsVerticalScroller {
                scrollView.hasVerticalScroller = showsVerticalScroller
            }
        }

        var bottomInset: CGFloat {
            parent.bottomContentInset
                + ChatDetailLayoutPolicy.timelineBottomPadding
        }

        func contentOriginY(viewportHeight: CGFloat) -> CGFloat {
            leadingHistoryReserve
                + NativeMessageTimelineLayoutPolicy.shortContentTopInset(
                    viewportHeight: viewportHeight,
                    contentHeight: contentHeight,
                    bottomInset: bottomInset,
                    verticalPadding:
                        ChatDetailLayoutPolicy.timelineTopPadding
                )
        }

        var effectiveContentHeight: CGFloat {
            let viewportHeight =
                scrollView?.contentView.bounds.height ?? 0
            return NativeMessageTimelineLayoutPolicy.documentHeight(
                contentOriginY: contentOriginY(
                    viewportHeight: viewportHeight
                ),
                contentHeight: contentHeight,
                bottomInset: bottomInset,
                viewportHeight: viewportHeight
            )
        }

        var scrollableDocumentHeight: CGFloat {
            documentView?.frame.height ?? effectiveContentHeight
        }

        func visibleAnchor(
            preferringVisibleMessageBeginning: Bool = false
        ) -> VisibleAnchor? {
            guard let canvas, let scrollView,
                  let result =
                    canvas.firstVisibleMessage(
                        in: scrollView.contentView.bounds,
                        preferringVisibleOrigin:
                            preferringVisibleMessageBeginning
                    )
            else { return nil }
            return VisibleAnchor(
                messageID: result.0,
                offsetFromViewportTop: result.1
            )
        }

        func restore(_ anchor: VisibleAnchor) {
            guard let index = items.firstIndex(where: {
                $0.messageID == anchor.messageID
            }), rowOrigins.indices.contains(index),
            let scrollView
            else { return }
            scroll(
                toDocumentY:
                    contentOriginY(
                        viewportHeight: scrollView.contentView.bounds.height
                    )
                    + rowOrigins[index]
                    - anchor.offsetFromViewportTop,
                scrollView: scrollView
            )
        }

        @discardableResult
        func applyInitialPositionIfNeeded() -> Bool {
            guard initialPositionConversation != parent.conversation,
                  let target = parent.initialScrollTarget,
                  let scrollView,
                  scrollView.contentView.bounds.width > 1,
                  scrollView.contentView.bounds.height > 1,
                  scroll(
                    to: resolvedInitialScrollTarget(
                        target,
                        viewportHeight: scrollView.contentView.bounds.height
                    ),
                    in: scrollView
                  )
            else {
                return false
            }
            initialPositionConversation = parent.conversation
            return true
        }

        func resolvedInitialScrollTarget(
            _ target: MessageTimelineScrollRequest.Target,
            viewportHeight: CGFloat
        ) -> MessageTimelineScrollRequest.Target {
            guard case let .message(messageID, _) = target,
                  parent.unreadMessageID == messageID,
                  let unreadIndex = items.firstIndex(where: {
                      $0.messageID == messageID
                  }),
                  let newestIndex = items.lastIndex(where: {
                      $0.messageID != nil
                  }),
                  rowOrigins.indices.contains(unreadIndex),
                  rowOrigins.indices.contains(newestIndex),
                  layouts.indices.contains(newestIndex)
            else {
                return target
            }
            let fitsAtBottom = NativeTimelineInitialPlacementPolicy
                .exactUnreadRunFitsAtBottom(
                    unreadMinimumY: rowOrigins[unreadIndex],
                    newestMaximumY:
                        rowOrigins[newestIndex]
                        + layouts[newestIndex].height,
                    viewportHeight: viewportHeight,
                    bottomInset: bottomInset
                )
            let conversationID = parent.conversation.id?.rawValue ?? 0
            Self.readStateLogger.debug(
                "Unread placement c=\(conversationID, privacy: .public) first=\(messageID.rawValue, privacy: .public) bottom=\(fitsAtBottom, privacy: .public)"
            )
            return fitsAtBottom ? .bottom : target
        }

        func applyScrollRequestIfNeeded() {
            guard let request = parent.scrollRequest,
                  request.id != lastScrollRequestID,
                  let scrollView
            else { return }
            guard scroll(to: request.target, in: scrollView) else {
                return
            }
            lastScrollRequestID = request.id
        }

        @discardableResult
        func scroll(
            to target: MessageTimelineScrollRequest.Target,
            in scrollView: NSScrollView
        ) -> Bool {
            let viewportHeight = scrollView.contentView.bounds.height
            switch target {
            case .bottom:
                scroll(toDocumentY: .greatestFiniteMagnitude, scrollView: scrollView)
            case let .message(messageID, anchor):
                guard let index = items.firstIndex(where: {
                    $0.messageID == messageID
                }) else { return false }
                let rowY =
                    contentOriginY(viewportHeight: viewportHeight)
                    + rowOrigins[index]
                let rowHeight = layouts[index].height
                scroll(
                    toDocumentY:
                        rowY - (viewportHeight - rowHeight) * anchor.y,
                    scrollView: scrollView
                )
            }
            if let canvas {
                canvas.prewarmRows(
                    above: scrollView.contentView.bounds,
                    count: 48
                )
            }
            return true
        }

        func scroll(
            toDocumentY targetY: CGFloat,
            scrollView: NSScrollView
        ) {
            let clampedY = NativeMessageTimelineLayoutPolicy.clampedDocumentY(
                proposedY: targetY,
                contentHeight: scrollableDocumentHeight,
                viewportHeight: scrollView.contentView.bounds.height,
                bottomInset: 0
            )
            let minimumY =
                parent.hasMoreMessages
                ? provisionalHistoryMinimumY(
                    viewportHeight:
                        scrollView.contentView.bounds.height
                )
                : 0
            scrollView.contentView.scroll(
                to: NSPoint(x: 0, y: max(minimumY, clampedY))
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
            positionViewportCanvas()
        }

        func reportScrollState(force: Bool = false) {
            let state = scrollState()
            guard force || state != lastReportedState else { return }
            lastReportedState = state
            scrollStateCallbackGeneration &+= 1
            let generation = scrollStateCallbackGeneration
            let callback = parent.onScrollStateChange
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.scrollStateCallbackGeneration == generation else {
                    return
                }
                callback(state)
            }
        }

        func publishScrollActivity(_ isActive: Bool) {
            guard lastReportedScrollActivity != isActive else { return }
            lastReportedScrollActivity = isActive
            scrollActivityCallbackGeneration &+= 1
            let generation = scrollActivityCallbackGeneration
            let callback = parent.onScrollActivityChange
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.scrollActivityCallbackGeneration == generation else {
                    return
                }
                callback(isActive)
            }
        }

        func publishInitialPosition(_ state: TimelineScrollState) {
            initialPositionCallbackGeneration &+= 1
            let generation = initialPositionCallbackGeneration
            let conversation = parent.conversation
            let callback = parent.onInitialPositionEstablished
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      self.initialPositionCallbackGeneration == generation,
                      self.parent.conversation == conversation
                else {
                    return
                }
                callback(state)
            }
        }

        func scrollState() -> TimelineScrollState {
            guard let scrollView else {
                return TimelineScrollState(isNearTop: true, isNearBottom: true)
            }
            let visibleRect = scrollView.contentView.bounds
            let hasEstablishedInitialPosition =
                initialPositionConversation == parent.conversation
            return TimelineScrollState(
                isNearTop:
                    visibleRect.minY - leadingHistoryReserve
                    < Self.prefetchDistance,
                isNearBottom:
                    NativeMessageTimelineLayoutPolicy.isAtTrueBottom(
                        documentHeight: scrollableDocumentHeight,
                        visibleMaximumY: visibleRect.maxY
                    ),
                contentFitsViewport:
                    !NativeMessageTimelineLayoutPolicy.showsVerticalScroller(
                        contentHeight: contentHeight,
                        viewportHeight: visibleRect.height,
                        bottomInset: bottomInset,
                        verticalPadding:
                            ChatDetailLayoutPolicy.timelineTopPadding
                    ),
                hasEstablishedInitialPosition:
                    hasEstablishedInitialPosition,
                hasReachedNewestMessageBoundary:
                    hasEstablishedInitialPosition
                    && hasReachedNewestMessageBoundary(in: visibleRect)
            )
        }

        func hasReachedNewestMessageBoundary(
            in visibleRect: CGRect
        ) -> Bool {
            guard let newestIndex = items.lastIndex(where: {
                $0.messageID != nil
            }),
                rowOrigins.indices.contains(newestIndex),
                layouts.indices.contains(newestIndex)
            else {
                return false
            }
            let newestMessageMaximumY =
                contentOriginY(viewportHeight: visibleRect.height)
                + rowOrigins[newestIndex]
                + layouts[newestIndex].height
            // This is the semantic read boundary: the bottom edge of the
            // newest message has entered the viewport. Composer/footer space
            // is irrelevant, and no fuzzy "near bottom" threshold is used.
            return NativeTimelineReadBoundaryPolicy
                .hasReachedNewestMessageBoundary(
                    newestMessageMaximumY: newestMessageMaximumY,
                    viewportMinimumY: visibleRect.minY,
                    viewportMaximumY: visibleRect.maxY
                )
        }

        var performanceAutoScrollStartOperation: () -> Void {
            { [self] in
            guard parent.runsPerformanceAutoScroll,
                  !didStartPerformanceAutoScroll,
                  items.count >= 100,
                  let canvas
            else { return }
            didStartPerformanceAutoScroll = true
            isPreparingOrRunningPerformanceBenchmark = true
            let handoffDisplayLinkTicker =
                NativeTimelineDisplayLinkTicker()
            var previousHandoffTickUptime =
                ProcessInfo.processInfo.systemUptime
            var maximumHandoffTickInterval = 0.0
            var delayedHandoffTicks = 0
            var completedHandoffTicks = 0
            var handoffPhase = "initial-render"
            let handoffStartUptime = ProcessInfo.processInfo.systemUptime
            var lastDelayedHandoffUptime = handoffStartUptime
            handoffDisplayLinkTicker.start(on: canvas) {
                let uptime = ProcessInfo.processInfo.systemUptime
                let interval = uptime - previousHandoffTickUptime
                previousHandoffTickUptime = uptime
                completedHandoffTicks += 1
                maximumHandoffTickInterval = max(
                    maximumHandoffTickInterval,
                    interval
                )
                if interval > 0.033 {
                    delayedHandoffTicks += 1
                    lastDelayedHandoffUptime = uptime
                    Self.performanceLogger.notice(
                        "SakuraCord delayed benchmark startup tick: \(interval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; phase \(handoffPhase, privacy: .public)"
                    )
                }
            }
            // Benchmark launch used to spend its warm-up interval as an
            // ordinary interactive timeline. That installed tracking and
            // accessibility proxies beneath a stationary pointer, then
            // tore them down on the first measured scroll frame. Besides
            // producing a visible hover/highlight phase, the transition
            // made the beginning of every run materially colder than the
            // rest. Enter the scrolling presentation before warm-up.
            //
            // Do not eagerly rasterize rows here. During active scrolling
            // the canvas deliberately paints uncached rows directly; a
            // prewarm would defeat that fallback and make the first cold
            // AppKit/CoreText bitmap block the main thread before motion.
            canvas.dismissHoverPresentationForScroll()
            noteScrollActivity()
            handoffPhase = "launch-stabilization"
            performanceAutoScrollTask = Task { @MainActor [weak self] in
                do {
                    // A fixed delay can expire before AppKit has presented even
                    // one timeline frame. Starting in that state leaves the
                    // ordinary hover/tracking presentation installed and the
                    // bottom overlay clipped until the first real display
                    // transaction arrives. Gate on frames actually delivered
                    // by this view, then require a brief responsive interval.
                    let startupDeadline =
                        ProcessInfo.processInfo.systemUptime + 3
                    while !NativeTimelineBenchmarkStartupPolicy.isReady(
                        completedTicks: completedHandoffTicks,
                        uptime: ProcessInfo.processInfo.systemUptime,
                        lastDelayedTickUptime: lastDelayedHandoffUptime
                    ),
                        ProcessInfo.processInfo.systemUptime < startupDeadline
                    {
                        try await Task.sleep(for: .milliseconds(16))
                    }
                } catch {
                    handoffDisplayLinkTicker.stop()
                    return
                }
                guard let self,
                      let scrollView = self.scrollView,
                      let canvas = self.canvas
                else { return }
                // The bottom spacer deliberately keeps the newest message
                // above the floating composer. Starting the benchmark at that
                // exact edge made its first frames look clipped at a hard
                // footer line; only after consuming the spacer did rows travel
                // beneath the overlay like the rest of the run. Move past the
                // spacer before telemetry and live-arrival stress begin.
                handoffPhase = "position-shift"
                let initialRect = scrollView.contentView.bounds
                scroll(
                    toDocumentY:
                        initialRect.minY
                        - bottomInset
                        - min(160, initialRect.height * 0.25),
                    scrollView: scrollView
                )
                handoffPhase = "settling"
                let ticksBeforePositionShift = completedHandoffTicks
                let positionShiftDeadline =
                    ProcessInfo.processInfo.systemUptime + 0.250
                do {
                    // Do not switch to measured motion until AppKit has
                    // presented the position shift that moves rows beneath the
                    // floating composer.
                    while completedHandoffTicks <= ticksBeforePositionShift,
                          ProcessInfo.processInfo.systemUptime
                            < positionShiftDeadline
                    {
                        try await Task.sleep(for: .milliseconds(8))
                    }
                } catch {
                    handoffDisplayLinkTicker.stop()
                    return
                }
                handoffDisplayLinkTicker.stop()
                Self.performanceLogger.notice(
                    """
                    SakuraCord timeline benchmark startup: \
                    max handoff tick \(maximumHandoffTickInterval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
                    max canvas draw \(canvas.maximumDrawDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
                    max row raster \(canvas.maximumRowRasterDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms \
                    over \(completedHandoffTicks, privacy: .public) ticks (\(delayedHandoffTicks, privacy: .public) above 33 ms)
                    """
                )
                canvas.resetDrawTelemetry()
                let signpost = Self.performanceSignposter.beginInterval(
                    "MessageTimelineAutoScrollBenchmark"
                )
                var previousTickUptime = ProcessInfo.processInfo.systemUptime
                var maximumTickInterval = 0.0
                var maximumScrollWork = 0.0
                var completedTicks = 0
                var delayedTicks = 0
                var maximumTickItemCount = items.count
                var maximumTickDocumentY = 0.0
                var historyStarvedTicks = 0
                var consecutiveHistoryStarvedTicks = 0
                var maximumHistoryStarvedTicks = 0
                let displayLinkTicker = NativeTimelineDisplayLinkTicker()
                self.performanceDisplayLinkTicker = displayLinkTicker
                var didFinish = false
                let finish: () -> Void = { [weak self, weak canvas, weak displayLinkTicker] in
                    guard !didFinish else { return }
                    didFinish = true
                    displayLinkTicker?.stop()
                    Self.performanceSignposter.endInterval(
                        "MessageTimelineAutoScrollBenchmark",
                        signpost
                    )
                    let summary = String(
                        format:
                            "SakuraCord timeline benchmark: max main-thread tick interval %.2f ms; "
                                + "max scroll work %.2f ms; max canvas draw %.2f ms; "
                                + "max row raster %.2f ms (height %.0f) over %d ticks "
                                + "(%d above 33 ms; max at %d items, y %.0f); "
                                + "history-starved %d ticks (max %d consecutive)",
                        maximumTickInterval * 1_000,
                        maximumScrollWork * 1_000,
                        (canvas?.maximumDrawDuration ?? 0) * 1_000,
                        (canvas?.maximumRowRasterDuration ?? 0) * 1_000,
                        canvas?.maximumRowRasterHeight ?? 0,
                        completedTicks,
                        delayedTicks,
                        maximumTickItemCount,
                        maximumTickDocumentY,
                        historyStarvedTicks,
                        maximumHistoryStarvedTicks
                    )
                    Self.performanceLogger.notice(
                        "\(summary, privacy: .public)"
                    )
                    self?.isPreparingOrRunningPerformanceBenchmark = false
                    self?.performanceDisplayLinkTicker = nil
                    self?.performanceBenchmarkFinish = nil
                    self?.finishScrollActivity()
                }
                self.performanceBenchmarkFinish = finish
                displayLinkTicker.start(on: canvas) { [weak self, weak scrollView] in
                    guard let self, let scrollView else {
                        finish()
                        return
                    }
                    let tickUptime = ProcessInfo.processInfo.systemUptime
                    let tickInterval = tickUptime - previousTickUptime
                    previousTickUptime = tickUptime
                    completedTicks += 1
                    let visibleRect = scrollView.contentView.bounds
                    if tickInterval > 0.033 {
                        delayedTicks += 1
                    }
                    if tickInterval > maximumTickInterval {
                        maximumTickInterval = tickInterval
                        maximumTickItemCount = items.count
                        maximumTickDocumentY = visibleRect.minY
                    }
                    if tickInterval >= 0.080 {
                        Self.performanceLogger.notice(
                            """
                            SakuraCord delayed timeline tick: \
                            \(tickInterval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; \
                            last update \(self.performanceUpdatePath, privacy: .public) \
                            \(self.lastPerformanceUpdateDuration, format: .fixed(precision: 2), privacy: .public) ms; \
                            items \(self.items.count, privacy: .public); revision \(self.rowsRevision, privacy: .public)
                            """
                        )
                    }
                    if items.count >= 500,
                       visibleRect.minY - leadingHistoryReserve <= 160
                    {
                        finish()
                        return
                    }
                    let workStart = ProcessInfo.processInfo.systemUptime
                    scroll(
                        toDocumentY: visibleRect.minY - 160,
                        scrollView: scrollView
                    )
                    let didAdvance =
                        scrollView.contentView.bounds.minY
                        < visibleRect.minY - 0.5
                    if !didAdvance, parent.hasMoreMessages {
                        historyStarvedTicks += 1
                        consecutiveHistoryStarvedTicks += 1
                        maximumHistoryStarvedTicks = max(
                            maximumHistoryStarvedTicks,
                            consecutiveHistoryStarvedTicks
                        )
                    } else {
                        consecutiveHistoryStarvedTicks = 0
                    }
                    maximumScrollWork = max(
                        maximumScrollWork,
                        ProcessInfo.processInfo.systemUptime - workStart
                    )
                    if completedTicks >= 1_200 {
                        finish()
                    }
                }
                NativeTimelinePerformanceBenchmarkGate.shared.begin()
            }
        }
        }

        func startPerformanceAutoScrollIfNeeded() {
            performanceAutoScrollStartOperation()
        }
}
