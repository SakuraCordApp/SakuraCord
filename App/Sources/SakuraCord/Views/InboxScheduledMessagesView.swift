import SakuraCordModels
import SwiftUI

/// The Inbox's Scheduled tab: each message with its send time and its
/// official actions, Send Now, Edit Message, Edit Schedule Time and Cancel.
struct InboxScheduledMessagesView: View {
    let model: AppModel
    @State private var editingTime: ScheduledMessage?

    var body: some View {
        let state = model.scheduledMessages
        Group {
            if state.messages.isEmpty, state.isLoading || !state.hasLoaded, state.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.messages.isEmpty, state.hasLoaded {
                // Only a list read once is known to be empty; a failed first read shows just its error.
                ContentUnavailableView {
                    Label("Send it at the perfect moment", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Draft your message, then choose Schedule Message from the + menu to pick when it sends.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: InterfaceScale.metric(8)) {
                        ForEach(state.messages) { message in
                            ScheduledMessageCard(model: model, message: message, isPending: state.pendingIDs.contains(message.id)) {
                                editingTime = message
                            }
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
        .windowModal(item: $editingTime, cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) { message in
            ScheduleMessageDialog(
                initialDate: message.sendAt, timeFormat: model.interfaceSettings.timestampFormat, scheduledMessageID: message.id
            ) {
                model.rescheduleMessage(message, at: $0)
            }
        }
    }
}

/// One scheduled message as the official list draws it: its send time, where
/// it goes with the row's actions, and the message as it will appear.
private struct ScheduledMessageCard: View {
    let model: AppModel
    let message: ScheduledMessage
    let isPending: Bool
    let editTime: () -> Void
    @State private var editedContent: String?
    /// The text this editor sent; only Discord saving it closes the editor.
    @State private var submittedContent: String?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        let channel = model.knownRootChannel(message.channelID)
            ?? model.sidebarThread(message.channelID).map(model.threadNavigationChannel)
        VStack(alignment: .leading, spacing: 0) {
            // Like the official list, a message whose channel is gone shows only its error and Cancel.
            if let channel {
                header
                destination(channel)
                Divider().padding(.horizontal, InterfaceScale.metric(12))
                body(channel)
            } else {
                HStack(spacing: InterfaceScale.metric(8)) {
                    Label("Scheduled message's channel not found.", systemImage: "exclamationmark.circle.fill")
                        .font(.interface(.headline))
                        .foregroundStyle(.red)
                    Spacer(minLength: InterfaceScale.metric(8))
                    actions(channel: nil)
                }
                .padding(InterfaceScale.metric(12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05))
        .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(16)))
        .opacity(isPending ? 0.6 : 1)
        .onChange(of: message.content) { _, content in
            guard content == submittedContent else { return }
            editedContent = nil
            submittedContent = nil
        }
    }

    private var header: some View {
        Group {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else {
                Label(
                    "Message scheduled for \(ScheduleTimeText.dayAndTime(message.sendAt, format: timeFormat, day: .dateTime.day().month(.wide).year()))",
                    systemImage: "clock.fill"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.interface(.callout))
        .frame(maxWidth: .infinity)
        .padding(.vertical, InterfaceScale.metric(8))
        .background(.primary.opacity(0.04))
    }

    private func destination(_ channel: Channel) -> some View {
        let destination = InboxDestinationPresentation(channelID: channel.id, guildID: channel.guildID, model: model)
        return HStack(spacing: InterfaceScale.metric(8)) {
            Button {
                model.dismissInbox()
                model.navigate(to: channel.id)
            } label: {
                HStack(spacing: InterfaceScale.metric(8)) {
                    destinationIcon(channel, destination: destination)
                    Image(systemName: "chevron.right")
                        .font(.interface(.caption2).weight(.bold))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                        HStack(spacing: InterfaceScale.metric(5)) {
                            if channel.guildID != nil {
                                SakuraCordSystemSymbol.swiftUIImage(named: destination.systemImage)
                                    .font(.interface(.subheadline)).foregroundStyle(.secondary)
                            }
                            Text(channel.name).font(.interface(.headline)).lineLimit(1)
                        }
                        if !destination.subtitle.isEmpty {
                            Text(destination.subtitle).font(.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Conversation")
            Spacer(minLength: InterfaceScale.metric(8))
            if isPending {
                ProgressView().controlSize(.small)
            } else {
                actions(channel: channel)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(12))
        .padding(.vertical, InterfaceScale.metric(8))
    }

    @ViewBuilder private func destinationIcon(_ channel: Channel, destination: InboxDestinationPresentation) -> some View {
        let size = InterfaceScale.metric(32)
        if let guildName = destination.guildName {
            GuildIconView(name: guildName, iconURL: destination.guildIconURL, size: size,
                          cornerRadius: InterfaceScale.metric(9), animates: false)
        } else {
            let recipient = channel.recipients.first
            AvatarView(name: recipient?.displayName ?? channel.name, url: channel.iconURL ?? recipient?.avatarURL, size: size)
        }
    }

    private func body(_ channel: Channel) -> some View {
        let author = message.preview.map(model.authorPresentation(for:))
        let user = author?.user ?? model.currentUser
        return VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            if let replyTo = message.replyTo {
                ScheduledReplyContext(model: model, channelID: message.channelID, messageID: replyTo)
            }
            HStack(alignment: .top, spacing: InterfaceScale.metric(12)) {
                AvatarView(name: user?.displayName ?? "", url: user?.avatarURL, size: InterfaceScale.metric(40))
                VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                    HStack(spacing: InterfaceScale.metric(6)) {
                        Text(user?.displayName ?? "")
                            .font(.interface(.headline))
                            .foregroundStyle(author?.roleColorHex.map { Color(hex: $0) } ?? .primary)
                        Text(ScheduleTimeText.time(message.sendAt, format: timeFormat))
                            .font(.interface(.caption))
                            .foregroundStyle(.secondary)
                        if message.flags.contains(.suppressNotifications) {
                            Image(systemName: "bell.slash.fill")
                                .font(.interface(.caption))
                                .foregroundStyle(.secondary)
                                .help("Silent")
                        }
                    }
                    content
                }
            }
        }
        .padding(InterfaceScale.metric(12))
    }

    @ViewBuilder private var content: some View {
        if let editedContent {
            TextField("Message", text: Binding(get: { editedContent }, set: { self.editedContent = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 8)
                // Locked while any change to the row is answered, so a save can't drop later typing.
                .disabled(isPending)
                .focused($isEditorFocused)
                .padding(InterfaceScale.metric(8))
                .background(.primary.opacity(0.06), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(10)))
                .onSubmit {
                    // The editor stays open until Discord saves the edit, so a refused one keeps its text.
                    if model.editScheduledMessage(message, content: editedContent) {
                        submittedContent = editedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        self.editedContent = nil
                    }
                }
                .onExitCommand {
                    self.editedContent = nil
                    submittedContent = nil
                }
            Text("Escape to cancel · Return to save")
                .font(.interface(.caption2))
                .foregroundStyle(.tertiary)
        } else if !visibleContent.isEmpty {
            CustomEmojiRichText(
                model: model,
                message: message.preview,
                content: visibleContent,
                emojiSize: InterfaceScale.metric(22),
                baseFontSize: InterfaceScale.fontSize(15),
                mentionPresentation: MessageMentionResolver(model: model, message: message.preview).presentation
            )
        }
        if let preview = message.preview {
            ForEach(preview.stickers) { sticker in
                StickerPreview(sticker: sticker)
                    .frame(width: InterfaceScale.metric(160), height: InterfaceScale.metric(160))
            }
            if let media = ForwardMessagePreviewPlan.make(message: preview).media, let url = media.url {
                // A GIF link's embed plays its looping video over the still, as in the timeline.
                let video = media.isSpoiler ? nil : preview.embeds.first { $0.type?.lowercased() == "gifv" }?.video
                ZStack {
                    AnimatedRemoteImage(url: url, animates: !media.isSpoiler, maximumPixelDimension: 400, contentMode: .fit)
                    if let videoURL = video.flatMap({ $0.proxyURL ?? $0.url }) {
                        ScheduledGIFVideo(url: videoURL)
                    }
                }
                .aspectRatio(video.flatMap { video in
                    video.width.flatMap { width in video.height.flatMap { $0 > 0 ? CGFloat(width) / CGFloat($0) : nil } }
                }, contentMode: .fit)
                .frame(maxWidth: InterfaceScale.metric(240), maxHeight: InterfaceScale.metric(180), alignment: .leading)
                .blur(radius: media.isSpoiler ? 24 : 0)
                .overlay {
                    if media.isSpoiler {
                        Text("Spoiler").font(.interface(.caption).weight(.bold)).padding(.horizontal, InterfaceScale.metric(8))
                            .padding(.vertical, InterfaceScale.metric(4)).glassEffect(.regular, in: Capsule())
                    }
                }
                .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(8)))
            }
        }
        if message.attachmentCount > 0 {
            let count = message.attachmentCount
            Label(count == 1 ? String(localized: "1 attachment") : String(localized: "\(count) attachments"), systemImage: "paperclip")
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
        }
    }

    /// The text as the timeline shows it, without a link its media replaces.
    private var visibleContent: String {
        guard let preview = message.preview else { return message.content }
        var shown = preview
        shown.content = message.content
        return MessageEmbedPresentation.visibleMessageContent(for: shown)
    }

    private var timeFormat: InterfaceTimestampFormat { model.interfaceSettings.timestampFormat }

    /// The official list's wording for a message Discord will not send.
    private var failure: LocalizedStringResource? {
        switch message.state {
        case .scheduled: nil
        case .userCannotSchedule: "Message could not be sent, permission was denied"
        case .disabled, .userNotFound, .channelNotFound, .sendFailed: "Message could not be sent"
        }
    }

    private func actions(channel: Channel?) -> some View {
        HoverActionPill {
            if channel != nil {
                HoverActionButton(systemImage: "paperplane", help: "Send Now") { model.sendScheduledMessageNow(message) }
                HoverActionButton(systemImage: "pencil", help: "Edit Message") {
                    editedContent = message.content
                    isEditorFocused = true
                }
                HoverActionButton(systemImage: "clock", help: "Edit Schedule Time", action: editTime)
            }
            HoverActionButton(systemImage: "xmark.circle", help: "Cancel Scheduled Message", role: .destructive) {
                model.cancelScheduledMessage(message)
            }
        }
    }
}

/// The message a scheduled reply answers, as the timeline shows it above a reply.
private struct ScheduledReplyContext: View {
    let model: AppModel
    let channelID: ChannelID
    let messageID: MessageID

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            Image(systemName: "arrow.turn.up.right")
                .font(.interface(.caption).weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: InterfaceScale.metric(40))
            if let replied = model.retainedMessage(channelID: channelID, messageID: messageID) {
                AvatarView(name: replied.author.displayName, url: replied.author.avatarURL, size: InterfaceScale.metric(16))
                Text(replied.author.displayName).fontWeight(.semibold).foregroundStyle(.secondary)
                Text(summary(of: replied)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                // The official list's words for a reply whose message isn't loaded.
                Text("Message could not be loaded").italic().foregroundStyle(.secondary)
            }
        }
        .font(.interface(.caption))
        .lineLimit(1)
    }

    /// One line as the timeline's reply line reads, its spoilers kept covered.
    private func summary(of replied: Message) -> AttributedString {
        let prepared = MessageReplySummary.summary(
            content: replied.content, mentionLabel: MessageMentionResolver(model: model, message: replied).label
        )
        let text = NSMutableAttributedString(string: prepared.text)
        for range in prepared.spoilerRanges {
            text.addAttribute(.backgroundColor, value: NativeTimelineSpoilerAppearance.textBackgroundColor(hover: 0), range: range)
            NativeTimelineSpoilerAppearance.concealText(in: text, range: range)
        }
        return AttributedString(text)
    }
}

/// A scheduled GIF's looping video, played as the GIF picker plays it.
private struct ScheduledGIFVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> GIFPickerVideoCanvas {
        GIFPickerVideoCanvas()
    }

    // A video that fails to load leaves the still beneath it. `display` clears
    // the canvas, visibility included, so visibility is set after it.
    func updateNSView(_ canvas: GIFPickerVideoCanvas, context: Context) {
        canvas.display(url) {}
        canvas.setViewportVisible(true)
    }
}
