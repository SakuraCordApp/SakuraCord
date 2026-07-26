import SakuraCordModels
import SwiftUI

struct MessageTimelineView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    @State private var scrollPolicy = MessageTimelineScrollPolicy()
    @State private var allowsAutomaticHistoryLoading = false
    @State private var highlightedMessageID: MessageID?

    private let bottomID = "message-timeline-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    // Not lazy: rows outside a lazy realization window trade
                    // their measured height for an estimate, so the content
                    // size oscillates by hundreds of points while scrolling and
                    // the visible messages shift under the reader. Realizing
                    // every row keeps the content size fixed. History only
                    // grows 50 rows per explicit "Load earlier", never while
                    // scrolling, so the cost is user-paced rather than per
                    // frame.
                    VStack(alignment: .leading, spacing: 0) {
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
                }
                .onScrollGeometryChange(for: ScrollDiagnosticsSample.self) { geometry in
                    // Stays constant unless diagnostics are on, so the action
                    // never fires in an ordinary run.
                    ScrollDiagnostics.isEnabled
                        ? ScrollDiagnosticsSample(
                            contentHeight: geometry.contentSize.height,
                            contentOffset: geometry.contentOffset.y
                        )
                        : ScrollDiagnosticsSample(contentHeight: 0, contentOffset: 0)
                } action: { _, value in
                    ScrollDiagnostics.recordGeometry(
                        height: value.contentHeight,
                        offset: value.contentOffset
                    )
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        ScrollDiagnostics.beginScroll(rowCount: model.messageRows.count)
                        scrollPolicy.userScrollBegan()
                    case .idle:
                        switch oldPhase {
                        case .tracking, .interacting, .decelerating:
                            ScrollDiagnostics.endScroll()
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
                    if let error = model.messageLoadError {
                        MessageLoadErrorBanner(message: error, retry: model.retryMessageLoad)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !scrollPolicy.isNearBottom, !model.messages.isEmpty {
                        Button {
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
                    scrollPolicy.didChangeChannel()
                    proxy.scrollTo(bottomID, anchor: .bottom)
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

    mutating func didChangeChannel() {
        isNearBottom = true
        followsNewMessages = true
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
