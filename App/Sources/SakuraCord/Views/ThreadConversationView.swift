import SakuraCordModels
import SwiftUI

nonisolated enum ThreadInitialScrollTarget: Equatable {
    case firstUnread
    case newest
}

nonisolated enum ThreadTimelinePresentationPolicy {
    static func initialScrollTarget(
        isForumPost: Bool,
        hasUnreadReplies: Bool
    ) -> ThreadInitialScrollTarget {
        isForumPost || !hasUnreadReplies ? .newest : .firstUnread
    }

    static func showsNewRepliesButton(
        isNearBottom: Bool,
        hasUnreadReplies: Bool,
        messageCount: Int
    ) -> Bool {
        !isNearBottom && hasUnreadReplies && messageCount > 0
    }
}

struct ThreadPaneFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let nextFrame = nextValue()
        if nextFrame != .zero {
            value = nextFrame
        }
    }
}

struct SupplementaryConversationPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 440, maxHeight: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ThreadPaneFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            }
    }
}

struct ThreadConversationView: View {
    let model: AppModel
    @State private var floatingFooterHeight: CGFloat =
        ChatDetailLayoutPolicy.defaultFloatingFooterHeight

    var body: some View {
        SupplementaryConversationPane {
            if let thread = model.openThread {
                if model.openThreadAccess == .hidden {
                    ThreadUnavailableView()
                } else {
                    ThreadMessageTimelineView(
                        model: model,
                        bottomContentInset: ChatDetailLayoutPolicy.bottomContentInset(
                            measuredFooterHeight: floatingFooterHeight
                        )
                    )
                    .overlay(alignment: .bottom) {
                        ThreadConversationFooter(model: model, thread: thread) { height in
                            floatingFooterHeight = height
                        }
                    }
                }
            }
        }
    }
}

private struct ThreadConversationFooter: View {
    let model: AppModel
    let thread: MessageThreadSummary
    let footerHeightChanged: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.threadErrorMessage {
                ThreadErrorBanner(message: error)
            }
            if thread.isLocked {
                ThreadStateBanner(
                    title: isForumPost ? "Locked post" : "Locked thread",
                    message: "Only moderators can send messages.",
                    systemImage: "lock.fill",
                    actionTitle: canUpdateForumPost && model.canManageForumPosts ? "Unlock" : nil,
                    actionSystemImage: "lock.open.fill",
                    action: { updateForumPost(.locked(false)) }
                )
            } else if thread.isArchived {
                ThreadStateBanner(
                    title: isForumPost ? "Closed post" : "Archived thread",
                    message: "Sending a reply will reopen it.",
                    systemImage: "archivebox.fill",
                    actionTitle: canUpdateForumPost && model.canArchiveForumPost(forumPost) ? "Reopen" : nil,
                    actionSystemImage: "arrow.uturn.backward.circle.fill",
                    action: { updateForumPost(.archived(false)) }
                )
            }
            ThreadConversationComposer(model: model, thread: thread)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            footerHeightChanged(height)
        }
    }

    private var isForumPost: Bool {
        model.selectedChannel?.kind == .forum
    }

    private var forumPost: ForumPost {
        model.forumCataloguePosts.first(where: { $0.id == thread.id })
            ?? ForumPost(thread: thread)
    }

    private var canUpdateForumPost: Bool {
        model.forumCataloguePosts.contains { $0.id == thread.id }
    }

    private func updateForumPost(_ mutation: ForumPostMutation) {
        guard canUpdateForumPost else { return }
        let post = forumPost
        Task { await model.updateForumPost(post, mutation: mutation) }
    }
}

private struct ThreadConversationComposer: View {
    let model: AppModel
    let thread: MessageThreadSummary

    var body: some View {
        VStack(spacing: 0) {
            switch model.openThreadAccess {
            case .checking:
                DisabledComposerView(message: "Checking thread permissions…")
            case .readable(canSend: true):
                ComposerView(
                    model: model,
                    channelName: thread.name,
                    conversation: .thread
                )
            case .readable(canSend: false):
                if !thread.isLocked {
                    DisabledComposerView(
                        message: "You do not have permission to send messages in this thread."
                    )
                }
            case .hidden:
                EmptyView()
            }
        }
    }
}

private struct ThreadStateBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String?
    let actionSystemImage: String
    let action: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                if let actionTitle {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionSystemImage)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 46)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

private struct ThreadUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Thread unavailable",
            systemImage: "lock.fill",
            description: Text("You cannot view messages in this thread.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadBeginningView: View {
    let title: String
    let starterName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 68, height: 68)
                .background(.quaternary, in: Circle())

            Text(title)
                .font(.largeTitle.weight(.bold))
                .textSelection(.enabled)

            if let starterName {
                Text("Started by \(starterName)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("This is the start of the thread.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ThreadMessageTimelineView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    @State private var isNearBottom = false
    @State private var didEstablishInitialPosition = false
    @State private var initialPositionTracker = TimelineInitialPositionTracker()

    private let bottomID = "thread-conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let thread = model.openThread,
                           ConversationBeginningPolicy.showsBeginning(
                               isLoading: model.isLoadingThread,
                               hasMoreBefore: model.hasMoreThreadMessages,
                               hasError: model.threadErrorMessage != nil
                           )
                        {
                            ThreadBeginningView(
                                title: thread.name,
                                starterName: threadStarterName
                            )
                            if let startedAt = model.openThreadStartedAt {
                                DateSeparator(date: startedAt)
                            }
                        }

                        if model.hasMoreThreadMessages {
                            EarlierThreadMessageLoader(
                                isLoading: model.isLoadingEarlierThread,
                                load: { loadEarlier(using: proxy) }
                            )
                        }

                        ForEach(model.threadMessageRows.enumerated(), id: \.element.id) {
                            index, row in
                            VStack(alignment: .leading, spacing: 0) {
                                if showsDateSeparator(at: index, for: row) {
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
                                    canEdit: row.message.author.id
                                        == model.snapshot?.currentUser.id,
                                    saveEdit: { value in
                                        Task { await model.edit(row.message, content: value) }
                                    },
                                    reply: nil,
                                    markUnread: {
                                        model.markMessageAndFollowingUnread(row.message)
                                    },
                                    openReply: { id in
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            proxy.scrollTo(id, anchor: .center)
                                        }
                                    },
                                    delete: { Task { await model.delete(row.message) } },
                                    react: { emoji in
                                        Task { await model.toggleReaction(emoji, on: row.message) }
                                    }
                                )
                                .equatable()
                            }
                            .id(row.id)
                        }

                        Color.clear.frame(height: bottomContentInset).id(bottomID)
                    }
                    .padding(.vertical, 10)
                    .frame(
                        minHeight: ThreadTimelineLayoutPolicy.minimumContentHeight(
                            viewportHeight: geometry.size.height
                        ),
                        alignment: .bottom
                    )
                }
                .defaultScrollAnchor(.bottom)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: ThreadScrollState.self) { geometry in
                    ThreadScrollState(
                        isNearBottom: geometry.contentSize.height - geometry.contentOffset.y
                            - geometry.containerSize.height < 100
                    )
                } action: { _, value in
                    isNearBottom = value.isNearBottom
                    if let threadID = model.openThread?.id {
                        if let isAtNewest = initialPositionTracker.resolve(
                            channelID: threadID,
                            actualIsAtNewest: value.isNearBottom
                        ) {
                            model.reportTimelineInitialPosition(
                                channelID: threadID,
                                isAtNewest: isAtNewest
                            )
                        } else {
                            model.reportTimelinePosition(
                                channelID: threadID,
                                isAtNewest: value.isNearBottom
                            )
                        }
                    }
                }
                .onScrollPhaseChange { _, newPhase, _ in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        if let threadID = model.openThread?.id {
                            model.reportTimelineUserInteraction(channelID: threadID)
                        }
                    case .idle, .animating:
                        break
                    }
                }
                .overlay {
                    if MessageTimelineLoadingPolicy.showsInitialPlaceholder(
                        isLoading: model.isLoadingThread,
                        messageCount: model.threadMessages.count
                    ) {
                        MessageTimelineLoadingSkeleton()
                    }
                }
                .overlay(alignment: .top) {
                    if let threadID = model.openThread?.id,
                       let summary = unreadSummary
                    {
                        UnreadMessagesBanner(summary: summary) {
                            model.markConversationRead(channelID: threadID)
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if ThreadTimelinePresentationPolicy.showsNewRepliesButton(
                        isNearBottom: isNearBottom,
                        hasUnreadReplies: unreadSummary != nil,
                        messageCount: model.threadMessages.count
                    ) {
                        Button {
                            if let threadID = model.openThread?.id {
                                model.reportTimelineUserInteraction(channelID: threadID)
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        } label: {
                            Label("New replies", systemImage: "arrow.down")
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
                        .accessibilityHint("Scrolls to the latest reply")
                    }
                }
                .onChange(of: model.threadMessages.last?.id) { oldID, id in
                    guard oldID != nil, id != nil, isNearBottom else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: bottomContentInset) {
                    guard isNearBottom else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: model.openThread?.id) {
                    isNearBottom = false
                    didEstablishInitialPosition = false
                    initialPositionTracker.cancel()
                }
                .onChange(of: model.hasCompletedInitialThreadLoad) {
                    establishInitialPosition(using: proxy)
                }
                .task(id: model.openThread?.id) {
                    isNearBottom = false
                    didEstablishInitialPosition = false
                    initialPositionTracker.cancel()
                    establishInitialPosition(using: proxy)
                }
            }
        }
    }

    private var threadStarterName: String? {
        guard let starter = model.openThreadStarter else { return nil }
        return model.membersByID[starter.id]?.user.displayName
            ?? starter.displayName
    }

    private func showsDateSeparator(at index: Int, for row: MessageRowPresentation) -> Bool {
        if index > 0 {
            return row.startsDay
        }
        let showsBeginning = ConversationBeginningPolicy.showsBeginning(
            isLoading: model.isLoadingThread,
            hasMoreBefore: model.hasMoreThreadMessages,
            hasError: model.threadErrorMessage != nil
        )
        return ThreadTimelineLayoutPolicy.showsFirstReplyDateSeparator(
            showsBeginning: showsBeginning,
            starterDate: model.openThreadStartedAt,
            firstReplyDate: row.message.timestamp
        )
    }

    private func loadEarlier(using proxy: ScrollViewProxy) {
        let threadID = model.openThread?.id
        let anchor = model.threadMessages.first?.id
        Task {
            await model.loadEarlierThread()
            guard let anchor, model.openThread?.id == threadID else { return }
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private var unreadSummary: AccountReadStateModel.TimelineUnreadSummary? {
        guard let threadID = model.openThread?.id else { return nil }
        return model.timelineUnreadSummary(
            channelID: threadID,
            messages: model.threadMessages,
            hasMoreBefore: model.hasMoreThreadMessages
        )
    }

    private func establishInitialPosition(using proxy: ScrollViewProxy) {
        guard !didEstablishInitialPosition,
              model.hasCompletedInitialThreadLoad,
              let threadID = model.openThread?.id
        else { return }
        didEstablishInitialPosition = true
        let initialTarget = ThreadTimelinePresentationPolicy.initialScrollTarget(
            isForumPost: model.selectedChannel?.kind == .forum,
            hasUnreadReplies: unreadSummary != nil
        )
        if initialTarget == .firstUnread, let summary = unreadSummary {
            proxy.scrollTo(summary.firstUnreadMessageID, anchor: .top)
        } else {
            isNearBottom = true
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        initialPositionTracker.begin(channelID: threadID)
        resolveInitialPositionAfterLayout(
            threadID: threadID,
            assumesNewestPosition: initialTarget == .newest
        )
    }

    private func resolveInitialPositionAfterLayout(
        threadID: ChannelID,
        assumesNewestPosition: Bool
    ) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard model.openThread?.id == threadID,
                  let isAtNewest = initialPositionTracker.resolve(
                      channelID: threadID,
                      actualIsAtNewest: assumesNewestPosition || isNearBottom
                  )
            else { return }
            model.reportTimelineInitialPosition(
                channelID: threadID,
                isAtNewest: isAtNewest
            )
        }
    }
}

private struct EarlierThreadMessageLoader: View {
    let isLoading: Bool
    let load: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Loading earlier replies…")
            } else {
                Button("Load earlier replies", action: load)
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct ThreadErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

private struct ThreadScrollState: Equatable {
    let isNearBottom: Bool
}
