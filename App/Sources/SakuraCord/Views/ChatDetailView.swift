import SakuraCordModels
import SwiftUI

struct ChatDetailView: View {
    let model: AppModel
    @State private var floatingFooterHeight: CGFloat =
        ChatDetailLayoutPolicy.defaultFloatingFooterHeight

    var body: some View {
        if let channel = model.selectedChannel {
            if model.selectedConversationAccess == .hidden {
                HiddenChannelView(
                    channel: channel,
                    lastMessageDate: channel.lastMessageID?.createdAt,
                    lastPinDate: channel.lastPinTimestamp,
                    allowedPrincipals: HiddenChannelAccessPresentation.allowedPrincipals(
                        channel: channel,
                        members: model.members,
                        roles: model.guildRoles
                    )
                )
            } else {
                MessageTimelineView(
                    model: model,
                    bottomContentInset: ChatDetailLayoutPolicy.bottomContentInset(
                        measuredFooterHeight: floatingFooterHeight
                    )
                )
                .overlay(alignment: .bottom) {
                    ChatDetailFooter(
                        model: model,
                        channel: channel,
                        access: model.selectedConversationAccess
                    )
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

    var body: some View {
        VStack(spacing: 0) {
            switch access {
            case .checking:
                DisabledComposerView(message: "Checking channel permissions…")
            case .readable(canSend: true):
                TypingIndicatorView(typingState: model.typingState, channelID: channel.id)
                ComposerView(model: model, channelName: channel.name)
            case .readable(canSend: false):
                DisabledComposerView(
                    message: channel.isOfficialSystemDirectMessage
                        ? "This chat is reserved for official Discord notifications."
                        : "You do not have permission to send messages in this channel."
                )
            case .hidden:
                EmptyView()
            }
        }
    }
}

struct DisabledComposerView: View {
    let message: String

    var body: some View {
        HStack(spacing: 0) {
            Text(message)
                .font(.system(size: 15))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 24)
        .frame(height: ChatChromeMetrics.controlHeight)
        .glassEffect(
            .regular,
            in: RoundedRectangle(
                cornerRadius: ChatChromeMetrics.controlCornerRadius,
                style: .continuous
            )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct HiddenChannelView: View {
    let channel: Channel
    let lastMessageDate: Date?
    let lastPinDate: Date?
    let allowedPrincipals: [HiddenChannelAccessPrincipal]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    HiddenChannelHeader(channel: channel)

                    HiddenChannelMetadata(
                        lastMessageDate: lastMessageDate,
                        lastPinDate: lastPinDate
                    )

                    if !allowedPrincipals.isEmpty {
                        HiddenChannelAllowedPrincipals(principals: allowedPrincipals)
                            .padding(.top, 10)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}

private struct HiddenChannelHeader: View {
    let channel: Channel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 82, height: 82)
                .background(.quaternary, in: Circle())

            Text(channel.kind == .voice ? "Voice channel chat unavailable" : "This is a hidden text channel")
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)

            Text(
                channel.kind == .voice
                    ? "You cannot see the messages in \(channel.name)."
                    : "You cannot see the messages in #\(channel.name)."
            )
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HiddenChannelMetadata: View {
    let lastMessageDate: Date?
    let lastPinDate: Date?

    var body: some View {
        VStack(spacing: 7) {
            if let lastMessageDate {
                Text(
                    "Last message created: \(lastMessageDate, format: .dateTime.day().month(.abbreviated).year().hour().minute())"
                )
            }
            if let lastPinDate {
                Text(
                    "Last message pin: \(lastPinDate, format: .dateTime.day().month(.abbreviated).year().hour().minute())"
                )
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}

private struct HiddenChannelAllowedPrincipals: View {
    let principals: [HiddenChannelAccessPrincipal]
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Text("Allowed users and roles:")
                    Image(systemName: "chevron.up")
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                        .font(.callout.weight(.bold))
                }
                .font(.title3.weight(.bold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                HiddenChannelPrincipalFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(principals) { principal in
                        HiddenChannelPrincipalChip(principal: principal)
                    }
                }
                .frame(maxWidth: 700)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct HiddenChannelPrincipalChip: View {
    let principal: HiddenChannelAccessPrincipal

    private var tint: Color {
        principal.colorHex.map(Color.init(hex:)) ?? .accentColor
    }

    var body: some View {
        HStack(spacing: 6) {
            switch principal.kind {
            case .member:
                AvatarView(name: principal.name, url: principal.avatarURL, size: 21)
            case .role:
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
            }
            Text(principal.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().stroke(tint.opacity(0.62), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HiddenChannelPrincipalFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        plan(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = plan(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        let rows = Dictionary(grouping: result.frames.indices) { result.frames[$0].minY }
        var horizontalOffsets: [CGFloat: CGFloat] = [:]
        for (rowY, indices) in rows {
            let rowWidth = indices.map { result.frames[$0].maxX }.max() ?? 0
            horizontalOffsets[rowY] = max(0, (bounds.width - rowWidth) / 2)
        }
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + frame.minX + horizontalOffsets[frame.minY, default: 0],
                    y: bounds.minY + frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func plan(proposal: ProposedViewSize, subviews: Subviews) -> (
        size: CGSize,
        frames: [CGRect]
    ) {
        let maximumWidth = proposal.width ?? 700
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return InlineWrappingLayoutPlan.frames(
            sizes: sizes,
            maximumWidth: maximumWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
    }
}

private struct TypingIndicatorView: View {
    let typingState: TypingStateModel
    let channelID: ChannelID

    var body: some View {
        Text(typingState.presentation(in: channelID) ?? " ")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
            .padding(.horizontal, 16)
            .accessibilityHidden(typingState.presentation(in: channelID) == nil)
    }
}
