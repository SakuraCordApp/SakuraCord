import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    func apply(
        storage: NativeTimelineCanvasStorage,
        model: AppModel,
        actions: NativeTimelineRowActions,
        viewportWidth: CGFloat,
        minimumHeight: CGFloat,
        bottomSpacerHeight: CGFloat,
        contentOriginY: CGFloat,
        historySkeleton: TimelineHistorySkeletonPresentation? = nil
    ) {
        precondition(storage.items.count == storage.layouts.count)
        precondition(storage.items.count == storage.rowOrigins.count)
        let previousContentOriginY = self.contentOriginY
        let contentOriginMoved: Bool
        // The coordinator and canvas intentionally share storage to avoid
        // copying thousands of rows. The coordinator mutates that storage
        // before calling apply, so a snapshot taken here is already the new
        // value. Consume the snapshot captured before the shared mutation.
        let reactionCountsBeforeUpdate =
            pendingReactionCountSnapshot ?? reactionCountSnapshot()
        pendingReactionCountSnapshot = nil
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        self.storage = storage
        self.model = model
        installSpoilerRevealStore(model.timelineSpoilerRevealStore)
        self.actions = actions
        baseContentOriginY = contentOriginY
        self.minimumHeight = max(1, minimumHeight)
        self.bottomSpacerHeight = max(0, bottomSpacerHeight)
        let previousHistorySkeleton = self.historySkeleton
        self.historySkeleton = historySkeleton
        // A conversation can disappear while its edit overlay is still
        // installed (for example, closing a supplementary thread). Reconcile
        // the cached edit index against the replacement storage before any
        // transient geometry reads it.
        reconcileEditingRow()
        self.contentOriginY = transientContentOriginY
        contentOriginMoved =
            abs(previousContentOriginY - self.contentOriginY) >= 0.5
        if activeMentionPopoverAnchor?.sourceRect() == nil {
            closeMentionPopover()
        }
        if let selection = textSelection {
            let selectionValue = storage.items.firstIndex(where: {
                $0.identifier == selection.itemIdentifier
            }).flatMap { index -> NSAttributedString? in
                guard storage.layouts.indices.contains(index) else {
                    return nil
                }
                return selectableTextRegions(
                    for: storage.items[index],
                    layout: storage.layouts[index]
                ).first(where: {
                    $0.region == selection.region
                })?.value
            }
            if selectionValue == nil
                || NSMaxRange(selection.range)
                    > (selectionValue?.length ?? 0)
            {
                textSelection = nil
                textSelectionGesture = nil
            }
        }
        let size = NSSize(
            width: max(1, viewportWidth),
            height: max(displayedContentHeight, self.minimumHeight)
        )
        applyDocumentSize(size)
        // A short timeline moves every row when its bottom-anchored origin
        // changes. Invalidating only an appended row leaves the old pixels
        // behind until a later footer/layout pass, which looks like rows
        // slowly sliding through and over one another.
        if contentOriginMoved {
            contentOriginInvalidationCount += 1
            needsDisplay = true
        }
        if previousHistorySkeleton != historySkeleton {
            // The canvas uses a bounded viewport-sized backing layer. A
            // skeleton can disappear while its former document coordinates
            // are simultaneously becoming real rows, so a targeted union can
            // miss stale pixels after the viewport window moves. Redrawing
            // the bounded canvas clears that transition without touching the
            // rest of the virtual document.
            needsDisplay = true
            reconcileHistorySkeletonShimmer()
        }
        reconcileReactionCountAnimations(
            storedBeforeUpdate: reactionCountsBeforeUpdate
        )
        scheduleInitialReactionCountCapture()
        reconcileVisibleReactionPreviewLoads()
        startVisibleInlineVideosImmediately()
        scheduleAnimatedMediaReconciliation()
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        reconcileLoadingIndicators()
        reconcileSpoilerOverlays()
        if !suppressesHoverPresentation {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if !suppressesHoverPresentation {
            reconcileAccessibilityProxies()
        }
        reconcileReactionHover()
        reconcileActionCapsule()
        if !suppressesHoverPresentation {
            synchronizeHoverWithCurrentPointer()
        }
        redrawMovedShortContentSynchronously(
            from: previousContentOriginY,
            contentOriginMoved: contentOriginMoved
        )
    }

    func updateHistorySkeleton(
        _ presentation: TimelineHistorySkeletonPresentation?
    ) {
        guard historySkeleton != presentation else { return }
        historySkeleton = presentation
        // The backing layer is only the viewport plus bounded overscan. Clear
        // that bounded surface whenever provisional history appears,
        // disappears, or belongs to a different conversation so no stale
        // placeholder pixels can survive into materialized rows.
        needsDisplay = true
        reconcileHistorySkeletonShimmer()
    }

    func reconcileHistorySkeletonShimmer() {
        historySkeletonShimmerTask?.cancel()
        historySkeletonShimmerTask = nil
        guard historySkeleton != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }

        historySkeletonShimmerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let frame = self?.historySkeleton?.frame
                else { return }
                self?.setNeedsDisplay(frame)
                do {
                    try await Task.sleep(
                        for: .seconds(
                            SkeletonShimmerStyle.minimumFrameInterval
                        )
                    )
                } catch {
                    return
                }
            }
        }
    }

    func updateContentOriginY(
        _ value: CGFloat,
        minimumHeight: CGFloat,
        bottomSpacerHeight: CGFloat
    ) {
        let oldOriginY = contentOriginY
        let oldMinimumHeight = self.minimumHeight
        let oldBottomSpacerHeight = self.bottomSpacerHeight
        baseContentOriginY = value
        self.minimumHeight = max(1, minimumHeight)
        self.bottomSpacerHeight = max(0, bottomSpacerHeight)
        contentOriginY = transientContentOriginY
        guard abs(oldOriginY - contentOriginY) >= 0.5
                || abs(oldMinimumHeight - self.minimumHeight) >= 0.5
                || abs(oldBottomSpacerHeight - self.bottomSpacerHeight) >= 0.5
        else { return }
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        let size = NSSize(
            width: max(1, frame.width),
            height: max(displayedContentHeight, self.minimumHeight)
        )
        applyDocumentSize(size)
        if !suppressesHoverPresentation {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if !suppressesHoverPresentation {
            reconcileAccessibilityProxies()
        }
        reconcileReactionHover()
        reconcileActionCapsule()
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        positionInlineVideoOverlays()
        positionLottieStickerOverlays()
        reconcileLoadingIndicators()
        positionSpoilerOverlays()
        needsDisplay = true
        if !suppressesHoverPresentation {
            synchronizeHoverWithCurrentPointer()
        }
        redrawMovedShortContentSynchronously(
            from: oldOriginY,
            contentOriginMoved:
                abs(oldOriginY - contentOriginY) >= 0.5
        )
    }

    func redrawMovedShortContentSynchronously(
        from previousContentOriginY: CGFloat,
        contentOriginMoved: Bool
    ) {
        guard contentOriginMoved,
              window != nil,
              max(previousContentOriginY, contentOriginY)
                > ChatDetailLayoutPolicy.timelineTopPadding + 0.5
        else { return }
        // Bottom-aligned timelines move every existing row when a live
        // message consumes some of their leading space. With
        // `.onSetNeedsDisplay`, AppKit is allowed to preserve the old backing
        // pixels until the next display transaction. A pointer event can
        // invalidate only the newly positioned row first, leaving a duplicate
        // of that row at its former location. Short timelines cover at most
        // one viewport, so finish this bounded redraw before hover tracking is
        // allowed to paint a partial row.
        synchronousShortContentRedrawCount += 1
        displayIfNeeded()
    }

    func captureReactionCountsBeforeStorageMutation() {
        pendingReactionCountSnapshot = reactionCountSnapshot()
    }

    func invalidateRows(_ indexes: IndexSet) {
        for index in indexes where items.indices.contains(index) {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func invalidateVisibleContent() {
        setNeedsDisplay(visibleRect)
    }

    func invalidatePresentationCaches() {
        pointer.cancelPrewarming()
        clearBitmapCache(keepingCapacity: true)
        bitmapInsertionOrder.removeAll(keepingCapacity: true)
        bitmapEvictionIndex = 0
        bitmapCost = 0
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        presentationCacheInvalidationCount += 1
        needsDisplay = true
    }

    /// A channel switch replaces pointer geometry and transient hover state,
    /// but it does not make an otherwise identical row bitmap stale. Message
    /// snowflakes are globally unique, and `cachedBitmap(for:width:)` also
    /// validates the complete item, width, and appearance before reuse. Keep
    /// those bounded bitmaps warm so returning to a recent conversation does
    /// not synchronously raster every visible CoreText row again.
    func invalidateConversationTransientCaches() {
        pointer.cancelPrewarming()
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    func dismissHoverPresentationForScroll() {
        // Prewarming is idle work. A scroll can begin after a programmatic
        // position request has queued it but before that main-actor task gets
        // its first turn. Cancel it at the activity boundary so a cold bitmap
        // raster cannot block the first scrolling frames.
        pointer.cancelPrewarming()
        // Bounds changes arrive for every momentum-scroll tick. All teardown
        // and playback suppression below must happen only at the transition
        // into scrolling, never for each tick.
        guard !suppressesHoverPresentation else { return }
        suppressesHoverPresentation = true
        // Pause native playback once without destroying its presentation.
        // Recreating AVPlayer and Lottie overlays on each reconciliation
        // produced the benchmark's regular FAST/pause cadence, while removing
        // them made otherwise loaded videos and stickers blink out as soon as
        // scrolling began. Retaining the bounded overlays preserves their
        // current frames and avoids both costs.
        for overlay in inlineVideoOverlays.values {
            overlay.pauseForScroll()
        }
        for overlay in lottieStickerOverlays.values {
            overlay.pauseForScroll()
        }
        for overlay in animatedMediaOverlays.values {
            overlay.setPlaybackSuppressed(true)
        }
        // Setting the flag only prevents future installation. Existing
        // in-visible-rect areas otherwise remain registered, so AppKit walks
        // and hit-tests the moving timeline under a stationary pointer on
        // every scroll transaction even though no hover can be presented.
        // Tear them and their cursor regions down immediately.
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        cancelReactionCountAnimations()
        animatedMediaReconcileTask?.cancel()
        animatedMediaReconcileTask = nil
        NativeTimelineMediaStore.shared.cancelAnimatedRequests(
            owner: visibleMediaPinOwner
        )
        let clearedTargets = pointer.clearHoverAndPressTargets()
        reactionHoverCoordinator.close()
        closeMessageProfilePopover()
        removeActionCapsule()
        freezeEditingRowForScroll()
        reconcileAccessibilityProxies()
        if let old = clearedTargets.row {
            setNeedsDisplay(rowFrame(at: old))
        }
        if let oldCompactTimestamp = clearedTargets.compactTimestampRow,
           oldCompactTimestamp != clearedTargets.row {
            setNeedsDisplay(rowFrame(at: oldCompactTimestamp))
        }
        if let oldMention = clearedTargets.mention,
           let oldMentionIndex = items.firstIndex(where: {
               $0.identifier == oldMention.itemIdentifier
           }),
           oldMentionIndex != clearedTargets.row,
           oldMentionIndex != clearedTargets.compactTimestampRow
        {
            setNeedsDisplay(rowFrame(at: oldMentionIndex))
        }
        if let oldTextLink = clearedTargets.textLink,
           let oldTextLinkIndex = items.firstIndex(where: {
               $0.identifier == oldTextLink.itemIdentifier
           }),
           oldTextLinkIndex != clearedTargets.row,
           oldTextLinkIndex != clearedTargets.compactTimestampRow
        {
            setNeedsDisplay(rowFrame(at: oldTextLinkIndex))
        }
        if let oldTextSpoiler = clearedTargets.textSpoiler,
           let oldTextSpoilerIndex = items.firstIndex(where: {
               $0.identifier == oldTextSpoiler.itemIdentifier
           }),
           oldTextSpoilerIndex != clearedTargets.row,
           oldTextSpoilerIndex != clearedTargets.compactTimestampRow
        {
            setNeedsDisplay(rowFrame(at: oldTextSpoilerIndex))
        }
        if let oldCodeBlock = clearedTargets.codeBlock,
           let oldCodeBlockIndex = items.firstIndex(where: {
               $0.identifier == oldCodeBlock.itemIdentifier
           }),
           oldCodeBlockIndex != clearedTargets.row,
           oldCodeBlockIndex != clearedTargets.compactTimestampRow
        {
            setNeedsDisplay(rowFrame(at: oldCodeBlockIndex))
        }
        if let oldComponentButton = clearedTargets.componentButton {
            invalidateComponentButton(oldComponentButton)
        }
    }

    func allowHoverPresentationAfterScroll() {
        suppressesHoverPresentation = false
        for overlay in animatedMediaOverlays.values {
            overlay.setPlaybackSuppressed(false)
        }
        refreshVisibleMediaPins()
        reconcileVisibleReactionPreviewLoads()
        restoreEditingRowAfterScroll()
        reconcileAnimatedMedia()
        reconcileLoadingIndicators()
        reconcileSpoilerOverlays()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        reconcileAccessibilityProxies()
        synchronizeHoverWithCurrentPointer()
    }

    func setMediaViewerInteractionBlocked(_ isBlocked: Bool) {
        guard mediaViewerBlocksInteractions != isBlocked else { return }
        mediaViewerBlocksInteractions = isBlocked
        if isBlocked {
            pointer.clearHoverAndPressTargets()
            reactionHoverCoordinator.close()
            closeMessageProfilePopover()
            closeMentionPopover()
            closeComponentChoicePopover()
            removeActionCapsule()
            needsDisplay = true
        }
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    func installViewportGeometry(frame: CGRect, bounds: CGRect) {
        if self.bounds != bounds {
            self.bounds = bounds
            // A fast gesture can replace the entire overscanned window in one
            // event. Explicitly request the new bounded backing contents so
            // Core Animation never presents an empty document slice while
            // waiting for an unrelated invalidation.
            needsDisplay = true
        }
        if self.frame != frame {
            // `setFrameSize` invokes `onWidthChange` synchronously. That
            // callback can relayout the timeline and recursively install a
            // newer document-sized viewport. Installing this pass's bounds
            // first ensures it cannot overwrite those corrected bounds after
            // the callback returns. Before this ordering, the first scroll
            // event repaired the stale launch geometry, making the content
            // visibly jump into place.
            self.frame = frame
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) >= 1 {
            onWidthChange?(newSize.width)
        }
        positionEditingRow()
        positionActionCapsule()
        positionAnimatedMediaOverlays()
        positionInlineVideoOverlays()
        positionLottieStickerOverlays()
        reconcileLoadingIndicators()
        positionSpoilerOverlays()
    }

    func applyDocumentSize(_ size: NSSize) {
        if usesViewportSizedBacking {
            onDocumentSizeChange?(size)
        } else if frame.size != size {
            super.setFrameSize(size)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelReactionPreviewLoads()
            mediaInvalidationTask?.cancel()
            mediaInvalidationTask = nil
            pendingMediaInvalidations.removeAll(keepingCapacity: false)
            NativeTimelineMediaStore.shared.removeStaticRequests(
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared.releaseVisibleImages(
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared.releasePinnedImages(
                owner: visibleMediaPinOwner
            )
            NativeTimelineMediaStore.shared.cancelAnimatedRequests(
                owner: visibleMediaPinOwner
            )
            clearBitmapCache(keepingCapacity: false)
            bitmapInsertionOrder.removeAll(keepingCapacity: false)
            bitmapEvictionIndex = 0
            bitmapCost = 0
            removeReactionMouseMonitor()
            cancelReactionCountAnimations()
            reactionCountBaselineTask?.cancel()
            reactionCountBaselineTask = nil
            animatedMediaReconcileTask?.cancel()
            animatedMediaReconcileTask = nil
            animatedMediaRows.removeAll()
            inlineVideoRows.removeAll()
            lottieStickerRows.removeAll()
            removeInlineVideoOverlays()
            removeLottieStickerOverlays()
            removeAnimatedMediaOverlays()
            removeLoadingIndicators()
            removeSpoilerOverlays()
            reactionPickerCoordinator.close(notifyBinding: false)
            reactionHoverCoordinator.close()
            closeMessageProfilePopover()
            closeComponentChoicePopover()
            closeMentionPopover()
            reactionPickerSource.frame = .zero
            pointer.clearHoverAndPressTargets()
            removeAccessibilityProxies()
            removeActionCapsule()
            endEditing(commit: nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installReactionMouseMonitor()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.reconcileAccessibilityProxies()
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.reconcileAccessibilityProxies()
            }
        }
    }

    func rowFrame(at index: Int) -> CGRect {
        guard items.indices.contains(index) else { return .zero }
        return CGRect(
            x: 0,
            y: displayedRowOrigin(at: index),
            width: bounds.width,
            height: displayedRowHeight(at: index)
        )
    }

    func rowIndex(at documentY: CGFloat) -> Int? {
        guard !rowOrigins.isEmpty else { return nil }
        var lower = 0
        var upper = rowOrigins.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if displayedRowOrigin(at: middle) + displayedRowHeight(at: middle)
                <= documentY
            {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return items.indices.contains(lower) ? lower : nil
    }

    func firstVisibleMessage(
        in rect: CGRect,
        preferringVisibleOrigin: Bool = false
    ) -> (MessageID, CGFloat)? {
        guard var index = rowIndex(at: rect.minY) else { return nil }
        var intersectingMessage: (MessageID, CGFloat)?
        while items.indices.contains(index) {
            if let id = items[index].messageID {
                let offset = displayedRowOrigin(at: index) - rect.minY
                if intersectingMessage == nil {
                    intersectingMessage = (id, offset)
                }
                if !preferringVisibleOrigin
                    || (offset >= 0 && offset < rect.height)
                {
                    return (id, offset)
                }
            }
            index += 1
        }
        return intersectingMessage
    }

    var drawOperation: @MainActor (NSRect) -> Void {
        { [self] dirtyRect in
        let startUptime = ProcessInfo.processInfo.systemUptime
        defer {
            maximumDrawDuration = max(
                maximumDrawDuration,
                ProcessInfo.processInfo.systemUptime - startUptime
            )
        }
        drawSuperclassContent(in: dirtyRect)
        refreshVisibleMediaPins()
        reconcileVisibleReactionPreviewLoads()
        // This view is transparent and layer-backed. Core Graphics does not
        // guarantee that invalidating a region clears its previous backing
        // pixels before draw(_:). Clear first so bottom-origin changes cannot
        // composite newly positioned rows over their former positions.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        drawHistorySkeleton(in: dirtyRect)
        guard !items.isEmpty,
              var index = rowIndex(at: max(0, dirtyRect.minY))
        else { return }

        while items.indices.contains(index),
              displayedRowOrigin(at: index) < dirtyRect.maxY
        {
            let rowFrame = rowFrame(at: index)
            if rowFrame.intersects(dirtyRect) {
                let revealedTextSpoilerState =
                    textSpoilerRevealState(
                        for: items[index].identifier
                    )
                if items[index].messageID == editingMessageID {
                    NSGraphicsContext.current?.cgContext.clear(
                        rowFrame.intersection(dirtyRect)
                    )
                    requestMedia(for: items[index], at: index)
                    NativeTimelineRowPainter.draw(
                        item: items[index],
                        layout: layouts[index],
                        in: rowFrame,
                        model: model,
                        isHovered: false,
                        hidesMessageContent: true,
                        spoilerRevealStore: spoilerRevealStore
                    )
                    if let snapshot = editingRowScrollSnapshot {
                        snapshot.draw(
                            in: editingOverlayFrame(at: index),
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: nil
                        )
                    }
                    index += 1
                    continue
                }
                requestMedia(for: items[index], at: index)
                let countTransitions = reactionCountTransitions(
                    inMessageAt: index
                )
                if hoveredRow == index
                    || hoveredCompactTimestampRow == index
                    || hoveredMention?.itemIdentifier
                        == items[index].identifier
                    || hoveredTextLink?.itemIdentifier
                        == items[index].identifier
                    || hoveredTextSpoiler?.itemIdentifier
                        == items[index].identifier
                    || hoveredComponentButton?.messageID
                        == items[index].messageID
                    || visualPressedComponentButton?.messageID
                        == items[index].messageID
                    || !countTransitions.isEmpty
                    || textSelection?.itemIdentifier
                        == items[index].identifier
                    || !revealedTextSpoilerState.isEmpty
                {
                    NativeTimelineRowPainter.draw(
                        item: items[index],
                        layout: layouts[index],
                        in: rowFrame,
                        model: model,
                        isHovered: hoveredRow == index,
                        showsCompactTimestamp:
                            hoveredCompactTimestampRow == index,
                        hoveredMention:
                            hoveredMention?.itemIdentifier
                                == items[index].identifier
                            ? hoveredMention
                            : nil,
                        hoveredTextLink:
                            hoveredTextLink?.itemIdentifier
                                == items[index].identifier
                            ? hoveredTextLink
                            : nil,
                        hoveredTextSpoiler:
                            hoveredTextSpoiler?.itemIdentifier
                                == items[index].identifier
                            ? hoveredTextSpoiler
                            : nil,
                        hoveredComponentButton:
                            hoveredComponentButton?.messageID
                                == items[index].messageID
                            ? hoveredComponentButton
                            : nil,
                        pressedComponentButton:
                            visualPressedComponentButton?.messageID
                                == items[index].messageID
                            ? visualPressedComponentButton
                            : nil,
                        componentButtonPressProgress:
                            visualPressedComponentButton?.messageID
                                == items[index].messageID
                            ? componentButtonPressProgress
                            : 0,
                        hoveredReactionID: hoveredReactionID(
                            inMessageAt: index
                        ),
                        isAddReactionHovered: isAddReactionHovered(
                            inMessageAt: index
                        ),
                        textSelection: textSelection,
                        revealedTextSpoilerState:
                            revealedTextSpoilerState,
                        spoilerRevealStore: spoilerRevealStore,
                        reactionCountTransitions: countTransitions
                    )
                } else {
                    let cachedBitmap = cachedBitmap(
                        for: items[index],
                        width: rowFrame.width
                    )
                    if NativeTimelineScrollingRenderPolicy
                        .usesDirectPainter(
                            isScrolling: suppressesHoverPresentation,
                            hasCachedBitmap: cachedBitmap != nil
                        )
                    {
                        NativeTimelineRowPainter.draw(
                            item: items[index],
                            layout: layouts[index],
                            in: rowFrame,
                            model: model,
                            isHovered: false,
                            revealedTextSpoilerState:
                                revealedTextSpoilerState,
                            spoilerRevealStore: spoilerRevealStore
                        )
                    } else {
                        (cachedBitmap ?? bitmap(
                            for: items[index],
                            at: index,
                            layout: layouts[index],
                            width: rowFrame.width
                        )).draw(
                            in: rowFrame,
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: nil
                        )
                    }
                }
                if let hoveredCodeBlock,
                   hoveredCodeBlock.itemIdentifier
                    == items[index].identifier
                {
                    drawCodeBlockCopyControl(hoveredCodeBlock)
                }
            }
            index += 1
        }

        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawOperation(dirtyRect)
        if let presentedConversationID {
            AppPerformanceSignposts.reportConversationFirstFrame(
                channelID: presentedConversationID
            )
        }
    }

    func drawCodeBlockCopyControl(
        _ target: NativeTimelineCodeBlockPointerTarget
    ) {
        let buttonFrame = target.copyButtonFrame
        let point = currentMouseLocationInCanvas()
        let isButtonHovered = buttonFrame.contains(point)
        if isButtonHovered
            || pressedCodeBlockCopyButton?.itemIdentifier
                == target.itemIdentifier
                && pressedCodeBlockCopyButton?.region == target.region
                && pressedCodeBlockCopyButton?.rangeLocation
                    == target.rangeLocation
        {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                concentricRoundedRect: buttonFrame,
                cornerRadius: 4
            ).fill()
        }
        guard let symbol = NSImage(
            systemSymbolName: "doc.on.doc.fill",
            accessibilityDescription: "Copy code"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: 16,
                weight: .regular
            )
            .applying(
                NSImage.SymbolConfiguration(
                    paletteColors: [
                        NSColor.labelColor.withAlphaComponent(
                            isButtonHovered ? 1 : 0.88
                        ),
                    ]
                )
            )
        ) else { return }
        let iconFrame = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: symbol.size,
            alignmentRect: symbol.alignmentRect,
            in: buttonFrame.insetBy(dx: 6, dy: 6)
        )
        symbol.draw(
            in: iconFrame,
            from: .zero,
            operation: .sourceOver,
            fraction: isButtonHovered ? 1 : 0.88,
            respectFlipped: true,
            hints: nil
        )
    }

    func textSpoilerRevealState(
        for identifier: NativeMessageTimelineItem.Identifier
    ) -> NativeTimelineTextSpoilerRevealState {
        var result = NativeTimelineTextSpoilerRevealState()
        guard let rowIndex = items.firstIndex(where: {
            $0.identifier == identifier
        }),
           layouts.indices.contains(rowIndex),
           let messageID = items[rowIndex].messageID
        else { return result }
        for selectable in selectableTextRegions(
            for: items[rowIndex],
            layout: layouts[rowIndex]
        ) {
            guard let contentID = textSpoilerContentID(
                for: selectable.region,
                layout: layouts[rowIndex]
            ) else { continue }
            for location in spoilerRevealStore.revealedTextLocations(
                messageID: messageID,
                contentID: contentID,
                contentHash: selectable.value.string.hashValue
            ) {
                result.reveal(
                    region: selectable.region,
                    rangeLocation: location
                )
            }
        }
        return result
    }

    func textSpoilerRevealKey(
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        rangeLocation: Int
    ) -> NativeTimelineTextSpoilerRevealKey? {
        guard let rowIndex = items.firstIndex(where: {
            $0.identifier == itemIdentifier
        }),
           layouts.indices.contains(rowIndex),
           let messageID = items[rowIndex].messageID,
           let selectable = selectableTextRegions(
               for: items[rowIndex],
               layout: layouts[rowIndex]
           ).first(where: { $0.region == region }),
           let contentID = textSpoilerContentID(
               for: region,
               layout: layouts[rowIndex]
           )
        else { return nil }
        return NativeTimelineTextSpoilerRevealKey(
            messageID: messageID,
            contentID: contentID,
            contentHash: selectable.value.string.hashValue,
            rangeLocation: rangeLocation
        )
    }

    func textSpoilerContentID(
        for region: NativeTimelineTextRegion,
        layout: NativeTimelineRowLayout
    ) -> String? {
        switch region {
        case .beginningTitle, .beginningDescription:
            return nil
        case .content:
            return "message-content"
        case let .embed(embedID, textIndex):
            return "embed:\(embedID):\(textIndex)"
        case let .component(layoutIndex, textIndex):
            guard layout.componentLayouts.indices.contains(layoutIndex),
                  layout.componentLayouts[layoutIndex]
                      .textRegions.indices.contains(textIndex)
            else { return nil }
            return "component:"
                + (
                    layout.componentLayouts[layoutIndex]
                        .textRegions[textIndex].contentID
                        ?? "\(layoutIndex):\(textIndex)"
                )
        }
    }

    func drawHistorySkeleton(in dirtyRect: CGRect) {
        guard let presentation = historySkeleton,
              presentation.frame.intersects(dirtyRect)
        else { return }

        let frame = presentation.frame
        let clipped = frame.intersection(dirtyRect)
        guard !clipped.isNull, clipped.height > 0 else { return }

        let rowStride: CGFloat = 76
        let rowCount = max(1, Int(ceil(frame.height / rowStride)))
        let firstOrdinal = max(
            0,
            Int(floor((frame.maxY - clipped.maxY) / rowStride))
        )
        let lastOrdinal = min(
            rowCount - 1,
            max(
                firstOrdinal,
                Int(ceil((frame.maxY - clipped.minY) / rowStride))
            )
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clipped).addClip()
        let shimmerMask = NSBezierPath()

        for ordinal in firstOrdinal ... lastOrdinal {
            let rowTop =
                frame.maxY - CGFloat(ordinal + 1) * rowStride
            drawHistorySkeletonRow(
                ordinal: ordinal,
                rowTop: rowTop,
                frameWidth: frame.width,
                shimmerMask: shimmerMask
            )
        }

        drawHistorySkeletonShimmer(mask: shimmerMask, in: frame)
    }

    private func drawHistorySkeletonRow(
        ordinal: Int,
        rowTop: CGFloat,
        frameWidth: CGFloat,
        shimmerMask: NSBezierPath
    ) {
        let contentX: CGFloat = 64
        let maximumContentWidth = max(80, frameWidth - contentX - 14)
        let authorWidths: [CGFloat] = [92, 126, 108, 148]
        let lineFractions: [[CGFloat]] = [
            [0.72],
            [0.91, 0.58],
            [0.84, 0.76, 0.42],
            [0.64, 0.88],
        ]
        let avatarPath = NSBezierPath(ovalIn: CGRect(
            x: 14,
            y: rowTop + 11,
            width: 38,
            height: 38
        ))
        NSColor.placeholderTextColor.withAlphaComponent(0.18).setFill()
        avatarPath.fill()
        shimmerMask.append(avatarPath)

        let authorWidth = min(
            maximumContentWidth * 0.45,
            authorWidths[ordinal % authorWidths.count]
        )
        let authorPath = NSBezierPath(
            roundedRect: CGRect(
                x: contentX,
                y: rowTop + 10,
                width: authorWidth,
                height: 10
            ),
            xRadius: 5,
            yRadius: 5
        )
        NSColor.placeholderTextColor.withAlphaComponent(0.16).setFill()
        authorPath.fill()
        shimmerMask.append(authorPath)

        let timestampPath = NSBezierPath(
            roundedRect: CGRect(
                x: contentX + authorWidth + 8,
                y: rowTop + 12,
                width: 38,
                height: 7
            ),
            xRadius: 3.5,
            yRadius: 3.5
        )
        NSColor.placeholderTextColor.withAlphaComponent(0.11).setFill()
        timestampPath.fill()
        shimmerMask.append(timestampPath)

        let fractions = lineFractions[ordinal % lineFractions.count]
        for (line, fraction) in fractions.enumerated() {
            let linePath = NSBezierPath(
                roundedRect: CGRect(
                    x: contentX,
                    y: rowTop + 28 + CGFloat(line) * 13,
                    width: max(34, maximumContentWidth * fraction),
                    height: 8
                ),
                xRadius: 4,
                yRadius: 4
            )
            linePath.fill()
            shimmerMask.append(linePath)
        }
    }

    private func drawHistorySkeletonShimmer(
        mask: NSBezierPath,
        in frame: CGRect
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !mask.isEmpty,
              let gradient = NSGradient(
                  colorsAndLocations:
                  (.clear, 0),
                  (NSColor.labelColor.withAlphaComponent(0.18), 0.25),
                  (NSColor.labelColor.withAlphaComponent(0.92), 0.5),
                  (NSColor.labelColor.withAlphaComponent(0.18), 0.75),
                  (.clear, 1)
              )
        else { return }

        let width = max(frame.width, 1)
        let phase = SkeletonShimmerStyle.phase(at: Date())
        let bandFrame = CGRect(
            x: frame.minX
                + width
                    * (
                        SkeletonShimmerStyle.startingOffsetFraction
                            + SkeletonShimmerStyle.travelFraction * phase
                    ),
            y: frame.minY,
            width: width * SkeletonShimmerStyle.bandWidthFraction,
            height: frame.height
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        mask.addClip()
        gradient.draw(in: bandFrame, angle: 0)
    }

    func resetDrawTelemetry() {
        maximumDrawDuration = 0
        maximumRowRasterDuration = 0
        maximumRowRasterHeight = 0
    }

    func prewarmRows(above rect: CGRect, count: Int) {
        prewarmTask?.cancel()
        let boundedCount = min(count, Self.prewarmRowLimit)
        guard boundedCount > 0,
              let firstVisible = rowIndex(at: rect.minY),
              firstVisible > 0
        else {
            return
        }
        let lowerBound = max(0, firstVisible - boundedCount)
        let indexes = Array(stride(
            from: firstVisible - 1,
            through: lowerBound,
            by: -1
        ))
        prewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for index in indexes {
                guard !Task.isCancelled,
                      self.items.indices.contains(index),
                      self.layouts.indices.contains(index)
                else { return }
                // Prewarmed row bitmaps must participate in the same media
                // lifecycle as on-screen draws. Otherwise they can cache
                // placeholders before a row becomes visible and, when the
                // shared media store already has the image, no asynchronous
                // completion remains to invalidate that stale bitmap.
                self.requestMedia(
                    for: self.items[index],
                    at: index,
                    priority: .prefetch
                )
                _ = self.bitmap(
                    for: self.items[index],
                    at: index,
                    layout: self.layouts[index],
                    width: self.bounds.width
                )
                // `Task.yield()` may immediately resume the same main-actor
                // task, allowing dozens of full-width CoreText/Core Graphics
                // rasters to bunch up before the next presentation pass.
                // A short real delay keeps prewarming inside the benchmark's
                // existing warm-up window without producing a visible
                // launch-to-scroll hitch.
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return
                }
            }
        }
    }

    func bitmap(
        for item: NativeMessageTimelineItem,
        at index: Int,
        layout: NativeTimelineRowLayout,
        width: CGFloat
    ) -> NSImage {
        if let cached = cachedBitmap(for: item, width: width) {
            return cached
        }
        let appearanceName = effectiveAppearance.name

        let rasterStart = ProcessInfo.processInfo.systemUptime
        let size = NSSize(width: width, height: layout.height)
        let scale = max(
            1,
            window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
        )
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(layout.height * scale)))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else {
            return NSImage(size: size)
        }
        NSGraphicsContext.saveGraphicsState()
        graphics.cgContext.scaleBy(x: scale, y: scale)
        graphics.cgContext.translateBy(x: 0, y: layout.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        let flippedGraphics = NSGraphicsContext(
            cgContext: graphics.cgContext,
            flipped: true
        )
        NSGraphicsContext.current = flippedGraphics
        NativeTimelineRowPainter.draw(
            item: item,
            layout: layout,
            in: CGRect(origin: .zero, size: size),
            model: model,
            isHovered: false,
            spoilerRevealStore: spoilerRevealStore
        )
        flippedGraphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let rasterDuration =
            ProcessInfo.processInfo.systemUptime - rasterStart
        if rasterDuration > maximumRowRasterDuration {
            maximumRowRasterDuration = rasterDuration
            maximumRowRasterHeight = layout.height
        }

        let mediaPinOwner = UUID()
        NativeTimelineMediaStore.shared.pinLoadedImages(
            for: mediaKeys(for: item, at: index),
            owner: mediaPinOwner
        )
        let cost = max(1, Int(ceil(width * layout.height * 4 * scale * scale)))
        if let previous = bitmapCache[item.identifier] {
            bitmapCost -= previous.cost
            NativeTimelineMediaStore.shared.releasePinnedImages(
                owner: previous.mediaPinOwner
            )
        } else {
            bitmapInsertionOrder.append(item.identifier)
        }
        bitmapCache[item.identifier] = CachedRowBitmap(
            item: item,
            width: width,
            appearanceName: appearanceName,
            image: image,
            cost: cost,
            mediaPinOwner: mediaPinOwner
        )
        bitmapCost += cost
        evictBitmapsIfNeeded()
        return image
    }

    func cachedBitmap(
        for item: NativeMessageTimelineItem,
        width: CGFloat
    ) -> NSImage? {
        guard let cached = bitmapCache[item.identifier],
              cached.item == item,
              abs(cached.width - width) < 0.5,
              cached.appearanceName == effectiveAppearance.name
        else { return nil }
        return cached.image
    }

    func evictBitmapsIfNeeded() {
        while bitmapCost > Self.bitmapCostLimit,
              bitmapEvictionIndex < bitmapInsertionOrder.count
        {
            let identifier = bitmapInsertionOrder[bitmapEvictionIndex]
            bitmapEvictionIndex += 1
            if let removed = bitmapCache.removeValue(forKey: identifier) {
                bitmapCost -= removed.cost
                NativeTimelineMediaStore.shared.releasePinnedImages(
                    owner: removed.mediaPinOwner
                )
            }
        }
        if bitmapEvictionIndex > 1_024,
           bitmapEvictionIndex * 2 > bitmapInsertionOrder.count
        {
            bitmapInsertionOrder.removeFirst(bitmapEvictionIndex)
            bitmapEvictionIndex = 0
        }
    }

    func clearBitmapCache(keepingCapacity: Bool) {
        for cached in bitmapCache.values {
            NativeTimelineMediaStore.shared.releasePinnedImages(
                owner: cached.mediaPinOwner
            )
        }
        bitmapCache.removeAll(keepingCapacity: keepingCapacity)
    }

    func requestMedia(
        for item: NativeMessageTimelineItem,
        at index: Int,
        priority: MediaLoadPriority = .visible
    ) {
        let identifier = item.identifier
        let requestOwner = visibleMediaPinOwner
        let keys = mediaKeys(for: item, at: index)
        for key in keys {
            NativeTimelineMediaStore.shared.request(
                key,
                owner: requestOwner,
                subscriber: identifier,
                priority: priority
            ) { [weak self] _ in
                self?.scheduleMediaInvalidation(identifier)
            }
        }
    }

    func reconcileVisibleReactionPreviewLoads() {
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard window != nil,
              viewport.width > 0,
              viewport.height > 0,
              !items.isEmpty,
              !layouts.isEmpty,
              var index = rowIndex(at: max(0, viewport.minY))
        else {
            cancelReactionPreviewLoads()
            return
        }

        var desired:
            [ReactionPreviewLoadKey: (reaction: Reaction, message: Message)] = [:]
        while items.indices.contains(index),
              layouts.indices.contains(index),
              displayedRowOrigin(at: index) < viewport.maxY
        {
            if rowFrame(at: index).intersects(viewport),
               case let .message(row, _, _) = items[index]
            {
                let reactions = layouts[index].reactionRegions.map(\.reaction)
                for reaction in MessageReactionPresentation
                    .previewLoadCandidates(fromPresented: reactions)
                {
                    let key = ReactionPreviewLoadKey(
                        messageID: row.message.id,
                        reactionID: reaction.id
                    )
                    desired[key] = (reaction, row.message)
                }
            }
            index += 1
        }

        let obsolete = visibleReactionPreviewLoadKeys.subtracting(desired.keys)
        for key in obsolete {
            reactionPreviewLoadTasks.removeValue(forKey: key)?.cancel()
            visibleReactionPreviewLoadKeys.remove(key)
        }

        for (key, input) in desired
        where visibleReactionPreviewLoadKeys.insert(key).inserted
        {
            reactionPreviewLoadTasks[key] = Task { @MainActor [weak self] in
                guard let self,
                      self.visibleReactionPreviewLoadKeys.contains(key),
                      let model = self.model
                else { return }
                await model.loadReactionReactors(
                    input.reaction,
                    on: input.message
                )
            }
        }
    }

    func cancelReactionPreviewLoads() {
        for task in reactionPreviewLoadTasks.values {
            task.cancel()
        }
        reactionPreviewLoadTasks.removeAll(keepingCapacity: true)
        visibleReactionPreviewLoadKeys.removeAll(keepingCapacity: true)
    }

    func scheduleMediaInvalidation(
        _ identifier: NativeMessageTimelineItem.Identifier
    ) {
        pendingMediaInvalidations.insert(identifier)
        mediaInvalidationTask?.cancel()
        mediaInvalidationTask = Task { @MainActor [weak self] in
            do {
                // Gallery tiles frequently finish in the same display frame.
                // Collapse their row-wide bitmap rebuilds into one transaction.
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard let self else { return }
            self.mediaInvalidationTask = nil
            let identifiers = self.pendingMediaInvalidations
            self.pendingMediaInvalidations.removeAll(keepingCapacity: true)
            self.refreshVisibleMediaPins()
            var dirtyRect = CGRect.null
            for identifier in identifiers {
                self.invalidateBitmap(identifier)
                if let index = self.items.firstIndex(where: {
                    $0.identifier == identifier
                }) {
                    dirtyRect = dirtyRect.union(self.rowFrame(at: index))
                }
            }
            if !dirtyRect.isNull {
                self.setNeedsDisplay(dirtyRect)
            }
        }
    }

    func refreshVisibleMediaPins() {
        let viewport =
            enclosingScrollView?.documentVisibleRect ?? visibleRect
        guard viewport.height > 0,
              !items.isEmpty,
              !layouts.isEmpty,
              var index = rowIndex(at: max(0, viewport.minY))
        else {
            NativeTimelineMediaStore.shared.retainVisibleImages(
                for: [],
                owner: visibleMediaPinOwner
            )
            if pointer.suppressesHoverPresentation {
                NativeTimelineMediaStore.shared
                    .cancelStaticRequestsOutsideVisibleSet(
                        owner: visibleMediaPinOwner
                    )
            }
            return
        }

        var keys: Set<NativeTimelineMediaKey> = []
        while items.indices.contains(index),
              layouts.indices.contains(index),
              displayedRowOrigin(at: index) < viewport.maxY
        {
            if rowFrame(at: index).intersects(viewport) {
                keys.formUnion(mediaKeys(for: items[index], at: index))
            }
            index += 1
        }
        NativeTimelineMediaStore.shared.retainVisibleImages(
            for: keys,
            owner: visibleMediaPinOwner
        )
        if pointer.suppressesHoverPresentation {
            NativeTimelineMediaStore.shared
                .cancelStaticRequestsOutsideVisibleSet(
                    owner: visibleMediaPinOwner
                )
        }
    }

    var mediaKeysOperation:
        @MainActor (NativeMessageTimelineItem, Int?) -> Set<NativeTimelineMediaKey>
    {
        { [self] item, index in
        guard let index,
              layouts.indices.contains(index),
              case let .message(row, _, _) = item
        else { return [] }
        let message = row.message
        let visibleEmbedCount =
            MessageEmbedPresentation.visibleEmbeds(for: message).count
        var keys: [NativeTimelineMediaKey] = []
        keys.reserveCapacity(
            1 + message.attachments.count + visibleEmbedCount
                + message.stickers.count
        )
        let author = model?.authorPresentation(for: message)
        if let url = author?.user.avatarURL ?? message.author.avatarURL {
            keys.append(.avatar(url))
        }
        if let url =
            author?.user.avatarDecorationURL
                ?? message.author.avatarDecorationURL
        {
            keys.append(.avatarDecoration(url))
        }
        if let url = message.interactionMetadata?.user?.avatarURL {
            keys.append(.avatar(url))
        }
        if let preview = row.replyPreview,
           let url = model?.authorPresentation(for: preview).user.avatarURL {
            keys.append(.avatar(url))
        } else if let key = NativeTimelineReplyMediaPolicy.avatarKey(
            for: row.replyPreview
        ) {
            keys.append(key)
        }
        for region in layouts[index].linkedImageRegions {
            keys.append(.media(
                region.reference.displayURL,
                maximumPixelDimension: region.reference.isEmoji ? 96 : 720
            ))
        }
        if let model {
            let mentionResolver = MessageMentionResolver(
                model: model,
                message: message
            )
            for token in row.textPlan.preparedText?.tokens ?? [] {
                switch token {
                case let .customEmoji(emoji):
                    let reference = EmojiReference(rawToken: emoji.rawToken)
                    guard let url =
                        reference.id.flatMap({ model.customEmojiURLsByID[$0] })
                        ?? reference.imageURL(size: 64)
                    else { continue }
                    keys.append(.media(url, maximumPixelDimension: 64))
                case let .mention(mention):
                    if let url = mentionResolver.presentation(mention).avatarURL {
                        keys.append(.avatar(url))
                    }
                }
            }
        }
        for region in layouts[index].attachmentRegions {
            let attachment = region.attachment
            guard NativeTimelineSpoilerConcealmentPolicy
                .shouldLoadOrAnimate(
                    messageID: message.id,
                    contentID:
                        NativeTimelineComponentRevealKey
                            .attachmentComponentID(attachment.id),
                    isSpoiler: attachment.isSpoiler,
                    store: spoilerRevealStore
                )
            else { continue }
            switch attachment.mediaKind {
            case .image, .animatedImage:
                if let key = NativeTimelineMediaKey.attachment(attachment) {
                    keys.append(key)
                }
            case .video, .audio, .file:
                break
            }
        }
        for region in layouts[index].embedRegions {
            for image in region.imageRegions {
                keys.append(
                    .media(
                        image.url,
                        maximumPixelDimension: image.maximumPixelDimension
                    )
                )
            }
            for textRegion in region.textRegions {
                let value = textRegion.text.value
                let range = NSRange(location: 0, length: value.length)
                value.enumerateAttribute(
                    .discordEmojiToken,
                    in: range
                ) { rawValue, _, _ in
                    guard let rawToken = rawValue as? String else { return }
                    let reference = EmojiReference(rawToken: rawToken)
                    let customURL = reference.id.flatMap { id in
                        model?.customEmojiURLsByID[id]
                    }
                    guard let url = customURL
                        ?? reference.imageURL(size: 64)
                    else { return }
                    keys.append(.media(url, maximumPixelDimension: 64))
                }
                value.enumerateAttribute(
                    .nativeTimelineMention,
                    in: range
                ) { rawValue, _, _ in
                    guard let mention =
                        (rawValue as? NativeTimelineMentionBox)?
                        .presentation,
                        let url = mention.avatarURL
                    else { return }
                    keys.append(.avatar(url))
                }
            }
            if !region.mediaIsVideo,
               let url = region.mediaURL
            {
                keys.append(.media(url))
            }
        }
        for componentLayout in layouts[index].componentLayouts {
            let hiddenContainerFrames =
                NativeTimelineSpoilerConcealmentPolicy
                    .hiddenContainerFrames(
                        in: componentLayout,
                        messageID: message.id,
                        store: spoilerRevealStore
                    )
            for image in componentLayout.images {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        image.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    ),
                      !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                          messageID: message.id,
                          contentID: image.componentID,
                          isSpoiler: image.isSpoiler,
                          store: spoilerRevealStore
                      )
                else { continue }
                keys.append(
                    .media(
                        image.displayURL,
                        maximumPixelDimension: image.maximumPixelDimension
                    )
                )
            }
            for media in componentLayout.media {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        media.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    ),
                      !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                          messageID: message.id,
                          contentID: media.componentID,
                          isSpoiler: media.isSpoiler,
                          store: spoilerRevealStore
                      )
                else { continue }
                keys.append(.media(media.displayURL))
            }
            for button in componentLayout.buttons {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        button.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
                else { continue }
                guard let emoji = button.emoji,
                      emoji.id != nil,
                      let url = emoji.imageURL(size: 32)
                else { continue }
                keys.append(.media(url, maximumPixelDimension: 64))
            }
            for textRegion in componentLayout.textRegions {
                guard !NativeTimelineSpoilerConcealmentPolicy
                    .isInsideHiddenContainer(
                        textRegion.frame,
                        hiddenContainerFrames:
                            hiddenContainerFrames
                    )
                else { continue }
                appendInlineMediaKeys(
                    from: textRegion.text.value,
                    model: model,
                    into: &keys
                )
            }
        }
        for sticker in message.stickers where sticker.format != .lottie {
            if let url = sticker.mediaURL {
                keys.append(.media(url, maximumPixelDimension: 384))
            }
        }
        for region in layouts[index].reactionRegions {
            let reference = region.reaction.emojiReference
            if let id = reference.id,
               let url = model?.customEmojiURLsByID[id]
                    ?? reference.imageURL(size: 64)
            {
                keys.append(.media(url, maximumPixelDimension: 64))
            }
            for avatar in region.avatarRegions {
                if let url = avatar.reactor.avatarURL {
                    keys.append(.avatar(url))
                }
            }
        }

        return Set(keys)

        }
    }

    func mediaKeys(
        for item: NativeMessageTimelineItem,
        at index: Int?
    ) -> Set<NativeTimelineMediaKey> {
        mediaKeysOperation(item, index)
    }

    func appendInlineMediaKeys(
        from value: NSAttributedString,
        model: AppModel?,
        into keys: inout [NativeTimelineMediaKey]
    ) {
        let range = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(
            .discordEmojiToken,
            in: range
        ) { rawValue, _, _ in
            guard let rawToken = rawValue as? String else { return }
            let reference = EmojiReference(rawToken: rawToken)
            let customURL = reference.id.flatMap { id in
                model?.customEmojiURLsByID[id]
            }
            guard let url = customURL
                ?? reference.imageURL(size: 64)
            else { return }
            keys.append(.media(url, maximumPixelDimension: 64))
        }
        value.enumerateAttribute(
            .nativeTimelineMention,
            in: range
        ) { rawValue, _, _ in
            guard let mention =
                (rawValue as? NativeTimelineMentionBox)?.presentation,
                let url = mention.avatarURL
            else { return }
            keys.append(.avatar(url))
        }
    }

    func invalidateBitmap(
        _ identifier: NativeMessageTimelineItem.Identifier
    ) {
        guard let removed = bitmapCache.removeValue(forKey: identifier) else {
            return
        }
        bitmapCost -= removed.cost
        NativeTimelineMediaStore.shared.releasePinnedImages(
            owner: removed.mediaPinOwner
        )
    }
}
