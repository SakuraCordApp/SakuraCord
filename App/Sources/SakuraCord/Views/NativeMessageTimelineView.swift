import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
private final class NativeTimelineDisplayLinkTicker: NSObject {
    private var displayLink: CADisplayLink?
    private var tick: (() -> Void)?

    func start(on view: NSView, tick: @escaping () -> Void) {
        stop()
        self.tick = tick
        let displayLink = view.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        tick = nil
    }

    @objc
    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        tick?()
    }
}

nonisolated enum NativeTimelineBenchmarkStartupPolicy {
    static let minimumPresentedFrames = 2
    static let quietInterval: TimeInterval = 0.100

    static func isReady(
        completedTicks: Int,
        uptime: TimeInterval,
        lastDelayedTickUptime: TimeInterval
    ) -> Bool {
        completedTicks >= minimumPresentedFrames
            && uptime >= lastDelayedTickUptime + quietInterval
    }
}

struct MessageTimelineScrollRequest: Equatable {
    enum Target: Equatable {
        case bottom
        case message(MessageID, anchor: UnitPoint)
    }

    let id = UUID()
    let target: Target
}

nonisolated enum TimelineInitialPositionPolicy {
    /// Keep the unread divider in the upper third of the viewport so the
    /// reader sees both prior context and the unread run that follows.
    static let unreadViewportAnchor = UnitPoint(x: 0.5, y: 0.28)

    static func target(
        firstUnreadMessageID: MessageID?,
        hasExactUnreadBoundary: Bool,
        prefersNewest: Bool
    ) -> MessageTimelineScrollRequest.Target {
        guard !prefersNewest,
              hasExactUnreadBoundary,
              let firstUnreadMessageID
        else {
            return .bottom
        }
        return .message(
            firstUnreadMessageID,
            anchor: unreadViewportAnchor
        )
    }

    static func targetWhenReady(
        hasCompletedInitialLoad: Bool,
        firstUnreadMessageID: MessageID?,
        hasExactUnreadBoundary: Bool,
        prefersNewest: Bool
    ) -> MessageTimelineScrollRequest.Target? {
        guard hasCompletedInitialLoad else { return nil }
        return target(
            firstUnreadMessageID: firstUnreadMessageID,
            hasExactUnreadBoundary: hasExactUnreadBoundary,
            prefersNewest: prefersNewest
        )
    }
}

enum NativeTimelineConversation: Equatable {
    case channel(ChannelID?)
    case thread(ChannelID?)

    var id: ChannelID? {
        switch self {
        case let .channel(id), let .thread(id):
            id
        }
    }

    var supportsReply: Bool {
        switch self {
        case .channel:
            true
        case .thread:
            false
        }
    }

    var loaderKind: NativeTimelineLoaderKind {
        switch self {
        case .channel:
            .messages
        case .thread:
            .replies
        }
    }

    @MainActor
    func rows(in model: AppModel) -> [MessageRowPresentation] {
        switch self {
        case .channel:
            model.messageRows
        case .thread:
            model.threadMessageRows
        }
    }

    @MainActor
    func rowsRevision(in model: AppModel) -> UInt64 {
        switch self {
        case .channel:
            model.messageRowsRevision
        case .thread:
            model.threadMessageRowsRevision
        }
    }

    @MainActor
    func rowsUpdateHint(in model: AppModel) -> MessageRowsUpdateHint? {
        switch self {
        case .channel:
            model.messageRowsUpdateHint
        case .thread:
            model.threadMessageRowsUpdateHint
        }
    }

    @MainActor
    func rowsUpdateJournal(in model: AppModel) -> MessageRowsUpdateJournal {
        switch self {
        case .channel:
            model.messageRowsUpdateJournal
        case .thread:
            model.threadMessageRowsUpdateJournal
        }
    }
}

nonisolated enum NativeTimelineLoaderKind: Equatable {
    case messages
    case replies

    var loadingLabel: String {
        switch self {
        case .messages:
            "Loading earlier messages…"
        case .replies:
            "Loading earlier replies…"
        }
    }
}

nonisolated struct NativeTimelineHistorySkeletonPresentation: Equatable {
    let frame: CGRect
    let kind: NativeTimelineLoaderKind
    let conversationID: ChannelID?
}

enum NativeTimelineBeginning: Equatable {
    case channel(Channel, rulesChannelID: ChannelID?)
    case thread(
        id: ChannelID,
        title: String,
        starterName: String?,
        startedAt: Date?
    )

    var id: ChannelID {
        switch self {
        case let .channel(channel, _):
            channel.id
        case let .thread(id, _, _, _):
            id
        }
    }

    var title: String {
        switch self {
        case let .channel(channel, _):
            switch channel.kind {
            case .directMessage, .groupDirectMessage:
                "Beginning of your conversation with \(channel.name)"
            case .voice:
                "Welcome to \(channel.name)!"
            default:
                "Welcome to #\(channel.name)!"
            }
        case let .thread(_, title, _, _):
            title
        }
    }

    var description: String {
        switch self {
        case let .channel(channel, _):
            if let topic = channel.topic?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !topic.isEmpty {
                return topic
            }
            switch channel.kind {
            case .directMessage, .groupDirectMessage:
                return "This is the beginning of your direct message history."
            case .voice:
                return "This is the start of the \(channel.name) voice channel chat."
            default:
                return "This is the start of the #\(channel.name) channel."
            }
        case let .thread(_, _, starterName?, _):
            return "Started by \(starterName)"
        case .thread:
            return "This is the start of the thread."
        }
    }

    var isDescriptionSelectable: Bool {
        switch self {
        case .channel:
            true
        case let .thread(_, _, starterName, _):
            starterName != nil
        }
    }

    var symbolName: String {
        switch self {
        case let .channel(channel, rulesChannelID):
            if rulesChannelID == channel.id {
                return "newspaper.fill"
            }
            switch channel.kind {
            case .directMessage:
                return "person.fill"
            case .groupDirectMessage:
                return "person.2.fill"
            case .announcement:
                return "megaphone.fill"
            case .forum:
                return "bubble.left.and.bubble.right.fill"
            case .voice:
                return "bubble.left.fill"
            default:
                return "number"
            }
        case .thread:
            return "bubble.left.and.bubble.right.fill"
        }
    }

    var startedAt: Date? {
        guard case let .thread(_, _, _, startedAt) = self else { return nil }
        return startedAt
    }

}

enum NativeMessageTimelineItem: Equatable {
    nonisolated enum Identifier: Hashable {
        case beginning(ChannelID)
        case loader
        case message(MessageID)
    }

    case beginning(NativeTimelineBeginning)
    case loader(isLoading: Bool, kind: NativeTimelineLoaderKind)
    case message(
        MessageRowPresentation,
        isUnreadBoundary: Bool,
        isHighlighted: Bool
    )

    var messageID: MessageID? {
        guard case let .message(row, _, _) = self else { return nil }
        return row.id
    }

    var messageRow: MessageRowPresentation? {
        guard case let .message(row, _, _) = self else { return nil }
        return row
    }

    var identifier: Identifier {
        switch self {
        case let .beginning(beginning):
            .beginning(beginning.id)
        case .loader:
            .loader
        case let .message(row, _, _):
            .message(row.id)
        }
    }
}

nonisolated enum NativeTimelineAutomaticHistoryPolicy {
    static func shouldReevaluateAfterUpdate(
        wasLoadingEarlier: Bool,
        isLoadingEarlier: Bool,
        previousRowCount: Int,
        currentRowCount: Int
    ) -> Bool {
        wasLoadingEarlier
            && !isLoadingEarlier
            && currentRowCount > previousRowCount
    }
}

nonisolated enum NativeTimelineEarlierLoaderPolicy {
    static func includesLoader(
        hasMoreMessages: Bool,
        isLoadingEarlier: Bool
    ) -> Bool {
        hasMoreMessages || isLoadingEarlier
    }
}

nonisolated enum NativeMessageTimelineLayoutPolicy {
    struct LeadingHistoryReserveUpdate: Equatable {
        let reserve: CGFloat
        let grew: Bool
    }

    static func consumingLeadingHistoryReserve(
        _ currentReserve: CGFloat,
        prependedHeight: CGFloat,
        chunk: CGFloat
    ) -> LeadingHistoryReserveUpdate {
        let currentReserve = max(0, currentReserve)
        let prependedHeight = max(0, prependedHeight)
        let chunk = max(1, chunk)
        guard prependedHeight > 0 else {
            return LeadingHistoryReserveUpdate(
                reserve: currentReserve,
                grew: false
            )
        }
        if currentReserve >= prependedHeight {
            return LeadingHistoryReserveUpdate(
                reserve: currentReserve - prependedHeight,
                grew: false
            )
        }
        let shortage = prependedHeight - currentReserve
        let addedChunks = max(1, ceil(shortage / chunk))
        return LeadingHistoryReserveUpdate(
            reserve:
                currentReserve
                + addedChunks * chunk
                - prependedHeight,
            grew: true
        )
    }

    /// Keep one bounded page of provisional geometry above the oldest loaded
    /// row. It is large enough for a fast gesture to continue naturally while
    /// an authenticated request is in flight, without turning a slow request
    /// into an unbounded chain of speculative history loads.
    static func provisionalHistoryDepth(
        reserve: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        min(
            max(0, reserve),
            max(8_000, max(1, viewportHeight) * 8)
        )
    }

    static func provisionalHistoryMinimumY(
        reserve: CGFloat,
        viewportHeight: CGFloat,
        allowsProvisionalHistory: Bool
    ) -> CGFloat {
        let reserve = max(0, reserve)
        guard allowsProvisionalHistory else { return reserve }
        return max(
            0,
            reserve
                - provisionalHistoryDepth(
                    reserve: reserve,
                    viewportHeight: viewportHeight
                )
        )
    }

    static func showsHistorySkeleton(
        hasMoreMessages: Bool,
        isLoadingEarlier: Bool,
        followsMaterializedHistoryBoundary: Bool
    ) -> Bool {
        hasMoreMessages
            && (
                isLoadingEarlier
                    || followsMaterializedHistoryBoundary
            )
    }

    static func insertionIndexes<ID: Hashable>(
        preserving oldIdentifiers: [ID],
        in newIdentifiers: [ID]
    ) -> IndexSet? {
        guard newIdentifiers.count >= oldIdentifiers.count else { return nil }
        var oldIndex = oldIdentifiers.startIndex
        var insertions = IndexSet()
        for (newIndex, identifier) in newIdentifiers.enumerated() {
            if oldIndex < oldIdentifiers.endIndex,
               identifier == oldIdentifiers[oldIndex]
            {
                oldIndex += 1
            } else {
                insertions.insert(newIndex)
            }
        }
        return oldIndex == oldIdentifiers.endIndex ? insertions : nil
    }

    static func removalIndexes<ID: Hashable>(
        preserving newIdentifiers: [ID],
        in oldIdentifiers: [ID]
    ) -> IndexSet? {
        insertionIndexes(
            preserving: newIdentifiers,
            in: oldIdentifiers
        )
    }

    static func acceptsRowSnapshot(
        itemsAreEmpty: Bool,
        conversationChanged: Bool,
        publishedRevision: UInt64,
        appliedRevision: UInt64
    ) -> Bool {
        itemsAreEmpty
            || conversationChanged
            || publishedRevision != appliedRevision
    }

    static func requiresFirstMessageBoundaryRebuild(
        from oldStartsDayOverride: Bool?,
        to newStartsDayOverride: Bool?
    ) -> Bool {
        // A thread beginning can replace its loading item without advancing
        // the row revision. Rebuild so the already-realized first row gives
        // the beginning ownership of its same-day separator immediately.
        oldStartsDayOverride != newStartsDayOverride
    }

    static func shortContentTopInset(
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat,
        verticalPadding: CGFloat
    ) -> CGFloat {
        verticalPadding
            + max(
                0,
                viewportHeight - contentHeight - bottomInset - verticalPadding
            )
    }

    static func showsVerticalScroller(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat,
        verticalPadding: CGFloat
    ) -> Bool {
        contentHeight
            + bottomInset
            + verticalPadding
            > viewportHeight + 0.5
    }

    static func clampedDocumentY(
        proposedY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let maximumY = max(0, contentHeight - viewportHeight + bottomInset)
        return min(max(0, proposedY), maximumY)
    }

    static func documentHeight(
        contentOriginY: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        max(
            viewportHeight,
            contentOriginY + contentHeight + bottomInset
        )
    }

    static func isAtTrueBottom(
        documentHeight: CGFloat,
        visibleMaximumY: CGFloat,
        tolerance: CGFloat = 1.5
    ) -> Bool {
        max(0, documentHeight - visibleMaximumY)
            <= max(0, tolerance)
    }

    /// The previous LazyVStack renderer top-pinned the first intersecting
    /// message when a width change reflowed a row that began above the
    /// viewport. Preserve that behavior instead of keeping an arbitrary point
    /// inside a tall media-heavy row.
    static func widthChangeAnchorOffset(
        from rawOffsetFromViewportTop: CGFloat
    ) -> CGFloat {
        max(
            ChatDetailLayoutPolicy.timelineWidthReflowTopInset,
            rawOffsetFromViewportTop
        )
    }

    /// When the viewport grows, the former SwiftUI renderer retained the
    /// first message whose beginning was actually visible. Anchoring a
    /// partially clipped media row instead would reveal content that was
    /// above the viewport before the expansion.
    static func prefersVisibleMessageBeginning(
        from oldWidth: CGFloat,
        to newWidth: CGFloat
    ) -> Bool {
        newWidth > oldWidth
    }
}

@MainActor
final class NativeTimelineDocumentView: NSView {
    override var isFlipped: Bool { true }
}

struct NativeMessageTimelineView: NSViewRepresentable {
    let model: AppModel
    let conversation: NativeTimelineConversation
    let beginning: NativeTimelineBeginning?
    let firstMessageStartsDayOverride: Bool?
    let hasMoreMessages: Bool
    let isLoadingEarlier: Bool
    let bottomContentInset: CGFloat
    let unreadMessageID: MessageID?
    let highlightedMessageID: MessageID?
    let initialScrollTarget: MessageTimelineScrollRequest.Target?
    let scrollRequest: MessageTimelineScrollRequest?
    let runsPerformanceAutoScroll: Bool
    let loadEarlier: () -> Void
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
        isLoadingEarlier: Bool,
        bottomContentInset: CGFloat,
        unreadMessageID: MessageID?,
        highlightedMessageID: MessageID?,
        initialScrollTarget: MessageTimelineScrollRequest.Target? = nil,
        scrollRequest: MessageTimelineScrollRequest?,
        runsPerformanceAutoScroll: Bool,
        loadEarlier: @escaping () -> Void,
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
        self.isLoadingEarlier = isLoadingEarlier
        self.bottomContentInset = bottomContentInset
        self.unreadMessageID = unreadMessageID
        self.highlightedMessageID = highlightedMessageID
        self.initialScrollTarget = initialScrollTarget
        self.scrollRequest = scrollRequest
        self.runsPerformanceAutoScroll = runsPerformanceAutoScroll
        self.loadEarlier = loadEarlier
        self.openReply = openReply
        self.onScrollActivityChange = onScrollActivityChange
        self.onScrollStateChange = onScrollStateChange
        self.onInitialPositionEstablished =
            onInitialPositionEstablished
        self.onUserScrollBegan = onUserScrollBegan
        self.onUserScrollEnded = onUserScrollEnded
    }

    fileprivate var rowsRevision: UInt64 {
        conversation.rowsRevision(in: model)
    }

    fileprivate var presentationRevision: UInt64 {
        model.timelinePresentationRevision
    }

    fileprivate var rowsUpdateHint: MessageRowsUpdateHint? {
        conversation.rowsUpdateHint(in: model)
    }

    fileprivate var rowsUpdateJournal: MessageRowsUpdateJournal {
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
        coordinator.stopObserving()
        scrollView.documentView = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        private struct VisibleAnchor {
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
        private static let prefetchDistance: CGFloat = 8_000
        private static let leadingHistoryReserveChunk: CGFloat = 65_536
        private static let performanceSignposter = OSSignposter(
            subsystem: "dev.sakuracord.SakuraCord",
            category: "PointsOfInterest"
        )
        private static let performanceLogger = Logger(
            subsystem: "dev.sakuracord.SakuraCord",
            category: "TimelinePerformance"
        )

        private var parent: NativeMessageTimelineView
        private var actions: NativeTimelineRowActions
        private let storage = NativeTimelineCanvasStorage()
        private var items: [NativeMessageTimelineItem] {
            _read { yield storage.items }
            _modify { yield &storage.items }
        }
        private var layouts: [NativeTimelineRowLayout] {
            _read { yield storage.layouts }
            _modify { yield &storage.layouts }
        }
        private var rowHeights: [CGFloat] {
            _read { yield storage.rowHeights }
            _modify { yield &storage.rowHeights }
        }
        private var rowOrigins: [CGFloat] {
            _read { yield storage.rowOrigins }
            _modify { yield &storage.rowOrigins }
        }
        private var contentHeight: CGFloat {
            get { storage.contentHeight }
            set { storage.contentHeight = newValue }
        }
        private var rowCount = 0
        private var messageIDs: [MessageID] = []
        private var firstRowID: MessageID?
        private var lastRowID: MessageID?
        private var rowsRevision: UInt64 = 0
        private var presentationRevision: UInt64 = 0
        private var layoutWidth: CGFloat = 0
        private var didMutateItems = false
        private var dirtyItemIndexes = IndexSet()
        private var requiresVisibleRedraw = false
        private var requiresAnchorRestore = false
        private var requiresFullOriginRebuild = false
        private var appendedLayoutCount = 0
        private var didPrependItems = false
        private var leadingHistoryReserve: CGFloat = 0
        private var followsMaterializedHistoryBoundary = false
        private var performanceUpdatePath = "none"
        private var performanceFallbackReason = "none"
        private var lastPerformanceUpdateDuration = 0.0
        private var lastLoggedPerformanceFallbackReason: String?

        private weak var canvas: NativeTimelineCanvasView?
        private weak var documentView: NativeTimelineDocumentView?
        private weak var scrollView: NSScrollView?
        private var observations: [NSObjectProtocol] = []
        private var lastScrollRequestID: UUID?
        private var lastReportedState: TimelineScrollState?
        private var scrollStateCallbackGeneration: UInt64 = 0
        private var lastReportedScrollActivity: Bool?
        private var scrollActivityCallbackGeneration: UInt64 = 0
        private var initialPositionCallbackGeneration: UInt64 = 0
        private var initialPositionConversation:
            NativeTimelineConversation?
        private var lastViewportSize = CGSize.zero
        private var isApplyingUpdate = false
        private var scrollIdleTask: Task<Void, Never>?
        private var lastScrollActivityUptime = 0.0
        private var performanceAutoScrollTask: Task<Void, Never>?
        private var performanceDisplayLinkTicker:
            NativeTimelineDisplayLinkTicker?
        private var performanceBenchmarkFinish: (() -> Void)?
        private var didStartPerformanceAutoScroll = false
        private var isPreparingOrRunningPerformanceBenchmark = false

        init(parent: NativeMessageTimelineView) {
            self.parent = parent
            actions = Self.makeActions(from: parent)
        }

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

            let scrollView = NSScrollView()
            scrollView.documentView = documentView
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
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

        func update(parent: NativeMessageTimelineView, scrollView: NSScrollView) {
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
            let wasNearBottom = scrollState().isNearBottom
            let bottomInsetChanged =
                abs(
                    oldParent.bottomContentInset
                        - parent.bottomContentInset
                ) >= 0.5
            if conversationChanged {
                leadingHistoryReserve = 0
                followsMaterializedHistoryBoundary = false
                initialPositionConversation = nil
                initialPositionCallbackGeneration &+= 1
            }
            self.parent = parent
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
            let width = max(220, scrollView.contentView.bounds.width.rounded())
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
            let reconcileStartUptime = ProcessInfo.processInfo.systemUptime
            if presentationChanged || conversationChanged {
                canvas.invalidatePresentationCaches()
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
                            "SakuraCord timeline fallback: \(self.performanceFallbackReason, privacy: .public); coordinator \(String(describing: ObjectIdentifier(self)), privacy: .public); items \(fallbackItemCount); old rows \(fallbackOldRowCount); new rows \(newRows.count); old revision \(self.rowsRevision); new revision \(parent.rowsRevision); old leading \(fallbackOldLeadingCount); new leading \(self.makeLeadingItems(from: parent).count)"
                        )
                    }
                }
            }
            let reconcileEndUptime = ProcessInfo.processInfo.systemUptime
            if acceptsNewRows, !hasUnpublishedRows {
                rowCount = newRows.count
                firstRowID = newRows.first?.id
                lastRowID = newRows.last?.id
                rowsRevision = parent.rowsRevision
            }
            presentationRevision = parent.presentationRevision
            let metadataEndUptime = ProcessInfo.processInfo.systemUptime
            if didMutateItems {
                if requiresFullOriginRebuild {
                    rebuildOrigins()
                } else if appendedLayoutCount > 0 {
                    appendOrigins(count: appendedLayoutCount)
                }
                if didPrependItems, parent.hasMoreMessages {
                    let reserveUpdate =
                        NativeMessageTimelineLayoutPolicy
                        .consumingLeadingHistoryReserve(
                            leadingHistoryReserve,
                            prependedHeight:
                                max(0, contentHeight - oldContentHeight),
                            chunk: Self.leadingHistoryReserveChunk
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
                } else if oldItemCount == 0,
                          parent.hasMoreMessages,
                          leadingHistoryReserve == 0
                {
                    leadingHistoryReserve =
                        Self.leadingHistoryReserveChunk
                }
                let originsEndUptime = ProcessInfo.processInfo.systemUptime
                applySnapshot(to: canvas, in: scrollView)
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
                canvas.actions = actions
            }
            let reserveCollapseAnchor: VisibleAnchor?
            if !parent.hasMoreMessages {
                followsMaterializedHistoryBoundary = false
                reserveCollapseAnchor = leadingHistoryReserve > 0
                    ? visibleAnchor()
                    : nil
                leadingHistoryReserve = 0
            } else {
                reserveCollapseAnchor = nil
            }
            updateInsets()
            updateHistorySkeletonPresentation()
            if let reserveCollapseAnchor {
                restore(reserveCollapseAnchor)
            }
            if wasNearBottom,
               (bottomInsetChanged || (didMutateItems && !didPrependItems))
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
            applyScrollRequestIfNeeded()
            if establishedInitialPosition {
                publishInitialPosition(scrollState())
            }
            reportScrollState(
                force:
                    NativeTimelineAutomaticHistoryPolicy
                    .shouldReevaluateAfterUpdate(
                        wasLoadingEarlier: oldParent.isLoadingEarlier,
                        isLoadingEarlier: parent.isLoadingEarlier,
                        previousRowCount: oldRowCount,
                        currentRowCount: rowCount
                    )
            )
            startPerformanceAutoScrollIfNeeded()
            isApplyingUpdate = false
            lastViewportSize = scrollView.contentView.bounds.size
        }

        func stopObserving() {
            scrollIdleTask?.cancel()
            scrollIdleTask = nil
            performanceAutoScrollTask?.cancel()
            performanceAutoScrollTask = nil
            performanceBenchmarkFinish?()
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

        private static func makeActions(
            from parent: NativeMessageTimelineView
        ) -> NativeTimelineRowActions {
            NativeTimelineRowActions(
                loadEarlier: parent.loadEarlier,
                openReply: parent.openReply,
                reply: parent.conversation.supportsReply
                    ? { [weak model = parent.model] message in
                        model?.reply(to: message)
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
                    model?.markMessageAndFollowingUnread(message)
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
                submitComponent: {
                    [weak model = parent.model]
                    message,
                    customID,
                    kind,
                    values in
                    guard let model else { return }
                    Task {
                        await model.submitComponent(
                            on: message,
                            customID: customID,
                            kind: kind,
                            values: values
                        )
                    }
                }
            )
        }

        private func rebuildAll(
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
                layouts = items.map { layout(for: $0, width: width) }
                rowHeights = layouts.map(\.height)
                didMutateItems = true
                requiresVisibleRedraw = true
                requiresAnchorRestore = true
                requiresFullOriginRebuild = true
                performanceUpdatePath = "rebuild"
            }
        }

        private func applyFastUpdate(
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
                if oldParent.highlightedMessageID != newParent.highlightedMessageID {
                    if let id = oldParent.highlightedMessageID {
                        affectedIDs.insert(id)
                    }
                    if let id = newParent.highlightedMessageID {
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
                if case let .replace(changedIndexes)? =
                    newParent.rowsUpdateHint?.change,
                   newParent.rowsUpdateHint?.revision == newParent.rowsRevision,
                   newParent.rowsRevision == rowsRevision &+ 1
                {
                    guard changedIndexes.allSatisfy({
                        newRows.indices.contains($0)
                            && items.indices.contains(oldLeadingCount + $0)
                            && items[oldLeadingCount + $0].messageID
                                == newRows[$0].id
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
                    }
                    performanceUpdatePath = "replace-bounded"
                    return true
                }
                guard rowCount == newRows.count,
                      newRows.indices.allSatisfy({
                          items[oldLeadingCount + $0].messageID
                              == newRows[$0].id
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

        private func applyJournalUpdate(
            from oldParent: NativeMessageTimelineView,
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            width: CGFloat
        ) -> Bool {
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
            if oldParent.highlightedMessageID
                != newParent.highlightedMessageID
            {
                if let id = oldParent.highlightedMessageID {
                    changedMessageIDs.insert(id)
                }
                if let id = newParent.highlightedMessageID {
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
            let finalMessageIDs = newRows.map(\.id)
            let oldMessageIDSet = Set(messageIDs)
            let finalMessageIDSet = Set(finalMessageIDs)
            guard oldMessageIDSet.count == messageIDs.count,
                  finalMessageIDSet.count == finalMessageIDs.count
            else {
                performanceFallbackReason =
                    "journal-duplicate-message-id"
                return false
            }
            let removalRowIndexes = messageIDs.indices.filter { rowIndex in
                !finalMessageIDSet.contains(messageIDs[rowIndex])
            }
            guard removalRowIndexes.allSatisfy({
                journalRemovedMessageIDs.contains(messageIDs[$0])
            }) else {
                performanceFallbackReason = "journal-remove-identity"
                return false
            }
            let insertionRowIndexes =
                finalMessageIDs.indices.filter { rowIndex in
                    !oldMessageIDSet.contains(finalMessageIDs[rowIndex])
                }
            guard insertionRowIndexes.allSatisfy({
                journalInsertedMessageIDs.contains(finalMessageIDs[$0])
            }) else {
                performanceFallbackReason = "journal-insert-identity"
                return false
            }
            var appliedMessageIDs = messageIDs
            for rowIndex in removalRowIndexes.reversed() {
                appliedMessageIDs.remove(at: rowIndex)
            }
            for rowIndex in insertionRowIndexes {
                appliedMessageIDs.insert(
                    finalMessageIDs[rowIndex],
                    at: rowIndex
                )
            }
            guard appliedMessageIDs == finalMessageIDs else {
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
                replaceItem(
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
                    && !oldMessageIDSet.contains(firstMessageID)
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

        private func replaceItem(
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

        private func itemAffectsVisibleCoordinates(at index: Int) -> Bool {
            guard let scrollView,
                  rowOrigins.indices.contains(index)
            else { return true }
            let viewport = scrollView.contentView.bounds
            let documentOrigin =
                contentOriginY(viewportHeight: viewport.height)
                    + rowOrigins[index]
            return documentOrigin < viewport.maxY
        }

        private func layout(
            for item: NativeMessageTimelineItem,
            width: CGFloat
        ) -> NativeTimelineRowLayout {
            NativeTimelineRowLayout.make(
                item: item,
                width: width,
                model: parent.model
            )
        }

        private func rebuildOrigins() {
            rowOrigins = Array(repeating: 0, count: rowHeights.count)
            var y: CGFloat = 0
            rowHeights.withUnsafeBufferPointer { buffer in
                for index in buffer.indices {
                    rowOrigins[index] = y
                    y += buffer[index]
                }
            }
            contentHeight = y
        }

        private func appendOrigins(count: Int) {
            guard count > 0, count <= rowHeights.count else { return }
            rowOrigins.reserveCapacity(rowHeights.count)
            var y = contentHeight
            for index in rowHeights.count - count ..< rowHeights.count {
                rowOrigins.append(y)
                y += rowHeights[index]
            }
            contentHeight = y
        }

        private func applySnapshot(
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

        private func updateDocumentSize(_ proposedSize: NSSize) {
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

        private func positionViewportCanvas() {
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
        private func clampToMaterializedHistoryBoundary() -> Bool {
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

        private var allowsProvisionalHistory: Bool {
            parent.isLoadingEarlier
                || followsMaterializedHistoryBoundary
        }

        private func provisionalHistoryMinimumY(
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

        private func historySkeletonPresentation(
            viewportHeight: CGFloat
        ) -> NativeTimelineHistorySkeletonPresentation? {
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
            return NativeTimelineHistorySkeletonPresentation(
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

        private func updateHistorySkeletonPresentation() {
            guard let canvas, let scrollView else { return }
            canvas.updateHistorySkeleton(
                historySkeletonPresentation(
                    viewportHeight:
                        max(1, scrollView.contentView.bounds.height)
                )
            )
        }

        @discardableResult
        private func reconcileViewportGeometryIfNeeded(
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
            if establishedInitialPosition {
                publishInitialPosition(scrollState())
            }
            isApplyingUpdate = false
            reportScrollState(force: true)
            return true
        }

        private func relayoutForWidthChange(_ proposedWidth: CGFloat) {
            _ = reconcileViewportGeometryIfNeeded(
                proposedWidth: proposedWidth
            )
        }

        private func makeItems(
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

        private func makeLeadingItems(
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

        private func messageItem(
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

        private func beginObserving(_ scrollView: NSScrollView) {
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

        private func noteScrollActivity() {
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

        private func finishScrollActivity() {
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

        private func updateInsets() {
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

        private var bottomInset: CGFloat {
            parent.bottomContentInset
                + ChatDetailLayoutPolicy.timelineBottomPadding
        }

        private func contentOriginY(viewportHeight: CGFloat) -> CGFloat {
            leadingHistoryReserve
                + NativeMessageTimelineLayoutPolicy.shortContentTopInset(
                    viewportHeight: viewportHeight,
                    contentHeight: contentHeight,
                    bottomInset: bottomInset,
                    verticalPadding:
                        ChatDetailLayoutPolicy.timelineTopPadding
                )
        }

        private var effectiveContentHeight: CGFloat {
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

        private var scrollableDocumentHeight: CGFloat {
            documentView?.frame.height ?? effectiveContentHeight
        }

        private func visibleAnchor(
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

        private func restore(_ anchor: VisibleAnchor) {
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
        private func applyInitialPositionIfNeeded() -> Bool {
            guard initialPositionConversation != parent.conversation,
                  let target = parent.initialScrollTarget,
                  let scrollView,
                  scrollView.contentView.bounds.width > 1,
                  scrollView.contentView.bounds.height > 1,
                  scroll(to: target, in: scrollView)
            else {
                return false
            }
            initialPositionConversation = parent.conversation
            return true
        }

        private func applyScrollRequestIfNeeded() {
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
        private func scroll(
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

        private func scroll(
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

        private func reportScrollState(force: Bool = false) {
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

        private func publishScrollActivity(_ isActive: Bool) {
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

        private func publishInitialPosition(_ state: TimelineScrollState) {
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

        private func scrollState() -> TimelineScrollState {
            guard let scrollView else {
                return TimelineScrollState(isNearTop: true, isNearBottom: true)
            }
            let visibleRect = scrollView.contentView.bounds
            return TimelineScrollState(
                isNearTop:
                    visibleRect.minY - leadingHistoryReserve
                    < Self.prefetchDistance,
                isNearBottom:
                    NativeMessageTimelineLayoutPolicy.isAtTrueBottom(
                        documentHeight: scrollableDocumentHeight,
                        visibleMaximumY: visibleRect.maxY
                    )
            )
        }

        private func startPerformanceAutoScrollIfNeeded() {
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
                    "SakuraCord timeline benchmark startup: max handoff tick \(maximumHandoffTickInterval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; max canvas draw \(canvas.maximumDrawDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms; max row raster \(canvas.maximumRowRasterDuration * 1_000, format: .fixed(precision: 2), privacy: .public) ms over \(completedHandoffTicks, privacy: .public) ticks (\(delayedHandoffTicks, privacy: .public) above 33 ms)"
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
                let finish: () -> Void = {
                    [weak self, weak canvas, weak displayLinkTicker] in
                    guard !didFinish else { return }
                    didFinish = true
                    displayLinkTicker?.stop()
                    Self.performanceSignposter.endInterval(
                        "MessageTimelineAutoScrollBenchmark",
                        signpost
                    )
                    let summary = String(
                        format:
                            "SakuraCord timeline benchmark: max main-thread tick interval %.2f ms; max scroll work %.2f ms; max canvas draw %.2f ms; max row raster %.2f ms (height %.0f) over %d ticks (%d above 33 ms; max at %d items, y %.0f); history-starved %d ticks (max %d consecutive)",
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
                displayLinkTicker.start(on: canvas) {
                    [weak self, weak scrollView] in
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
                            "SakuraCord delayed timeline tick: \(tickInterval * 1_000, format: .fixed(precision: 2), privacy: .public) ms; last update \(self.performanceUpdatePath, privacy: .public) \(self.lastPerformanceUpdateDuration, format: .fixed(precision: 2), privacy: .public) ms; items \(self.items.count, privacy: .public); revision \(self.rowsRevision, privacy: .public)"
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
}
