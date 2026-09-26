import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

nonisolated enum NativeTimelineViewportWindowPolicy {
    static let overscan: CGFloat = 320
    static let minimumRetainedBuffer: CGFloat = 80

    static func geometry(
        viewport: CGRect,
        documentSize: CGSize,
        currentFrame: CGRect
    ) -> (frame: CGRect, bounds: CGRect) {
        let documentHeight = max(1, documentSize.height)
        let viewportWidth = max(1, viewport.width)
        let canvasHeight = min(
            documentHeight,
            max(1, viewport.height + overscan * 2)
        )
        let maximumOriginY = max(0, documentHeight - canvasHeight)

        let frameCoversViewport =
            abs(currentFrame.width - viewportWidth) < 0.5
            && abs(currentFrame.height - canvasHeight) < 0.5
            && currentFrame.minY <= viewport.minY + 0.5
            && currentFrame.maxY >= viewport.maxY - 0.5
            && currentFrame.minY >= -0.5
            && currentFrame.maxY <= documentHeight + 0.5
        let retainsLeadingBuffer =
            currentFrame.minY <= 0.5
            || viewport.minY - currentFrame.minY >= minimumRetainedBuffer
        let retainsTrailingBuffer =
            currentFrame.maxY >= documentHeight - 0.5
            || currentFrame.maxY - viewport.maxY >= minimumRetainedBuffer

        if frameCoversViewport,
           retainsLeadingBuffer,
           retainsTrailingBuffer
        {
            let bounds = CGRect(
                x: 0,
                y: currentFrame.minY,
                width: currentFrame.width,
                height: currentFrame.height
            )
            return (currentFrame, bounds)
        }

        let originY = min(
            maximumOriginY,
            max(0, viewport.minY - overscan)
        )
        let frame = CGRect(
            x: 0,
            y: originY,
            width: viewportWidth,
            height: canvasHeight
        )
        let bounds = CGRect(
            x: 0,
            y: originY,
            width: frame.width,
            height: frame.height
        )
        return (frame, bounds)
    }
}

nonisolated enum NativeTimelineWidthRelayoutPolicy {
    static let asynchronousRowThreshold = 1_000
    static let batchSize = 96

    static func indexes(
        itemCount: Int,
        visibleRange: Range<Int>?
    ) -> [Int] {
        guard itemCount > 0 else { return [] }
        let allIndexes = 0 ..< itemCount
        guard let visibleRange else { return Array(allIndexes) }
        let lower = min(itemCount, max(0, visibleRange.lowerBound))
        let upper = min(itemCount, max(lower, visibleRange.upperBound))
        guard lower < upper else { return Array(allIndexes) }
        var result: [Int] = []
        result.reserveCapacity(itemCount)
        result.append(contentsOf: lower ..< upper)
        result.append(contentsOf: upper ..< itemCount)
        result.append(contentsOf: 0 ..< lower)
        return result
    }
}

@MainActor
final class NativeTimelineBenchmarkStartupState {
    let ticker = NativeTimelineDisplayLinkTicker()
    let startedAt = ProcessInfo.processInfo.systemUptime
    var previousTickUptime = ProcessInfo.processInfo.systemUptime
    var maximumTickInterval = 0.0
    var delayedTicks = 0
    var completedTicks = 0
    var phase = "initial-render"
    var lastDelayedTickUptime = ProcessInfo.processInfo.systemUptime

    func recordTick(at uptime: TimeInterval) -> TimeInterval {
        let interval = uptime - previousTickUptime
        previousTickUptime = uptime
        completedTicks += 1
        maximumTickInterval = max(maximumTickInterval, interval)
        if interval > 0.033 {
            delayedTicks += 1
            lastDelayedTickUptime = uptime
        }
        return interval
    }
}

@MainActor
final class NativeTimelineBenchmarkRunState {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let ticker = NativeTimelineDisplayLinkTicker()
    let scrollsTowardLater: Bool
    let closeMeasurement: () -> Void
    var controller: NativeTimelineBenchmarkScrollController
    var previousTickUptime: TimeInterval
    var maximumTickInterval = 0.0
    var maximumScrollWork = 0.0
    var completedTicks = 0
    var delayedTicks = 0
    var tickIntervals: [TimeInterval] = []
    var delayedTickSamples: [NativeTimelineBenchmarkArtifact.DelayedTick] = []
    var maximumTickItemCount: Int
    var maximumTickDocumentY = 0.0
    var historyStarvedTicks = 0
    var consecutiveHistoryStarvedTicks = 0
    var maximumHistoryStarvedTicks = 0
    var didFinish = false

    init(
        scrollsTowardLater: Bool,
        initialItemCount: Int,
        closeMeasurement: @escaping () -> Void
    ) {
        self.scrollsTowardLater = scrollsTowardLater
        self.closeMeasurement = closeMeasurement
        controller = NativeTimelineBenchmarkScrollController(startedAt: startedAt)
        previousTickUptime = startedAt
        maximumTickItemCount = initialItemCount
        tickIntervals.reserveCapacity(1_500)
        delayedTickSamples.reserveCapacity(64)
    }

    func recordTick(at uptime: TimeInterval, itemCount: Int, documentY: CGFloat) -> TimeInterval {
        let interval = uptime - previousTickUptime
        previousTickUptime = uptime
        completedTicks += 1
        tickIntervals.append(interval)
        if interval > 0.033 {
            delayedTicks += 1
            delayedTickSamples.append(
                .init(offset: uptime - startedAt, interval: interval)
            )
        }
        if interval > maximumTickInterval {
            maximumTickInterval = interval
            maximumTickItemCount = itemCount
            maximumTickDocumentY = documentY
        }
        return interval
    }

    func recordHistoryProgress(didAdvance: Bool, hasMoreHistory: Bool) {
        if !didAdvance, hasMoreHistory {
            historyStarvedTicks += 1
            consecutiveHistoryStarvedTicks += 1
            maximumHistoryStarvedTicks = max(
                maximumHistoryStarvedTicks,
                consecutiveHistoryStarvedTicks
            )
        } else {
            consecutiveHistoryStarvedTicks = 0
        }
    }

    @discardableResult
    func finish(
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        endActivity: () -> Void = { AppScrollWorkGate.endActivity() },
        beforeMeasurementClose: () -> Void,
        performBookkeeping: (_ elapsed: TimeInterval) -> Void
    ) -> TimeInterval? {
        guard !didFinish else { return nil }
        didFinish = true
        endActivity()
        ticker.stop()
        beforeMeasurementClose()
        return NativeTimelineBenchmarkFinishSequence.run(
            startedAt: startedAt,
            now: now,
            closeMeasurement: closeMeasurement,
            performBookkeeping: performBookkeeping
        )
    }
}

extension NativeMessageTimelineCoordinator {
        func refreshLinkedImageLayouts(
            for identifiers: Set<NativeMessageTimelineItem.Identifier>
        ) {
            guard let canvas, let scrollView, layoutWidth > 0,
                  initialPositionConversation == parent.conversation
            else { return }
            var changed: [(Int, NativeTimelineRowLayout)] = []
            for index in items.indices
            where identifiers.contains(items[index].identifier)
                && layouts.indices.contains(index)
                && !layouts[index].linkedImageRegions.isEmpty
            {
                let updated = layout(for: items[index], width: layoutWidth)
                let previousFrames = layouts[index].linkedImageRegions.map(\.frame)
                let updatedFrames = updated.linkedImageRegions.map(\.frame)
                if previousFrames != updatedFrames {
                    changed.append((index, updated))
                }
            }
            guard !changed.isEmpty else { return }

            let wasNearBottom = scrollState().isNearBottom
            let anchor = wasNearBottom ? nil : visibleAnchor()
            isApplyingUpdate = true
            cancelLayoutPreparation()
            for (index, updated) in changed {
                layouts[index] = updated
                rowHeights[index] = updated.height
                cacheItemLayout(items[index], layout: updated)
                canvas.invalidateBitmap(items[index].identifier)
            }
            rebuildOrigins()
            applySnapshot(to: canvas, in: scrollView)
            if wasNearBottom {
                scroll(toDocumentY: .greatestFiniteMagnitude, scrollView: scrollView)
            } else if let anchor {
                restore(anchor)
            }
            positionViewportCanvas()
            canvas.invalidateVisibleContent()
            isApplyingUpdate = false
            reportScrollState(force: true)
        }

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

        /// Member-store presentation changes can alter an author's name,
        /// avatar, role color, or a resolved mention without changing the
        /// immutable message row itself. Refresh that one row's derived layout
        /// and bitmap instead of bumping the global presentation revision.
        func refreshItemPresentation(
            at index: Int,
            with item: NativeMessageTimelineItem,
            width: CGFloat
        ) {
            guard items.indices.contains(index),
                  layouts.indices.contains(index),
                  rowHeights.indices.contains(index)
            else { return }
            if items[index] != item {
                replaceItem(at: index, with: item, width: width)
                return
            }
            let previousHeight = layouts[index].height
            let updatedLayout = layout(for: item, width: width)
            layouts[index] = updatedLayout
            rowHeights[index] = updatedLayout.height
            canvas?.invalidateBitmap(item.identifier)
            canvas?.mentionPointerRegionCache[item.identifier] = nil
            canvas?.codeBlockPointerRegionCache[item.identifier] = nil
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
            if let preparation = layoutPreparation,
               preparation.isComplete,
               preparation.presentationRevision == parent.presentationRevision,
               preparation.inviteRevision == parent.model.serverInvites.revision,
               abs(preparation.width - width) < 0.5,
               let cached = preparation.layouts[item.identifier],
               cached.item == item,
               cached.layout.fontRevision == ProfileNameFontCache.revision {
                recentLayoutCacheHits += 1
                return cached.layout
            }
            return NativeTimelineRowLayout.make(
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
            in scrollView: NSScrollView,
            redrawsMovedShortContentSynchronously: Bool = true
        ) {
            let viewportHeight = max(1, scrollView.contentView.bounds.height)
            updateDocumentSize(
                NSSize(
                    width: layoutWidth,
                    height: effectiveContentHeight
                )
            )
            canvas.presentedConversationID = parent.conversation.id
            canvas.messageInteractionContext =
                parent.conversation.messageInteractionContext
            canvas.apply(
                storage: storage,
                model: parent.model,
                actions: actions,
                viewportWidth: layoutWidth,
                minimumHeight: viewportHeight,
                bottomSpacerHeight:
                    bottomInset + trailingHistoryReserve,
                contentOriginY: contentOriginY(
                    viewportHeight: viewportHeight
                ),
                historySkeleton:
                    historySkeletonPresentation(
                        viewportHeight: viewportHeight
                    ),
                redrawsMovedShortContentSynchronously:
                    redrawsMovedShortContentSynchronously
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
                // Row layout may deliberately retain its previous width
                // while a resize is coalesced, but this remains a vertical-
                // only document. Pinning the document to the viewport keeps
                // that transient backing width from becoming a real
                // horizontal scroll range.
                width: max(1, viewport.width),
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
            var viewport = scrollView.contentView.bounds
            if pendingLayoutWidth != nil, layoutWidth > 0 {
                // A settled width relayout is pending. Keep the backing view
                // at the width its row layouts and cached bitmaps describe;
                // resizing that layer early stretches the previous pixels
                // until an unrelated invalidation (such as hover) repaints
                // them. The clip view can temporarily crop or reveal the
                // old-width canvas without presenting distorted text.
                viewport.size.width = layoutWidth
            }
            let geometry = NativeTimelineViewportWindowPolicy.geometry(
                viewport: viewport,
                documentSize: documentView.frame.size,
                currentFrame: canvas.frame
            )
            canvas.installViewportGeometry(
                frame: geometry.frame,
                bounds: geometry.bounds
            )
        }

        @discardableResult
        func clampToMaterializedHistoryBoundaries() -> Bool {
            var didClamp = false
            for direction in TimelineHistoryDirection.allCases
            where clampToMaterializedHistoryBoundary(direction) {
                didClamp = true
            }
            return didClamp
        }

        func clampToMaterializedHistoryBoundary(
            _ direction: TimelineHistoryDirection
        ) -> Bool {
            guard hasMoreHistory(direction),
                  historyReserve(direction) > 0,
                  let scrollView
            else {
                setFollowsMaterializedHistoryBoundary(false, direction: direction)
                return false
            }
            let clipView = scrollView.contentView
            let boundaryY = materializedHistoryScrollBoundaryY(
                direction,
                viewportHeight: clipView.bounds.height
            )
            let attemptedProvisionalHistory: Bool
            switch direction {
            case .earlier:
                if !isApplyingUpdate,
                   clipView.bounds.minY > boundaryY + 1
                {
                    setFollowsMaterializedHistoryBoundary(
                        false,
                        direction: direction
                    )
                }
                attemptedProvisionalHistory =
                    clipView.bounds.minY < boundaryY - 0.5
            case .later:
                if !isApplyingUpdate,
                   clipView.bounds.minY < boundaryY - 1
                {
                    setFollowsMaterializedHistoryBoundary(
                        false,
                        direction: direction
                    )
                }
                attemptedProvisionalHistory =
                    clipView.bounds.minY > boundaryY + 0.5
            }
            if attemptedProvisionalHistory {
                setFollowsMaterializedHistoryBoundary(true, direction: direction)
            }
            let clampedY = provisionalHistoryBoundaryY(
                direction,
                viewportHeight: clipView.bounds.height
            )
            let requiresClamp = switch direction {
            case .earlier:
                clipView.bounds.minY < clampedY - 0.5
            case .later:
                clipView.bounds.minY > clampedY + 0.5
            }
            guard requiresClamp else { return attemptedProvisionalHistory }
            clipView.scroll(
                to: NSPoint(
                    x: clipView.bounds.minX,
                    y: clampedY
                )
            )
            scrollView.reflectScrolledClipView(clipView)
            return true
        }

        func allowsProvisionalHistory(
            _ direction: TimelineHistoryDirection
        ) -> Bool {
            isLoadingHistory(direction)
                || followsMaterializedHistoryBoundary(direction)
        }

        func provisionalHistoryMinimumY(
            viewportHeight: CGFloat
        ) -> CGFloat {
            provisionalHistoryBoundaryY(
                .earlier,
                viewportHeight: viewportHeight
            )
        }

        func provisionalHistoryBoundaryY(
            _ direction: TimelineHistoryDirection,
            viewportHeight: CGFloat
        ) -> CGFloat {
            switch direction {
            case .earlier:
                NativeMessageTimelineLayoutPolicy
                    .provisionalHistoryMinimumY(
                        reserve: leadingHistoryReserve,
                        viewportHeight: viewportHeight,
                        allowsProvisionalHistory:
                            parent.hasMoreMessages
                            && allowsProvisionalHistory(direction)
                    )
            case .later:
                NativeMessageTimelineLayoutPolicy
                    .provisionalHistoryMaximumY(
                        materializedMaximumY:
                            materializedHistoryMaximumY(
                                viewportHeight: viewportHeight
                            ),
                        reserve: trailingHistoryReserve,
                        viewportHeight: viewportHeight,
                        bottomInset: bottomInset,
                        allowsProvisionalHistory:
                            parent.hasMoreLaterMessages
                            && allowsProvisionalHistory(direction)
                    )
            }
        }

        func historySkeletonPresentation(
            viewportHeight: CGFloat
        ) -> TimelineHistorySkeletonPresentation? {
            let visibleRect = scrollView?.contentView.bounds ?? .zero
            let presentations = TimelineHistoryDirection.allCases.compactMap {
                historySkeletonPresentation(
                    for: $0,
                    viewportHeight: viewportHeight
                )
            }
            return presentations.first(where: {
                $0.frame.intersects(visibleRect.insetBy(dx: 0, dy: -viewportHeight))
            }) ?? presentations.first
        }

        func historySkeletonPresentation(
            for direction: TimelineHistoryDirection,
            viewportHeight: CGFloat
        ) -> TimelineHistorySkeletonPresentation? {
            guard NativeMessageTimelineLayoutPolicy.showsHistorySkeleton(
                hasMoreMessages: hasMoreHistory(direction),
                isLoading: isLoadingHistory(direction),
                followsMaterializedHistoryBoundary:
                    followsMaterializedHistoryBoundary(direction)
            ),
                  historyReserve(direction) > 0
            else {
                return nil
            }
            let minimumY: CGFloat
            let maximumY: CGFloat
            switch direction {
            case .earlier:
                minimumY = NativeMessageTimelineLayoutPolicy
                    .provisionalHistoryMinimumY(
                        reserve: leadingHistoryReserve,
                        viewportHeight: viewportHeight,
                        allowsProvisionalHistory: true
                    )
                maximumY = contentOriginY(viewportHeight: viewportHeight)
            case .later:
                minimumY = materializedHistoryMaximumY(
                    viewportHeight: viewportHeight
                )
                maximumY = minimumY + trailingHistoryReserve
            }
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

        func hasMoreHistory(_ direction: TimelineHistoryDirection) -> Bool {
            switch direction {
            case .earlier: parent.hasMoreMessages
            case .later: parent.hasMoreLaterMessages
            }
        }

        func isLoadingHistory(_ direction: TimelineHistoryDirection) -> Bool {
            switch direction {
            case .earlier: parent.isLoadingEarlier
            case .later: parent.isLoadingLater
            }
        }

        func historyReserve(_ direction: TimelineHistoryDirection) -> CGFloat {
            switch direction {
            case .earlier: leadingHistoryReserve
            case .later: trailingHistoryReserve
            }
        }

        func followsMaterializedHistoryBoundary(
            _ direction: TimelineHistoryDirection
        ) -> Bool {
            switch direction {
            case .earlier: followsMaterializedHistoryBoundary
            case .later: followsMaterializedLaterHistoryBoundary
            }
        }

        func setFollowsMaterializedHistoryBoundary(
            _ value: Bool,
            direction: TimelineHistoryDirection
        ) {
            switch direction {
            case .earlier: followsMaterializedHistoryBoundary = value
            case .later: followsMaterializedLaterHistoryBoundary = value
            }
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
            proposedWidth: CGFloat? = nil,
            appliesWidthImmediately: Bool = false,
            preparedLayouts: [NativeTimelineRowLayout]? = nil
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
            let reflowsWidth = widthChanged
                && (appliesWidthImmediately || layoutWidth <= 0)
            if widthChanged, !reflowsWidth {
                scheduleRelayoutForWidthChange(width)
            } else if !widthChanged, !appliesWidthImmediately {
                // A live resize can return to the established width before
                // the debounce fires. The canvas does not change width while
                // a relayout is pending, so it emits no callback for that
                // return trip; cancel the obsolete destination here.
                widthRelayoutTask?.cancel()
                widthRelayoutTask = nil
                pendingLayoutWidth = nil
            }
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
                        reflowsWidth
                        && NativeMessageTimelineLayoutPolicy
                        .prefersVisibleMessageBeginning(
                            from: layoutWidth,
                            to: width
                        )
                )
                : nil
            let anchor =
                reflowsWidth
                ? visiblePosition?.topPinnedForWidthChange
                : visiblePosition

            isApplyingUpdate = true
            if reflowsWidth {
                let targetLayouts = preparedLayouts
                    ?? items.map { layout(for: $0, width: width) }
                layoutWidth = width
                layouts = targetLayouts
                rowHeights = layouts.map(\.height)
                rebuildOrigins()
                applySnapshot(to: canvas, in: scrollView)
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
            if reflowsWidth {
                // Restore the anchor before choosing the dirty rectangle.
                // Invalidating the old visible rect leaves the newly restored
                // viewport backed by stretched Core Animation contents until
                // pointer movement happens to dirty an individual row.
                // Redraw the complete bounded backing window synchronously:
                // it is only the viewport plus overscan, not the full message
                // document, and guarantees no stale-width layer tiles survive
                // the transition.
                canvas.needsDisplay = true
                canvas.layer?.setNeedsDisplay()
                canvas.display()
            }
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
            scheduleRelayoutForWidthChange(proposedWidth)
        }

        func scheduleRelayoutForWidthChange(_ proposedWidth: CGFloat) {
            let width = max(220, proposedWidth.rounded())
            guard abs(width - layoutWidth) >= 1 else {
                widthRelayoutGeneration &+= 1
                widthRelayoutTask?.cancel()
                widthRelayoutTask = nil
                pendingLayoutWidth = nil
                return
            }
            if pendingLayoutWidth == width,
               widthRelayoutTask != nil
            {
                // Bounds notifications, scrolling, and unrelated timeline
                // publications can all rediscover the same stale width while
                // the debounce or bounded reflow is active. Preserve that work
                // so an active channel cannot postpone layout indefinitely.
                return
            }
            guard layoutWidth > 0,
                  initialPositionConversation == parent.conversation
            else {
                _ = reconcileViewportGeometryIfNeeded(
                    proposedWidth: width,
                    appliesWidthImmediately: true
                )
                return
            }
            pendingLayoutWidth = width
            widthRelayoutGeneration &+= 1
            let generation = widthRelayoutGeneration
            widthRelayoutTask?.cancel()
            widthRelayoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard let self,
                      self.pendingLayoutWidth == width,
                      self.widthRelayoutGeneration == generation
                else { return }
                self.widthRelayoutTask = nil
                self.applyPendingWidthRelayout()
            }
        }

        func applyPendingWidthRelayout() {
            guard let width = pendingLayoutWidth else { return }
            widthRelayoutTask = nil
            guard items.count >= NativeTimelineWidthRelayoutPolicy
                .asynchronousRowThreshold
            else {
                pendingLayoutWidth = nil
                _ = reconcileViewportGeometryIfNeeded(
                    proposedWidth: width,
                    appliesWidthImmediately: true
                )
                return
            }
            beginBatchedWidthRelayout(width)
        }

        func beginBatchedWidthRelayout(_ width: CGFloat) {
            let sourceItems = items
            let sourceConversation = parent.conversation
            let sourcePresentationRevision = parent.presentationRevision
            let sourceInviteRevision = parent.model.serverInvites.revision
            let visibleRange = visibleItemRangeForWidthRelayout()
            let indexes = NativeTimelineWidthRelayoutPolicy.indexes(
                itemCount: sourceItems.count,
                visibleRange: visibleRange
            )
            widthRelayoutGeneration &+= 1
            let generation = widthRelayoutGeneration
            widthRelayoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var prepared: [NativeTimelineRowLayout?] = .init(
                    repeating: nil,
                    count: sourceItems.count
                )
                var offset = 0
                while offset < indexes.count {
                    guard !Task.isCancelled,
                          self.widthRelayoutGeneration == generation,
                          self.pendingLayoutWidth == width,
                          self.parent.conversation == sourceConversation
                    else { return }
                    let upperBound = min(
                        indexes.count,
                        offset + NativeTimelineWidthRelayoutPolicy.batchSize
                    )
                    for orderedIndex in offset ..< upperBound {
                        let index = indexes[orderedIndex]
                        prepared[index] = self.layout(
                            for: sourceItems[index],
                            width: width
                        )
                    }
                    offset = upperBound
                    if offset < indexes.count {
                        await Task.yield()
                    }
                }
                guard !Task.isCancelled,
                      self.widthRelayoutGeneration == generation,
                      self.pendingLayoutWidth == width,
                      self.parent.conversation == sourceConversation
                else { return }
                let preparedByIdentifier = Dictionary(
                    uniqueKeysWithValues: sourceItems.indices.compactMap { index -> (
                            NativeMessageTimelineItem.Identifier,
                            (NativeMessageTimelineItem, NativeTimelineRowLayout)
                        )? in
                        guard let layout = prepared[index] else { return nil }
                        return (
                            sourceItems[index].identifier,
                            (sourceItems[index], layout)
                        )
                    }
                )
                let canReusePreparedPresentation =
                    self.parent.presentationRevision
                        == sourcePresentationRevision
                        && self.parent.model.serverInvites.revision == sourceInviteRevision
                let finalLayouts = self.items.map { item in
                    if canReusePreparedPresentation,
                       let prepared = preparedByIdentifier[item.identifier],
                       prepared.0 == item,
                       prepared.1.fontRevision == ProfileNameFontCache.revision
                    {
                        return prepared.1
                    }
                    return self.layout(for: item, width: width)
                }
                self.widthRelayoutTask = nil
                self.pendingLayoutWidth = nil
                _ = self.reconcileViewportGeometryIfNeeded(
                    proposedWidth: width,
                    appliesWidthImmediately: true,
                    preparedLayouts: finalLayouts
                )
            }
        }

        func visibleItemRangeForWidthRelayout() -> Range<Int>? {
            guard let canvas,
                  !items.isEmpty,
                  let first = canvas.rowIndex(at: canvas.visibleRect.minY)
            else { return nil }
            let last = canvas.rowIndex(at: canvas.visibleRect.maxY)
                ?? (items.count - 1)
            return first ..< min(items.count, max(first + 1, last + 1))
        }

        func makeItems(
            from parent: NativeMessageTimelineView,
            rows: [MessageRowPresentation]
        ) -> [NativeMessageTimelineItem] {
            if parent.conversation == .inbox(.unread) {
                let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                var result: [NativeMessageTimelineItem] = []
                for group in parent.model.inbox.groups {
                    result.append(.inboxGroup(InboxGroupHeaderPresentation(group, model: parent.model)))
                    if !group.isCollapsed {
                        result.append(contentsOf: group.events.map(NativeMessageTimelineItem.inboxEvent))
                        result.append(contentsOf: group.forumPosts.map(NativeMessageTimelineItem.inboxForumPost))
                        result.append(contentsOf: group.messages.compactMap { rowsByID[$0.id] }.map { messageItem($0, from: parent) })
                        if !group.isLoaded { break }
                    }
                }
                return result
            }
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
                    endsGroup: row.endsGroup,
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
                isHighlighted: parent.selectedMessageID == row.id
            )
        }

        func beginObserving(_ scrollView: NSScrollView) {
            stopObserving()
            let center = NotificationCenter.default
            observations = [
                center.addObserver(forName: ServerInvitePresentationStore.changed, object: nil, queue: .main) { [weak self] notification in
                    let store = notification.object as? ServerInvitePresentationStore
                    let reference = notification.userInfo?["reference"] as? ServerInviteReference
                    MainActor.assumeIsolated {
                        guard let self, store === self.parent.model.serverInvites else { return }
                        Task { @MainActor [weak self] in
                            await Task.yield()
                            self?.refreshServerInvites(reference)
                        }
                    }
                },
                center.addObserver(
                    forName: ProfileNameFontLoader.didLoadFonts,
                    object: nil, queue: .main
                ) { [weak self] notification in
                    guard let ids = notification.userInfo?["fontIDs"] as? Set<Int> else { return }
                    MainActor.assumeIsolated {
                        self?.refreshDisplayNameFonts(ids)
                    }
                },
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
                            self.clampToMaterializedHistoryBoundaries()
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
                        self?.liveScrollTrackingWillBegin()
                    }
                },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.liveScrollTrackingDidEnd()
                    }
                },
                center.addObserver(
                    forName: .sakuracordMessageRowsDidChange,
                    object: parent.model,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.scheduleModelRowsUpdate()
                    }
                },
                center.addObserver(
                    forName: .sakuraCordThemeDidCommit,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.canvas?.invalidatePresentationCaches()
                    }
                },
            ]
            observations += [.NSCalendarDayChanged, NSApplication.didBecomeActiveNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.scheduleModelRowsUpdate()
                    }
                }
            }
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

        func liveScrollTrackingDidEnd() {
            let interval = Self.performanceSignposter.beginInterval(
                "TimelineLiveScrollEnd"
            )
            defer {
                Self.performanceSignposter.endInterval(
                    "TimelineLiveScrollEnd",
                    interval
                )
            }
            let state = scrollState()
            isEarlierHistoryScrollGestureActive = false
            hasEarlierHistoryScrollIntent = state.isInProvisionalHistory
            isLaterHistoryScrollGestureActive = false
            hasLaterHistoryScrollIntent =
                state.isInProvisionalLaterHistory
            if !state.isInProvisionalHistory,
               followsMaterializedHistoryBoundary
            {
                followsMaterializedHistoryBoundary = false
                updateHistorySkeletonPresentation()
            }
            if !state.isInProvisionalLaterHistory,
               followsMaterializedLaterHistoryBoundary
            {
                followsMaterializedLaterHistoryBoundary = false
                updateHistorySkeletonPresentation()
            }
            // `didEndLiveScroll` also fires when a fresh trackpad gesture
            // interrupts momentum. Restoring hover, accessibility, and media
            // presentation synchronously here made that new gesture wait for
            // a full reconciliation before AppKit could move its first frame.
            // Keep the existing idle grace alive across rapid gestures; the
            // task created by `noteScrollActivity` performs the same restore
            // after input has genuinely settled.
            noteScrollActivity()
            parent.onUserScrollEnded(state)
            requestHistoryIfNeeded(.earlier, for: state)
            requestHistoryIfNeeded(.later, for: state)
        }

        func liveScrollTrackingWillBegin() {
            let interval = Self.performanceSignposter.beginInterval(
                "TimelineLiveScrollStart"
            )
            defer {
                Self.performanceSignposter.endInterval(
                    "TimelineLiveScrollStart",
                    interval
                )
            }
            canvas?.dismissHoverPresentationForScroll()
            noteScrollActivity()
            isEarlierHistoryScrollGestureActive = true
            isLaterHistoryScrollGestureActive = true
            let state = scrollState()
            if state.isNearTop {
                hasEarlierHistoryScrollIntent = true
                // Activate the reserved coordinates before AppKit handles the
                // first upward delta. Initial ten-message pages can otherwise
                // visibly pin at their oldest row until the loading-state
                // update arrives, even though later pages already have ample
                // provisional history above them.
                if parent.hasMoreMessages,
                   leadingHistoryReserve > 0,
                   !followsMaterializedHistoryBoundary
                {
                    followsMaterializedHistoryBoundary = true
                    updateHistorySkeletonPresentation()
                }
                // Trackpad gestures may begin while AppKit is already
                // constrained at the materialized top and therefore produce
                // no bounds notification at all. Re-arm automatic pagination
                // from the gesture itself in that case.
                reportScrollState(force: true)
            }
            if state.isNearLoadedBottom {
                hasLaterHistoryScrollIntent = true
                if parent.hasMoreLaterMessages,
                   trailingHistoryReserve > 0,
                   !followsMaterializedLaterHistoryBoundary
                {
                    followsMaterializedLaterHistoryBoundary = true
                    updateHistorySkeletonPresentation()
                }
                reportScrollState(force: true)
            }
            parent.onUserScrollBegan()
        }

        func finishScrollActivity() {
            guard !isPreparingOrRunningPerformanceBenchmark else { return }
            scrollIdleTask?.cancel()
            scrollIdleTask = nil
            publishScrollActivity(false)
            if let canvas {
                canvas.allowHoverPresentationAfterScroll()
            }
        }

        func updateInsets() {
            guard let scrollView, let canvas else { return }
            let viewportHeight = scrollView.contentView.bounds.height
            canvas.updateContentOriginY(
                contentOriginY(viewportHeight: viewportHeight),
                minimumHeight: max(1, viewportHeight),
                bottomSpacerHeight:
                    bottomInset + trailingHistoryReserve
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
            let topInset = if parent.conversation.alignsUnderfilledContentToTop {
                ChatDetailLayoutPolicy.timelineTopPadding
            } else {
                NativeMessageTimelineLayoutPolicy.shortContentTopInset(
                    viewportHeight: viewportHeight,
                    contentHeight: contentHeight,
                    bottomInset: bottomInset,
                    verticalPadding:
                        ChatDetailLayoutPolicy.timelineTopPadding
                )
            }
            return leadingHistoryReserve
                + topInset
        }

        var effectiveContentHeight: CGFloat {
            let viewportHeight =
                scrollView?.contentView.bounds.height ?? 0
            return NativeMessageTimelineLayoutPolicy.documentHeight(
                contentOriginY: contentOriginY(
                    viewportHeight: viewportHeight
                ),
                contentHeight: contentHeight + trailingHistoryReserve,
                bottomInset: bottomInset,
                viewportHeight: viewportHeight
            )
        }

        var scrollableDocumentHeight: CGFloat {
            documentView?.frame.height ?? effectiveContentHeight
        }

        func materializedHistoryMaximumY(
            viewportHeight: CGFloat
        ) -> CGFloat {
            contentOriginY(viewportHeight: viewportHeight) + contentHeight
        }

        func materializedHistoryScrollBoundaryY(
            _ direction: TimelineHistoryDirection,
            viewportHeight: CGFloat
        ) -> CGFloat {
            switch direction {
            case .earlier:
                leadingHistoryReserve
            case .later:
                max(
                    0,
                    materializedHistoryMaximumY(
                        viewportHeight: viewportHeight
                    ) + bottomInset - viewportHeight
                )
            }
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
            case .top:
                scroll(toDocumentY: 0, scrollView: scrollView)
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
            let maximumY =
                parent.hasMoreLaterMessages
                    ? provisionalHistoryBoundaryY(
                        .later,
                        viewportHeight:
                            scrollView.contentView.bounds.height
                    )
                    : max(
                        0,
                        scrollableDocumentHeight
                            - scrollView.contentView.bounds.height
                    )
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: 0,
                    y: min(maximumY, max(minimumY, clampedY))
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
            positionViewportCanvas()
        }

        func reportScrollState(force: Bool = false) {
            let state = scrollState()
            if hasEarlierHistoryScrollIntent,
               !isEarlierHistoryScrollGestureActive,
               !state.isInProvisionalHistory
            {
                hasEarlierHistoryScrollIntent = false
            }
            if hasLaterHistoryScrollIntent,
               !isLaterHistoryScrollGestureActive,
               !state.isInProvisionalLaterHistory
            {
                hasLaterHistoryScrollIntent = false
            }
            requestHistoryIfNeeded(.earlier, for: state)
            requestHistoryIfNeeded(.later, for: state)
            guard force || state != lastReportedState else { return }
            lastReportedState = state
            pendingScrollState = state
            // A clamped high-frequency gesture can request a forced report on
            // every display tick. Replacing a yield-delayed callback each time
            // starves all of them, so pagination never learns that it is still
            // near the top. Keep one main-actor handoff and let it consume the
            // newest coalesced state.
            guard scrollStateCallbackTask == nil else { return }
            let conversation = parent.conversation
            scrollStateCallbackTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.scrollStateCallbackTask = nil
                guard !Task.isCancelled,
                      self.parent.conversation == conversation,
                      let state = self.pendingScrollState
                else { return }
                self.pendingScrollState = nil
                self.parent.onScrollStateChange(state)
            }
        }

        /// The native scroll view owns the authoritative gesture and clamp
        /// state, so it must not depend exclusively on a yield-delayed SwiftUI
        /// state callback to continue a user-requested history climb. During a
        /// display-rate gesture that callback can be postponed until after the
        /// viewport has consumed its entire provisional reserve. Issue at most
        /// one request per observed loading cycle directly from the native
        /// boundary; the model's directional loader retains its own in-flight
        /// guard.
        func requestHistoryIfNeeded(
            _ direction: TimelineHistoryDirection,
            for state: TimelineScrollState
        ) {
            let isNearBoundary = switch direction {
            case .earlier: state.isNearTop
            case .later: state.isNearLoadedBottom
            }
            let hasIntent = switch direction {
            case .earlier: hasEarlierHistoryScrollIntent
            case .later: hasLaterHistoryScrollIntent
            }
            let hasIssuedRequest = switch direction {
            case .earlier: hasIssuedEarlierHistoryRequest
            case .later: hasIssuedLaterHistoryRequest
            }
            guard isNearBoundary,
                  hasIntent,
                  hasMoreHistory(direction),
                  !isLoadingHistory(direction),
                  !hasIssuedRequest
            else { return }
            switch direction {
            case .earlier:
                hasIssuedEarlierHistoryRequest = true
                parent.loadEarlier()
            case .later:
                hasIssuedLaterHistoryRequest = true
                parent.loadLater()
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
                return TimelineScrollState(
                    isNearTop: true,
                    isNearBottom: !parent.hasMoreLaterMessages,
                    isNearLoadedBottom: true
                )
            }
            let visibleRect = scrollView.contentView.bounds
            let hasEstablishedInitialPosition =
                initialPositionConversation == parent.conversation
            let isAtDocumentBottom =
                NativeMessageTimelineLayoutPolicy.isAtTrueBottom(
                    documentHeight: scrollableDocumentHeight,
                    visibleMaximumY: visibleRect.maxY
                )
            let isNearLoadedBottom =
                materializedHistoryMaximumY(
                    viewportHeight: visibleRect.height
                ) - visibleRect.maxY < (parent.conversation.isInbox ? 2_000 : Self.prefetchDistance)
            return TimelineScrollState(
                isNearTop:
                    visibleRect.minY - leadingHistoryReserve
                    < Self.prefetchDistance,
                isNearBottom:
                    isAtDocumentBottom
                    && !parent.hasMoreLaterMessages,
                isNearLoadedBottom: isNearLoadedBottom,
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
                    && hasReachedNewestMessageBoundary(in: visibleRect),
                isInProvisionalHistory:
                    parent.hasMoreMessages
                    && visibleRect.minY
                        < leadingHistoryReserve - 0.5,
                isInProvisionalLaterHistory:
                    parent.hasMoreLaterMessages
                    && visibleRect.minY
                        > materializedHistoryScrollBoundaryY(
                            .later,
                            viewportHeight: visibleRect.height
                        ) + 0.5
            )
        }

        func hasReachedNewestMessageBoundary(
            in visibleRect: CGRect
        ) -> Bool {
            guard !parent.hasMoreLaterMessages else { return false }
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

        func beginPerformanceBenchmarkPaginationIntent(towardLater: Bool) {
            if towardLater {
                isLaterHistoryScrollGestureActive = true
                hasLaterHistoryScrollIntent = true
                hasIssuedLaterHistoryRequest = parent.isLoadingLater
            } else {
                isEarlierHistoryScrollGestureActive = true
                hasEarlierHistoryScrollIntent = true
                hasIssuedEarlierHistoryRequest = parent.isLoadingEarlier
            }
        }

        func endPerformanceBenchmarkPaginationIntent(towardLater: Bool) {
            if towardLater {
                isLaterHistoryScrollGestureActive = false
                hasLaterHistoryScrollIntent = false
            } else {
                isEarlierHistoryScrollGestureActive = false
                hasEarlierHistoryScrollIntent = false
            }
        }
}
