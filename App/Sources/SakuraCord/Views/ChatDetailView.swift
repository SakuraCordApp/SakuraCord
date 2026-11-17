import SakuraCordModels
import SwiftUI

struct ChatDetailView: View {
    let model: AppModel
    @State private var floatingFooterHeight: CGFloat =
        ChatDetailLayoutPolicy.defaultFloatingFooterHeight
    @State private var editRequest: MessageTimelineEditRequest?

    var body: some View {
        if let channel = model.selectedChannel {
            if model.selectedConversationAccess == .hidden {
                ContentUnavailableView(
                    "Channel unavailable", systemImage: "lock.fill",
                    description: Text("You cannot view messages in this channel.")
                )
                .background {
                    DisplayCompleteFrameReporter(
                        presentationID: channel.id.rawValue
                    ) {
                        guard model.selectedChannelID == channel.id else {
                            return
                        }
                        AppPerformanceSignposts
                            .reportNonTimelineWorkspaceFrame()
                        AppPerformanceSignposts.reportConversationFirstFrame(
                            channelID: channel.id
                        )
                    }
                    .frame(width: 1, height: 1)
                }
            } else {
                MessageTimelineView(
                    model: model,
                    bottomContentInset: ChatDetailLayoutPolicy.bottomContentInset(
                        measuredFooterHeight: floatingFooterHeight
                    ),
                    editRequest: editRequest
                )
                .overlay(alignment: .bottom) {
                    ConversationFooterHost {
                        ChatDetailFooter(
                            model: model,
                            channel: channel,
                            access: model.selectedConversationAccess,
                            onEditMessage: { messageID in
                                editRequest = MessageTimelineEditRequest(
                                    messageID: messageID
                                )
                            }
                        )
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        floatingFooterHeight = height
                    }
                }
            }
        } else {
            ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right", description: Text("Select a server and channel to begin."))
        }
    }
}

private struct ChatDetailFooter: View {
    let model: AppModel
    let channel: Channel
    let access: ConversationAccess
    let onEditMessage: (MessageID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let request = channel.messageRequest {
                // Discord asks for a decision before a request can be answered.
                DisabledComposerView(
                    message: request == .spam ? "Discord filed this request as spam." : "Accept this request to reply.",
                    appearance: model.appearanceSettings.composerBarAppearance
                ) {
                    MessageRequestActions(model: model, channel: channel)
                        .controlSize(.small)
                }
            } else if let guildID = channel.guildID, model.onboardingMember(in: guildID)?.isPending == true,
                      case .readable = access {
                // A screened member answers the server's form before talking, as in Discord's input blocker.
                DisabledComposerView(
                    message: "You must complete a few more steps before you can talk.",
                    appearance: model.appearanceSettings.composerBarAppearance
                ) {
                    Button("Complete") { model.openGuildJoinApplication(guildID) }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            } else {
                composerSlot
            }
        }
    }

    private var composerSlot: some View {
        ConversationComposerSlot(
            access: access,
            timeoutUntil: model.guildTimeoutUntil(in: channel.id),
            appearance: model.appearanceSettings.composerBarAppearance,
            checkingMessage: "Checking channel permissions…",
            readOnlyMessage: channel.isOfficialSystemDirectMessage
                ? "This chat is reserved for official Discord notifications."
                : "You do not have permission to send messages in this channel."
        ) {
            if model.messageAppearance(for: channel.id) == .bubbles {
                TypingBubbleIndicatorView(model: model, channel: channel)
            } else {
                TypingIndicatorView(typingState: model.typingState, channelID: channel.id)
            }
            ComposerView(
                model: model,
                channelName: channel.name,
                onEditMessage: onEditMessage
            )
        }
    }
}

/// The composer slot shared by every conversation footer. A timeout,
/// permission check or read-only notice takes the composer's place.
struct ConversationComposerSlot<Composer: View>: View {
    let access: ConversationAccess
    let timeoutUntil: Date?
    let appearance: ComposerBarAppearance
    let checkingMessage: String
    /// Shown when the conversation is readable but not writable.
    let readOnlyMessage: String?
    @ViewBuilder let composer: Composer

    var body: some View {
        if let timeoutUntil {
            DisabledComposerView(
                message: "You are timed out.",
                appearance: appearance,
                timeoutUntil: timeoutUntil
            )
        } else {
            switch access {
            case .checking:
                DisabledComposerView(message: checkingMessage, appearance: appearance)
            case .readable(canSend: true):
                composer
            case .readable(canSend: false):
                if let readOnlyMessage {
                    DisabledComposerView(message: readOnlyMessage, appearance: appearance)
                }
            case .hidden:
                EmptyView()
            }
        }
    }
}

struct DisabledComposerView<Accessory: View>: View {
    let message: String
    let appearance: ComposerBarAppearance
    var timeoutUntil: Date?
    /// Controls at the bar's trailing edge, read apart from the notice.
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let usesDefaultStyle = appearance == .defaultStyle
        let shape = usesDefaultStyle
            ? AnyShape(ConcentricRectangle(
                cornerRadius: ChatChromeMetrics.composerCornerRadius,
                style: .continuous
            ))
            : AnyShape(ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(
                        ChatChromeMetrics.composerMinimumCornerRadius
                    )
                ),
                isUniform: true
            ))

        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if timeoutUntil != nil {
                    Image(systemName: "clock")
                        .foregroundStyle(.red)
                        .padding(.trailing, InterfaceScale.metric(8))
                        .accessibilityHidden(true)
                }
                Text(message)
                Spacer(minLength: 0)
                if let until = timeoutUntil {
                    Text(timerInterval: min(Date.now, until) ... until, countsDown: true, showsHours: true)
                        .monospacedDigit()
                        .fixedSize()
                        .help("Timeout ends \(until.formatted(date: .abbreviated, time: .standard))")
                }
            }
            .accessibilityElement(children: .combine)
            accessory
        }
        .font(.interfaceSystem(size: InterfaceTypographyMetrics.messageTextSize))
        .foregroundStyle(timeoutUntil == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.white))
        .padding(.horizontal, usesDefaultStyle ? ChatChromeMetrics.composerTextLeadingInset : InterfaceScale.metric(24))
        // A long notice at a large message size wraps and the bar grows with it.
        .padding(.vertical, InterfaceScale.metric(8))
        .frame(
            minHeight: usesDefaultStyle
                ? ChatChromeMetrics.composerControlHeight
                : ChatChromeMetrics.controlHeight
        )
        .glassEffect(.regular, in: shape)
        .padding(.horizontal, ChatChromeMetrics.composerWindowInset)
        .padding(.bottom, ChatChromeMetrics.composerWindowInset)
    }
}

extension DisabledComposerView where Accessory == EmptyView {
    init(message: String, appearance: ComposerBarAppearance, timeoutUntil: Date? = nil) {
        self.init(message: message, appearance: appearance, timeoutUntil: timeoutUntil) { EmptyView() }
    }
}

private struct TypingIndicatorView: View {
    let typingState: TypingStateModel
    let channelID: ChannelID

    var body: some View {
        Text(typingState.presentation(in: channelID) ?? " ")
            .font(.interface(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(18), maxHeight: InterfaceScale.metric(18), alignment: .leading)
            .padding(.horizontal, InterfaceScale.metric(16))
            .accessibilityHidden(typingState.presentation(in: channelID) == nil)
    }
}
