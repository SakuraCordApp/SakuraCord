import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

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

enum NativeTimelineConversation: Hashable {
    case channel(ChannelID?)
    case thread(ChannelID?)
    case search
    case pins(ChannelID)
    case inbox(InboxTab)
    case resource(GuildID, ChannelID)

    var id: ChannelID? {
        switch self {
        case let .channel(id), let .thread(id):
            id
        case .pins(let id), .resource(_, let id):
            id
        case .search, .inbox:
            nil
        }
    }

    var supportsReply: Bool {
        self != .search && !isPins && !isInbox && !isResource
    }

    var activatesMessageOnClick: Bool {
        self == .search || isPins || isInbox
    }

    nonisolated var alignsUnderfilledContentToTop: Bool {
        switch self {
        case .search, .pins, .inbox, .resource:
            true
        case .channel, .thread:
            false
        }
    }

    var messageInteractionContext: NativeTimelineMessageInteractionContext {
        if self == .inbox(.mentions) { return .inboxMention }
        if isInbox { return .inboxResult }
        if self == .search { return .searchResult }
        return isPins ? .pinnedResult : .conversation
    }

    var loaderKind: NativeTimelineLoaderKind {
        switch self {
        case .channel:
            .messages
        case .thread:
            .replies
        case .search, .resource:
            .messages
        case .inbox:
            .messages
        case .pins:
            .pins
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
        case .pins:
            model.pinnedMessages.rows
        case .inbox:
            model.inbox.rows
        case .resource(_, let channelID):
            model.guideResource(for: channelID)?.rows ?? []
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
        case .inbox:
            model.inbox.rowsRevision
        case .pins:
            model.pinnedMessages.rowsRevision
        case .resource(_, let channelID):
            model.guideResource(for: channelID)?.revision ?? 0
        }
    }

    @MainActor
    func rowsUpdateHint(in model: AppModel) -> MessageRowsUpdateHint? {
        switch self {
        case .channel:
            model.messageRowsUpdateHint
        case .thread:
            model.threadMessageRowsUpdateHint
        case .search, .pins, .inbox, .resource:
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
        case .inbox:
            model.inbox.rowsUpdateJournal
        case .pins:
            model.pinnedMessages.rowsUpdateJournal
        case .resource(_, let channelID):
            model.guideResource(for: channelID)?.journal ?? MessageRowsUpdateJournal()
        }
    }

    var isResource: Bool {
        if case .resource = self { return true }
        return false
    }

    var isInbox: Bool {
        if case .inbox = self { return true }
        return false
    }

    private var isPins: Bool {
        if case .pins = self { return true }
        return false
    }
}

nonisolated enum NativeTimelineMessageInteractionContext: Equatable {
    case conversation
    case searchResult
    case pinnedResult
    case inboxResult
    case inboxMention
}

nonisolated enum NativeTimelineLoaderKind: Equatable {
    case messages
    case replies
    case pins

    var loadingLabel: String {
        switch self {
        case .messages:
            "Loading earlier messages…"
        case .replies:
            "Loading earlier replies…"
        case .pins:
            "Loading more pinned messages…"
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
        startedAt: Date?,
        isForumPost: Bool = false
    )

    var id: ChannelID {
        switch self {
        case let .channel(channel, _):
            channel.id
        case let .thread(id, _, _, _, _):
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
        case let .thread(_, title, _, _, _):
            title
        }
    }

    /// The channel's own topic, if it has one.
    var topic: String? {
        guard case let .channel(channel, _) = self,
              let topic = channel.topic?.trimmingCharacters(in: .whitespacesAndNewlines),
              !topic.isEmpty
        else { return nil }
        return topic
    }

    var description: String {
        if let topic { return topic }
        switch self {
        case let .channel(channel, _):
            switch channel.kind {
            case .directMessage, .groupDirectMessage:
                return "This is the beginning of your direct message history."
            case .voice:
                return "This is the start of the \(channel.name) voice channel chat."
            default:
                return "This is the start of the #\(channel.name) channel."
            }
        case let .thread(_, _, starterName?, _, _):
            return "Started by \(starterName)"
        case .thread:
            return "This is the start of the thread."
        }
    }

    var isDescriptionSelectable: Bool {
        switch self {
        case .channel:
            true
        case let .thread(_, _, starterName, _, _):
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
        case let .thread(_, _, _, _, isForumPost):
            return ChannelIconPresentation.threadSystemImage(isForumPost: isForumPost)
        }
    }

    var startedAt: Date? {
        guard case let .thread(_, _, _, startedAt, _) = self else { return nil }
        return startedAt
    }

}

enum NativeMessageTimelineItem: Equatable {
    nonisolated enum Identifier: Hashable {
        case suppressedMessages(MessageID)
        case beginning(ChannelID)
        case inboxGroup(ChannelID)
        case inboxForumPost(ChannelID)
        case inboxEvent(ScheduledEventID)
        case loader
        case message(MessageRowIdentity)
    }

    case suppressedMessages(SuppressedMessageGroup)
    case beginning(NativeTimelineBeginning)
    case inboxGroup(InboxGroupHeaderPresentation)
    case inboxForumPost(ForumPost)
    case inboxEvent(InboxScheduledEvent)
    case loader(isLoading: Bool, kind: NativeTimelineLoaderKind)
    case message(
        MessageRowPresentation,
        isUnreadBoundary: Bool,
        isHighlighted: Bool
    )

    var messageID: MessageID? {
        switch self {
        case let .message(row, _, _): row.id
        // A concealed run is still a message boundary for scrolling and read
        // acknowledgement. Revealed runs use their original rows instead.
        case let .suppressedMessages(group) where !group.isRevealed: group.id
        default: nil
        }
    }

    func containsMessage(_ id: MessageID) -> Bool {
        if case let .suppressedMessages(group) = self {
            return !group.isRevealed && group.messageIDs.contains(id)
        }
        return messageID == id
    }

    var messageRow: MessageRowPresentation? {
        guard case let .message(row, _, _) = self else { return nil }
        return row
    }

    var beginning: NativeTimelineBeginning? {
        guard case let .beginning(beginning) = self else { return nil }
        return beginning
    }

    /// The ID that keys this row's text state, such as revealed spoilers: its
    /// message's, or for a channel's beginning, the channel's.
    var textOwnerID: MessageID? {
        messageID ?? beginning.map { MessageID(rawValue: $0.id.rawValue) }
    }

    var identifier: Identifier {
        switch self {
        case let .suppressedMessages(group):
            .suppressedMessages(group.id)
        case let .inboxEvent(event):
            .inboxEvent(event.id)
        case let .inboxGroup(header):
            .inboxGroup(header.channelID)
        case let .inboxForumPost(post):
            .inboxForumPost(post.id)
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

    /// A fully loaded conversation without messages has reached its newest
    /// edge once the end of the document is in view. Without this the first
    /// message to arrive would be treated as unseen and plant a NEW divider,
    /// while a viewport scrolled away from the end must not read it.
    static func hasReachedEmptyTimelineBoundary(
        hasMoreEarlier: Bool,
        isLoadingEarlier: Bool,
        isLoadingLater: Bool,
        isAtDocumentBottom: Bool
    ) -> Bool {
        !hasMoreEarlier && !isLoadingEarlier && !isLoadingLater
            && isAtDocumentBottom
    }

    /// AppKit reports wheel and trackpad deltas after applying the natural
    /// scrolling preference, so a negative vertical delta moves the viewport
    /// toward the newest message at the bottom of the timeline.
    static func isScrollTowardNewest(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        deltaY < 0 && abs(deltaY) > abs(deltaX)
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
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maximumY = max(0, contentHeight - viewportHeight)
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

}

@MainActor
final class NativeTimelineDocumentView: NSView {
    override var isFlipped: Bool { true }
}
