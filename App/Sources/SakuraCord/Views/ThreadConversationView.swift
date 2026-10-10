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
            .frame(minWidth: InterfaceScale.metric(340), idealWidth: InterfaceScale.metric(400), maxWidth: InterfaceScale.metric(440), maxHeight: .infinity)
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
    @State private var editRequest: MessageTimelineEditRequest?

    var body: some View {
        if model.isThreadFullWidth {
            conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SupplementaryConversationPane { conversation }
        }
    }

    @ViewBuilder private var conversation: some View {
        if let thread = model.openThread {
                if model.openThreadAccess == .hidden {
                    ThreadUnavailableView()
                } else {
                    ThreadMessageTimelineView(
                        model: model,
                        bottomContentInset: ChatDetailLayoutPolicy.bottomContentInset(
                            measuredFooterHeight: floatingFooterHeight
                        ),
                        editRequest: editRequest
                    )
                    .overlay(alignment: .bottom) {
                        ThreadConversationFooter(
                            model: model,
                            thread: thread,
                            footerHeightChanged: { height in
                                floatingFooterHeight = height
                            },
                            onEditMessage: { messageID in
                                editRequest = MessageTimelineEditRequest(
                                    messageID: messageID
                                )
                            }
                        )
                    }
                }
            } else if let creation = model.threadCreation {
                ThreadCreationView(model: model, creation: creation)
            }
    }
}

private struct ThreadCreationView: View {
    let model: AppModel
    @Bindable var creation: ThreadCreationDraft
    @FocusState private var isNameFocused: Bool

    var body: some View {
        let usesDefaultStyle = model.appearanceSettings.composerBarAppearance == .defaultStyle
        let fieldShape = RoundedRectangle(
            cornerRadius: usesDefaultStyle
                ? ChatChromeMetrics.composerCornerRadius : ChatChromeMetrics.composerMinimumCornerRadius,
            style: .continuous
        )
        VStack(alignment: .leading, spacing: InterfaceScale.metric(18)) {
            SakuraCordSystemSymbol.swiftUIImage(named: SakuraCordSystemSymbol.thread)
                .font(.interfaceSystem(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(64), height: InterfaceScale.metric(64))
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                Text("Thread Name")
                    .font(.interface(.headline))
                ZStack(alignment: .leading) {
                    TextField("", text: $creation.name)
                        .tint(SakuraCordAccentColor.color)
                        .textFieldStyle(.plain)
                        .font(.interfaceSystem(size: 15))
                        .focused($isNameFocused)
                        .accessibilityLabel("Thread Name")
                        .onSubmit { model.validateThreadCreation() }
                    if creation.name.isEmpty {
                        Text("New Thread")
                            .font(.interfaceSystem(size: 15))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, InterfaceScale.metric(11))
                .frame(
                    maxWidth: .infinity,
                    minHeight: usesDefaultStyle
                        ? ChatChromeMetrics.composerControlHeight : ChatChromeMetrics.controlHeight,
                    alignment: .leading
                )
                .background {
                    Color.clear.glassEffect(.regular.interactive(), in: fieldShape)
                }
                .contentShape(fieldShape)
                .simultaneousGesture(TapGesture().onEnded { isNameFocused = true })
                if creation.showsValidationErrors, creation.trimmedName.isEmpty {
                    ThreadCreationError(message: "Thread Name is required")
                }
            }

            if creation.permissions.canCreatePrivate {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                    Text("Private Thread")
                        .font(.interface(.headline))
                    Toggle("Only people you invite and moderators can see", isOn: $creation.isPrivate)
                        .toggleStyle(.checkbox)
                        .tint(SakuraCordAccentColor.color)
                        .disabled(!creation.permissions.canCreatePublic)
                }
            }

            if creation.showsValidationErrors, isMissingStarterMessage {
                ThreadCreationError(message: "Starter Message is required")
            }
        }
        .padding(.horizontal, ChatChromeMetrics.composerWindowInset)
        .padding(.bottom, InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(model: model, channelName: "", conversation: .thread)
        }
        .disabled(creation.isSubmitting)
    }

    private var isMissingStarterMessage: Bool {
        model.threadDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.threadComposerAttachments.isEmpty
    }
}

private struct ThreadCreationError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.interface(.callout))
            .foregroundStyle(.red)
    }
}

private struct ThreadConversationFooter: View {
    let model: AppModel
    let thread: MessageThreadSummary
    let footerHeightChanged: (CGFloat) -> Void
    let onEditMessage: (MessageID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.threadErrorMessage {
                ThreadErrorBanner(
                    message: error,
                    retry: retryThreadLoad
                )
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
            ThreadConversationComposer(
                model: model,
                thread: thread,
                onEditMessage: onEditMessage
            )
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            footerHeightChanged(height)
        }
    }

    private var isForumPost: Bool {
        model.openThreadParentChannel?.kind == .forum
    }

    private var retryThreadLoad: (() -> Void)? {
        guard model.canRetryThreadLoad else { return nil }
        return { model.retryThreadLoad() }
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
    let onEditMessage: (MessageID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch model.openThreadAccess {
            case .checking:
                DisabledComposerView(
                    message: "Checking thread permissions…",
                    appearance: model.appearanceSettings.composerBarAppearance
                )
            case .readable(canSend: true):
                ComposerView(
                    model: model,
                    channelName: thread.name,
                    conversation: .thread,
                    onEditMessage: onEditMessage
                )
            case .readable(canSend: false):
                if !thread.isLocked {
                    DisabledComposerView(
                        message: "You do not have permission to send messages in this thread.",
                        appearance: model.appearanceSettings.composerBarAppearance
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
        GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
            HStack(spacing: InterfaceScale.metric(10)) {
                Image(systemName: systemImage)
                    .font(.interfaceSystem(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: InterfaceScale.metric(26), height: InterfaceScale.metric(26))
                    .background(.quaternary, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.interface(.callout).weight(.semibold))
                    Text(message)
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: InterfaceScale.metric(8))

                if let actionTitle {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionSystemImage)
                            .padding(.horizontal, InterfaceScale.metric(10))
                            .frame(minHeight: InterfaceScale.metric(30))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .padding(.horizontal, InterfaceScale.metric(10))
            .frame(minHeight: InterfaceScale.metric(46))
            .glassEffect(
                .regular,
                in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(13), style: .continuous)
            )
        }
        .padding(.horizontal, InterfaceScale.metric(10))
        .padding(.vertical, InterfaceScale.metric(8))
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

private struct ThreadMessageTimelineView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    let editRequest: MessageTimelineEditRequest?
    @State private var isNearBottom = false
    @State private var hasEstablishedInitialPosition = false
    @State private var hasEarlierHistoryScrollIntent = false
    @State private var isEarlierHistoryScrollGestureActive = false
    @State private var highlightedMessageID: MessageID?
    @State private var scrollRequest: MessageTimelineScrollRequest?

    var body: some View {
        let conversationID = model.openThread?.id
        NativeMessageTimelineView(
            model: model,
            conversation: .thread(conversationID),
            beginning: beginning,
            firstMessageStartsDayOverride: firstMessageStartsDayOverride,
            hasMoreMessages: model.hasMoreThreadMessages,
            isLoadingEarlier:
                MessageTimelineLoadingPolicy.showsEarlierIndicator(
                    isLoadingInitialPage: model.isLoadingThread,
                    messageCount: model.threadMessages.count,
                    isLoadingEarlierPage: model.isLoadingEarlierThread
                ),
            bottomContentInset: bottomContentInset,
            unreadMessageID: exactUnreadBoundaryMessageID,
            highlightedMessageID: highlightedMessageID,
            selectedMessageID: model.threadReplyingTo?.id,
            initialScrollTarget: initialScrollTarget,
            scrollRequest: scrollRequest,
            editRequest: editRequest,
            runsPerformanceAutoScroll: false,
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
            onUserScrollEnded: handleUserScrollEnded,
            onUserScrollTowardNewest: handleUserScrollTowardNewest
        )
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if MessageTimelineLoadingPolicy.showsInitialPlaceholder(
                isLoading: model.isLoadingThread,
                messageCount: model.threadMessages.count
            ) {
                MessageTimelineLoadingSkeleton(
                    bottomContentInset: bottomContentInset
                )
            }
        }
        .overlay(alignment: .top) {
            if let threadID = model.openThread?.id,
               let summary = unreadSummary
            {
                UnreadMessagesBanner(summary: summary) {
                    model.markConversationRead(channelID: threadID)
                }
                .padding(InterfaceScale.metric(8))
            }
        }
        .overlay(alignment: .bottom) {
            if ThreadTimelinePresentationPolicy.showsNewRepliesButton(
                isNearBottom: isNearBottom,
                hasUnreadReplies: unreadSummary != nil,
                messageCount: model.threadMessages.count
            ), hasEstablishedInitialPosition {
                Button {
                    handleUserScrollTowardNewest()
                    requestScroll(.bottom)
                } label: {
                    Label("New replies", systemImage: "arrow.down")
                        .font(.interface(.callout).weight(.semibold))
                        .padding(.horizontal, InterfaceScale.metric(15))
                        .padding(.vertical, InterfaceScale.metric(8))
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
                .accessibilityHint("Scrolls to the latest reply")
            }
        }
        .onChange(of: model.openThread?.id) { oldID, _ in
            if let oldID {
                model.reportTimelineLiveScrolling(
                    false,
                    conversationID: oldID
                )
            }
            isNearBottom = false
            hasEstablishedInitialPosition = false
            hasEarlierHistoryScrollIntent = false
            isEarlierHistoryScrollGestureActive = false
        }
        .onChange(of: model.messageNavigationRequest, initial: true) { _, request in
            guard let request,
                  request.channelID == model.openThread?.id,
                  model.threadMessages.contains(where: {
                      $0.id == request.messageID
                  })
            else { return }
            requestScroll(.message(request.messageID, anchor: .center))
            highlight(request.messageID)
            model.completeMessageNavigation(requestID: request.requestID)
        }
        .onChange(of: model.conversationNewestRequest) { _, request in
            guard let request,
                  request.channelID == model.openThread?.id
            else { return }
            requestScroll(.bottom)
            model.completeConversationNewestRequest(requestID: request.requestID)
        }
        .onChange(of: model.threadReplyingTo?.id) { _, messageID in
            guard let messageID else { return }
            requestScroll(.message(messageID, anchor: .center))
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
            guard !model.consumeEscapeForPinnedMessages() else { return }
            guard !model.consumeEscapeForUnfocusedMessageSearch() else { return }
            guard !model.consumeEscapeForReply(in: .thread) else { return }
            guard !model.consumeEscapeForComposerAttachments(in: .thread) else { return }
            guard !model.consumeEscapeForSupplementaryConversation() else { return }
            if let conversationID {
                model.completeConversationReadingAndAdvance(
                    channelID: conversationID
                )
            }
        }
    }

    private var threadStarterName: String? {
        guard let starter = model.openThreadStarter else { return nil }
        return model.membersByID[starter.id]?.user.displayName
            ?? starter.displayName
    }

    private var beginning: NativeTimelineBeginning? {
        guard let thread = model.openThread,
              ConversationBeginningPolicy.showsBeginning(
            isLoading: model.isLoadingThread,
            hasMoreBefore: model.hasMoreThreadMessages,
            hasError: model.threadErrorMessage != nil
        ) else { return nil }
        return .thread(
            id: thread.id,
            title: thread.name,
            starterName: threadStarterName,
            startedAt: model.openThreadStartedAt,
            isForumPost: model.openThreadParentChannel?.kind == .forum
        )
    }

    private var firstMessageStartsDayOverride: Bool? {
        guard beginning != nil, let first = model.threadMessageRows.first else {
            return nil
        }
        return ThreadTimelineLayoutPolicy.showsFirstReplyDateSeparator(
            showsBeginning: true,
            starterDate: model.openThreadStartedAt,
            firstReplyDate: first.message.timestamp
        )
    }

    private func loadEarlier() {
        Task {
            await model.loadEarlierThread()
        }
    }

    private func openReply(_ messageID: MessageID) {
        guard model.threadMessages.contains(where: { $0.id == messageID }) else {
            return
        }
        requestScroll(.message(messageID, anchor: .center))
    }

    private var unreadSummary: AccountReadStateModel.TimelineUnreadSummary? {
        guard let threadID = model.openThread?.id else { return nil }
        return model.timelineUnreadSummary(
            channelID: threadID,
            messages: model.threadMessages,
            hasMoreBefore:
                model.hasMoreThreadMessages
                || (model.isLoadingThread && !model.threadMessages.isEmpty)
        )
    }

    private var exactUnreadBoundaryMessageID: MessageID? {
        guard let threadID = model.openThread?.id else { return nil }
        return model.unreadDividerMessageID(channelID: threadID)
    }

    private var loadedExactUnreadBoundaryMessageID: MessageID? {
        guard let messageID = exactUnreadBoundaryMessageID,
              model.threadMessages.contains(where: { $0.id == messageID })
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
        let initialTarget = ThreadTimelinePresentationPolicy.initialScrollTarget(
            isForumPost: model.openThreadParentChannel?.kind == .forum,
            hasUnreadReplies: summary != nil
        )
        return TimelineInitialPositionPolicy.targetWhenReady(
            hasCompletedInitialLoad:
                model.hasCompletedInitialThreadLoad,
            firstUnreadMessageID: dividerMessageID ?? summary?.firstUnreadMessageID,
            hasExactUnreadBoundary:
                dividerMessageID != nil || summary?.isLowerBound == false,
            prefersNewest: initialTarget == .newest
        )
    }

    private func handleInitialPosition(_ state: TimelineScrollState) {
        guard !hasEstablishedInitialPosition,
              state.hasEstablishedInitialPosition,
              let threadID = model.openThread?.id
        else {
            return
        }
        hasEstablishedInitialPosition = true
        isNearBottom = state.isNearBottom
        model.reportTimelineInitialPosition(
            channelID: threadID,
            hasReachedReadBoundary:
                TimelineReadEligibilityPolicy.hasReachedReadBoundary(state)
        )
    }

    private func handleScrollState(_ state: TimelineScrollState) {
        isNearBottom = state.isNearBottom
        let retainedHistoryIntent =
            TimelineHistoryScrollIntentPolicy.shouldRetain(
                hasIntent: hasEarlierHistoryScrollIntent,
                isGestureActive: isEarlierHistoryScrollGestureActive,
                isInProvisionalHistory: state.isInProvisionalHistory
            )
        if hasEarlierHistoryScrollIntent != retainedHistoryIntent {
            hasEarlierHistoryScrollIntent = retainedHistoryIntent
        }
        if TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: state.isNearTop,
            contentFitsViewport: state.contentFitsViewport,
            allowsAutomaticLoading: true,
            hasMoreMessages: model.hasMoreThreadMessages,
            isLoading: model.isLoadingEarlierThread,
            requiresUserScrollIntent:
                hasUnresolvedInitialUnreadBoundary,
            hasUserScrollIntent:
                hasEarlierHistoryScrollIntent
        )
        {
            loadEarlier()
        }
        guard state.hasEstablishedInitialPosition else { return }
        if !hasEstablishedInitialPosition {
            handleInitialPosition(state)
            return
        }
        guard let threadID = model.openThread?.id else { return }
        model.reportTimelinePosition(
            channelID: threadID,
            hasReachedReadBoundary:
                TimelineReadEligibilityPolicy.hasReachedReadBoundary(state)
        )
    }

    private func handleUserScrollBegan() {
        isEarlierHistoryScrollGestureActive = true
        if hasUnresolvedInitialUnreadBoundary {
            hasEarlierHistoryScrollIntent = true
        }
    }

    private func handleUserScrollTowardNewest() {
        guard let threadID = model.openThread?.id else { return }
        model.reportTimelineScrollTowardNewest(channelID: threadID)
    }

    private func handleUserScrollEnded(_ state: TimelineScrollState) {
        isEarlierHistoryScrollGestureActive = false
        hasEarlierHistoryScrollIntent =
            TimelineHistoryScrollIntentPolicy.shouldRetain(
                hasIntent: hasEarlierHistoryScrollIntent,
                isGestureActive: false,
                isInProvisionalHistory: state.isInProvisionalHistory
            )
        isNearBottom = state.isNearBottom
        handleScrollState(state)
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
}

private struct ThreadErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: InterfaceScale.metric(8))
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.link)
            }
        }
        .font(.interface(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, InterfaceScale.metric(12))
        .padding(.vertical, InterfaceScale.metric(8))
        .background(.quaternary, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(10), style: .continuous))
        .padding(.horizontal, InterfaceScale.metric(12))
        .padding(.bottom, InterfaceScale.metric(6))
    }
}
