import SakuraCordModels
import SwiftUI

struct GuildResourceConversationView: View {
    let model: AppModel
    let guildID: GuildID
    let resource: GuildResourceState

    var body: some View {
        VStack(spacing: 0) {
            if let error = resource.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again") { model.loadGuideResource() }
                        .buttonStyle(.glass)
                        .disabled(resource.loading)
                }
                .padding(.horizontal, InterfaceScale.metric(24))
            }
            if resource.loading, resource.messages.isEmpty {
                ProgressView("Loading resource…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if resource.messages.isEmpty {
                if resource.error != nil {
                    ContentUnavailableView("Resource Unavailable", systemImage: "doc.text")
                } else {
                    ContentUnavailableView("No Resource Content", systemImage: "doc.text", description: Text("This resource channel has no messages yet."))
                }
            } else {
                NativeMessageTimelineView(
                    model: model, conversation: .resource(guildID, resource.channelID), beginning: nil,
                    firstMessageStartsDayOverride: false, hasMoreMessages: false,
                    hasMoreLaterMessages: resource.hasMore, isLoadingEarlier: false, isLoadingLater: resource.loading,
                    laterHistoryLoadFailed: resource.error != nil, bottomContentInset: 24, unreadMessageID: nil,
                    highlightedMessageID: nil, initialScrollTarget: resource.rows.first.map { .message($0.id, anchor: .top) },
                    scrollRequest: nil, runsPerformanceAutoScroll: false, loadEarlier: {},
                    loadLater: { model.loadGuideResource() }, openReply: { _ in },
                    onScrollActivityChange: { _ in }, onScrollStateChange: { _ in }, onUserScrollBegan: {}, onUserScrollEnded: { _ in }
                )
            }
        }
    }
}
