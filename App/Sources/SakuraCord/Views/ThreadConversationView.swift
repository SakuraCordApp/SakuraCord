import SakuraCordModels
import SwiftUI

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

    var body: some View {
        SupplementaryConversationPane {
            VStack(spacing: 0) {
                if let thread = model.openThread {
                    if model.openThreadAccess == .hidden {
                        ThreadUnavailableView()
                    } else {
                        ThreadMessageTimelineView(model: model)
                        if let error = model.threadErrorMessage {
                            ThreadErrorBanner(message: error)
                        }
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
                            DisabledComposerView(
                                message: "You do not have permission to send messages in this thread."
                            )
                        case .hidden:
                            EmptyView()
                        }
                    }
                }
            }
        }
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
    @State private var isNearBottom = true

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

                        ForEach(model.threadMessageRows.enumerated(), id: \.element.id) { index, row in
                            VStack(alignment: .leading, spacing: 0) {
                                if showsDateSeparator(at: index, for: row) {
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
                                    saveEdit: { value in
                                        Task { await model.edit(row.message, content: value) }
                                    },
                                    reply: nil,
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

                        Color.clear.frame(height: 1).id(bottomID)
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
                }
                .overlay {
                    if MessageTimelineLoadingPolicy.showsInitialPlaceholder(
                        isLoading: model.isLoadingThread,
                        messageCount: model.threadMessages.count
                    ) {
                        MessageTimelineLoadingSkeleton()
                    }
                }
                .overlay(alignment: .bottom) {
                    if !isNearBottom, !model.threadMessages.isEmpty {
                        Button {
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
                        .padding(.bottom, 10)
                        .accessibilityHint("Scrolls to the latest reply")
                    }
                }
                .onChange(of: model.threadMessages.last?.id) { oldID, id in
                    guard oldID != nil, let id, isNearBottom else { return }
                    // Keep short threads anchored near the composer while revealing only the
                    // newly appended row in longer histories.
                    proxy.scrollTo(id)
                }
                .onChange(of: model.openThread?.id) {
                    isNearBottom = true
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
