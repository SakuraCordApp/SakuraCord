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

    /// - Parameter isDetachedFromNewest: The loaded window ends before the
    ///   newest reply, so scrolling alone cannot reach it.
    static func showsNewRepliesButton(
        isNearBottom: Bool,
        hasUnreadReplies: Bool,
        isDetachedFromNewest: Bool = false,
        messageCount: Int
    ) -> Bool {
        // A detached window ends before the newest reply even when its own
        // bottom is in view, so the way back to newest always shows.
        (!isNearBottom || isDetachedFromNewest)
            && (hasUnreadReplies || isDetachedFromNewest)
            && messageCount > 0
    }
}

struct ThreadConversationView: View {
    let model: AppModel
    @State private var floatingFooterHeight: CGFloat =
        ChatDetailLayoutPolicy.defaultFloatingFooterHeight
    @State private var editRequest: MessageTimelineEditRequest?

    @ViewBuilder var body: some View {
        if let thread = model.openThread {
            if model.withholdsOpenThreadContent {
                if model.openThreadResolution == .failed {
                    ThreadUnavailableView(retry: model.retryOpenThreadResolution)
                } else if model.openThreadAccess == .hidden {
                    ThreadUnavailableView()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

            if let starter = creation.starterMessage {
                ThreadStarterMessagePreview(model: model, message: starter)
            }

            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                Text(creation.starterMessage == nil ? "Thread Name" : "Thread Name (Optional)")
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
                        Text(creation.starterMessage == nil ? "New Thread" : creation.defaultName)
                            .lineLimit(1)
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
                if creation.showsValidationErrors, creation.nameToCreate == nil {
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
            if let error = creation.submissionError {
                ThreadCreationError(message: error)
            }
        }
        .padding(.horizontal, ChatChromeMetrics.composerWindowInset)
        .padding(.bottom, InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let until = model.guildTimeoutUntil(in: creation.parentID) {
                DisabledComposerView(
                    message: "You are timed out.",
                    appearance: model.appearanceSettings.composerBarAppearance,
                    timeoutUntil: until
                )
            } else {
                ComposerView(model: model, channelName: "", conversation: .thread)
            }
        }
        .disabled(creation.isSubmitting)
    }

    private var isMissingStarterMessage: Bool {
        model.threadDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.threadComposerAttachments.isEmpty
    }
}

/// The message a thread is being started from, as the first-party creation
/// pane shows it above the name field.
private struct ThreadStarterMessagePreview: View {
    let model: AppModel
    let message: Message

    var body: some View {
        let author = model.authorPresentation(for: message)
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            Text(author.user.displayName)
                .font(.interface(.callout).weight(.semibold))
                .foregroundStyle(author.roleColorHex.map { Color(hex: $0) } ?? .primary)
            Text(previewText)
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(12), style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting a thread from \(author.user.displayName): \(previewText)")
    }

    private var previewText: String {
        let content = model.readableThreadStarterContent(message)
        if !content.isEmpty { return content }
        if let title = message.embeds.first?.title { return title }
        if let question = message.poll?.question { return question }
        return message.attachments.isEmpty ? "Message" : "Attachment"
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
                // Readers who cannot send see the lock once, in the disabled
                // composer, as read-only channels present it.
                // Moderators who cannot send unlock from the thread's More menu.
                if model.openThreadAccess.canSend {
                    ThreadStateBanner(
                        title: isForumPost ? "Locked post" : "Locked thread",
                        message: "Only moderators can send messages.",
                        systemImage: "lock.fill",
                        actionTitle: policy.canManage ? "Unlock" : nil,
                        actionSystemImage: "lock.open.fill",
                        action: { model.updateThread(thread, mutation: .locked(false)) }
                    )
                }
            } else if thread.isArchived {
                ThreadStateBanner(
                    title: isForumPost ? "Closed post" : "Archived thread",
                    message: "Sending a reply will reopen it.",
                    systemImage: "archivebox.fill",
                    actionTitle: policy.canChangeArchive ? "Reopen" : nil,
                    actionSystemImage: "arrow.uturn.backward.circle.fill",
                    action: { model.updateThread(thread, mutation: .archived(false)) }
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

    private var policy: ThreadActionPolicy {
        model.threadActionPolicy(thread)
    }

    private var retryThreadLoad: (() -> Void)? {
        guard model.canRetryThreadLoad else { return nil }
        return { model.retryThreadLoad() }
    }
}

private struct ThreadConversationComposer: View {
    let model: AppModel
    let thread: MessageThreadSummary
    let onEditMessage: (MessageID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConversationComposerSlot(
                access: model.openThreadAccess,
                timeoutUntil: model.guildTimeoutUntil(in: thread.id, guildID: thread.guildID),
                appearance: model.appearanceSettings.composerBarAppearance,
                checkingMessage: "Checking thread permissions…",
                readOnlyMessage: thread.isLocked
                    ? "This \(model.openThreadParentChannel?.kind == .forum ? "post" : "thread") is locked."
                    : "You do not have permission to send messages in this channel."
            ) {
                ComposerView(
                    model: model,
                    channelName: thread.name,
                    conversation: .thread,
                    onEditMessage: onEditMessage
                )
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
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("Thread unavailable", systemImage: "lock.fill")
        } description: {
            Text("You cannot view messages in this thread.")
        } actions: {
            if let retry {
                Button("Try Again", action: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadMessageTimelineView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    let editRequest: MessageTimelineEditRequest?
    @State private var isNearBottom = false
    @State private var hasEstablishedInitialPosition = false
    @State private var historyPaging = TimelineHistoryPaging()
    @State private var latestScrollState = TimelineScrollState(isNearTop: false, isNearBottom: false)
    @State private var highlightedMessageID: MessageID?
    @State private var scrollRequest: MessageTimelineScrollRequest?

    var body: some View {
        let conversationID = model.openThread?.id
        let unread = unreadPresentation
        NativeMessageTimelineView(
            model: model,
            conversation: .thread(conversationID),
            beginning: beginning,
            firstMessageStartsDayOverride: firstMessageStartsDayOverride,
            hasMoreMessages: model.hasMoreThreadMessages,
            hasMoreLaterMessages: model.hasMoreLaterThreadMessages,
            isLoadingEarlier:
                MessageTimelineLoadingPolicy.showsEarlierIndicator(
                    isLoadingInitialPage: model.isLoadingThread,
                    messageCount: model.threadMessages.count,
                    isLoadingEarlierPage: model.isLoadingEarlierThread
                ),
            isLoadingLater: model.isLoadingLaterThread,
            earlierHistoryLoadFailed:
                model.threadErrorMessage != nil && model.threadErrorScope == .earlierPage,
            laterHistoryLoadFailed:
                model.threadErrorMessage != nil && model.threadErrorScope == .laterPage,
            bottomContentInset: bottomContentInset,
            unreadMessageID: unread.dividerMessageID,
            highlightedMessageID: highlightedMessageID,
            selectedMessageID: model.threadReplyingTo?.id,
            initialScrollTarget: model.threadTimelinePosition.restore ?? unread.initialScrollTarget,
            scrollRequest: scrollRequest,
            editRequest: editRequest,
            runsPerformanceAutoScroll: false,
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
               let summary = unread.summary
            {
                UnreadMessagesBanner(
                    summary: summary,
                    isLoadingHistory: model.isLoadingThread || model.isLoadingEarlierThread,
                    jumpToUnread: {
                        model.jumpToUnreadBoundary(channelID: threadID)
                    },
                    markRead: {
                        model.markConversationRead(channelID: threadID)
                    }
                )
                .padding(InterfaceScale.metric(8))
            }
        }
        .overlay(alignment: .bottom) {
            if ThreadTimelinePresentationPolicy.showsNewRepliesButton(
                isNearBottom: isNearBottom,
                hasUnreadReplies: unread.summary != nil,
                isDetachedFromNewest: model.isThreadWindowAwayFromNewest,
                messageCount: model.threadMessages.count
            ), hasEstablishedInitialPosition
                || (model.isThreadWindowAwayFromNewest && model.hasCompletedInitialThreadLoad)
            {
                TimelineNewestButton(
                    title: unread.summary != nil ? "New replies" : "Scroll to bottom",
                    hasUnread: unread.summary != nil,
                    bottomContentInset: bottomContentInset,
                    accessibilityHint: "Scrolls to the latest reply"
                ) {
                    handleUserScrollTowardNewest()
                    if model.isThreadWindowAwayFromNewest {
                        Task { await model.loadNewestThreadWindow() }
                    } else {
                        requestScroll(.bottom, glides: true)
                    }
                }
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
            historyPaging = TimelineHistoryPaging()
            latestScrollState = TimelineScrollState(isNearTop: false, isNearBottom: false)
        }
        .onChange(of: model.messageNavigationRequest, initial: true) { _, request in
            guard let request,
                  request.channelID == model.openThread?.id,
                  model.threadMessages.contains(where: {
                      $0.id == request.messageID
                  })
            else { return }
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
                  request.channelID == model.openThread?.id
            else { return }
            requestScroll(.bottom)
            model.completeConversationNewestRequest(requestID: request.requestID)
        }
        .onChange(of: model.threadReplyingTo?.id) { _, messageID in
            guard let messageID else { return }
            requestScroll(.message(messageID, anchor: .center), glides: true)
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
            model.handleTimelineEscape(in: .thread, conversationID: conversationID)
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

    private func loadLater() {
        Task {
            await model.loadLaterThread()
        }
    }

    private func openReply(_ messageID: MessageID) {
        guard model.threadMessages.contains(where: { $0.id == messageID }) else {
            return
        }
        requestScroll(.message(messageID, anchor: .center), glides: true)
    }

    private var unreadPresentation: TimelineUnreadPresentation {
        let isForumPost = model.openThreadParentChannel?.kind == .forum
        return TimelineUnreadPresentation(
            model: model,
            conversationID: model.openThread?.id,
            messages: model.threadMessages,
            hasMoreBefore: model.hasMoreThreadMessages,
            isLoadingInitialPage: model.isLoadingThread,
            hasCompletedInitialLoad: model.hasCompletedInitialThreadLoad,
            showsSummary: !model.hasMoreLaterThreadMessages,
            prefersNewest: { hasUnread in
                ThreadTimelinePresentationPolicy.initialScrollTarget(
                    isForumPost: isForumPost,
                    hasUnreadReplies: hasUnread
                ) == .newest
            }
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
        model.threadTimelinePosition.restore = nil
        model.reportTimelineInitialPosition(
            channelID: threadID,
            hasReachedReadBoundary:
                TimelineReadEligibilityPolicy.hasReachedReadBoundary(state)
        )
    }

    private func handleScrollState(_ state: TimelineScrollState) {
        isNearBottom = state.isNearBottom
        if state.hasEstablishedInitialPosition {
            model.threadTimelinePosition.reading = state.isNearBottom
                ? .bottom
                : state.readingMessage.map { .readingPosition($0.id, offsetFromViewportTop: $0.offsetFromViewportTop) }
        }
        latestScrollState = state
        let retainedPaging = historyPaging.retained(for: state)
        if historyPaging != retainedPaging {
            historyPaging = retainedPaging
        }
        loadHistoryIfNeeded(for: state)
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

    private func loadHistoryIfNeeded(for state: TimelineScrollState) {
        let directions = historyPaging.directionsToLoad(
            for: state,
            allowsAutomaticLoading: true,
            edges: TimelineHistoryEdges(
                hasMoreEarlier: model.hasMoreThreadMessages,
                hasMoreLater: model.hasMoreLaterThreadMessages,
                isLoadingEarlier: model.isLoadingEarlierThread,
                isLoadingLater: model.isLoadingLaterThread,
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
        historyPaging.gestureBegan(
            grantsEarlierIntent: unreadPresentation.hasUnresolvedInitialBoundary,
            isNearLoadedBottom: latestScrollState.isNearLoadedBottom
        )
    }

    private func handleUserScrollTowardNewest() {
        guard let threadID = model.openThread?.id else { return }
        model.reportTimelineScrollTowardNewest(channelID: threadID)
    }

    private func handleUserScrollEnded(_ state: TimelineScrollState) {
        historyPaging.gestureEnded(state)
        isNearBottom = state.isNearBottom
        handleScrollState(state)
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
