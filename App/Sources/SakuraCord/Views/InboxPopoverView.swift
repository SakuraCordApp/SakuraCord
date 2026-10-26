import SakuraCordModels
import SwiftUI

struct InboxPopoverView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            InboxToolbar(model: model)
            InboxContent(model: model)
                .animation(.easeOut(duration: 0.18), value: model.inbox.tab)
            if let error = model.inbox.errorMessage {
                HStack(spacing: InterfaceScale.metric(8)) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.interface(.callout)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: InterfaceScale.metric(8))
                    Button("Retry", action: model.retryInboxLoad)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .padding(.horizontal, InterfaceScale.metric(12))
                .padding(.vertical, InterfaceScale.metric(8))
                .background(.primary.opacity(0.06), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
                .padding(InterfaceScale.metric(10))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.inbox.errorMessage)
        .frame(width: InterfaceScale.metric(460), height: InterfaceScale.metric(580))
        .sheet(item: Binding(get: { model.inbox.selectedEvent }, set: { model.inbox.selectedEvent = $0 })) { event in
            InboxEventDetailsView(event: event, model: model)
        }
        .alert("Age-Restricted Channel", isPresented: Binding(
            get: { model.inbox.ageRestrictedGuildID != nil },
            set: { if !$0 { model.cancelInboxAgeAgreement() } }
        )) {
            if model.currentUser?.allowsAdultContent == true {
                Button("Continue", action: model.acceptInboxAgeAgreement)
            }
            Button("Cancel", role: .cancel, action: model.cancelInboxAgeAgreement)
        } message: {
            Text(model.currentUser?.allowsAdultContent == true
                 ? "This channel contains age-restricted content. Do you wish to proceed?"
                 : "Confirm your age in Discord before opening this channel.")
        }
        .onExitCommand(perform: model.dismissInbox)
        .onDisappear { model.dismissInbox() }
    }
}

private struct InboxToolbar: View {
    let model: AppModel
    @State private var confirmsMarkAll = false

    var body: some View {
        let inbox = model.inbox
        HStack(spacing: InterfaceScale.metric(6)) {
            InboxTabPicker(selection: inbox.tab, unreadCount: inbox.groups.count, select: model.selectInboxTab)
            Spacer(minLength: 0)
            if inbox.tab == .mentions {
                Menu {
                    Toggle("Include @everyone", isOn: Binding(
                        get: { inbox.query.includesEveryone },
                        set: { inbox.query.includesEveryone = $0; model.inboxMentionQueryDidChange() }
                    ))
                    Toggle("Include @role", isOn: Binding(
                        get: { inbox.query.includesRoles },
                        set: { inbox.query.includesRoles = $0; model.inboxMentionQueryDidChange() }
                    ))
                    if let guildID = model.selectedChannel?.guildID {
                        Toggle("All Servers", isOn: Binding(
                            get: { inbox.query.guildID == nil },
                            set: { inbox.query.guildID = $0 ? nil : guildID; model.inboxMentionQueryDidChange() }
                        ))
                    }
                } label: {
                    HoverActionControlLabel(isSelected: !inbox.query.includesEveryone || !inbox.query.includesRoles || inbox.query.guildID != nil) {
                        Image(systemName: "line.3.horizontal.decrease").font(.interface(.callout).weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Filter Mentions")
                .accessibilityLabel("Filter Mentions")
                .transition(.opacity)
            } else {
                if !inbox.undoGroups.isEmpty {
                    HoverActionButton(systemImage: "arrow.uturn.backward", help: "Undo Mark Read", action: model.undoInboxRead)
                        .keyboardShortcut("z", modifiers: .command)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                HoverActionButton(systemImage: "envelope.open", help: "Mark All as Read") { confirmsMarkAll = true }
                    .disabled(inbox.groups.isEmpty)
                    .confirmationDialog("Mark all Inbox conversations as read?", isPresented: $confirmsMarkAll) {
                        Button("Mark All as Read", action: model.markAllInboxRead)
                    }
                    .transition(.opacity)
            }
            HoverActionButton(systemImage: "arrow.clockwise", help: "Refresh Inbox", action: model.reloadInbox)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: inbox.isRefreshing)
                .disabled(inbox.isRefreshing)
        }
        .animation(.snappy(duration: 0.22), value: inbox.tab)
        .animation(.snappy(duration: 0.22), value: inbox.undoGroups.isEmpty)
        .padding(.horizontal, InterfaceScale.metric(10))
        .padding(.top, InterfaceScale.metric(10))
        .padding(.bottom, InterfaceScale.metric(6))
    }
}

private struct InboxTabPicker: View {
    let selection: InboxTab
    let unreadCount: Int
    let select: (InboxTab) -> Void

    var body: some View {
        Picker("Inbox", selection: Binding(get: { selection }, set: { select($0) })) {
            Group {
                if unreadCount > 0 {
                    Text("Unread (\(unreadCount))")
                } else {
                    Text("Unread")
                }
            }
            .tag(InboxTab.unread)
            Text("Mentions")
                .tag(InboxTab.mentions)
        }
        .pickerStyle(.tabs)
        .controlSize(.large)
        .labelsHidden()
        .fixedSize()
    }
}

private struct InboxContent: View {
    let model: AppModel

    var body: some View {
        let inbox = model.inbox
        let isEmpty = inbox.tab == .mentions ? inbox.visibleMentions.isEmpty : inbox.groups.isEmpty
        // Retained content and known-empty results render immediately; only a
        // first fetch with nothing to show waits on the network.
        let awaitsFirstPage = inbox.tab == .mentions ? inbox.hasMoreMentions : true
        if isEmpty, inbox.isLoading, awaitsFirstPage {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty {
            ContentUnavailableView(
                inbox.tab == .mentions ? "No Mentions" : "You're All Caught Up",
                systemImage: inbox.tab == .mentions ? "at" : "tray",
                description: nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NativeMessageTimelineView(
                model: model, conversation: .inbox(inbox.tab), beginning: nil,
                firstMessageStartsDayOverride: nil,
                hasMoreMessages: false, hasMoreLaterMessages: inbox.hasMore,
                isLoadingEarlier: false, isLoadingLater: inbox.isLoading,
                laterHistoryLoadFailed: inbox.errorMessage != nil,
                bottomContentInset: 0, unreadMessageID: nil, highlightedMessageID: nil,
                selectedMessageID: inbox.selectedMessageID,
                initialScrollTarget: .top,
                scrollRequest: inbox.scrollRequest, runsPerformanceAutoScroll: false,
                loadEarlier: {}, loadLater: model.loadMoreInbox,
                openReply: { id in
                    if let message = inbox.rows.first(where: { $0.message.replyTo == id })?.message {
                        model.navigateToInboxResult(message, messageID: id)
                    }
                },
                onScrollActivityChange: { _ in }, onScrollStateChange: { state in
                    if state.isNearLoadedBottom { model.loadMoreInbox() }
                },
                onUserScrollBegan: {}, onUserScrollEnded: { _ in }
            )
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}
