import SakuraCordModels
import SwiftUI

struct MessageTimelineView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    private let runsPerformanceAutoScroll =
        AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        .runsChatPerformanceAutoScroll
    @State private var scrollPolicy = MessageTimelineScrollPolicy()
    @State private var allowsAutomaticHistoryLoading = false
    @State private var highlightedMessageID: MessageID?
    @State private var hasEstablishedInitialPosition = false
    @State private var scrollRequest: MessageTimelineScrollRequest?
    @State private var latestScrollState = TimelineScrollState(
        isNearTop: false,
        isNearBottom: false
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
            isLoadingEarlier:
                MessageTimelineLoadingPolicy.showsEarlierIndicator(
                    isLoadingInitialPage: model.isLoadingMessages,
                    messageCount: model.messages.count,
                    isLoadingEarlierPage: model.isLoadingEarlier
                ),
            bottomContentInset: bottomContentInset,
            unreadMessageID: exactUnreadBoundaryMessageID,
            highlightedMessageID: highlightedMessageID,
            initialScrollTarget: initialScrollTarget,
            scrollRequest: scrollRequest,
            runsPerformanceAutoScroll: runsPerformanceAutoScroll,
            loadEarlier: loadEarlier,
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
                MessageTimelineLoadingSkeleton()
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
                        scrollPolicy.didRequestBottom()
                        requestScroll(.bottom)
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
                    scrollPolicy.didRequestBottom()
                    requestScroll(.bottom)
                } label: {
                    Label("New messages", systemImage: "arrow.down")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .glassEffect(
                            .regular.tint(Color.accentColor).interactive(),
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
            scrollPolicy.didBeginChannel()
            latestScrollState = TimelineScrollState(
                isNearTop: false,
                isNearBottom: false
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
        .task(id: model.selectedChannelID) {
            allowsAutomaticHistoryLoading = false
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            allowsAutomaticHistoryLoading = true
            loadEarlierIfNeeded(for: latestScrollState)
        }
        .onDisappear {
            if let conversationID {
                model.reportTimelineLiveScrolling(
                    false,
                    conversationID: conversationID
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

    private func openReply(_ messageID: MessageID) {
        scrollPolicy.didNavigateAwayFromBottom()
        requestScroll(.message(messageID, anchor: .center))
        highlight(messageID)
    }

    private var unreadSummary: AccountReadStateModel.TimelineUnreadSummary? {
        guard let channelID = model.selectedChannelID else { return nil }
        return model.timelineUnreadSummary(
            channelID: channelID,
            messages: model.messages,
            hasMoreBefore:
                model.hasMoreMessages
                || (model.isLoadingMessages && !model.messages.isEmpty)
        )
    }

    private var exactUnreadBoundaryMessageID: MessageID? {
        TimelineUnreadBoundaryPolicy.displayedMessageID(
            firstUnreadMessageID: unreadSummary?.firstUnreadMessageID,
            isLowerBound: unreadSummary?.isLowerBound ?? false
        )
    }

    private var initialScrollTarget: MessageTimelineScrollRequest.Target? {
        let summary = unreadSummary
        return TimelineInitialPositionPolicy.targetWhenReady(
            hasCompletedInitialLoad:
                model.hasCompletedInitialMessageLoad,
            firstUnreadMessageID: summary?.firstUnreadMessageID,
            hasExactUnreadBoundary: summary?.isLowerBound == false,
            prefersNewest: false
        )
    }

    private func handleInitialPosition(_ state: TimelineScrollState) {
        guard !hasEstablishedInitialPosition,
              let channelID = model.selectedChannelID
        else {
            return
        }
        hasEstablishedInitialPosition = true
        latestScrollState = state
        if state.isNearBottom {
            scrollPolicy.didRequestBottom()
        } else {
            scrollPolicy.didNavigateAwayFromBottom()
        }
        model.reportTimelineInitialPosition(
            channelID: channelID,
            isAtNewest: state.isNearBottom
        )
    }

    private func requestScroll(_ target: MessageTimelineScrollRequest.Target) {
        scrollRequest = MessageTimelineScrollRequest(target: target)
    }

    private func highlight(_ messageID: MessageID) {
        highlightedMessageID = messageID
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if highlightedMessageID == messageID {
                highlightedMessageID = nil
            }
        }
    }

    private func handleScrollState(_ value: TimelineScrollState) {
        latestScrollState = value
        if scrollPolicy.isNearBottom != value.isNearBottom {
            scrollPolicy.updateGeometry(isNearBottom: value.isNearBottom)
        }
        loadEarlierIfNeeded(for: value)
        if hasEstablishedInitialPosition,
           let channelID = model.selectedChannelID
        {
            model.reportTimelinePosition(
                channelID: channelID,
                isAtNewest: value.isNearBottom
            )
        }
    }

    private func loadEarlierIfNeeded(for state: TimelineScrollState) {
        guard state.isNearTop,
              allowsAutomaticHistoryLoading,
              model.hasMoreMessages,
              !model.isLoadingEarlier
        else { return }
        loadEarlier()
    }

    private func handleUserScrollBegan() {
        scrollPolicy.userScrollBegan()
        if let channelID = model.selectedChannelID {
            model.reportTimelineUserInteraction(channelID: channelID)
        }
    }

    private func handleUserScrollEnded(_ value: TimelineScrollState) {
        scrollPolicy.userScrollEnded(isNearBottom: value.isNearBottom)
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
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        let count = summary.loadedUnreadCount.formatted()
        let noun = summary.loadedUnreadCount == 1 ? "message" : "messages"
        if summary.isLowerBound {
            return "\(count)+ new \(noun) in loaded history"
        }
        let time = summary.firstUnreadTimestamp.formatted(
            date: .omitted,
            time: .shortened
        )
        return "\(count) new \(noun) since \(time)"
    }
}

struct TimelineScrollState: Equatable {
    let isNearTop: Bool
    let isNearBottom: Bool

    init(isNearTop: Bool, isNearBottom: Bool) {
        self.isNearTop = isNearTop
        self.isNearBottom = isNearBottom
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
    private static let patterns = [
        MessageTimelineSkeletonRow(id: 0, firstLineWidth: 132, secondLineWidth: 330),
        MessageTimelineSkeletonRow(id: 1, firstLineWidth: 94, secondLineWidth: 470),
        MessageTimelineSkeletonRow(id: 2, firstLineWidth: 156, secondLineWidth: 280),
        MessageTimelineSkeletonRow(id: 3, firstLineWidth: 116, secondLineWidth: 410),
        MessageTimelineSkeletonRow(id: 4, firstLineWidth: 142, secondLineWidth: 355),
        MessageTimelineSkeletonRow(id: 5, firstLineWidth: 102, secondLineWidth: 445),
    ]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(0 ..< MessageTimelineSkeletonLayout.rowCount(for: geometry.size.height), id: \.self) { index in
                        MessageTimelineSkeletonMessage(
                            row: Self.patterns[index % Self.patterns.count],
                            availableLineWidth: max(120, geometry.size.width - 84)
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
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

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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
