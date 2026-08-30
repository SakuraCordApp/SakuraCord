import SakuraCordModels
import SwiftUI

struct PinnedMessagesPopoverView: View {
    let model: AppModel
    private let runsPerformanceAutoScroll = ProcessInfo.processInfo.arguments.contains(
        "--offline-pins-performance-autoscroll"
    )

    var body: some View {
        @Bindable var pins = model.pinnedMessages
        VStack(spacing: 0) {
            HStack {
                Label("Pinned Messages", systemImage: "pin.fill")
                    .font(.headline)
                Spacer()
                if pins.isLoadingMore {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()

            GeometryReader { proxy in
                content(pins)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
            }
        }
        .frame(width: 440, height: 560)
        .onExitCommand { model.dismissPinnedMessages() }
        .onAppear { AppPerformanceSignposts.reportPinnedMessagesPanelReady() }
        .onDisappear {
            AppPerformanceSignposts.reportPinnedMessagesClosed()
            if pins.isPresented {
                model.dismissPinnedMessages()
            }
        }
    }

    @ViewBuilder
    private func content(_ pins: PinnedMessagesState) -> some View {
        if !pins.hasReadPermission {
            ContentUnavailableView(
                "Pinned Messages Unavailable",
                systemImage: "lock.fill",
                description: Text("You need permission to view this channel's message history.")
            )
        } else if pins.isLoading, pins.items.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading pinned messages…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = pins.errorMessage, pins.items.isEmpty {
            ContentUnavailableView(
                "Couldn't Load Pinned Messages",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .overlay(alignment: .bottom) {
                Button("Try Again") {
                    model.presentPinnedMessages(channelID: pins.channelID)
                }
                    .padding(.bottom, 24)
            }
        } else if pins.items.isEmpty {
            ContentUnavailableView(
                "No Pinned Messages",
                systemImage: "pin.slash",
                description: Text(
                    model.canManageActiveConversationPins
                        ? "Pin a message from its context menu to keep it here."
                        : "This conversation doesn't have any pinned messages yet."
                )
            )
        } else if let channelID = pins.channelID {
            NativeMessageTimelineView(
                model: model,
                conversation: .pins(channelID),
                beginning: nil,
                firstMessageStartsDayOverride: false,
                hasMoreMessages: false,
                hasMoreLaterMessages: pins.hasMore,
                isLoadingEarlier: false,
                isLoadingLater: pins.isLoadingMore,
                laterHistoryLoadFailed: pins.errorMessage != nil,
                bottomContentInset: 0,
                unreadMessageID: nil,
                highlightedMessageID: nil,
                initialScrollTarget: pins.rows.first.map {
                    .message($0.id, anchor: .top)
                },
                scrollRequest: nil,
                runsPerformanceAutoScroll: runsPerformanceAutoScroll,
                loadEarlier: {},
                loadLater: model.loadMorePinnedMessages,
                openReply: { messageID in
                    model.dismissPinnedMessages()
                    model.navigateToPinnedReply(messageID)
                },
                onScrollActivityChange: { _ in },
                onScrollStateChange: { _ in },
                onUserScrollBegan: AppPerformanceSignposts.beginPinnedMessagesScroll,
                onUserScrollEnded: { _ in
                    AppPerformanceSignposts.endPinnedMessagesScroll()
                }
            )
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}
