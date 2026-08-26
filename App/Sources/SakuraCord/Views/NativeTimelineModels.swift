import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
final class NativeTimelineDisplayLinkTicker: NSObject {
    var displayLink: CADisplayLink?
    var tick: (() -> Void)?

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
    func displayLinkDidFire(_ displayLink: CADisplayLink) {
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

struct MessageTimelineEditRequest: Equatable {
    let id = UUID()
    let messageID: MessageID
}

nonisolated enum TimelineInitialPositionPolicy {
    /// Keep the unread divider in the upper third of the viewport so the
    /// reader sees both prior context and the unread run that follows.
    static let unreadViewportAnchor = UnitPoint(x: 0.5, y: 0.28)
    /// When the acknowledged boundary is older than the loaded page, begin at
    /// that page's oldest row. Earlier unread pages remain above the reader.
    static let unresolvedUnreadViewportAnchor = UnitPoint.top

    static func target(
        firstUnreadMessageID: MessageID?,
        hasExactUnreadBoundary: Bool,
        prefersNewest: Bool
    ) -> MessageTimelineScrollRequest.Target {
        guard !prefersNewest,
              let firstUnreadMessageID
        else {
            return .bottom
        }
        return .message(
            firstUnreadMessageID,
            anchor:
                hasExactUnreadBoundary
                ? unreadViewportAnchor
                : unresolvedUnreadViewportAnchor
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

nonisolated enum TimelineHistoryDirection: CaseIterable, Sendable {
    case earlier
    case later
}

nonisolated enum TimelineHistoryLoadingPolicy {
    static func shouldLoad(
        isNearBoundary: Bool,
        contentFitsViewport: Bool,
        allowsAutomaticLoading: Bool,
        hasMoreMessages: Bool,
        isLoading: Bool,
        requiresUserScrollIntent: Bool,
        hasUserScrollIntent: Bool
    ) -> Bool {
        guard isNearBoundary,
              allowsAutomaticLoading,
              hasMoreMessages,
              !isLoading
        else {
            return false
        }
        return contentFitsViewport
            || !requiresUserScrollIntent
            || hasUserScrollIntent
    }
}

nonisolated enum TimelineHistoryScrollIntentPolicy {
    static func shouldRetain(
        hasIntent: Bool,
        isGestureActive: Bool,
        isInProvisionalHistory: Bool
    ) -> Bool {
        hasIntent && (isGestureActive || isInProvisionalHistory)
    }
}

enum NativeTimelineConversation: Hashable {
    case channel(ChannelID?)
    case thread(ChannelID?)
    case search

    var id: ChannelID? {
        switch self {
        case let .channel(id), let .thread(id):
            id
        case .search:
            nil
        }
    }

    var supportsReply: Bool {
        self != .search
    }

    var activatesMessageOnClick: Bool {
        self == .search
    }

    var messageInteractionContext: NativeTimelineMessageInteractionContext {
        self == .search ? .searchResult : .conversation
    }

    var loaderKind: NativeTimelineLoaderKind {
        switch self {
        case .channel:
            .messages
        case .thread:
            .replies
        case .search:
            .messages
        }
    }

    @MainActor
    func rows(in model: AppModel) -> [MessageRowPresentation] {
        switch self {
        case .channel:
            model.messageRows
        case .thread:
            model.threadMessageRows
        case .search:
            model.messageSearch.rows
        }
    }

    @MainActor
    func rowsRevision(in model: AppModel) -> UInt64 {
        switch self {
        case .channel:
            model.messageRowsRevision
        case .thread:
            model.threadMessageRowsRevision
        case .search:
            model.messageSearch.rowsRevision
        }
    }

    @MainActor
    func rowsUpdateHint(in model: AppModel) -> MessageRowsUpdateHint? {
        switch self {
        case .channel:
            model.messageRowsUpdateHint
        case .thread:
            model.threadMessageRowsUpdateHint
        case .search:
            nil
        }
    }

    @MainActor
    func rowsUpdateJournal(in model: AppModel) -> MessageRowsUpdateJournal {
        switch self {
        case .channel:
            model.messageRowsUpdateJournal
        case .thread:
            model.threadMessageRowsUpdateJournal
        case .search:
            model.messageSearch.rowsUpdateJournal
        }
    }
}

nonisolated enum NativeTimelineMessageInteractionContext: Equatable {
    case conversation
    case searchResult
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

nonisolated struct TimelineHistorySkeletonPresentation: Equatable {
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
        case message(MessageRowIdentity)
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
            .message(row.identity)
        }
    }
}

nonisolated enum NativeTimelineAutomaticHistoryPolicy {
    static func shouldReevaluateAfterUpdate(
        wasLoading: Bool,
        isLoading: Bool,
        previousRowCount: Int,
        currentRowCount: Int
    ) -> Bool {
        wasLoading
            && !isLoading
            && currentRowCount > previousRowCount
    }

}

nonisolated enum NativeTimelineMessageJumpHighlightPolicy {
    static let holdDuration: TimeInterval = 0.3
    static let fadeDuration: TimeInterval = 1.2
    static let totalDuration = holdDuration + fadeDuration

    static func opacity(
        elapsed: TimeInterval,
        reducesMotion: Bool = false
    ) -> CGFloat {
        let elapsed = max(0, elapsed)
        guard elapsed < totalDuration else { return 0 }
        guard !reducesMotion, elapsed > holdDuration else { return 1 }
        let progress = min(
            1,
            (elapsed - holdDuration) / fadeDuration
        )
        let easedProgress = progress * progress * (3 - 2 * progress)
        return CGFloat(1 - easedProgress)
    }
}

nonisolated enum NativeTimelineBenchmarkScrollPolicy {
    // Keep the authenticated workload continuously moving at a speed that is
    // representative of reading/skim scrolling. The former 9,600 pt/s target
    // crossed roughly 160 points per 60 Hz frame, exhausting live history far
    // faster than a person could inspect it and obscuring account-scale costs.
    /// Run for one fixed wall-clock interval at a refresh-independent target
    /// speed. Delayed frames remain part of the result: the step cap avoids
    /// measuring a stall twice, while the artifact records the resulting
    /// spatial deficit instead of censoring the run.
    static let pointsPerSecond: CGFloat = 1_200
    static let maximumStep: CGFloat = 40
    static let duration: TimeInterval = 20
    static let nominalDistance = pointsPerSecond * duration

    static func distance(tickInterval: TimeInterval) -> CGFloat {
        min(
            maximumStep,
            max(0, CGFloat(tickInterval)) * pointsPerSecond
        )
    }

    static func distanceDeficit(completedDistance: CGFloat) -> CGFloat {
        max(0, nominalDistance - completedDistance)
    }

    static func spatialQuality(completedDistance: CGFloat) -> Double {
        min(1, max(0, Double(completedDistance / nominalDistance)))
    }
}

nonisolated struct NativeTimelineBenchmarkScrollController {
    enum Outcome: Equatable {
        case continueBenchmark
        case completed
        case insufficientHistory
        case paginationFailed
    }

    let startedAt: TimeInterval
    private(set) var completedDistance: CGFloat = 0

    mutating func recordTick(
        uptime: TimeInterval,
        previousDocumentY: CGFloat,
        currentDocumentY: CGFloat,
        hasMoreMessages: Bool,
        paginationFailed: Bool = false
    ) -> Outcome {
        let advance = max(0, previousDocumentY - currentDocumentY)
        completedDistance += advance
        if paginationFailed {
            return .paginationFailed
        }
        if advance <= 0.5, !hasMoreMessages {
            return .insufficientHistory
        }
        if uptime - startedAt >= NativeTimelineBenchmarkScrollPolicy.duration {
            return .completed
        }
        return .continueBenchmark
    }
}

enum NativeTimelineBenchmarkFinishOutcome: String {
    case completed
    case insufficientHistory
    case cancelled
    case paginationFailed
}

@MainActor
enum NativeTimelineBenchmarkFinishSequence {
    @discardableResult
    static func run(
        startedAt: TimeInterval,
        now: () -> TimeInterval,
        closeMeasurement: () -> Void,
        performBookkeeping: (_ elapsed: TimeInterval) -> Void
    ) -> TimeInterval {
        let elapsed = now() - startedAt
        closeMeasurement()
        performBookkeeping(elapsed)
        return elapsed
    }
}

nonisolated struct NativeTimelineRenderTelemetry: Equatable, Sendable {
    let canvasDrawCount: Int
    let canvasDrawTotalDuration: TimeInterval
    let canvasDrawMaximumDuration: TimeInterval
    let rowRasterCount: Int
    let rowRasterTotalDuration: TimeInterval
    let rowRasterMaximumDuration: TimeInterval
    let rowRasterMaximumHeight: CGFloat
    let rowBitmapCacheHitCount: Int
    let liveScrollDirectPaintCount: Int

    var canvasDrawAverageDuration: TimeInterval {
        canvasDrawCount > 0
            ? canvasDrawTotalDuration / Double(canvasDrawCount)
            : 0
    }

    var rowRasterAverageDuration: TimeInterval {
        rowRasterCount > 0
            ? rowRasterTotalDuration / Double(rowRasterCount)
            : 0
    }
}

@MainActor
enum NativeTimelineBenchmarkArtifact {
    struct DelayedTick {
        let offset: TimeInterval
        let interval: TimeInterval
    }

    static func write(
        outcome: NativeTimelineBenchmarkFinishOutcome,
        completedDistance: CGFloat,
        elapsed: TimeInterval,
        completedTicks: Int? = nil,
        delayedTicks: Int? = nil,
        tickIntervals: [TimeInterval]? = nil,
        delayedTickSamples: [DelayedTick]? = nil,
        maximumTickInterval: TimeInterval? = nil,
        maximumScrollWork: TimeInterval? = nil,
        historyStarvedTicks: Int? = nil,
        maximumConsecutiveHistoryStarvedTicks: Int? = nil,
        renderTelemetry: NativeTimelineRenderTelemetry? = nil
    ) {
        guard let path = ProcessInfo.processInfo.environment[
            "SAKURACORD_PERFORMANCE_RESULT_PATH"
        ] else { return }
        let deficit = NativeTimelineBenchmarkScrollPolicy.distanceDeficit(
            completedDistance: completedDistance
        )
        let quality = NativeTimelineBenchmarkScrollPolicy.spatialQuality(
            completedDistance: completedDistance
        )
        let duration = NativeTimelineBenchmarkScrollPolicy.duration
        let overshoot = max(0, elapsed - duration)
        var contents = """
        outcome\t\(outcome.rawValue)
        elapsed_seconds\t\(elapsed)
        nominal_duration_seconds\t\(duration)
        elapsed_overshoot_seconds\t\(overshoot)
        completed_distance_points\t\(completedDistance)
        nominal_distance_points\t\(NativeTimelineBenchmarkScrollPolicy.nominalDistance)
        distance_deficit_points\t\(deficit)
        spatial_quality_ratio\t\(quality)

        """
        if let completedTicks,
           let delayedTicks,
           let tickIntervals,
           let delayedTickSamples,
           let maximumTickInterval,
           let maximumScrollWork,
           let historyStarvedTicks,
           let maximumConsecutiveHistoryStarvedTicks
        {
            let sortedTickIntervals = tickIntervals.sorted()
            let medianTickInterval = percentile(
                sortedTickIntervals,
                percentile: 0.50
            )
            let p95TickInterval = percentile(
                sortedTickIntervals,
                percentile: 0.95
            )
            let p99TickInterval = percentile(
                sortedTickIntervals,
                percentile: 0.99
            )
            let delayedTickRate = completedTicks > 0
                ? Double(delayedTicks) / Double(completedTicks)
                : 0
            let delayedTickSampleText = delayedTickSamples.map { sample in
                "\(sample.offset * 1_000):\(sample.interval * 1_000)"
            }.joined(separator: ",")
            contents += """
            completed_ticks\t\(completedTicks)
            delayed_ticks_over_33ms\t\(delayedTicks)
            delayed_tick_rate\t\(delayedTickRate)
            median_tick_interval_ms\t\(medianTickInterval * 1_000)
            p95_tick_interval_ms\t\(p95TickInterval * 1_000)
            p99_tick_interval_ms\t\(p99TickInterval * 1_000)
            maximum_tick_interval_ms\t\(maximumTickInterval * 1_000)
            delayed_tick_samples_offset_ms_interval_ms\t\(delayedTickSampleText)
            maximum_scroll_work_ms\t\(maximumScrollWork * 1_000)
            history_starved_ticks\t\(historyStarvedTicks)
            maximum_consecutive_history_starved_ticks\t\(maximumConsecutiveHistoryStarvedTicks)

            """
        }
        if let renderTelemetry {
            contents += """
            canvas_draw_count\t\(renderTelemetry.canvasDrawCount)
            canvas_draw_total_ms\t\(renderTelemetry.canvasDrawTotalDuration * 1_000)
            canvas_draw_average_ms\t\(renderTelemetry.canvasDrawAverageDuration * 1_000)
            canvas_draw_maximum_ms\t\(renderTelemetry.canvasDrawMaximumDuration * 1_000)
            row_raster_count\t\(renderTelemetry.rowRasterCount)
            row_raster_total_ms\t\(renderTelemetry.rowRasterTotalDuration * 1_000)
            row_raster_average_ms\t\(renderTelemetry.rowRasterAverageDuration * 1_000)
            row_raster_maximum_ms\t\(renderTelemetry.rowRasterMaximumDuration * 1_000)
            row_raster_maximum_height_points\t\(renderTelemetry.rowRasterMaximumHeight)
            row_bitmap_cache_hit_count\t\(renderTelemetry.rowBitmapCacheHitCount)
            live_scroll_direct_paint_count\t\(renderTelemetry.liveScrollDirectPaintCount)

            """
        }
        try? contents.write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func percentile(
        _ sortedValues: [TimeInterval],
        percentile: Double
    ) -> TimeInterval {
        guard !sortedValues.isEmpty else { return 0 }
        let rank = Int(ceil(percentile * Double(sortedValues.count)))
        return sortedValues[min(max(rank - 1, 0), sortedValues.count - 1)]
    }
}

nonisolated enum NativeTimelineReadBoundaryPolicy {
    static func hasReachedNewestMessageBoundary(
        newestMessageMaximumY: CGFloat,
        viewportMinimumY: CGFloat,
        viewportMaximumY: CGFloat,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        newestMessageMaximumY >= viewportMinimumY - tolerance
            && newestMessageMaximumY <= viewportMaximumY + tolerance
    }
}

nonisolated enum NativeTimelineInitialPlacementPolicy {
    /// If the exact unread run and the footer both fit in the viewport, the
    /// newest message is the useful initial anchor. Keeping the first unread
    /// row at the contextual 28% anchor in this case leaves a pointless
    /// scroll range below content the reader can already see and makes the
    /// timeline disagree with its own read-boundary state.
    static func exactUnreadRunFitsAtBottom(
        unreadMinimumY: CGFloat,
        newestMaximumY: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        let unreadRunHeight = max(0, newestMaximumY - unreadMinimumY)
        return unreadRunHeight + max(0, bottomInset)
            <= max(0, viewportHeight) + max(0, tolerance)
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
    struct HistoryReserveUpdate: Equatable {
        let reserve: CGFloat
        let grew: Bool
    }

    static func consumingHistoryReserve(
        _ currentReserve: CGFloat,
        materializedHeight: CGFloat,
        chunk: CGFloat
    ) -> HistoryReserveUpdate {
        let currentReserve = max(0, currentReserve)
        let materializedHeight = max(0, materializedHeight)
        let chunk = max(1, chunk)
        guard materializedHeight > 0 else {
            return HistoryReserveUpdate(
                reserve: currentReserve,
                grew: false
            )
        }
        let remainingReserve = currentReserve - materializedHeight
        let minimumReserve = chunk / 2
        if remainingReserve >= minimumReserve {
            return HistoryReserveUpdate(
                reserve: remainingReserve,
                grew: false
            )
        }
        // A media-heavy page can fit in the current coordinate reserve while
        // consuming nearly all of it. Waiting until the next page exceeds the
        // reserve leaves only a few thousand scroll points of skeleton and
        // visibly pins a fast gesture during the following request. Refill
        // before falling below half a chunk; anchor restoration absorbs the
        // coordinate growth without moving already visible messages.
        let addedChunks = max(
            1,
            ceil((minimumReserve - remainingReserve) / chunk)
        )
        return HistoryReserveUpdate(
            reserve:
                remainingReserve
                + addedChunks * chunk,
            grew: true
        )
    }

    /// Expose the complete bounded reserve above the oldest loaded row while
    /// the user is actively crossing that boundary. The document already
    /// advertises this reserve to AppKit's scroller; exposing only a small
    /// suffix made the viewport stop while the thumb still showed substantial
    /// space above it. Network pagination remains separately bounded to one
    /// in-flight page and requires a live user gesture at unresolved unread
    /// boundaries.
    static func provisionalHistoryDepth(
        reserve: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        max(0, reserve)
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

    static func provisionalHistoryMaximumY(
        materializedMaximumY: CGFloat,
        reserve: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat,
        allowsProvisionalHistory: Bool
    ) -> CGFloat {
        let materializedDocumentHeight =
            materializedMaximumY + max(0, bottomInset)
        let provisionalDepth = allowsProvisionalHistory
            ? provisionalHistoryDepth(
                reserve: reserve,
                viewportHeight: viewportHeight
            )
            : 0
        return max(
            0,
            materializedDocumentHeight + provisionalDepth - viewportHeight
        )
    }

    static func showsHistorySkeleton(
        hasMoreMessages: Bool,
        isLoading: Bool,
        followsMaterializedHistoryBoundary: Bool
    ) -> Bool {
        hasMoreMessages
            && (
                isLoading
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
