import SakuraCordModels
import SwiftUI

/// The Inbox's Scheduled tab: each message with its send time and its
/// official actions, Send Now, Edit Message, Edit Schedule Time and Cancel.
struct InboxScheduledMessagesView: View {
    let model: AppModel

    var body: some View {
        let state = model.scheduledMessages
        Group {
            if state.messages.isEmpty, state.isLoading || !state.hasLoaded, state.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.messages.isEmpty {
                ContentUnavailableView {
                    Label("No Scheduled Messages", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Choose Schedule Message from the + menu to send a message later.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: InterfaceScale.metric(8)) {
                        ForEach(state.messages) { message in
                            ScheduledMessageCard(model: model, message: message, isPending: state.pendingIDs.contains(message.id))
                        }
                    }
                    .padding(InterfaceScale.metric(10))
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = state.errorMessage {
                InboxNotice(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: error) {
                    Button("Retry", action: model.loadScheduledMessages)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else if model.scheduledMessageLimit == 1, state.hasLoaded, !state.messages.isEmpty {
                // Like the official list, only an account Nitro would help hears about the limit.
                InboxNotice(
                    systemImage: "sparkles",
                    tint: SakuraCordAccentColor.color,
                    text: "Nitro raises your scheduled message limit to \(ScheduledMessagePolicy.nitroLimit)."
                ) { EmptyView() }
            }
        }
        .animation(.snappy(duration: 0.25), value: state.messages.map(\.id))
        .animation(.snappy(duration: 0.25), value: state.errorMessage)
    }
}

private struct ScheduledMessageCard: View {
    let model: AppModel
    let message: ScheduledMessage
    let isPending: Bool
    @State private var isEditingTime = false
    @State private var editedContent: String?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        let channel = model.knownRootChannel(message.channelID)
            ?? model.sidebarThread(message.channelID).map(model.threadNavigationChannel)
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            HStack(spacing: InterfaceScale.metric(8)) {
                status(channel: channel)
                Spacer(minLength: InterfaceScale.metric(8))
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    actions(channel: channel)
                }
            }
            // Like the official list, a message whose channel is gone shows only its error and Cancel.
            if let channel {
                Button {
                    model.dismissInbox()
                    model.navigate(to: channel.id)
                } label: {
                    Label(channelTitle(channel), systemImage: channel.guildID == nil ? "bubble.left" : "number")
                        .font(.interface(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open Conversation")
                content
            }
        }
        .padding(InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16)))
        .opacity(isPending ? 0.6 : 1)
    }

    @ViewBuilder private var content: some View {
        if let editedContent {
            TextField("Message", text: Binding(get: { editedContent }, set: { self.editedContent = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 8)
                .focused($isEditorFocused)
                .padding(InterfaceScale.metric(8))
                .background(.primary.opacity(0.06), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(10)))
                .onSubmit {
                    // The editor stays open until the row's other change is answered.
                    guard !isPending else { return }
                    model.editScheduledMessage(message, content: editedContent)
                    self.editedContent = nil
                }
                .onExitCommand { self.editedContent = nil }
            Text("Escape to cancel · Return to save")
                .font(.interface(.caption2))
                .foregroundStyle(.tertiary)
        } else if !message.content.isEmpty {
            Text(message.content)
                .font(.interface(.body))
                .lineLimit(4)
                .textSelection(.enabled)
        }
        if !details.isEmpty {
            HStack(spacing: InterfaceScale.metric(10)) {
                ForEach(details, id: \.text) { detail in
                    Label(detail.text, systemImage: detail.systemImage)
                }
            }
            .font(.interface(.caption))
            .foregroundStyle(.secondary)
        }
    }

    private func channelTitle(_ channel: Channel) -> String {
        guard let guildID = channel.guildID,
              let guild = model.snapshot?.guilds.first(where: { $0.id == guildID })
        else { return channel.name }
        return "\(channel.name) · \(guild.name)"
    }

    @ViewBuilder private func status(channel: Channel?) -> some View {
        if let failure = failure(channel: channel) {
            Label(failure, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else {
            Label {
                Text(message.sendAt.formatted(date: .abbreviated, time: .shortened))
            } icon: {
                Image(systemName: "clock").foregroundStyle(SakuraCordAccentColor.color)
            }
        }
    }

    /// The official list's wording: an unknown channel wins over the state Discord reports.
    private func failure(channel: Channel?) -> LocalizedStringResource? {
        if channel == nil, model.snapshot != nil { return "Scheduled message's channel not found." }
        return switch message.state {
        case .scheduled: nil
        case .userCannotSchedule: "Message could not be sent, permission was denied"
        case .disabled, .userNotFound, .channelNotFound, .sendFailed: "Message could not be sent"
        }
    }

    private var details: [(text: String, systemImage: String)] {
        var details: [(String, String)] = []
        if message.replyTo != nil { details.append((String(localized: "Reply"), "arrowshape.turn.up.left")) }
        if message.attachmentCount > 0 {
            let count = message.attachmentCount
            details.append((count == 1 ? String(localized: "1 attachment") : String(localized: "\(count) attachments"), "paperclip"))
        }
        if message.flags.contains(.suppressNotifications) { details.append((String(localized: "Silent"), "bell.slash")) }
        return details
    }

    private func actions(channel: Channel?) -> some View {
        HoverActionPill {
            if channel != nil {
                HoverActionButton(systemImage: "paperplane", help: "Send Now") { model.sendScheduledMessageNow(message) }
                HoverActionButton(systemImage: "pencil", help: "Edit Message") {
                    editedContent = message.content
                    isEditorFocused = true
                }
                HoverActionButton(systemImage: "clock", help: "Edit Schedule Time") { isEditingTime = true }
                    .popover(isPresented: $isEditingTime, arrowEdge: .bottom) {
                        ScheduleMessagePicker(initialDate: message.sendAt, scheduledMessageID: message.id) {
                            isEditingTime = false
                            model.rescheduleMessage(message, at: $0)
                        }
                    }
            }
            HoverActionButton(systemImage: "xmark.circle", help: "Cancel Scheduled Message", role: .destructive) {
                model.cancelScheduledMessage(message)
            }
        }
    }
}
