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
    @State private var hasEarlierHistoryScrollIntent = false
    @State private var isEarlierHistoryScrollGestureActive = false
    @State private var hasLaterHistoryScrollIntent = false
    @State private var isLaterHistoryScrollGestureActive = false
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
            unreadMessageID: exactUnreadBoundaryMessageID,
            highlightedMessageID: highlightedMessageID,
            selectedMessageID: model.replyingTo?.id,
            initialScrollTarget: initialScrollTarget,
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
            onUserScrollEnded: handleUserScrollEnded
        )
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if MessageTimelineLoadingPolicy.showsInitialPlaceholder(
                isLoading: model.isLoadingMessages,
                messageCount: model.messages.count
            ) {
                MessageTimelineLoadingSkeleton(
                    bottomContentInset: bottomContentInset
                )
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let error = model.messageLoadError {
                    MessageLoadErrorBanner(message: error, retry: model.retryMessageLoad)
                }
                if let channelID = model.selectedChannelID,
                   let summary = unreadSummary
                {
                    UnreadMessagesBanner(summary: summary) {
                        model.markConversationRead(channelID: channelID)
                    }
                }
            }
            .padding(8)
        }
        .overlay(alignment: .bottom) {
            if hasEstablishedInitialPosition,
               !scrollPolicy.isNearBottom,
               !model.messages.isEmpty
            {
                Button {
                    if let channelID = model.selectedChannelID {
                        model.reportTimelineUserInteraction(channelID: channelID)
                    }
                    if model.hasMoreLaterMessages {
                        Task {
                            await model.loadNewestMessageWindow()
                        }
                    } else {
                        scrollPolicy.didRequestBottom()
                        requestScroll(.bottom)
                    }
                } label: {
                    Label("New messages", systemImage: "arrow.down")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .environment(\.colorScheme, .dark)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(
                            .regular.tint(SakuraCordAccentColor.color).interactive(),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .padding(
                    .bottom,
                    ChatDetailLayoutPolicy.newMessagesButtonBottomPadding(
                        bottomContentInset: bottomContentInset
                    )
                )
                .accessibilityHint("Scrolls to the latest message")
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
            hasEarlierHistoryScrollIntent = false
            isEarlierHistoryScrollGestureActive = false
            hasLaterHistoryScrollIntent = false
            isLaterHistoryScrollGestureActive = false
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
            requestScroll(.message(request.messageID, anchor: .center))
            highlight(request.messageID)
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
            requestScroll(.message(messageID, anchor: .center))
        }
        .task(id: model.selectedChannelID) {
            allowsAutomaticHistoryLoading = false
            hasEarlierHistoryScrollIntent = false
            isEarlierHistoryScrollGestureActive = false
            hasLaterHistoryScrollIntent = false
            isLaterHistoryScrollGestureActive = false
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            allowsAutomaticHistoryLoading = true
            loadHistoryIfNeeded(.earlier, for: latestScrollState)
            loadHistoryIfNeeded(.later, for: latestScrollState)
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
            guard !model.consumeEscapeForMediaViewer() else { return }
            guard !model.consumeEscapeForUnfocusedMessageSearch() else { return }
            guard !model.consumeEscapeForReply(in: .channel) else { return }
            guard !model.consumeEscapeForComposerAttachments(in: .channel) else { return }
            guard !model.consumeEscapeForSupplementaryConversation() else { return }
            if let conversationID {
                model.completeConversationReadingAndAdvance(
                    channelID: conversationID
                )
            }
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
        guard let channel = beginningChannel else { return nil }
        return model.snapshot?.guilds.first { $0.id == channel.guildID }?.rulesChannelID
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
            requestScroll(.message(messageID, anchor: .center))
            highlight(messageID)
        } else if let channel = model.selectedChannel {
            model.navigate(
                to: channel.guildID,
                channelID: channel.id,
                messageID: messageID
            )
        }
    }

    private var unreadSummary: AccountReadStateModel.TimelineUnreadSummary? {
        guard !model.hasMoreLaterMessages,
              let channelID = model.selectedChannelID
        else { return nil }
        return model.timelineUnreadSummary(
            channelID: channelID,
            messages: model.messages,
            hasMoreBefore:
                model.hasMoreMessages
                || (model.isLoadingMessages && !model.messages.isEmpty)
        )
    }

    private var exactUnreadBoundaryMessageID: MessageID? {
        guard let channelID = model.selectedChannelID else { return nil }
        return model.unreadDividerMessageID(channelID: channelID)
    }

    private var loadedExactUnreadBoundaryMessageID: MessageID? {
        guard let messageID = exactUnreadBoundaryMessageID,
              model.messages.contains(where: { $0.id == messageID })
        else {
            return nil
        }
        return messageID
    }

    private var hasUnresolvedInitialUnreadBoundary: Bool {
        loadedExactUnreadBoundaryMessageID == nil
            && unreadSummary?.isLowerBound == true
    }

    private var initialScrollTarget: MessageTimelineScrollRequest.Target? {
        let summary = unreadSummary
        let dividerMessageID = loadedExactUnreadBoundaryMessageID
        return TimelineInitialPositionPolicy.targetWhenReady(
            hasCompletedInitialLoad:
                model.hasCompletedInitialMessageLoad,
            firstUnreadMessageID: dividerMessageID ?? summary?.firstUnreadMessageID,
            hasExactUnreadBoundary:
                dividerMessageID != nil || summary?.isLowerBound == false,
            prefersNewest: false
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
            && !hasUnresolvedInitialUnreadBoundary
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

    private func requestScroll(_ target: MessageTimelineScrollRequest.Target) {
        scrollRequest = MessageTimelineScrollRequest(target: target)
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
        let retainedHistoryIntent =
            TimelineHistoryScrollIntentPolicy.shouldRetain(
                hasIntent: hasEarlierHistoryScrollIntent,
                isGestureActive: isEarlierHistoryScrollGestureActive,
                isInProvisionalHistory: value.isInProvisionalHistory
            )
        if hasEarlierHistoryScrollIntent != retainedHistoryIntent {
            hasEarlierHistoryScrollIntent = retainedHistoryIntent
        }
        let retainedLaterHistoryIntent =
            TimelineHistoryScrollIntentPolicy.shouldRetain(
                hasIntent: hasLaterHistoryScrollIntent,
                isGestureActive: isLaterHistoryScrollGestureActive,
                isInProvisionalHistory:
                    value.isInProvisionalLaterHistory
            )
        if hasLaterHistoryScrollIntent != retainedLaterHistoryIntent {
            hasLaterHistoryScrollIntent = retainedLaterHistoryIntent
        }
        if scrollPolicy.isNearBottom != value.isNearBottom {
            scrollPolicy.updateGeometry(isNearBottom: value.isNearBottom)
        }
        loadHistoryIfNeeded(.earlier, for: value)
        loadHistoryIfNeeded(.later, for: value)
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
                    && !hasUnresolvedInitialUnreadBoundary
            )
        }
    }

    private func loadHistoryIfNeeded(
        _ direction: TimelineHistoryDirection,
        for state: TimelineScrollState
    ) {
        let isEarlier = direction == .earlier
        guard TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary:
                isEarlier ? state.isNearTop : state.isNearLoadedBottom,
            contentFitsViewport: state.contentFitsViewport,
            allowsAutomaticLoading: allowsAutomaticHistoryLoading,
            hasMoreMessages:
                isEarlier
                    ? model.hasMoreMessages
                    : model.hasMoreLaterMessages,
            isLoading:
                isEarlier ? model.isLoadingEarlier : model.isLoadingLater,
            requiresUserScrollIntent:
                isEarlier && hasUnresolvedInitialUnreadBoundary,
            hasUserScrollIntent:
                isEarlier
                    ? hasEarlierHistoryScrollIntent
                    : hasLaterHistoryScrollIntent
        )
        else { return }
        if isEarlier {
            loadEarlier()
        } else {
            loadLater()
        }
    }

    private func handleUserScrollBegan() {
        scrollPolicy.userScrollBegan()
        isEarlierHistoryScrollGestureActive = true
        isLaterHistoryScrollGestureActive = true
        if latestScrollState.isNearLoadedBottom {
            hasLaterHistoryScrollIntent = true
        }
        if hasUnresolvedInitialUnreadBoundary {
            // Keep the intent for the complete live gesture. A fast upward
            // scroll can consume more than one bounded history page before
            // AppKit sends didEndLiveScroll; clearing it after the first page
            // strands the viewport against a still-provisional boundary.
            hasEarlierHistoryScrollIntent = true
        }
        if let channelID = model.selectedChannelID {
            model.reportTimelineUserInteraction(channelID: channelID)
        }
    }

    private func handleUserScrollEnded(_ value: TimelineScrollState) {
        isEarlierHistoryScrollGestureActive = false
        isLaterHistoryScrollGestureActive = false
        hasEarlierHistoryScrollIntent =
            TimelineHistoryScrollIntentPolicy.shouldRetain(
                hasIntent: hasEarlierHistoryScrollIntent,
                isGestureActive: false,
                isInProvisionalHistory: value.isInProvisionalHistory
            )
        hasLaterHistoryScrollIntent =
            TimelineHistoryScrollIntentPolicy.shouldRetain(
                hasIntent: hasLaterHistoryScrollIntent,
                isGestureActive: false,
                isInProvisionalHistory:
                    value.isInProvisionalLaterHistory
            )
        scrollPolicy.userScrollEnded(isNearBottom: value.isNearBottom)
        loadHistoryIfNeeded(.earlier, for: value)
        loadHistoryIfNeeded(.later, for: value)
    }
}

struct DateSeparator: View {
    let date: Date
    var body: some View {
        HStack(spacing: 10) {
            separatorLine
            Text(date, format: .dateTime.day().month(.wide).year())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            separatorLine
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.red)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.red, in: Capsule())
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }
}

struct UnreadMessagesBanner: View {
    let summary: AccountReadStateModel.TimelineUnreadSummary
    let markRead: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: markRead) {
                Label("Mark as Read", systemImage: "bell.badge")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Marks this conversation read")
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.interactive(),
            in: ConcentricRectangle(cornerRadius: 13, style: .continuous)
        )
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

nonisolated struct TimelineScrollState: Equatable, Sendable {
    let isNearTop: Bool
    let isNearBottom: Bool
    let isNearLoadedBottom: Bool
    let contentFitsViewport: Bool
    let hasEstablishedInitialPosition: Bool
    let hasReachedNewestMessageBoundary: Bool
    let isInProvisionalHistory: Bool
    let isInProvisionalLaterHistory: Bool

    init(
        isNearTop: Bool,
        isNearBottom: Bool,
        isNearLoadedBottom: Bool? = nil,
        contentFitsViewport: Bool = false,
        hasEstablishedInitialPosition: Bool = false,
        hasReachedNewestMessageBoundary: Bool = false,
        isInProvisionalHistory: Bool = false,
        isInProvisionalLaterHistory: Bool = false
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
            ZStack {
                SakuraCordThemeBackground()
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 20) {
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
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
        }
        // The timeline itself extends through the top scroll-edge safe area so
        // messages can flow beneath the translucent channel toolbar. Cover
        // that same complete viewport during an initial load; otherwise stale
        // timeline pixels remain visible above the first inset skeleton row.
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading messages")
    }
}

struct ChannelBeginningView: View {
    let channel: Channel
    let rulesChannelID: ChannelID?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 68, height: 68)
                .background(.quaternary, in: Circle())

            Text(title)
                .font(.largeTitle.weight(.bold))
                .textSelection(.enabled)
                .tint(SakuraCordAccentColor.color)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .tint(SakuraCordAccentColor.color)
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 18)
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
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(.secondary.opacity(0.16))
                .frame(width: 40, height: 40)
                .skeletonShimmer()

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    skeletonLine(
                        width: min(row.firstLineWidth, availableLineWidth * 0.52),
                        height: 10
                    )
                    skeletonLine(width: min(54, availableLineWidth * 0.2), height: 8)
                }
                skeletonLine(width: min(row.secondLineWidth, availableLineWidth), height: 9)
                skeletonLine(
                    width: min(row.secondLineWidth * 0.68, availableLineWidth * 0.72),
                    height: 9
                )
            }
            .padding(.top, 2)
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
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text(message).lineLimit(2)
            Spacer(minLength: 8)
            Button("Retry", action: retry).buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary)
    }
}
