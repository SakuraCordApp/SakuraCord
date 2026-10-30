import AppKit
import SakuraCordModels

/// A group of rows opening or closing in place below its header.
///
/// Rows stay real canvas content throughout. The group's own rows never move;
/// they are clipped to `revealedHeight`. The hidden height is taken up by
/// displacing the rows on either side: rows before the group (including its
/// header) move by `beforeShift`, and rows after it by `beforeShift - hidden`.
///
/// Each motion ends on the geometry the timeline will have once its rows
/// change, so the structural update that follows is invisible: an expanding
/// group measures how far the inserted rows moved its header and animates
/// that away, and a collapsing group predicts how far removing its rows will
/// pull the header down (a short or bottom-scrolled timeline cannot keep it in
/// place) and animates toward it. Geometry is cached per frame, so the cost of
/// a frame does not grow with the length of the timeline.
///
/// A collapsing group keeps its rows until the motion ends, so the model can
/// collapse immediately: Inbox groups hold them here (`heldItems`), and
/// blocked or ignored runs hold them in `IgnoredUsersState.collapsingMessageIDs`.
struct NativeTimelineRowDisclosure {
    static let duration: TimeInterval = 0.3

    enum Key: Equatable {
        case inbox(ChannelID)
        case suppressedMessages(MessageID)
    }

    /// The header position the coordinator keeps when the group's rows change.
    struct ScrollAnchor {
        let key: Key
        let offsetFromViewportTop: CGFloat
    }

    let key: Key
    let isCollapsing: Bool
    let requestedUptime: TimeInterval
    var heldItems: [NativeMessageTimelineItem] = []
    var heldMessageIDs: [MessageID] = []
    var startHeight: CGFloat
    var revealedHeight: CGFloat
    var startBeforeShift: CGFloat
    var targetBeforeShift: CGFloat
    var beforeShift: CGFloat
    /// The header's viewport position before an expansion's rows arrive.
    var pendingHeaderViewportY: CGFloat?
    var startUptime: TimeInterval?
    var headerIndexHint: Int?
    var isFinished = false

    /// Ease-out with a soft landing, close to AppKit's disclosure motion.
    static func progress(at elapsed: TimeInterval) -> CGFloat {
        let fraction = min(1, max(0, elapsed / duration))
        return 1 - pow(1 - fraction, 4)
    }
}

extension NativeTimelineCanvasView {
    func toggleInboxGroup(_ channelID: ChannelID) {
        guard let model, let group = model.inbox.groups.first(where: { $0.id == channelID }) else { return }
        let key = NativeTimelineRowDisclosure.Key.inbox(channelID)
        guard !group.isAgeRestricted,
              let start = beginDisclosure(key, isCollapsing: !group.isCollapsed, keepsHeaderPosition: false) else {
            model.toggleInboxGroup(channelID)
            return
        }
        // Hover chrome belongs to a row position that is about to move.
        removeActionCapsule()
        if start.isCollapsing {
            let range = disclosureContentRange(for: key, headerIndex: start.headerIndex)
            rowDisclosure?.heldItems = Array(items[range])
        }
        model.toggleInboxGroup(channelID)
        startDisclosureMotion()
    }

    func toggleSuppressedGroup(_ group: SuppressedMessageGroup) {
        guard let model else { return }
        let key = NativeTimelineRowDisclosure.Key.suppressedMessages(group.id)
        // Accessibility actions can outlive the item they captured.
        var group = group
        if let headerIndex = disclosureHeaderIndex(for: key),
           case let .suppressedMessages(current) = items[headerIndex] { group = current }
        pendingDisclosureScrollAnchor = key
        guard let start = beginDisclosure(key, isCollapsing: group.isRevealed, keepsHeaderPosition: true) else {
            model.toggleSuppressedMessages(group.messageIDs)
            return
        }
        removeActionCapsule()
        if start.isCollapsing { rowDisclosure?.heldMessageIDs = group.messageIDs }
        model.toggleSuppressedMessages(group.messageIDs, holdsCollapsingRows: start.isCollapsing)
        startDisclosureMotion()
    }

    /// Rows the coordinator keeps for an Inbox group that is still visibly closing.
    func heldInboxItems(for channelID: ChannelID) -> [NativeMessageTimelineItem] {
        guard let rowDisclosure, rowDisclosure.isCollapsing, !rowDisclosure.isFinished,
              rowDisclosure.key == .inbox(channelID) else { return [] }
        return rowDisclosure.heldItems
    }

    /// Recomputes the cached geometry read by `displayedRowOrigin(at:)`.
    func refreshDisclosureGeometry() {
        guard var disclosure = rowDisclosure,
              let headerIndex = disclosureHeaderIndex(for: disclosure.key, hint: disclosure.headerIndexHint) else {
            clearDisclosure()
            return
        }
        disclosure.headerIndexHint = headerIndex
        let range = disclosureContentRange(for: disclosure.key, headerIndex: headerIndex)
        guard !range.isEmpty else {
            rowDisclosure = disclosure
            if disclosure.isCollapsing { clearDisclosure() } else { resetDisclosureGeometry() }
            return
        }
        if let previousY = disclosure.pendingHeaderViewportY {
            // The expansion's rows have landed: start from where the header was.
            let landedY = contentOriginY + rowOrigins[headerIndex] - viewportMinY
            disclosure.pendingHeaderViewportY = nil
            disclosure.startBeforeShift = previousY - landedY
            disclosure.beforeShift = disclosure.startBeforeShift
            disclosure.startHeight = disclosure.revealedHeight
        }
        rowDisclosure = disclosure
        // Rows are measured before applying the shift, which never moves the group's own rows.
        disclosureRange = range
        let hiddenHeight = max(0, contentHeight(of: range) - disclosure.revealedHeight)
        disclosureShiftBefore = disclosure.beforeShift
        disclosureShiftAfter = disclosure.beforeShift - hiddenHeight
        disclosureRelativeClipMinY = disclosure.beforeShift
        disclosureRelativeClipMaxY = disclosure.beforeShift + disclosure.revealedHeight
    }

    var disclosureClipMinY: CGFloat {
        guard !disclosureRange.isEmpty else { return -.greatestFiniteMagnitude }
        return contentOriginY + rowOrigins[disclosureRange.lowerBound] + disclosureRelativeClipMinY
    }

    var disclosureClipMaxY: CGFloat {
        guard !disclosureRange.isEmpty else { return .greatestFiniteMagnitude }
        return contentOriginY + rowOrigins[disclosureRange.lowerBound] + disclosureRelativeClipMaxY
    }

    func finishDisclosure() {
        guard rowDisclosure != nil else { return }
        clearDisclosure()
    }

    func clearDisclosure(redraws: Bool = true) {
        let disclosure = rowDisclosure
        rowDisclosure = nil
        disclosureTicker.stop()
        resetDisclosureGeometry()
        guard let disclosure else { return }
        if redraws { redrawForRowMotion() }
        // Drops held rows from the next published item list.
        if disclosure.isCollapsing, !disclosure.isFinished { releaseHeldRows(of: disclosure) }
    }

    /// A blocked or ignored run's highlighted area: the header's content and
    /// every revealed row in full, following the rows while they open or close.
    func suppressedHighlightFrame(headerIndex: Int) -> CGRect? {
        guard case let .suppressedMessages(group) = items[headerIndex],
              let header = layouts[headerIndex].suppressedHeader else { return nil }
        let frame = header.highlightFrame.offsetBy(dx: 0, dy: displayedRowOrigin(at: headerIndex))
        let range = suppressedContentRange(group, headerIndex: headerIndex)
        guard let last = range.last else { return frame }
        var maxY = displayedRowOrigin(at: last) + layouts[last].height
        if range == disclosureRange { maxY = min(maxY, disclosureClipMaxY) }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(frame.height, maxY - frame.minY))
    }

    /// The header whose highlighted area contains `index`, if any.
    func suppressedHeaderIndex(containing index: Int) -> Int? {
        guard let model else { return nil }
        var candidate = index
        while items.indices.contains(candidate) {
            switch items[candidate] {
            case .suppressedMessages: return candidate
            case let .message(row, _, _) where model.messageSuppressionReason(row.message) != nil:
                candidate -= 1
            default: return nil
            }
        }
        return nil
    }

    /// Visits displayed rows intersecting `rect` in index order. Rows hidden
    /// outside an animating group's clip do not end the walk early.
    func forEachDisplayedRow(in rect: CGRect, _ body: (Int) -> Void) {
        guard !items.isEmpty, var index = rowIndex(at: max(0, rect.minY)) else { return }
        while items.indices.contains(index) {
            let span = visibleRowSpan(at: index)
            if span.lowerBound >= rect.maxY { return }
            if disclosureRange.contains(index), span.lowerBound >= disclosureClipMaxY {
                index = disclosureRange.upperBound
                continue
            }
            if span.upperBound > span.lowerBound { body(index) }
            index += 1
        }
    }

    /// Clip both ends into the reveal interval, including empty rows. The
    /// resulting spans remain ordered while the surrounding rows move.
    func visibleRowSpan(at index: Int) -> Range<CGFloat> {
        let minY = displayedRowOrigin(at: index)
        let maxY = minY + displayedRowHeight(at: index)
        guard disclosureRange.contains(index) else { return unreadDividerGapSpan(at: index, minY: minY, maxY: maxY) }
        let clippedMin = min(disclosureClipMaxY, max(disclosureClipMinY, minY))
        let clippedMax = min(disclosureClipMaxY, max(disclosureClipMinY, maxY))
        return clippedMin ..< clippedMax
    }

    func disclosureHeaderIndex(for key: NativeTimelineRowDisclosure.Key, hint: Int? = nil) -> Int? {
        func matches(_ item: NativeMessageTimelineItem) -> Bool {
            switch (key, item) {
            case let (.inbox(channelID), .inboxGroup(header)): header.channelID == channelID
            case let (.suppressedMessages(id), .suppressedMessages(group)): group.id == id
            default: false
            }
        }
        if let hint, items.indices.contains(hint), matches(items[hint]) { return hint }
        return items.firstIndex(where: matches)
    }

    private struct DisclosureStart {
        let headerIndex: Int
        let isCollapsing: Bool
    }

    /// Installs the motion when its header is on screen; otherwise the caller
    /// applies the change without animation. A group that keeps its header in
    /// place compensates for the timeline's own response to the change.
    private func beginDisclosure(
        _ key: NativeTimelineRowDisclosure.Key,
        isCollapsing: Bool,
        keepsHeaderPosition: Bool
    ) -> DisclosureStart? {
        // Two row motions would fight over the same displacement.
        finishUnreadDividerGap()
        finishReactionTransitions()
        let previous = rowDisclosure?.key == key ? rowDisclosure : nil
        // Reversing the same group continues from where it is; another group snaps to its end.
        if previous == nil { finishDisclosure() } else { rowDisclosure = nil }
        guard AppMotionPolicy.animatesUncategorized,
              let headerIndex = disclosureHeaderIndex(for: key),
              displayedRowOrigin(at: headerIndex) < visibleRect.maxY,
              displayedRowOrigin(at: headerIndex) + layouts[headerIndex].height > visibleRect.minY
        else {
            if let previous {
                rowDisclosure = previous
                clearDisclosure()
            }
            return nil
        }
        let range = disclosureContentRange(for: key, headerIndex: headerIndex)
        if isCollapsing, range.isEmpty { return nil }
        let fullHeight = contentHeight(of: range)
        let beforeShift = previous?.beforeShift ?? 0
        var startHeight = previous?.revealedHeight ?? (isCollapsing ? fullHeight : 0)
        var targetBeforeShift: CGFloat = 0
        if isCollapsing, keepsHeaderPosition {
            // Removing the rows pulls everything above them down by whatever
            // the space below the viewport cannot absorb.
            targetBeforeShift = min(fullHeight, max(0, fullHeight - distanceBelowViewport))
        }
        if previous == nil, isCollapsing, targetBeforeShift == 0 {
            // Only the part inside the viewport needs to move.
            startHeight = min(startHeight, visibleExtent(of: range))
        }
        rowDisclosure = NativeTimelineRowDisclosure(
            key: key, isCollapsing: isCollapsing,
            requestedUptime: ProcessInfo.processInfo.systemUptime,
            startHeight: startHeight, revealedHeight: startHeight,
            startBeforeShift: beforeShift, targetBeforeShift: targetBeforeShift, beforeShift: beforeShift,
            pendingHeaderViewportY: !isCollapsing && keepsHeaderPosition
                ? displayedRowOrigin(at: headerIndex) - viewportMinY : nil,
            headerIndexHint: headerIndex
        )
        return DisclosureStart(headerIndex: headerIndex, isCollapsing: isCollapsing)
    }

    private func startDisclosureMotion() {
        refreshDisclosureGeometry()
        disclosureTicker.start(on: self) { [weak self] in self?.stepDisclosure() }
    }

    private func stepDisclosure() {
        guard var disclosure = rowDisclosure else {
            disclosureTicker.stop()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let headerIndex = disclosureHeaderIndex(for: disclosure.key, hint: disclosure.headerIndexHint) else {
            clearDisclosure()
            return
        }
        let range = disclosureContentRange(for: disclosure.key, headerIndex: headerIndex)
        if range.isEmpty || disclosure.pendingHeaderViewportY != nil {
            // An expanding group may still be loading; its header shows progress.
            if disclosure.isCollapsing || now - disclosure.requestedUptime > 4 { clearDisclosure() }
            return
        }
        let start = disclosure.startUptime ?? now
        disclosure.startUptime = start
        let target = if disclosure.isCollapsing {
            CGFloat(0)
        } else if disclosure.startBeforeShift == 0 {
            // Only the part inside the viewport needs to move.
            visibleExtent(of: range)
        } else {
            contentHeight(of: range)
        }
        let progress = NativeTimelineRowDisclosure.progress(at: now - start)
        disclosure.revealedHeight = disclosure.startHeight + (target - disclosure.startHeight) * progress
        disclosure.beforeShift = disclosure.startBeforeShift
            + (disclosure.targetBeforeShift - disclosure.startBeforeShift) * progress
        if progress >= 1 {
            if disclosure.isCollapsing {
                disclosure.isFinished = true
                rowDisclosure = disclosure
                disclosureTicker.stop()
                refreshDisclosureGeometry()
                redrawForRowMotion()
                if case .suppressedMessages = disclosure.key { pendingDisclosureScrollAnchor = disclosure.key }
                releaseHeldRows(of: disclosure)
            } else {
                clearDisclosure()
            }
            return
        }
        rowDisclosure = disclosure
        refreshDisclosureGeometry()
        redrawForRowMotion()
    }

    private func releaseHeldRows(of disclosure: NativeTimelineRowDisclosure) {
        switch disclosure.key {
        case .inbox: model?.publishInbox()
        case .suppressedMessages: model?.finishCollapsingSuppressedMessages(disclosure.heldMessageIDs)
        }
    }

    var viewportMinY: CGFloat {
        enclosingScrollView?.contentView.bounds.minY ?? visibleRect.minY
    }

    /// Scrollable document below the viewport, which absorbs removed height
    /// without moving anything on screen.
    private var distanceBelowViewport: CGFloat {
        guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return 0 }
        return max(0, document.frame.height - scrollView.contentView.bounds.maxY)
    }

    /// The part of a group's height that is on screen below its top.
    private func visibleExtent(of range: Range<Int>) -> CGFloat {
        let top = contentOriginY + rowOrigins[range.lowerBound]
        return min(contentHeight(of: range), max(0, visibleRect.maxY - top))
    }

    private func resetDisclosureGeometry() {
        disclosureRange = 0 ..< 0
        disclosureShiftBefore = 0
        disclosureShiftAfter = 0
        disclosureRelativeClipMinY = -.greatestFiniteMagnitude
        disclosureRelativeClipMaxY = .greatestFiniteMagnitude
    }

    func redrawForRowMotion(invalidating rect: CGRect? = nil) {
        // Hover regions are cached at the rows' displaced positions.
        mentionPointerRegionCache.removeAll(keepingCapacity: true)
        codeBlockPointerRegionCache.removeAll(keepingCapacity: true)
        if rowDisclosure?.isFinished ?? true, unreadDividerGap == nil, reactionRowMotions.isEmpty,
           !suppressesHoverPresentation {
            // The motion has landed: tracking areas and cursor rects follow the rows.
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        if let rect { setNeedsDisplay(rect) } else { invalidateVisibleContent() }
        reconcileInboxHeaders()
        positionAnimatedMediaOverlays()
        positionInlineVideoOverlays()
        reconcileVoiceMessageOverlay()
        reconcileActivityIndicators()
        positionSpoilerOverlays()
        maskDisclosureSubviews()
    }

    /// Hosted views inside the group follow the same clip as its drawn rows.
    private func maskDisclosureSubviews() {
        for view in disclosureMaskedViews { view.layer?.mask = nil }
        disclosureMaskedViews = []
        guard rowDisclosure != nil, !disclosureRange.isEmpty else { return }
        let rows = items[disclosureRange]
        let identifiers = Set(rows.map(\.identifier))
        let messageIDs = Set(rows.compactMap(\.messageID))
        var views: [NSView] = []
        for item in rows {
            switch item {
            case let .inboxForumPost(post): if let host = inboxForumPostHosts[post.id] { views.append(host) }
            case let .inboxEvent(event): if let host = inboxEventHosts[event.id] { views.append(host) }
            default: break
            }
        }
        views += animatedMediaOverlays.filter { identifiers.contains($0.key.row) }.map(\.value)
        views += inlineVideoOverlays.filter { identifiers.contains($0.key.row) }.map(\.value)
        views += activityIndicators.filter { identifiers.contains($0.key.row) }.map(\.value)
        views += spoilerOverlays.filter { messageIDs.contains($0.key.messageID) }.map(\.value)
        for view in views {
            view.wantsLayer = true
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            let minY = max(view.frame.minY, disclosureClipMinY)
            let maxY = min(view.frame.maxY, disclosureClipMaxY)
            let visible = CGRect(x: view.frame.minX, y: minY, width: view.frame.width, height: max(0, maxY - minY))
            mask.frame = view.convert(visible, from: self)
            view.layer?.mask = mask
            disclosureMaskedViews.append(view)
        }
    }

    private func disclosureContentRange(for key: NativeTimelineRowDisclosure.Key, headerIndex: Int) -> Range<Int> {
        switch (key, items[headerIndex]) {
        case (.inbox, _):
            var end = headerIndex + 1
            while items.indices.contains(end) {
                if case .inboxGroup = items[end] { break }
                end += 1
            }
            return headerIndex + 1 ..< end
        case let (.suppressedMessages, .suppressedMessages(group)):
            return suppressedContentRange(group, headerIndex: headerIndex)
        default:
            return headerIndex + 1 ..< headerIndex + 1
        }
    }

    /// The revealed or still-closing rows that follow a blocked or ignored header.
    private func suppressedContentRange(_ group: SuppressedMessageGroup, headerIndex: Int) -> Range<Int> {
        var end = headerIndex + 1
        while end - headerIndex - 1 < group.messageIDs.count, items.indices.contains(end),
              items[end].messageRow?.id == group.messageIDs[end - headerIndex - 1] { end += 1 }
        return headerIndex + 1 ..< end
    }

    private func contentHeight(of range: Range<Int>) -> CGFloat {
        range.reduce(0) { $0 + layouts[$1].height }
    }
}
