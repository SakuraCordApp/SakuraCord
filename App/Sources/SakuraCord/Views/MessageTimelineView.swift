import SakuraCordModels
import SwiftUI

struct MessageTimelineView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    var editRequest: MessageTimelineEditRequest?
    private let runsPerformanceAutoScroll =
        AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        .runsChatPerformanceAutoScroll
    @State private var scrollPolicy = MessageTimelineScrollPolicy()
    @State private var allowsAutomaticHistoryLoading = false
    @State private var historyPaging = TimelineHistoryPaging()
    @State private var highlightedMessageID: MessageID?
    @State private var hasEstablishedInitialPosition = false
    @State private var scrollRequest: MessageTimelineScrollRequest?
    @State private var latestScrollState = TimelineScrollState(
        isNearTop: false,
        isNearBottom: false,
        contentFitsViewport: false
    )

    var body: some View {
        let conversationID = model.selectedChannelID
        let unread = unreadPresentation
        let hasUnreadMessages = conversationID.map { model.isChannelUnread($0) } ?? false
        let showsLoadingSkeleton = MessageTimelineLoadingPolicy.showsInitialPlaceholder(
            isLoading: model.isLoadingMessages,
            messageCount: model.messages.count
        )
        NativeMessageTimelineView(
            model: model,
            conversation: .channel(conversationID),
            beginning: beginningChannel.map {
                .channel(
                    $0,
                    rulesChannelID: beginningRulesChannelID
                )
            },
            firstMessageStartsDayOverride: nil,
            hasMoreMessages: model.hasMoreMessages,
            hasMoreLaterMessages: model.hasMoreLaterMessages,
            isLoadingEarlier:
                MessageTimelineLoadingPolicy.showsEarlierIndicator(
                    isLoadingInitialPage: model.isLoadingMessages,
                    messageCount: model.messages.count,
                    isLoadingEarlierPage: model.isLoadingEarlier
                ),
            isLoadingLater: model.isLoadingLater,
            earlierHistoryLoadFailed:
                model.messageLoadErrorIsEarlierPage
                    && model.messageLoadError != nil,
            laterHistoryLoadFailed:
                model.messageLoadErrorIsLaterPage
                    && model.messageLoadError != nil,
            bottomContentInset: bottomContentInset,
            unreadMessageID: unread.dividerMessageID,
            highlightedMessageID: highlightedMessageID,
            selectedMessageID: model.replyingTo?.id,
            initialScrollTarget: unread.initialScrollTarget,
            scrollRequest: scrollRequest,
            editRequest: editRequest,
            runsPerformanceAutoScroll: runsPerformanceAutoScroll,
            loadEarlier: loadEarlier,
            loadLater: loadLater,
            openReply: openReply,
            onScrollActivityChange: { isScrolling in
                if let conversationID {
                    model.reportTimelineLiveScrolling(
                        isScrolling,
                        conversationID: conversationID
                    )
                }
            },
            onScrollStateChange: handleScrollState,
            onInitialPositionEstablished: handleInitialPosition,
            onUserScrollBegan: handleUserScrollBegan,
            onUserScrollEnded: handleUserScrollEnded,
            onUserScrollTowardNewest: handleUserScrollTowardNewest
        )
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .opacity(showsLoadingSkeleton ? 0 : 1)
        .allowsHitTesting(!showsLoadingSkeleton)
        .accessibilityHidden(showsLoadingSkeleton)
        .overlay {
            if showsLoadingSkeleton {
                MessageTimelineLoadingSkeleton(
                    bottomContentInset: bottomContentInset
                )
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: InterfaceScale.metric(8)) {
                if let error = model.messageLoadError {
                    MessageLoadErrorBanner(message: error, retry: model.retryMessageLoad)
                }
                if let channelID = model.selectedChannelID,
                   let summary = unread.summary
                {
                    UnreadMessagesBanner(
                        summary: summary,
                        isLoadingHistory: model.isLoadingMessages || model.isLoadingEarlier,
                        jumpToUnread: {
                            model.jumpToUnreadBoundary(channelID: channelID)
                        },
                        markRead: {
                            model.markConversationRead(channelID: channelID)
                        }
                    )
                }
            }
            .padding(InterfaceScale.metric(8))
        }
        .overlay(alignment: .bottom) {
            if hasEstablishedInitialPosition,
               !scrollPolicy.isNearBottom,
               !model.messages.isEmpty
            {
                TimelineNewestButton(
                    title: hasUnreadMessages ? "New messages" : "Scroll to bottom",
                    hasUnread: hasUnreadMessages,
                    bottomContentInset: bottomContentInset,
                    accessibilityHint: "Scrolls to the latest message"
                ) {
                    handleUserScrollTowardNewest()
                    if model.hasMoreLaterMessages {
                        Task {
                            await model.loadNewestMessageWindow()
                        }
                    } else {
                        scrollPolicy.didRequestBottom()
                        requestScroll(.bottom, glides: true)
                    }
                }
            }
        }
        .onChange(of: model.selectedChannelID) { oldID, _ in
            if let oldID {
                model.reportTimelineLiveScrolling(
                    false,
                    conversationID: oldID
                )
            }
            hasEstablishedInitialPosition = false
            historyPaging = TimelineHistoryPaging()
            scrollPolicy.didBeginChannel()
            latestScrollState = TimelineScrollState(
                isNearTop: false,
                isNearBottom: false,
                contentFitsViewport: false
            )
        }
        .onChange(of: model.messageNavigationRequest) { _, request in
            guard let request,
                  request.channelID == model.selectedChannelID,
                  model.messages.contains(where: { $0.id == request.messageID })
            else { return }
            scrollPolicy.didNavigateAwayFromBottom()
            requestScroll(
                .message(request.messageID, anchor: request.isUnreadBoundary
                    ? TimelineInitialPositionPolicy.unreadViewportAnchor : .center),
                glides: request.glides
            )
            if !request.isUnreadBoundary {
                highlight(request.messageID)
            }
            model.completeMessageNavigation(requestID: request.requestID)
        }
        .onChange(of: model.conversationNewestRequest) { _, request in
            guard let request,
                  request.channelID == model.selectedChannelID
            else { return }
            scrollPolicy.didRequestBottom()
            requestScroll(.bottom)
            model.completeConversationNewestRequest(requestID: request.requestID)
        }
        .onChange(of: model.replyingTo?.id) { _, messageID in
            guard let messageID else { return }
            requestScroll(.message(messageID, anchor: .center), glides: true)
        }
        .task(id: model.selectedChannelID) {
            allowsAutomaticHistoryLoading = false
            historyPaging = TimelineHistoryPaging()
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            allowsAutomaticHistoryLoading = true
            loadHistoryIfNeeded(for: latestScrollState)
        }
        .onDisappear {
            if let conversationID {
                model.reportTimelineLiveScrolling(
                    false,
                    conversationID: conversationID
                )
            }
        }
        .onExitCommand {
            model.handleTimelineEscape(in: .channel, conversationID: conversationID)
        }
    }

    private var beginningChannel: Channel? {
        guard let channel = model.selectedChannel,
              ConversationBeginningPolicy.showsBeginning(
                  isLoading: model.isLoadingMessages,
                  hasMoreBefore: model.hasMoreMessages,
                  hasError: model.messageLoadError != nil
              )
        else { return nil }
        return channel
    }

    private var beginningRulesChannelID: ChannelID? {
        guard let channel = beginningChannel,
              let guild = model.selectedGuild, guild.id == channel.guildID
        else { return nil }
        return guild.rulesChannelID
    }

    private func loadEarlier() {
        Task {
            await model.loadEarlier()
        }
    }

    private func loadLater() {
        Task {
            await model.loadLater()
        }
    }

    private func openReply(_ messageID: MessageID) {
        if model.messages.contains(where: { $0.id == messageID }) {
            scrollPolicy.didNavigateAwayFromBottom()
            requestScroll(.message(messageID, anchor: .center), glides: true)
            highlight(messageID)
        } else if let channel = model.selectedChannel {
            model.navigate(
                to: channel.guildID,
                channelID: channel.id,
                messageID: messageID
            )
        }
    }

    private var unreadPresentation: TimelineUnreadPresentation {
        TimelineUnreadPresentation(
            model: model,
            conversationID: model.selectedChannelID,
            messages: model.messages,
            hasMoreBefore: model.hasMoreMessages,
            isLoadingInitialPage: model.isLoadingMessages,
            hasCompletedInitialLoad: model.hasCompletedInitialMessageLoad,
            showsSummary: !model.hasMoreLaterMessages,
            prefersNewest: { _ in false }
        )
    }

    private func handleInitialPosition(_ state: TimelineScrollState) {
        guard !hasEstablishedInitialPosition,
              state.hasEstablishedInitialPosition,
              let channelID = model.selectedChannelID
        else {
            return
        }
        hasEstablishedInitialPosition = true
        latestScrollState = state
        let hasReachedReadBoundary =
            TimelineReadEligibilityPolicy.hasReachedReadBoundary(state)
        if hasReachedReadBoundary {
            scrollPolicy.didRequestBottom()
        } else {
            scrollPolicy.didNavigateAwayFromBottom()
        }
        model.reportTimelineInitialPosition(
            channelID: channelID,
            hasReachedReadBoundary: hasReachedReadBoundary
        )
    }

    private func requestScroll(_ target: MessageTimelineScrollRequest.Target, glides: Bool = false) {
        scrollRequest = MessageTimelineScrollRequest(target: target, isAnimated: glides)
    }

    private func highlight(_ messageID: MessageID) {
        highlightedMessageID = messageID
        Task {
            try? await Task.sleep(
                for: .seconds(
                    NativeTimelineMessageJumpHighlightPolicy.totalDuration
                )
            )
            if highlightedMessageID == messageID {
                highlightedMessageID = nil
            }
        }
    }

    private func handleScrollState(_ value: TimelineScrollState) {
        latestScrollState = value
        let retainedPaging = historyPaging.retained(for: value)
        if historyPaging != retainedPaging {
            historyPaging = retainedPaging
        }
        if scrollPolicy.isNearBottom != value.isNearBottom {
            scrollPolicy.updateGeometry(isNearBottom: value.isNearBottom)
        }
        loadHistoryIfNeeded(for: value)
        guard value.hasEstablishedInitialPosition else { return }
        if !hasEstablishedInitialPosition {
            // Exact viewport state is repeatable, so it also recovers if a
            // one-shot initial callback was superseded by another AppKit
            // update before delivery.
            handleInitialPosition(value)
            return
        }
        if let channelID = model.selectedChannelID {
            model.reportTimelinePosition(
                channelID: channelID,
                hasReachedReadBoundary:
                    TimelineReadEligibilityPolicy.hasReachedReadBoundary(value)
            )
        }
    }

    private func loadHistoryIfNeeded(for state: TimelineScrollState) {
        let directions = historyPaging.directionsToLoad(
            for: state,
            allowsAutomaticLoading: allowsAutomaticHistoryLoading,
            edges: TimelineHistoryEdges(
                hasMoreEarlier: model.hasMoreMessages,
                hasMoreLater: model.hasMoreLaterMessages,
                isLoadingEarlier: model.isLoadingEarlier,
                isLoadingLater: model.isLoadingLater,
                earlierRequiresIntent: unreadPresentation.hasUnresolvedInitialBoundary
            )
        )
        for direction in directions {
            switch direction {
            case .earlier: loadEarlier()
            case .later: loadLater()
            }
        }
    }

    private func handleUserScrollBegan() {
        scrollPolicy.userScrollBegan()
        historyPaging.gestureBegan(
            grantsEarlierIntent: unreadPresentation.hasUnresolvedInitialBoundary,
            isNearLoadedBottom: latestScrollState.isNearLoadedBottom
        )
    }

    private func handleUserScrollTowardNewest() {
        if let channelID = model.selectedChannelID {
            model.reportTimelineScrollTowardNewest(channelID: channelID)
        }
    }

    private func handleUserScrollEnded(_ value: TimelineScrollState) {
        historyPaging.gestureEnded(value)
        scrollPolicy.userScrollEnded(isNearBottom: value.isNearBottom)
        loadHistoryIfNeeded(for: value)
    }
}

struct DateSeparator: View {
    let date: Date
    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            separatorLine
            Text(date, format: .dateTime.day().month(.wide).year())
                .font(.interface(.caption2).weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            separatorLine
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Messages from \(date.formatted(date: .long, time: .omitted))")
    }

    private var separatorLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
    }
}

struct NewMessagesSeparator: View {
    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Rectangle()
                .fill(Color.red)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
            Text("NEW")
                .font(.interface(.caption2).weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, InterfaceScale.metric(7))
                .padding(.vertical, InterfaceScale.metric(3))
                .background(Color.red, in: Capsule())
        }
        .padding(.leading, InterfaceScale.metric(14))
        .padding(.trailing, InterfaceScale.metric(10))
        .padding(.vertical, InterfaceScale.metric(5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }
}

struct UnreadMessagesBanner: View {
    let summary: AccountReadStateModel.TimelineUnreadSummary
    let isLoadingHistory: Bool
    let jumpToUnread: () -> Void
    let markRead: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: InterfaceScale.metric(8)) {
                Text(message)
                    .lineLimit(1)
                    .padding(.leading, InterfaceScale.metric(12))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Spacer(minLength: InterfaceScale.metric(8))
                Button(action: markRead) {
                    Label("Mark as Read", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, InterfaceScale.metric(2))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .tint(SakuraCordAccentColor.color)
                .fixedSize()
                .accessibilityHint("Marks this conversation read")
            }
            .font(.interface(.callout).weight(.semibold))
            .padding(InterfaceScale.metric(4))
            .background {
                Button(action: jumpToUnread) {
                    Capsule()
                        .fill(.clear)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingHistory)
                .accessibilityLabel(message)
                .accessibilityHint("Jumps to the first unread message")
            }
            .glassEffect(.regular, in: Capsule())
        }
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        let count = summary.loadedUnreadCount.formatted()
        let noun = summary.loadedUnreadCount == 1 ? "message" : "messages"
        if summary.isLowerBound {
            return "\(count)+ new \(noun)"
        }
        let time = summary.firstUnreadTimestamp.formatted(
            date: .omitted,
            time: .shortened
        )
        return "\(count) new \(noun) since \(time)"
    }
}

/// A conversation timeline's unread boundary and the position it opens at.
/// Channel and thread timelines derive it the same way from their own store.
struct TimelineUnreadPresentation {
    let summary: AccountReadStateModel.TimelineUnreadSummary?
    /// The exact divider, when read state knows it.
    let dividerMessageID: MessageID?
    let initialScrollTarget: MessageTimelineScrollRequest.Target?
    /// Until the boundary page loads, earlier history waits for scroll intent.
    let hasUnresolvedInitialBoundary: Bool

    /// - Parameters:
    ///   - showsSummary: False while a detached later page is presented.
    ///   - prefersNewest: Whether to open at the newest message, given
    ///     whether unread messages exist.
    init(
        model: AppModel,
        conversationID: ChannelID?,
        messages: [Message],
        hasMoreBefore: Bool,
        isLoadingInitialPage: Bool,
        hasCompletedInitialLoad: Bool,
        showsSummary: Bool = true,
        prefersNewest: (_ hasUnread: Bool) -> Bool
    ) {
        let summary = showsSummary ? conversationID.flatMap {
            model.timelineUnreadSummary(
                channelID: $0,
                messages: messages,
                hasMoreBefore: hasMoreBefore || (isLoadingInitialPage && !messages.isEmpty)
            )
        } : nil
        let dividerMessageID = conversationID.flatMap { model.unreadDividerMessageID(channelID: $0) }
        let loadedDividerMessageID = dividerMessageID.flatMap { id in
            messages.contains(where: { $0.id == id }) ? id : nil
        }
        self.summary = summary
        self.dividerMessageID = dividerMessageID
        hasUnresolvedInitialBoundary = loadedDividerMessageID == nil && summary?.isLowerBound == true
        initialScrollTarget = TimelineInitialPositionPolicy.targetWhenReady(
            hasCompletedInitialLoad: hasCompletedInitialLoad,
            firstUnreadMessageID: loadedDividerMessageID ?? summary?.firstUnreadMessageID,
            hasExactUnreadBoundary: loadedDividerMessageID != nil || summary?.isLowerBound == false,
            prefersNewest: prefersNewest(summary != nil)
        )
    }
}

/// User scroll intent that lets history load past a provisional boundary. It
/// lasts for a whole live gesture, then while the viewport stays provisional.
struct TimelineHistoryScrollIntent: Equatable {
    private(set) var hasIntent = false
    private(set) var isGestureActive = false

    mutating func gestureBegan(grantsIntent: Bool) {
        isGestureActive = true
        if grantsIntent { hasIntent = true }
    }

    mutating func gestureEnded(isInProvisionalHistory: Bool) {
        isGestureActive = false
        self = retained(isInProvisionalHistory: isInProvisionalHistory)
    }

    func retained(isInProvisionalHistory: Bool) -> Self {
        var next = self
        next.hasIntent = TimelineHistoryScrollIntentPolicy.shouldRetain(
            hasIntent: hasIntent,
            isGestureActive: isGestureActive,
            isInProvisionalHistory: isInProvisionalHistory
        )
        return next
    }
}

/// What a timeline's store can load at each history edge.
struct TimelineHistoryEdges {
    let hasMoreEarlier: Bool
    let hasMoreLater: Bool
    let isLoadingEarlier: Bool
    let isLoadingLater: Bool
    /// Earlier history waits for scroll intent until the unread boundary loads.
    let earlierRequiresIntent: Bool
}

/// Automatic loading at a timeline's earlier and later history edges. The
/// channel and thread timelines drive it from their own stores.
struct TimelineHistoryPaging: Equatable {
    private var earlierIntent = TimelineHistoryScrollIntent()
    private var laterIntent = TimelineHistoryScrollIntent()

    func retained(for state: TimelineScrollState) -> Self {
        var next = self
        next.earlierIntent = earlierIntent.retained(isInProvisionalHistory: state.isInProvisionalHistory)
        next.laterIntent = laterIntent.retained(isInProvisionalHistory: state.isInProvisionalLaterHistory)
        return next
    }

    /// Keeps intent for the whole live gesture. A fast scroll can consume
    /// more than one bounded page before AppKit ends the live scroll;
    /// clearing intent after the first page strands the viewport against a
    /// still-provisional boundary.
    mutating func gestureBegan(grantsEarlierIntent: Bool, isNearLoadedBottom: Bool) {
        laterIntent.gestureBegan(grantsIntent: isNearLoadedBottom)
        earlierIntent.gestureBegan(grantsIntent: grantsEarlierIntent)
    }

    mutating func gestureEnded(_ state: TimelineScrollState) {
        earlierIntent.gestureEnded(isInProvisionalHistory: state.isInProvisionalHistory)
        laterIntent.gestureEnded(isInProvisionalHistory: state.isInProvisionalLaterHistory)
    }

    func directionsToLoad(
        for state: TimelineScrollState,
        allowsAutomaticLoading: Bool,
        edges: TimelineHistoryEdges
    ) -> [TimelineHistoryDirection] {
        TimelineHistoryDirection.allCases.filter { direction in
            let isEarlier = direction == .earlier
            return TimelineHistoryLoadingPolicy.shouldLoad(
                isNearBoundary: isEarlier ? state.isNearTop : state.isNearLoadedBottom,
                contentFitsViewport: state.contentFitsViewport,
                allowsAutomaticLoading: allowsAutomaticLoading,
                hasMoreMessages: isEarlier ? edges.hasMoreEarlier : edges.hasMoreLater,
                isLoading: isEarlier ? edges.isLoadingEarlier : edges.isLoadingLater,
                requiresUserScrollIntent: isEarlier && edges.earlierRequiresIntent,
                hasUserScrollIntent: isEarlier ? earlierIntent.hasIntent : laterIntent.hasIntent
            )
        }
    }
}

/// Returns a timeline to its newest message, highlighting unread messages.
struct TimelineNewestButton: View {
    let title: String
    let hasUnread: Bool
    let bottomContentInset: CGFloat
    let accessibilityHint: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .contentTransition(.opacity)
            } icon: {
                Image(systemName: "arrow.down")
                    .symbolEffect(.bounce, value: hasUnread)
                    .symbolEffectsRemoved(reduceMotion)
            }
            .font(.interface(.callout).weight(.semibold))
            .foregroundStyle(.primary)
            .environment(\.colorScheme, hasUnread ? .dark : colorScheme)
            .padding(.horizontal, InterfaceScale.metric(15))
            .padding(.vertical, InterfaceScale.metric(8))
            .contentShape(Capsule())
            .glassEffect(
                hasUnread
                    ? .regular.tint(SakuraCordAccentColor.color).interactive()
                    : .regular.interactive(),
                in: Capsule()
            )
            .animation(
                reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.18),
                value: hasUnread
            )
        }
        .buttonStyle(.plain)
        .padding(
            .bottom,
            ChatDetailLayoutPolicy.newMessagesButtonBottomPadding(
                bottomContentInset: bottomContentInset
            )
        )
        .accessibilityHint(accessibilityHint)
    }
}

nonisolated struct TimelineScrollState: Equatable, Sendable {
    let isNearTop: Bool
    let isNearBottom: Bool
    let isNearLoadedBottom: Bool
    let contentFitsViewport: Bool
    let hasEstablishedInitialPosition: Bool
    let hasReachedNewestMessageBoundary: Bool
    let isInProvisionalHistory: Bool
    let isInProvisionalLaterHistory: Bool
    /// Where the reader is: the message at the viewport's top and its
    /// offset from the viewport's top edge.
    let readingMessage: ReadingMessage?

    struct ReadingMessage: Equatable, Sendable {
        let id: MessageID
        let offsetFromViewportTop: CGFloat
    }

    /// Ignores the reading offset, which changes on every scrolled frame;
    /// the timeline reports it again when a scroll gesture settles.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isNearTop == rhs.isNearTop
            && lhs.isNearBottom == rhs.isNearBottom
            && lhs.isNearLoadedBottom == rhs.isNearLoadedBottom
            && lhs.contentFitsViewport == rhs.contentFitsViewport
            && lhs.hasEstablishedInitialPosition == rhs.hasEstablishedInitialPosition
            && lhs.hasReachedNewestMessageBoundary == rhs.hasReachedNewestMessageBoundary
            && lhs.isInProvisionalHistory == rhs.isInProvisionalHistory
            && lhs.isInProvisionalLaterHistory == rhs.isInProvisionalLaterHistory
            && lhs.readingMessage?.id == rhs.readingMessage?.id
    }

    init(
        isNearTop: Bool,
        isNearBottom: Bool,
        isNearLoadedBottom: Bool? = nil,
        contentFitsViewport: Bool = false,
        hasEstablishedInitialPosition: Bool = false,
        hasReachedNewestMessageBoundary: Bool = false,
        isInProvisionalHistory: Bool = false,
        isInProvisionalLaterHistory: Bool = false,
        readingMessage: ReadingMessage? = nil
    ) {
        self.isNearTop = isNearTop
        self.isNearBottom = isNearBottom
        self.isNearLoadedBottom = isNearLoadedBottom ?? isNearBottom
        self.contentFitsViewport = contentFitsViewport
        self.hasEstablishedInitialPosition =
            hasEstablishedInitialPosition
        self.hasReachedNewestMessageBoundary =
            hasReachedNewestMessageBoundary
        self.isInProvisionalHistory = isInProvisionalHistory
        self.isInProvisionalLaterHistory =
            isInProvisionalLaterHistory
        self.readingMessage = readingMessage
    }

}

nonisolated enum TimelineReadEligibilityPolicy {
    static func hasReachedReadBoundary(
        _ state: TimelineScrollState
    ) -> Bool {
        state.hasEstablishedInitialPosition
            && state.hasReachedNewestMessageBoundary
    }
}

struct MessageTimelineScrollPolicy: Equatable {
    private(set) var isNearBottom = true
    private(set) var followsNewMessages = true

    mutating func updateGeometry(isNearBottom: Bool) {
        guard self.isNearBottom != isNearBottom else { return }
        self.isNearBottom = isNearBottom
    }

    mutating func userScrollBegan() {
        followsNewMessages = false
    }

    mutating func userScrollEnded(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
        followsNewMessages = isNearBottom
    }

    mutating func didRequestBottom() {
        isNearBottom = true
        followsNewMessages = true
    }

    mutating func didNavigateAwayFromBottom() {
        isNearBottom = false
        followsNewMessages = false
    }

    mutating func didBeginChannel() {
        isNearBottom = false
        followsNewMessages = false
    }
}

enum MessageTimelineLoadingPolicy {
    static func showsInitialPlaceholder(isLoading: Bool, messageCount: Int) -> Bool {
        isLoading && messageCount == 0
    }

    static func showsEarlierIndicator(
        isLoadingInitialPage: Bool,
        messageCount: Int,
        isLoadingEarlierPage: Bool
    ) -> Bool {
        isLoadingEarlierPage
            || (isLoadingInitialPage && messageCount > 0)
    }
}

nonisolated enum TimelineUnreadBoundaryPolicy {
    static func displayedMessageID(
        firstUnreadMessageID: MessageID?,
        isLowerBound: Bool
    ) -> MessageID? {
        guard !isLowerBound else { return nil }
        return firstUnreadMessageID
    }
}

struct MessageTimelineLoadingSkeleton: View {
    var bottomContentInset: CGFloat = 0

    private static let patterns = [
        MessageTimelineSkeletonRow(id: 0, firstLineWidth: 132, secondLineWidth: 330),
        MessageTimelineSkeletonRow(id: 1, firstLineWidth: 94, secondLineWidth: 470),
        MessageTimelineSkeletonRow(id: 2, firstLineWidth: 156, secondLineWidth: 280),
        MessageTimelineSkeletonRow(id: 3, firstLineWidth: 116, secondLineWidth: 410),
        MessageTimelineSkeletonRow(id: 4, firstLineWidth: 142, secondLineWidth: 355),
        MessageTimelineSkeletonRow(id: 5, firstLineWidth: 102, secondLineWidth: 445),
    ]

    var body: some View {
        SkeletonShimmerTimeline {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: InterfaceScale.metric(20)) {
                    ForEach(
                        0 ..< MessageTimelineSkeletonLayout.rowCount(
                            for: max(0, geometry.size.height - bottomContentInset)
                        ),
                        id: \.self
                    ) { index in
                        MessageTimelineSkeletonMessage(
                            row: Self.patterns[index % Self.patterns.count],
                            availableLineWidth: max(120, geometry.size.width - 84)
                        )
                    }
                }
                .padding(.horizontal, InterfaceScale.metric(16))
                .padding(.vertical, InterfaceScale.metric(18))
                .frame(
                    maxWidth: .infinity,
                    minHeight: 0,
                    maxHeight: max(0, geometry.size.height - bottomContentInset),
                    alignment: .topLeading
                )
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // The timeline itself extends through the top scroll-edge safe area so
        // messages can flow beneath the translucent channel toolbar. Cover
        // that same complete viewport during an initial load. The native
        // timeline is hidden while these placeholders share the window background.
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading messages")
    }
}

struct ChannelBeginningView: View {
    let channel: Channel
    let rulesChannelID: ChannelID?

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(9)) {
            Image(systemName: symbol)
                .font(.interfaceSystem(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(68), height: InterfaceScale.metric(68))
                .background(.quaternary, in: Circle())

            Text(title)
                .font(.interface(.largeTitle).weight(.bold))
                .textSelection(.enabled)
                .tint(SakuraCordAccentColor.color)

            Text(description)
                .font(.interface(.body))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .tint(SakuraCordAccentColor.color)
        }
        .padding(.horizontal, InterfaceScale.metric(16))
        .padding(.top, InterfaceScale.metric(28))
        .padding(.bottom, InterfaceScale.metric(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        return switch channel.kind {
        case .directMessage, .groupDirectMessage:
            "Beginning of your conversation with \(channel.name)"
        case .voice:
            "Welcome to \(channel.name)!"
        default:
            "Welcome to #\(channel.name)!"
        }
    }

    private var description: String {
        if let topic = channel.topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
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
    }

    private var symbol: String {
        if rulesChannelID == channel.id {
            return "newspaper.fill"
        }
        return switch channel.kind {
        case .directMessage: "person.fill"
        case .groupDirectMessage: "person.2.fill"
        case .announcement: "megaphone.fill"
        case .forum: "bubble.left.and.bubble.right.fill"
        case .voice: "bubble.left.fill"
        default: "number"
        }
    }
}

private struct MessageTimelineSkeletonRow: Identifiable {
    let id: Int
    let firstLineWidth: CGFloat
    let secondLineWidth: CGFloat
}

private struct MessageTimelineSkeletonMessage: View {
    let row: MessageTimelineSkeletonRow
    let availableLineWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: InterfaceScale.metric(12)) {
            Circle()
                .fill(.secondary.opacity(0.16))
                .frame(width: InterfaceScale.metric(40), height: InterfaceScale.metric(40))
                .skeletonShimmer()

            VStack(alignment: .leading, spacing: InterfaceScale.metric(7)) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    skeletonLine(
                        width: min(row.firstLineWidth, availableLineWidth * 0.52),
                        height: InterfaceScale.metric(10)
                    )
                    skeletonLine(width: min(54, availableLineWidth * 0.2), height: 8)
                }
                skeletonLine(width: min(row.secondLineWidth, availableLineWidth), height: 9)
                skeletonLine(
                    width: min(row.secondLineWidth * 0.68, availableLineWidth * 0.72),
                    height: InterfaceScale.metric(9)
                )
            }
            .padding(.top, InterfaceScale.metric(2))
        }
    }

    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.16))
            .frame(width: width, height: height)
            .skeletonShimmer()
    }
}

private struct MessageLoadErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Image(systemName: "wifi.exclamationmark")
            Text(message).lineLimit(2)
            Spacer(minLength: InterfaceScale.metric(8))
            Button("Retry", action: retry).buttonStyle(.link)
        }
        .font(.interface(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(8))
        .background(.quaternary)
    }
}
