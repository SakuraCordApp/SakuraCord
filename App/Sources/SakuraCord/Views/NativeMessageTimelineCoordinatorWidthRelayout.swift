import AppKit
import SakuraCordModels

nonisolated enum NativeTimelineWidthRelayoutPolicy {
    static let asynchronousRowThreshold = 32

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

extension NativeMessageTimelineCoordinator {
        func applyImmediateWidthRelayout(
            _ width: CGFloat,
            preparedLayouts: [NativeTimelineRowLayout]?,
            to canvas: NativeTimelineCanvasView,
            in scrollView: NSScrollView
        ) {
            previewLayoutWidth = nil
            previewedRowIdentifiers.removeAll()
            rowsPreviewedAtCurrentWidth.removeAll()
            let metrics = NativeTimelineRowLayout.Metrics(source: parent.model)
            layouts = preparedLayouts ?? items.map { layout(for: $0, width: width, metrics: metrics) }
            layoutWidth = width
            rowHeights = layouts.map(\.height)
            rebuildOrigins()
            applySnapshot(to: canvas, in: scrollView)
        }

        func applyVisibleWidthPreview(
            _ width: CGFloat,
            resetsRows: Bool,
            to canvas: NativeTimelineCanvasView,
            in scrollView: NSScrollView
        ) {
            previewLayoutWidth = width
            if resetsRows { rowsPreviewedAtCurrentWidth.removeAll() }
            previewVisibleRows(at: width)
            applySnapshot(to: canvas, in: scrollView, viewportWidth: width)
        }

        func visiblePreviewRange() -> Range<Int>? {
            guard let visibleRange = visibleItemRangeForWidthRelayout() else {
                return nil
            }
            let lowerBound = max(0, visibleRange.lowerBound - 4)
            let upperBound = min(items.count, visibleRange.upperBound + 4)
            return lowerBound ..< upperBound
        }

        func visibleRowsNeedPreview() -> Bool {
            guard let range = visiblePreviewRange() else { return false }
            return range.contains { !rowsPreviewedAtCurrentWidth.contains(items[$0].identifier) }
        }

        func previewVisibleRows(at width: CGFloat) {
            guard let range = visiblePreviewRange() else { return }
            let metrics = NativeTimelineRowLayout.Metrics(source: parent.model)
            var didReflow = false
            for index in range {
                let identifier = items[index].identifier
                guard !rowsPreviewedAtCurrentWidth.contains(identifier) else {
                    continue
                }
                let rowLayout = layout(for: items[index], width: width, metrics: metrics)
                layouts[index] = rowLayout
                rowHeights[index] = rowLayout.height
                previewedRowIdentifiers.insert(identifier)
                rowsPreviewedAtCurrentWidth.insert(identifier)
                didReflow = true
            }
            if didReflow { rebuildOrigins() }
        }

        func restorePreviewedRows() {
            for index in items.indices
            where previewedRowIdentifiers.contains(items[index].identifier) {
                let rowLayout = layout(for: items[index], width: layoutWidth)
                layouts[index] = rowLayout
                rowHeights[index] = rowLayout.height
            }
            previewedRowIdentifiers.removeAll()
            rowsPreviewedAtCurrentWidth.removeAll()
            rebuildOrigins()
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
            // A workspace motion reschedules this on every frame, so only its
            // final width ever runs, as soon as the motion settles; the pause
            // is for live window resizes, which end without notice.
            let debounces = !WorkspaceLayoutMotion.isMoving
            widthRelayoutTask = Task { @MainActor [weak self] in
                if debounces {
                    do {
                        try await Task.sleep(for: .milliseconds(120))
                    } catch {
                        return
                    }
                }
                // A width change from a workspace motion reflows every row;
                // wait until the motion has its frames.
                await WorkspaceLayoutMotion.untilSettled()
                guard !Task.isCancelled, let self,
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
            let metrics = NativeTimelineRowLayout.Metrics(source: parent.model)
            let sourceConversation = parent.conversation
            let sourceTimestampDay = timestampDay
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
                var sliceStart = ProcessInfo.processInfo.systemUptime
                for index in indexes {
                    guard !Task.isCancelled,
                          self.widthRelayoutGeneration == generation,
                          self.pendingLayoutWidth == width,
                          self.parent.conversation == sourceConversation
                    else { return }
                    prepared[index] = self.layout(for: sourceItems[index], width: width, metrics: metrics)
                    if ProcessInfo.processInfo.systemUptime - sliceStart >= 0.0015 {
                        // Give AppKit a run-loop turn to draw. Task.yield() can
                        // immediately resume this main-actor job instead.
                        do {
                            try await Task.sleep(for: .milliseconds(1))
                        } catch {
                            return
                        }
                        sliceStart = ProcessInfo.processInfo.systemUptime
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
                    sourceTimestampDay == Calendar.autoupdatingCurrent.startOfDay(for: .now)
                        && self.parent.presentationRevision == sourcePresentationRevision
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
            guard let canvas, let scrollView,
                  !items.isEmpty,
                  let first = canvas.rowIndex(at: scrollView.contentView.bounds.minY)
            else { return nil }
            let last = canvas.rowIndex(at: scrollView.contentView.bounds.maxY)
                ?? (items.count - 1)
            return first ..< min(items.count, max(first + 1, last + 1))
        }
}
