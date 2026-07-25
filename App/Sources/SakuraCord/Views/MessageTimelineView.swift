import SakuraCordModels
import SwiftUI

struct MessageTimelineView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    @State private var scrollPolicy = MessageTimelineScrollPolicy()
    @State private var allowsAutomaticHistoryLoading = false
    @State private var highlightedMessageID: MessageID?
    @State private var didEstablishInitialPosition = false
    @State private var initialPositionTracker = TimelineInitialPositionTracker()

    private let bottomID = "message-timeline-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let channel = model.selectedChannel,
                           ConversationBeginningPolicy.showsBeginning(
                               isLoading: model.isLoadingMessages,
                               hasMoreBefore: model.hasMoreMessages,
                               hasError: model.messageLoadError != nil
                           )
                        {
                            ChannelBeginningView(
                                channel: channel,
                                rulesChannelID: model.snapshot?.guilds.first {
                                    $0.id == channel.guildID
                                }?.rulesChannelID
                            )
                        }
                        if model.hasMoreMessages {
                            EarlierMessageLoader(
                                isLoading: model.isLoadingEarlier
                            ) {
                                loadEarlier(using: proxy)
                            }
                        }
                        ForEach(model.messageRows) { row in
                            VStack(alignment: .leading, spacing: 0) {
                                if row.startsDay {
                                    DateSeparator(date: row.message.timestamp)
                                }
                                if unreadSummary?.firstUnreadMessageID == row.id {
                                    NewMessagesSeparator()
                                }
                                MessageRowView(
                                    model: model,
                                    message: row.message,
                                    authorPresentation: model.authorPresentation(for: row.message),
                                    startsGroup: row.startsGroup,
                                    replyPreview: row.replyPreview,
                                    isReplyAvailable: row.isReplyAvailable,
                                    canEdit: row.message.author.id == model.snapshot?.currentUser.id,
                                    saveEdit: { content in
                                        Task { await model.edit(row.message, content: content) }
                                    },
                                    reply: { model.reply(to: row.message) },
                                    markUnread: {
                                        model.markMessageAndFollowingUnread(row.message)
                                    },
                                    openReply: { id in
                                        scrollPolicy.didNavigateAwayFromBottom()
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            proxy.scrollTo(id, anchor: .center)
                                        }
                                        highlightedMessageID = id
                                        Task {
                                            try? await Task.sleep(for: .seconds(1.5))
                                            if highlightedMessageID == id {
                                                highlightedMessageID = nil
                                            }
                                        }
                                    },
                                    delete: { Task { await model.delete(row.message) } },
                                    react: { emoji in
                                        Task { await model.toggleReaction(emoji, on: row.message) }
                                    }
                                )
                                .equatable()
                                .background(
                                    highlightedMessageID == row.id
                                        ? Color.accentColor.opacity(0.14) : .clear
                                )
                            }
                            .id(row.id)
                        }
                        Color.clear
                            .frame(height: bottomContentInset)
                            .id(bottomID)
                    }
                    .padding(.vertical, ChatDetailLayoutPolicy.timelineVerticalPadding)
                    .frame(
                        minHeight: ChatDetailLayoutPolicy.timelineMinimumContentHeight(
                            viewportHeight: geometry.size.height
                        ),
                        alignment: .bottom
                    )
                }
                .defaultScrollAnchor(.bottom)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: TimelineScrollState.self) { geometry in
                    TimelineScrollState(geometry: geometry)
                } action: { _, value in
                    if scrollPolicy.isNearBottom != value.isNearBottom {
                        scrollPolicy.updateGeometry(isNearBottom: value.isNearBottom)
                    }
                    if value.isNearTop, allowsAutomaticHistoryLoading, model.hasMoreMessages,
                       !model.isLoadingEarlier
                    {
                        loadEarlier(using: proxy)
                    }
                    if let channelID = model.selectedChannelID {
                        if let isAtNewest = initialPositionTracker.resolve(
                            channelID: channelID,
                            actualIsAtNewest: value.isNearBottom
                        ) {
                            applyResolvedInitialPosition(
                                channelID: channelID,
                                isAtNewest: isAtNewest
                            )
                        } else {
                            model.reportTimelinePosition(
                                channelID: channelID,
                                isAtNewest: value.isNearBottom
                            )
                        }
                    }
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        scrollPolicy.userScrollBegan()
                        if let channelID = model.selectedChannelID {
                            model.reportTimelineUserInteraction(channelID: channelID)
                        }
                    case .idle:
                        switch oldPhase {
                        case .tracking, .interacting, .decelerating:
                            let value = TimelineScrollState(geometry: context.geometry)
                            scrollPolicy.userScrollEnded(
                                isNearBottom: value.isNearBottom
                            )
                        case .idle, .animating:
                            break
                        }
                    case .animating:
                        break
                    }
                }
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
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(bottomID, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottom) {
                    if !scrollPolicy.isNearBottom, !model.messages.isEmpty {
                        Button {
                            if let channelID = model.selectedChannelID {
                                model.reportTimelineUserInteraction(channelID: channelID)
                            }
                            scrollPolicy.didRequestBottom()
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
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
                .onChange(of: model.messages.last?.id) { oldID, id in
                    guard id != nil else { return }
                    guard oldID == nil || scrollPolicy.followsNewMessages else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: bottomContentInset) {
                    guard scrollPolicy.followsNewMessages else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: model.selectedChannelID) {
                    didEstablishInitialPosition = false
                    initialPositionTracker.cancel()
                    scrollPolicy.didBeginChannel()
                }
                .onChange(of: model.hasCompletedInitialMessageLoad) {
                    establishInitialPosition(using: proxy)
                }
                .onChange(of: model.messageNavigationRequest) { _, request in
                    guard let request,
                          request.channelID == model.selectedChannelID,
                          model.messages.contains(where: { $0.id == request.messageID })
                    else { return }
                    scrollPolicy.didNavigateAwayFromBottom()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(request.messageID, anchor: .center)
                    }
                    highlightedMessageID = request.messageID
                    model.completeMessageNavigation(requestID: request.requestID)
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if highlightedMessageID == request.messageID {
                            highlightedMessageID = nil
                        }
                    }
                }
                .task(id: model.selectedChannelID) {
                    didEstablishInitialPosition = false
                    initialPositionTracker.cancel()
                    scrollPolicy.didBeginChannel()
                    establishInitialPosition(using: proxy)
                    allowsAutomaticHistoryLoading = false
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    allowsAutomaticHistoryLoading = true
                }
            }
        }
    }

    private func loadEarlier(using proxy: ScrollViewProxy) {
        let anchor = model.messages.first?.id
        let channelID = model.selectedChannelID
        Task {
            await model.loadEarlier()
            guard let anchor, model.selectedChannelID == channelID else { return }
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private var unreadSummary: AccountReadStateModel.TimelineUnreadSummary? {
        guard let channelID = model.selectedChannelID else { return nil }
        return model.timelineUnreadSummary(
            channelID: channelID,
            messages: model.messages,
            hasMoreBefore: model.hasMoreMessages
        )
    }

    private func establishInitialPosition(using proxy: ScrollViewProxy) {
        guard !didEstablishInitialPosition,
              model.hasCompletedInitialMessageLoad,
              let channelID = model.selectedChannelID
        else { return }
        didEstablishInitialPosition = true
        if let summary = unreadSummary {
            proxy.scrollTo(summary.firstUnreadMessageID, anchor: .top)
        } else {
            scrollPolicy.didRequestBottom()
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        initialPositionTracker.begin(channelID: channelID)
        resolveInitialPositionAfterLayout(channelID: channelID)
    }

    private func resolveInitialPositionAfterLayout(channelID: ChannelID) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard model.selectedChannelID == channelID,
                  let isAtNewest = initialPositionTracker.resolve(
                      channelID: channelID,
                      actualIsAtNewest: scrollPolicy.isNearBottom
                  )
            else { return }
            applyResolvedInitialPosition(channelID: channelID, isAtNewest: isAtNewest)
        }
    }

    private func applyResolvedInitialPosition(channelID: ChannelID, isAtNewest: Bool) {
        if isAtNewest {
            scrollPolicy.didRequestBottom()
        } else {
            scrollPolicy.didNavigateAwayFromBottom()
        }
        model.reportTimelineInitialPosition(channelID: channelID, isAtNewest: isAtNewest)
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
        let suffix = summary.isLowerBound ? "+" : ""
        let noun = summary.loadedUnreadCount == 1 ? "message" : "messages"
        let time = summary.firstUnreadTimestamp.formatted(
            date: .omitted,
            time: .shortened
        )
        return "\(count)\(suffix) new \(noun) since \(time)"
    }
}

private struct EarlierMessageLoader: View {
    let isLoading: Bool
    let load: () -> Void

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier messages…")
                }
            } else {
                Button("Load earlier messages", action: load)
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct TimelineScrollState: Equatable {
    let isNearTop: Bool
    let isNearBottom: Bool

    init(isNearTop: Bool, isNearBottom: Bool) {
        self.isNearTop = isNearTop
        self.isNearBottom = isNearBottom
    }

    init(geometry: ScrollGeometry) {
        isNearTop = geometry.contentOffset.y < 100
        isNearBottom = geometry.contentSize.height - geometry.contentOffset.y
            - geometry.containerSize.height < 120
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

struct TimelineInitialPositionTracker: Equatable {
    private(set) var pendingChannelID: ChannelID?

    mutating func begin(channelID: ChannelID) {
        pendingChannelID = channelID
    }

    mutating func cancel() {
        pendingChannelID = nil
    }

    mutating func resolve(
        channelID: ChannelID,
        actualIsAtNewest: Bool
    ) -> Bool? {
        guard pendingChannelID == channelID else { return nil }
        pendingChannelID = nil
        return actualIsAtNewest
    }
}

enum MessageTimelineLoadingPolicy {
    static func showsInitialPlaceholder(isLoading: Bool, messageCount: Int) -> Bool {
        isLoading && messageCount == 0
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading messages")
    }
}

private struct ChannelBeginningView: View {
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
