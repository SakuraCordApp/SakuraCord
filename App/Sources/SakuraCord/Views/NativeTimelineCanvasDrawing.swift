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
    static let bitmapTileHeight: CGFloat = 128

    func apply(
        storage: NativeTimelineCanvasStorage,
        model: AppModel,
        actions: NativeTimelineRowActions,
        viewportWidth: CGFloat,
        minimumHeight: CGFloat,
        bottomSpacerHeight: CGFloat,
        contentOriginY: CGFloat,
        historySkeleton: TimelineHistorySkeletonPresentation? = nil,
        redrawsMovedShortContentSynchronously: Bool = true
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
        invalidateVisibleMediaProjection(keepingCapacity: true)
        self.storage = storage
        self.model = model
        reconcilePollPresentations()
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
        // After the content origin settles: an expansion measures where its
        // rows landed the header.
        refreshDisclosureGeometry()
        reconcileServerTagCardPresentation()
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
        prefetchVisibleVoiceMessages()
        startVisibleInlineVideosImmediately()
        scheduleAnimatedMediaReconciliation()
        positionAnimatedMediaOverlays()
        reconcileVoiceMessageOverlay()
        reconcileBeginningSelectionOverlay()
        reconcileActivityIndicators()
        reconcileSpoilerOverlays()
        if !suppressesHoverPresentation {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if !suppressesHoverPresentation {
            reconcileAccessibilityProxiesIfActive()
        }
        redrawMovedShortContentSynchronously(
            from: previousContentOriginY,
            contentOriginMoved: contentOriginMoved,
            isEnabled: redrawsMovedShortContentSynchronously
        )
        if !suppressesHoverPresentation {
            synchronizeHoverWithCurrentPointer()
        }
        reconcileReactionHover()
        reconcileActionCapsule()
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
        let frame = historySkeleton?.frame.intersection(bounds) ?? .null
        let animates = !frame.isNull && !frame.isEmpty
            && !isHiddenOrHasHiddenAncestor
            && window?.occlusionState.contains(.visible) == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        effectiveAppearance.performAsCurrentDrawingAppearance {
            historySkeletonShimmer.update(
                frame: frame.isNull ? .zero : frame,
                color: .labelColor, animates: animates
            )
        }
        guard animates else { return }
        guard historySkeletonShimmerFrame != frame
            || historySkeletonShimmerPresentation != historySkeleton
            || historySkeletonShimmerScale != InterfaceScale.factor
        else { return }
        historySkeletonShimmerFrame = frame
        historySkeletonShimmerScale = InterfaceScale.factor
        historySkeletonShimmerPresentation = historySkeleton
        let path = NSBezierPath()
        appendHistorySkeletonRows(in: frame, to: path, drawsBase: false)
        var translation = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: frame.size)
        mask.path = path.cgPath.copy(using: &translation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        historySkeletonShimmer.layer.mask = mask
        CATransaction.commit()
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
            reconcileAccessibilityProxiesIfActive()
        }
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        positionInlineVideoOverlays()
        reconcileVoiceMessageOverlay()
        reconcileActivityIndicators()
        positionSpoilerOverlays()
        componentChoiceOverlay?.repositionWithAnchor()
        needsDisplay = true
        redrawMovedShortContentSynchronously(
            from: oldOriginY,
            contentOriginMoved:
                abs(oldOriginY - contentOriginY) >= 0.5,
            isEnabled: true
        )
        if !suppressesHoverPresentation {
            synchronizeHoverWithCurrentPointer()
        }
        reconcileReactionHover()
        reconcileActionCapsule()
    }

    func redrawMovedShortContentSynchronously(
        from previousContentOriginY: CGFloat,
        contentOriginMoved: Bool,
        isEnabled: Bool
    ) {
        guard isEnabled,
              contentOriginMoved,
              window != nil,
              max(previousContentOriginY, contentOriginY)
                > ChatDetailLayoutPolicy.timelineTopPadding
                    + (enclosingScrollView?.scrollerInsets.top ?? 0) + 0.5
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
        AppPerformanceSignposts.measureSync(
            "TimelineSynchronousShortContentRedraw"
        ) {
            displayIfNeeded()
        }
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
        clearBitmapCache(keepingCapacity: true)
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        invalidateVisibleMediaProjection(keepingCapacity: true)
        removeAccessibilityProxies()
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
        reactionDetailsPopover?.close()
        cancelMessageJumpHighlight()
        finishSendTransitions()
        cancelTranscriptGlide()
        finishUnreadDividerFades()
        animatedMediaReconcileTask?.cancel()
        animatedMediaReconcileTask = nil
        visibleMediaRequestTask?.cancel()
        visibleMediaRequestTask = nil
        pendingVisibleMediaRequests.removeAll(keepingCapacity: true)
        invalidateVisibleMediaProjection(keepingCapacity: true)
        NativeTimelineMediaStore.shared.removeStaticRequests(
            owner: visibleMediaPinOwner
        )
        NativeTimelineMediaStore.shared.releaseVisibleImages(
            owner: visibleMediaPinOwner
        )
        NativeTimelineMediaStore.shared.cancelAnimatedRequests(
            owner: visibleMediaPinOwner
        )
        mediaReadyConversationID = nil
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    func dismissHoverPresentationForScroll() {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "TimelineScrollPresentationTeardown"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "TimelineScrollPresentationTeardown",
                interval
            )
        }
        // Bounds changes arrive for every momentum-scroll tick. All teardown
        // and playback suppression below must happen only at the transition
        // into scrolling, never for each tick.
        guard !suppressesHoverPresentation else { return }
        suppressesHoverPresentation = true
        finishSendTransitions()
        // Pause native playback once without destroying its presentation.
        // Recreating AVPlayer overlays on each reconciliation
        // produced the benchmark's regular FAST/pause cadence, while removing
        // them made otherwise loaded videos and stickers blink out as soon as
        // scrolling began. Retaining the bounded overlays preserves their
        // current frames and avoids both costs.
        for overlay in inlineVideoOverlays.values {
            overlay.pauseForScroll()
        }
        for overlay in animatedMediaOverlays.values {
            overlay.setPlaybackSuppressed(true)
        }
        // Remove existing tracking areas too so AppKit does not hit-test the
        // moving timeline under a stationary pointer during scrolling.
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
        closeServerTagPopover()
        removeActionCapsule()
        freezeEditingRowForScroll()
        reconcileAccessibilityProxiesIfActive()
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
        for oldComponentButton in clearedTargets.componentButtons {
            invalidateComponentButton(oldComponentButton)
        }
        if let messageID = clearedTargets.forwardedSourceMessageID,
           let index = items.firstIndex(where: { $0.messageID == messageID })
        {
            setNeedsDisplay(rowFrame(at: index))
        }
        if let messageID = clearedTargets.threadMessageID {
            invalidateThreadCard(messageID: messageID)
        }
        if let messageID = clearedTargets.serverTagMessageID {
            invalidateVisibleMessageRow(messageID: messageID)
        }
        if let messageID = clearedTargets.commandPillMessageID {
            invalidateVisibleMessageRow(messageID: messageID)
        }
        if let messageID = clearedTargets.footerAction?.messageID,
           let index = items.firstIndex(where: { $0.messageID == messageID })
        {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func allowHoverPresentationAfterScroll() {
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "TimelineScrollPresentationRestore"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "TimelineScrollPresentationRestore",
                interval
            )
        }
        suppressesHoverPresentation = false
        updateAvatarPlayback()
        for overlay in animatedMediaOverlays.values {
            overlay.setPlaybackSuppressed(false)
        }
        refreshVisibleMediaPins()
        reconcileVisibleReactionPreviewLoads()
        restoreEditingRowAfterScroll()
        reconcileAnimatedMedia()
        reconcileActivityIndicators()
        reconcileSpoilerOverlays()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        reconcileAccessibilityProxiesIfActive()
        synchronizeHoverWithCurrentPointer()
    }

    func modalInputDidChange() {
        setOverlayInteractionBlocked(!WindowModalCoordinator.allowsInput(for: self), mediaViewerHighlightedMessageID: mediaViewerHighlightedMessageID)
    }

    func setOverlayInteractionBlocked(
        _ isBlocked: Bool,
        mediaViewerHighlightedMessageID: MessageID?
    ) {
        let highlightChanged = self.mediaViewerHighlightedMessageID
            != mediaViewerHighlightedMessageID
        guard overlayBlocksInteractions != isBlocked || highlightChanged else {
            return
        }
        overlayBlocksInteractions = isBlocked
        self.mediaViewerHighlightedMessageID =
            mediaViewerHighlightedMessageID
        if isBlocked {
            pressedPollTarget = nil
            hoveredPollTarget = nil
            pollPopover?.close()
            reactionDetailsPopover?.close()
            pointer.clearHoverAndPressTargets()
            reactionHoverCoordinator.close()
            closeMessageProfilePopover()
            closeServerTagPopover()
            closeMentionPopover()
            closeComponentChoiceOverlay()
        }
        if isBlocked, mediaViewerHighlightedMessageID == nil {
            removeActionCapsule()
        } else {
            reconcileActionCapsule()
        }
        needsDisplay = true
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
            // Setting the frame after a bounds change of a different size
            // leaves the two sizes at different scales, which AppKit keeps
            // through the resize and shows as stretched contents. Settle them
            // together unless the callback installed newer geometry.
            if self.frame == frame, self.bounds != bounds {
                self.bounds = bounds
                needsDisplay = true
            }
        }
        reconcileHistorySkeletonShimmer()
        presentRowsEnteringViewport()
        // Supplementary Inbox rows are content, not hover presentation. Keep
        // them materialized as the viewport moves, including momentum ticks
        // that stay within the current overscanned backing window.
        if case .inboxGroup = items.first {
            reconcileInboxHeaders()
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
        reconcileVoiceMessageOverlay()
        reconcileActivityIndicators()
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
            reactionDetailsPopover?.close()
            clearDisclosure(redraws: false)
            finishSendTransitions()
            cancelTranscriptGlide()
            finishUnreadDividerFades()
            cancelReactionPreviewLoads()
            mediaInvalidationTask?.cancel()
            mediaInvalidationTask = nil
            pendingMediaInvalidations.removeAll(keepingCapacity: false)
            visibleMediaRequestTask?.cancel()
            visibleMediaRequestTask = nil
            pendingVisibleMediaRequests.removeAll(keepingCapacity: false)
            invalidateVisibleMediaProjection(keepingCapacity: false)
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
            removeReactionMouseMonitor()
            cancelReactionCountAnimations()
            reactionCountBaselineTask?.cancel()
            reactionCountBaselineTask = nil
            animatedMediaReconcileTask?.cancel()
            animatedMediaReconcileTask = nil
            animatedMediaRows.removeAll()
            inlineVideoRows.removeAll()
            removeInlineVideoOverlays()
            removeVoiceMessageOverlay()
            removeAnimatedMediaOverlays()
            removeActivityIndicators()
            removeSpoilerOverlays()
            reactionPickerCoordinator.close(notifyBinding: false)
            reactionHoverCoordinator.close()
            closeMessageProfilePopover()
            closeServerTagPopover()
            closeComponentChoiceOverlay()
            closeMentionPopover()
            reactionPickerSource.frame = .zero
            pointer.clearHoverAndPressTargets()
            removeAccessibilityProxies()
            removeActionCapsule()
            endEditing(commit: nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.reconcileAccessibilityProxiesIfActive()
            }
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        reconcileHistorySkeletonShimmer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcileHistorySkeletonShimmer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreInboxKeyboardFocus()
        reconcileHistorySkeletonShimmer()
        if window != nil {
            installReactionMouseMonitor()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.reconcileAccessibilityProxiesIfActive()
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
            if visibleRowSpan(at: middle).upperBound <= documentY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return items.indices.contains(lower) ? lower : nil
    }

    func startMessageJumpHighlight(_ messageID: MessageID) {
        cancelMessageJumpHighlight()
        let highlight = MessageJumpHighlight(
            messageID: messageID,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        messageJumpHighlight = highlight
        invalidateMessageJumpHighlight(messageID)
        let reducesMotion = !AppMotionPolicy.animatesUncategorized
        messageJumpHighlightTask = Task { @MainActor [weak self] in
            if reducesMotion {
                do {
                    try await Task.sleep(
                        for: .seconds(
                            NativeTimelineMessageJumpHighlightPolicy
                                .totalDuration
                        )
                    )
                } catch {
                    return
                }
            } else {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(16))
                    } catch {
                        return
                    }
                    guard let self,
                          self.messageJumpHighlight == highlight
                    else { return }
                    self.invalidateMessageJumpHighlight(messageID)
                    let elapsed =
                        ProcessInfo.processInfo.systemUptime
                            - highlight.startedAt
                    if elapsed
                        >= NativeTimelineMessageJumpHighlightPolicy
                            .totalDuration
                    {
                        break
                    }
                }
            }
            guard let self,
                  self.messageJumpHighlight == highlight
            else { return }
            self.messageJumpHighlight = nil
            self.messageJumpHighlightTask = nil
            self.invalidateMessageJumpHighlight(messageID)
        }
    }

    func cancelMessageJumpHighlight() {
        messageJumpHighlightTask?.cancel()
        messageJumpHighlightTask = nil
        guard let messageID = messageJumpHighlight?.messageID else { return }
        messageJumpHighlight = nil
        invalidateMessageJumpHighlight(messageID)
    }

    func invalidateMessageJumpHighlight(_ messageID: MessageID) {
        guard let index = items.firstIndex(where: {
            $0.messageID == messageID
        }) else { return }
        setNeedsDisplay(rowFrame(at: index))
    }

    func messageJumpHighlightPresentation(
        at index: Int,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> MessageJumpHighlightPresentation? {
        guard items.indices.contains(index),
              layouts.indices.contains(index),
              let highlightFrame = layouts[index].highlightFrame,
              let messageID = items[index].messageID,
              let highlight = messageJumpHighlight,
              highlight.messageID == messageID
        else { return nil }
        let opacity = NativeTimelineMessageJumpHighlightPolicy.opacity(
            elapsed: uptime - highlight.startedAt,
            reducesMotion: !AppMotionPolicy.animatesUncategorized
        )
        guard opacity > 0 else { return nil }
        let rowFrame = rowFrame(at: index)
        return MessageJumpHighlightPresentation(
            frame: highlightFrame.offsetBy(
                dx: rowFrame.minX,
                dy: rowFrame.minY
            ),
            opacity: opacity
        )
    }

    func firstVisibleMessage(
        in rect: CGRect
    ) -> (MessageID, CGFloat)? {
        guard var index = rowIndex(at: rect.minY) else { return nil }
        while items.indices.contains(index) {
            if let id = items[index].messageID {
                let offset = displayedRowOrigin(at: index) - rect.minY
                return (id, offset)
            }
            index += 1
        }
        return nil
    }

    func drawTimeline(in dirtyRect: NSRect) {
        let startUptime = ProcessInfo.processInfo.systemUptime
        defer {
            let duration =
                ProcessInfo.processInfo.systemUptime - startUptime
            drawCount += 1
            totalDrawDuration += duration
#if SAKURACORD_MOTION_BENCHMARK
            lifetimeDrawDuration += duration
#endif
            maximumDrawDuration = max(
                maximumDrawDuration,
                duration
            )
        }
        drawSuperclassContent(in: dirtyRect)
        let visibleMediaKeys = refreshVisibleMediaPins()
        reconcileVisibleReactionPreviewLoads()
        // This view is transparent and layer-backed. Core Graphics does not
        // guarantee that invalidating a region clears its previous backing
        // pixels before draw(_:). Clear first so bottom-origin changes cannot
        // composite newly positioned rows over their former positions.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        drawHistorySkeleton(in: dirtyRect)
        var displayedRows: [Int] = []
        forEachDisplayedRow(in: dirtyRect) { displayedRows.append($0) }
        drawSuppressedHighlights(for: displayedRows)
        for index in displayedRows {
            let rowFrame = rowFrame(at: index)
            guard rowFrame.intersects(dirtyRect) else { continue }
            guard disclosureRange.contains(index) else {
                drawTimelineRowClippedToUnreadDividerGap(
                    at: index, rowFrame: rowFrame, dirtyRect: dirtyRect, visibleMediaKeys: visibleMediaKeys
                )
                continue
            }
            // An animating group is clipped to its revealed height.
            let minY = max(rowFrame.minY, disclosureClipMinY)
            let maxY = min(rowFrame.maxY, disclosureClipMaxY)
            guard minY < maxY, let context = NSGraphicsContext.current?.cgContext else { continue }
            context.saveGState()
            context.clip(to: CGRect(x: rowFrame.minX, y: minY, width: rowFrame.width, height: maxY - minY))
            drawTimelineRow(at: index, rowFrame: rowFrame, dirtyRect: dirtyRect, visibleMediaKeys: visibleMediaKeys)
            context.restoreGState()
        }
    }

    /// Blocked and ignored areas span several rows, so they are drawn beneath
    /// all rows rather than into any one row's cached bitmap.
    private func drawSuppressedHighlights(for displayedRows: [Int]) {
        guard let first = displayedRows.first else { return }
        var headers: [Int] = []
        if let header = suppressedHeaderIndex(containing: first) { headers.append(header) }
        for index in displayedRows {
            guard case .suppressedMessages = items[index], headers.last != index else { continue }
            headers.append(index)
        }
        for header in headers {
            if let frame = suppressedHighlightFrame(headerIndex: header) {
                NativeTimelineRowPainter.drawSuppressedHighlight(frame)
            }
        }
    }

    func drawTimelineRow(
        at index: Int,
        rowFrame: CGRect,
        dirtyRect: CGRect,
        visibleMediaKeys: [NativeMessageTimelineItem.Identifier: Set<NativeTimelineMediaKey>]
    ) {
        let item = items[index]
        let preparedMediaKeys = visibleMediaKeys[item.identifier]
            ?? mediaKeys(for: item, at: index)
        drawMessageJumpHighlight(at: index)
        let revealState = textSpoilerRevealState(at: index)
        if let editingMessageID, item.messageID == editingMessageID {
            drawEditingTimelineRow(
                item, at: index, rowFrame: rowFrame, dirtyRect: dirtyRect,
                preparedMediaKeys: preparedMediaKeys
            )
            return
        } else if timelineRowRequiresDirectPresentation(
            item: item, index: index, revealState: revealState
        ) {
            drawInteractiveTimelineRow(
                item, at: index, rowFrame: rowFrame,
                preparedMediaKeys: preparedMediaKeys, revealState: revealState
            )
        } else {
            drawStableTimelineRow(
                item, at: index, rowFrame: rowFrame, dirtyRect: dirtyRect,
                preparedMediaKeys: preparedMediaKeys, revealState: revealState
            )
        }
        if let hoveredCodeBlock, hoveredCodeBlock.itemIdentifier == item.identifier {
            drawCodeBlockCopyControl(hoveredCodeBlock)
        }
        clearSendTransitionBubble(for: item, layout: layouts[index], rowFrame: rowFrame)
        if !unreadDividerFades.isEmpty {
            clearHeldUnreadDivider(for: item, layout: layouts[index], rowFrame: rowFrame)
        }
    }

    private func drawEditingTimelineRow(
        _ item: NativeMessageTimelineItem,
        at index: Int,
        rowFrame: CGRect,
        dirtyRect: CGRect,
        preparedMediaKeys: Set<NativeTimelineMediaKey>
    ) {
        NSGraphicsContext.current?.cgContext.clear(rowFrame.intersection(dirtyRect))
        enqueueVisibleMediaRequests(identifier: item.identifier, keys: preparedMediaKeys)
        NativeTimelineRowPainter.draw(
            item: item, layout: layouts[index], in: rowFrame, model: model,
            isHovered: false, drawsBubbleBackground: false, hidesMessageContent: true,
            spoilerRevealStore: spoilerRevealStore
        )
        editingRowScrollSnapshot?.draw(
            in: editingOverlayFrame(at: index), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil
        )
    }

    private func timelineRowRequiresDirectPresentation(
        item: NativeMessageTimelineItem,
        index: Int,
        revealState: NativeTimelineTextSpoilerRevealState
    ) -> Bool {
        isPreviewingWidth
            || layouts[index].pollLayout != nil
            || hoveredPollTarget?.messageID == item.messageID
            || hoveredRow == index
            || mediaViewerHighlightedMessageID == item.messageID
            || hoveredCompactTimestampRow == index
            || hoveredAuthorMessageID == item.messageID
            || hoveredServerTagMessageID == item.messageID
            || serverTagCardPresentation?.messageID == item.messageID
            || hoveredCommandPillMessageID == item.messageID
            || hoveredMention?.itemIdentifier == item.identifier
            || hoveredTextLink?.itemIdentifier == item.identifier
            || hoveredTextSpoiler?.itemIdentifier == item.identifier
            || hoveredComponentButton?.messageID == item.messageID
            || activeComponentChoiceTarget?.messageID == item.messageID
            || visualPressedComponentButton?.messageID == item.messageID
            || componentButtonHoverFades.keys.contains { $0.messageID == item.messageID }
            || hoveredForwardedSourceMessageID == item.messageID
            || hoveredThreadMessageID == item.messageID
            || hoveredFooterAction?.messageID == item.messageID
            || isSuppressedToggleHovered(item)
            || !reactionCountTransitions(inMessageAt: index).isEmpty
            || textSelection?.itemIdentifier == item.identifier
            || !revealState.isEmpty
    }

    private func isSuppressedToggleHovered(_ item: NativeMessageTimelineItem) -> Bool {
        guard case let .suppressedMessages(group) = item else { return false }
        return hoveredFooterAction == .init(messageID: group.id, kind: .suppressedToggle)
    }

    private func drawInteractiveTimelineRow(
        _ item: NativeMessageTimelineItem,
        at index: Int,
        rowFrame: CGRect,
        preparedMediaKeys: Set<NativeTimelineMediaKey>,
        revealState: NativeTimelineTextSpoilerRevealState
    ) {
        enqueueVisibleMediaRequests(identifier: item.identifier, keys: preparedMediaKeys)
        let presentsViewerHighlight = mediaViewerHighlightedMessageID == item.messageID
        NativeTimelineRowPainter.draw(
            item: item,
            layout: layouts[index],
            in: rowFrame,
            model: model,
            isHovered: hoveredRow == index || presentsViewerHighlight,
            showsCompactTimestamp: hoveredCompactTimestampRow == index,
            isAuthorHovered: hoveredAuthorMessageID == item.messageID,
            isServerTagHovered: hoveredServerTagMessageID == item.messageID || serverTagCardPresentation?.messageID == item.messageID,
            isCommandPillHovered: hoveredCommandPillMessageID == item.messageID,
            hoveredMention: hoveredMention?.itemIdentifier == item.identifier ? hoveredMention : nil,
            hoveredTextLink: hoveredTextLink?.itemIdentifier == item.identifier ? hoveredTextLink : nil,
            hoveredTextSpoiler: hoveredTextSpoiler?.itemIdentifier == item.identifier ? hoveredTextSpoiler : nil,
            hoveredComponentButton: hoveredComponentButton?.messageID == item.messageID ? hoveredComponentButton : nil,
            activeComponentChoiceTarget: activeComponentChoiceTarget?.messageID == item.messageID ? activeComponentChoiceTarget : nil,
            pressedComponentButton: visualPressedComponentButton?.messageID == item.messageID ? visualPressedComponentButton : nil,
            componentButtonPressProgress: visualPressedComponentButton?.messageID == item.messageID ? componentButtonPressProgress : 0,
            fileCardHoverProgress: fileCardHoverProgress(in: item.messageID),
            isForwardedSourceHovered: hoveredForwardedSourceMessageID == item.messageID,
            threadCardInteraction: threadCardInteraction(forMessageID: item.messageID),
            isEphemeralDismissHovered: hoveredFooterAction?.messageID == item.messageID && hoveredFooterAction?.kind == .ephemeralDismiss,
            isTranslationActionHovered: hoveredFooterAction?.messageID == item.messageID && hoveredFooterAction?.kind == .translation,
            hoveredDeliveryAction: hoveredFooterAction?.messageID == item.messageID ? hoveredFooterAction?.kind : nil,
            isSuppressedToggleHovered: isSuppressedToggleHovered(item),
            hoveredReactionID: hoveredReactionID(inMessageAt: index),
            isAddReactionHovered: isAddReactionHovered(inMessageAt: index),
            textSelection: textSelection,
            revealedTextSpoilerState: revealState,
            spoilerRevealStore: spoilerRevealStore,
            reactionCountTransitions: reactionCountTransitions(inMessageAt: index),
            pollPresentation: pollPresentation(for: item.messageID),
            animatedOverlayRoles: animatedOverlayRoles(for: item.identifier)
        )
    }

    private func drawStableTimelineRow(
        _ item: NativeMessageTimelineItem,
        at index: Int,
        rowFrame: CGRect,
        dirtyRect: CGRect,
        preparedMediaKeys: Set<NativeTimelineMediaKey>,
        revealState: NativeTimelineTextSpoilerRevealState
    ) {
        enqueueVisibleMediaRequests(identifier: item.identifier, keys: preparedMediaKeys)
        // Only rasterize the exposed slices of tall messages. A one-pixel
        // reveal must not synchronously draw an entire attachment gallery.
        if rowFrame.height > 256 {
            let exposed = rowFrame.intersection(dirtyRect)
            let firstTile = max(0, Int(floor((exposed.minY - rowFrame.minY) / Self.bitmapTileHeight)))
            let lastTile = max(firstTile, Int(ceil((exposed.maxY - rowFrame.minY) / Self.bitmapTileHeight)) - 1)
            for tileIndex in firstTile ... lastTile {
                let offset = CGFloat(tileIndex) * Self.bitmapTileHeight
                let tileFrame = CGRect(
                    x: rowFrame.minX, y: rowFrame.minY + offset,
                    width: rowFrame.width, height: min(Self.bitmapTileHeight, rowFrame.height - offset)
                )
                let image = cachedBitmap(for: item, width: rowFrame.width, tileIndex: tileIndex)
                    ?? bitmap(
                        for: item, at: index, layout: layouts[index], width: rowFrame.width,
                        preparedMediaKeys: preparedMediaKeys, tileIndex: tileIndex
                    )
                image.draw(
                    in: tileFrame, from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: nil
                )
            }
            return
        }
        let cached = cachedBitmap(for: item, width: rowFrame.width)
        let drawsDirectly = NativeTimelineScrollingRenderPolicy.usesDirectPainter(
            isScrolling: suppressesHoverPresentation || AppScrollActivity.isActive,
            hasCachedBitmap: cached != nil,
            estimatedBitmapCost: Self.estimatedBitmapCost(
                width: rowFrame.width,
                height: layouts[index].height,
                scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            ),
            cacheCostLimit: Self.bitmapCostLimit
        )
        if drawsDirectly {
            liveScrollDirectPaintCount += 1
            AppPerformanceSignposts.measureSync("TimelineLiveScrollDirectPaint") {
                NativeTimelineRowPainter.draw(
                    item: item, layout: layouts[index], in: rowFrame, model: model,
                    isHovered: false, revealedTextSpoilerState: revealState,
                    spoilerRevealStore: spoilerRevealStore,
                    animatedOverlayRoles: animatedOverlayRoles(for: item.identifier)
                )
            }
        } else {
            (cached ?? bitmap(
                for: item, at: index, layout: layouts[index], width: rowFrame.width,
                preparedMediaKeys: preparedMediaKeys
            )).draw(
                in: rowFrame, from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        AppPerformanceSignposts.measureSync("TimelineCanvasDraw") {
            drawTimeline(in: dirtyRect)
        }
        if let presentedConversationID,
           AppPerformanceSignposts.reportConversationFirstFrame(
                channelID: presentedConversationID
           )
        {
            mediaReadyConversationID = presentedConversationID
            NativeTimelineRowPainter.schedulePostFirstFrameSymbolPrewarm(
                appearance: effectiveAppearance
            )
            scheduleAnimatedMediaReconciliation()
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
                cornerRadius: InterfaceScale.metric(4)
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
            in: buttonFrame.insetBy(dx: InterfaceScale.metric(6), dy: InterfaceScale.metric(6))
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
        at rowIndex: Int
    ) -> NativeTimelineTextSpoilerRevealState {
        var result = NativeTimelineTextSpoilerRevealState()
        // Most rows have no revealed spoilers. Avoid building selectable
        // regions (and hashing their text) on every scrolling frame in that
        // case; callers already know the row's current storage index.
        guard !spoilerRevealStore.revealedText.isEmpty,
              items.indices.contains(rowIndex),
               layouts.indices.contains(rowIndex),
           let messageID = items[rowIndex].messageID
        else { return result }
        for selectable in selectableTextRegions(
            for: items[rowIndex],
            layout: layouts[rowIndex]
        ) {
            for location in revealedTextSpoilerLocations(
                messageID: messageID,
                region: selectable.region,
                value: selectable.value,
                layout: layouts[rowIndex]
            ) {
                result.reveal(
                    region: selectable.region,
                    rangeLocation: location
                )
            }
        }
        return result
    }

    func revealedTextSpoilerLocations(
        messageID: MessageID,
        region: NativeTimelineTextRegion,
        value: NSAttributedString,
        layout: NativeTimelineRowLayout
    ) -> Set<Int> {
        guard !spoilerRevealStore.revealedText.isEmpty,
              let contentID = textSpoilerContentID(
                  for: region,
                  layout: layout
              )
        else { return [] }
        return spoilerRevealStore.revealedTextLocations(
            messageID: messageID,
            contentID: contentID,
            value: value
        )
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
            return NativeTimelineTextSpoilerRevealKey.messageContentID
        case let .translation(id):
            return "translation:\(id)"
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
        guard let frame = historySkeleton?.frame else { return }
        let clipped = frame.intersection(dirtyRect)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clipped).addClip()
        appendHistorySkeletonRows(in: dirtyRect, to: NSBezierPath(), drawsBase: true)
    }

    private func appendHistorySkeletonRows(
        in dirtyRect: CGRect, to path: NSBezierPath, drawsBase: Bool
    ) {
        guard let presentation = historySkeleton else { return }
        let frame = presentation.frame
        let clipped = frame.intersection(dirtyRect)
        guard !clipped.isNull, clipped.height > 0 else { return }
        let rowStride = InterfaceScale.metric(76)
        let rowCount = max(1, Int(ceil(frame.height / rowStride)))
        let firstOrdinal = max(0, Int(floor((frame.maxY - clipped.maxY) / rowStride)))
        let lastOrdinal = min(
            rowCount - 1,
            max(firstOrdinal, Int(ceil((frame.maxY - clipped.minY) / rowStride)))
        )
        for ordinal in firstOrdinal ... lastOrdinal {
            drawHistorySkeletonRow(
                ordinal: ordinal,
                rowTop: frame.maxY - CGFloat(ordinal + 1) * rowStride,
                frameWidth: frame.width, shimmerMask: path, drawsBase: drawsBase
            )
        }
    }

    private func drawHistorySkeletonRow(
        ordinal: Int,
        rowTop: CGFloat,
        frameWidth: CGFloat,
        shimmerMask: NSBezierPath,
        drawsBase: Bool
    ) {
        let contentX: CGFloat = InterfaceScale.metric(64)
        let maximumContentWidth = max(InterfaceScale.metric(80), frameWidth - contentX - InterfaceScale.metric(14))
        let authorWidths: [CGFloat] = [92, 126, 108, 148]
        let lineFractions: [[CGFloat]] = [
            [0.72],
            [0.91, 0.58],
            [0.84, 0.76, 0.42],
            [0.64, 0.88],
        ]
        let avatarPath = NSBezierPath(ovalIn: CGRect(
            x: InterfaceScale.metric(14),
            y: rowTop + InterfaceScale.metric(11),
            width: InterfaceScale.metric(38),
            height: InterfaceScale.metric(38)
        ))
        if drawsBase { SkeletonShimmerStyle.baseColor().setFill() }
        if drawsBase { avatarPath.fill() }
        shimmerMask.append(avatarPath)

        let authorWidth = min(
            maximumContentWidth * 0.45,
            authorWidths[ordinal % authorWidths.count]
        )
        let authorPath = NSBezierPath(
            roundedRect: CGRect(
                x: contentX,
                y: rowTop + InterfaceScale.metric(10),
                width: authorWidth,
                height: InterfaceScale.metric(10)
            ),
            xRadius: InterfaceScale.metric(5),
            yRadius: InterfaceScale.metric(5)
        )
        if drawsBase { authorPath.fill() }
        shimmerMask.append(authorPath)

        let timestampPath = NSBezierPath(
            roundedRect: CGRect(
                x: contentX + authorWidth + InterfaceScale.metric(8),
                y: rowTop + InterfaceScale.metric(12),
                width: InterfaceScale.metric(38),
                height: InterfaceScale.metric(7)
            ),
            xRadius: InterfaceScale.metric(3.5),
            yRadius: InterfaceScale.metric(3.5)
        )
        if drawsBase { timestampPath.fill() }
        shimmerMask.append(timestampPath)

        let fractions = lineFractions[ordinal % lineFractions.count]
        for (line, fraction) in fractions.enumerated() {
            let linePath = NSBezierPath(
                roundedRect: CGRect(
                    x: contentX,
                    y: rowTop + InterfaceScale.metric(28) + CGFloat(line) * 13,
                    width: max(InterfaceScale.metric(34), maximumContentWidth * fraction),
                    height: InterfaceScale.metric(8)
                ),
                xRadius: InterfaceScale.metric(4),
                yRadius: InterfaceScale.metric(4)
            )
            if drawsBase { linePath.fill() }
            shimmerMask.append(linePath)
        }
    }

    func resetDrawTelemetry() {
        maximumDrawDuration = 0
        totalDrawDuration = 0
        drawCount = 0
        maximumRowRasterDuration = 0
        maximumRowRasterHeight = 0
        totalRowRasterDuration = 0
        rowRasterCount = 0
        rowBitmapCacheHitCount = 0
        liveScrollDirectPaintCount = 0
    }

    var renderTelemetry: NativeTimelineRenderTelemetry {
        NativeTimelineRenderTelemetry(
            canvasDrawCount: drawCount,
            canvasDrawTotalDuration: totalDrawDuration,
            canvasDrawMaximumDuration: maximumDrawDuration,
            rowRasterCount: rowRasterCount,
            rowRasterTotalDuration: totalRowRasterDuration,
            rowRasterMaximumDuration: maximumRowRasterDuration,
            rowRasterMaximumHeight: maximumRowRasterHeight,
            rowBitmapCacheHitCount: rowBitmapCacheHitCount,
            liveScrollDirectPaintCount: liveScrollDirectPaintCount
        )
    }

    func bitmap(
        for item: NativeMessageTimelineItem,
        at index: Int,
        layout: NativeTimelineRowLayout,
        width: CGFloat,
        preparedMediaKeys: Set<NativeTimelineMediaKey>,
        tileIndex: Int = -1
    ) -> NSImage {
        if let cached = cachedBitmap(for: item, width: width, tileIndex: tileIndex) {
            return cached
        }
        let appearanceName = effectiveAppearance.name

        let rasterStart = ProcessInfo.processInfo.systemUptime
        let tileOrigin = tileIndex < 0 ? 0 : CGFloat(tileIndex) * Self.bitmapTileHeight
        let size = NSSize(
            width: width,
            height: tileIndex < 0 ? layout.height : min(Self.bitmapTileHeight, layout.height - tileOrigin)
        )
        let scale = max(
            1,
            window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
        )
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(size.height * scale)))
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
        graphics.cgContext.translateBy(x: 0, y: size.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        graphics.cgContext.translateBy(x: 0, y: -tileOrigin)
        let flippedGraphics = NSGraphicsContext(
            cgContext: graphics.cgContext,
            flipped: true
        )
        NSGraphicsContext.current = flippedGraphics
        AppPerformanceSignposts.measureSync("TimelineRowRaster") {
            NativeTimelineRowPainter.draw(
                item: item,
                layout: layout,
                in: CGRect(x: 0, y: 0, width: width, height: layout.height),
                model: model,
                isHovered: false,
                spoilerRevealStore: spoilerRevealStore,
                animatedOverlayRoles: animatedOverlayRoles(for: item.identifier)
            )
        }
        flippedGraphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let rasterDuration =
            ProcessInfo.processInfo.systemUptime - rasterStart
        recordRowRaster(duration: rasterDuration, height: size.height)

        var entry = bitmapCache[item.identifier]
        if let previous = entry,
           previous.item != item || abs(previous.width - width) >= 0.5
                || previous.appearanceName != appearanceName {
            invalidateBitmap(item.identifier)
            entry = nil
        }
        let mediaPinOwner = entry?.mediaPinOwner ?? UUID()
        NativeTimelineMediaStore.shared.pinLoadedImages(
            for: preparedMediaKeys,
            owner: mediaPinOwner
        )
        let cost = Self.estimatedBitmapCost(
            width: width,
            height: size.height,
            scale: scale
        )
        bitmapInsertionOrder.removeAll { $0 == item.identifier }
        bitmapInsertionOrder.append(item.identifier)
        var updated = entry ?? CachedRowBitmap(
            item: item,
            width: width,
            appearanceName: appearanceName,
            images: [:],
            cost: 0,
            mediaPinOwner: mediaPinOwner,
            missingMediaKeys: preparedMediaKeys.filter {
                NativeTimelineRowPainter.mediaImage(for: $0) == nil
            }
        )
        updated.images[tileIndex] = image
        updated.cost += cost
        bitmapCache[item.identifier] = updated
        bitmapCost += cost
        evictBitmapsIfNeeded()
        return image
    }

    private func recordRowRaster(duration: TimeInterval, height: CGFloat) {
        rowRasterCount += 1
        totalRowRasterDuration += duration
        if duration > maximumRowRasterDuration {
            maximumRowRasterDuration = duration
            maximumRowRasterHeight = height
        }
    }

    static func estimatedBitmapCost(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) -> Int {
        let pixelWidth = max(1, Int(ceil(max(0, width) * max(1, scale))))
        let pixelHeight = max(1, Int(ceil(max(0, height) * max(1, scale))))
        let pixelCount = pixelWidth.multipliedReportingOverflow(
            by: pixelHeight
        )
        guard !pixelCount.overflow else { return .max }
        let byteCount = pixelCount.partialValue.multipliedReportingOverflow(
            by: 4
        )
        return byteCount.overflow ? .max : byteCount.partialValue
    }

    func cachedBitmap(
        for item: NativeMessageTimelineItem,
        width: CGFloat,
        tileIndex: Int = -1
    ) -> NSImage? {
        guard let cached = bitmapCache[item.identifier],
              cached.item == item,
              abs(cached.width - width) < 0.5,
              cached.appearanceName == effectiveAppearance.name
        else { return nil }
        // Incomplete bitmaps can outlive their load subscriptions when a
        // conversation is detached. Recheck their missing images on reuse.
        if cached.missingMediaKeys.contains(where: {
            NativeTimelineRowPainter.mediaImage(for: $0) != nil
        }) {
            invalidateBitmap(item.identifier)
            return nil
        }
        guard let image = cached.images[tileIndex] else { return nil }
        rowBitmapCacheHitCount += 1
        return image
    }

    func evictBitmapsIfNeeded() {
        while bitmapCost > Self.bitmapCostLimit,
              !bitmapInsertionOrder.isEmpty
        {
            let identifier = bitmapInsertionOrder.removeFirst()
            if let removed = bitmapCache.removeValue(forKey: identifier) {
                bitmapCost -= removed.cost
                NativeTimelineMediaStore.shared.releasePinnedImages(
                    owner: removed.mediaPinOwner
                )
            }
        }
    }

    func clearBitmapCache(keepingCapacity: Bool) {
        for cached in bitmapCache.values {
            NativeTimelineMediaStore.shared.releasePinnedImages(
                owner: cached.mediaPinOwner
            )
        }
        bitmapCache.removeAll(keepingCapacity: keepingCapacity)
        bitmapInsertionOrder.removeAll(keepingCapacity: keepingCapacity)
        bitmapCost = 0
    }

}
