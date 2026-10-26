import AppKit
import SakuraCordModels
import SwiftUI

struct DirectMessageCallWorkspace: View {
    let model: AppModel
    let channel: Channel
    @SceneStorage("directMessageCallRegionHeight") private var preferredHeight = 340.0
    @State private var dragStartHeight: CGFloat?
    @State private var renderedHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let layout = DirectMessageCallLayout(availableHeight: geometry.size.height)
            let regionHeight = layout.clampedHeight(
                renderedHeight ?? CGFloat(preferredHeight)
            )

            VStack(spacing: 0) {
                DirectMessageCallRegion(model: model, channel: channel)
                    .frame(height: regionHeight)

                DirectMessageCallResizeHandle(
                    height: regionHeight,
                    onChanged: { translation in
                        let startHeight = dragStartHeight ?? regionHeight
                        dragStartHeight = startHeight
                        renderedHeight = layout.clampedHeight(
                            startHeight + translation
                        )
                    },
                    onEnded: {
                        let settledHeight = layout.clampedHeight(regionHeight)
                        renderedHeight = settledHeight
                        preferredHeight = Double(settledHeight)
                        dragStartHeight = nil
                    },
                    adjust: { delta in
                        let adjustedHeight = layout.clampedHeight(
                            regionHeight + delta
                        )
                        renderedHeight = adjustedHeight
                        preferredHeight = Double(adjustedHeight)
                    }
                )

                ChatDetailView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: geometry.size.height) { _, newHeight in
                let clampedHeight = DirectMessageCallLayout(
                    availableHeight: newHeight
                ).clampedHeight(
                    renderedHeight ?? CGFloat(preferredHeight)
                )
                renderedHeight = clampedHeight
                preferredHeight = Double(clampedHeight)
            }
        }
    }
}

struct DirectMessageCallLayout: Equatable {
    static var defaultHeight: CGFloat { InterfaceScale.metric(340) }
    static var preferredMinimumHeight: CGFloat { InterfaceScale.metric(210) }
    static var absoluteMinimumHeight: CGFloat { InterfaceScale.metric(150) }
    static var maximumHeight: CGFloat { InterfaceScale.metric(640) }
    static var minimumChatHeight: CGFloat { InterfaceScale.metric(220) }
    static var resizeHandleHeight: CGFloat { InterfaceScale.metric(12) }

    let availableHeight: CGFloat

    var minimumHeight: CGFloat {
        min(Self.preferredMinimumHeight, maximumHeight)
    }

    var maximumHeight: CGFloat {
        let roomAboveChat = availableHeight
            - Self.minimumChatHeight
            - Self.resizeHandleHeight
        return max(
            Self.absoluteMinimumHeight,
            min(Self.maximumHeight, roomAboveChat)
        )
    }

    func clampedHeight(_ proposedHeight: CGFloat) -> CGFloat {
        min(maximumHeight, max(minimumHeight, proposedHeight))
    }
}

private struct DirectMessageCallResizeHandle: View {
    let height: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let adjust: (CGFloat) -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)

            Divider()

            Capsule()
                .fill(isHovering ? Color.primary.opacity(0.55) : Color.primary.opacity(0.24))
                .frame(width: InterfaceScale.metric(42), height: InterfaceScale.metric(4))
        }
        .frame(height: DirectMessageCallLayout.resizeHandleHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in onChanged(value.translation.height) }
                .onEnded { _ in onEnded() }
        )
        .onModalHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
        .animation(.snappy(duration: 0.14), value: isHovering)
        .help("Drag to resize the call")
        .accessibilityElement()
        .accessibilityLabel("Resize call region")
        .accessibilityValue("\(Int(height)) points high")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjust(36)
            case .decrement:
                adjust(-36)
            @unknown default:
                break
            }
        }
    }
}

private struct DirectMessageCallRegion: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        VStack(spacing: 0) {
            VoiceVideoGrid(
                model: model,
                channel: channel,
                isCompact: true,
                ringingUserIDs: animatedRingingUserIDs
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isConnectedHere {
                VoiceCallControlDock(model: model)
                    .padding(.horizontal, InterfaceScale.metric(14))
                    .padding(.vertical, InterfaceScale.metric(10))
            } else {
                PrivateCallActionDock(
                    isIncoming: isIncoming,
                    isDisabled: model.isPrivateCallActionInFlight(in: channel.id),
                    accept: {
                        guard let call else { return }
                        Task { await model.acceptPrivateCall(call) }
                    },
                    decline: {
                        guard let call else { return }
                        Task { await model.declinePrivateCall(call) }
                    },
                    join: {
                        Task { await model.joinPrivateCall(in: channel) }
                    }
                )
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.vertical, InterfaceScale.metric(10))
            }
        }
        .background {
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.045),
                    Color.primary.opacity(0.018),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Direct message call")
    }

    private var call: PrivateCall? {
        model.privateCall(in: channel.id)
    }

    private var isConnectedHere: Bool {
        model.activeVoiceChannel?.id == channel.id
    }

    private var isIncoming: Bool {
        guard let currentUserID = model.currentUser?.id else { return false }
        return call?.isRinging(currentUserID) == true
    }

    private var animatedRingingUserIDs: Set<UserID> {
        guard let call else { return [] }
        if isIncoming, let currentUserID = model.currentUser?.id {
            return Set(
                call.ongoingRings
                    .filter { $0.recipientID == currentUserID }
                    .map(\.senderID)
            )
        }
        return Set(call.ongoingRings.map(\.recipientID))
    }
}

private struct PrivateCallActionDock: View {
    let isIncoming: Bool
    let isDisabled: Bool
    let accept: () -> Void
    let decline: () -> Void
    let join: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(10)) {
            HStack(spacing: InterfaceScale.metric(10)) {
                if isIncoming {
                    PrivateCallGlassButton(
                        title: "Decline",
                        systemImage: "phone.down.fill",
                        tint: Color(hex: 0xDA373C),
                        action: decline
                    )
                    PrivateCallGlassButton(
                        title: "Answer",
                        systemImage: "phone.fill",
                        tint: Color(hex: 0x23A55A),
                        action: accept
                    )
                } else {
                    PrivateCallGlassButton(
                        title: "Join Call",
                        systemImage: "phone.fill",
                        tint: SakuraCordAccentColor.color,
                        action: join
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(isDisabled)
    }
}

private struct PrivateCallGlassButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.interface(.callout).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, InterfaceScale.metric(16))
                .frame(height: InterfaceScale.metric(40))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint).interactive(), in: Capsule())
    }
}

private struct IncomingCallModalPresentation: Identifiable {
    let id: ChannelID
}

/// Incoming calls explicitly block the workspace until answered, declined or withdrawn.
struct IncomingPrivateCallWindowOverlay: View {
    let model: AppModel

    var body: some View {
        WindowModalOverlay(
            presentation: model.incomingPrivateCalls.first.map { IncomingCallModalPresentation(id: $0.channelID) },
            dismiss: {},
            content: { _, context in
            IncomingPrivateCallOverlay(model: model)
                 .onAppear {
                    context.preventsDismissal = true
                    context.escapeAction = {
                        if let call = model.incomingPrivateCalls.first,
                           !model.isPrivateCallActionInFlight(in: call.channelID) {
                            Task { await model.declinePrivateCall(call) }
                        }
                    }
                }
        })
    }
}

struct IncomingPrivateCallOverlay: View {
    let model: AppModel

    var body: some View {
        ZStack {
            WindowModalBackdrop(opacity: 0.18)

            if let call = model.incomingPrivateCalls.first,
               let channel = model.messagePresentationChannelsByID[call.channelID]
            {
                IncomingPrivateCallCard(
                    channel: channel,
                    additionalCallCount: max(0, model.incomingPrivateCalls.count - 1),
                    isDisabled: model.isPrivateCallActionInFlight(in: channel.id),
                    accept: {
                        Task { await model.acceptPrivateCall(call) }
                    },
                    decline: {
                        Task { await model.declinePrivateCall(call) }
                    }
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.24), value: model.incomingPrivateCalls.first?.channelID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Incoming call")

    }
}

private struct IncomingPrivateCallCard: View {
    let channel: Channel
    let additionalCallCount: Int
    let isDisabled: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(spacing: InterfaceScale.metric(13)) {
            DirectMessageAvatar(
                channel: channel,
                size: InterfaceScale.metric(92),
                status: nil,
                animates: true
            )
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.22), lineWidth: 4)
                        .padding(-InterfaceScale.metric(5))
                }
                .padding(.top, InterfaceScale.metric(2))

            VStack(spacing: InterfaceScale.metric(2)) {
                Text(channel.name)
                    .font(.interface(.title3).weight(.bold))
                    .lineLimit(1)
                Text(
                    channel.kind == .groupDirectMessage
                        ? "Incoming Group Call…" : "Incoming Call…"
                )
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: InterfaceScale.metric(14)) {
                HStack(spacing: InterfaceScale.metric(12)) {
                    IncomingCallActionButton(
                        title: "Decline",
                        systemImage: "xmark",
                        tint: Color(hex: 0xDA373C),
                        action: decline
                    )
                    IncomingCallActionButton(
                        title: "Answer",
                        systemImage: "phone.fill",
                        tint: Color(hex: 0x23A55A),
                        action: accept
                    )
                }
            }
            .padding(.top, InterfaceScale.metric(10))
            .disabled(isDisabled)

            if additionalCallCount > 0 {
                Text("\(additionalCallCount) more incoming")
                    .font(.interface(.caption).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, InterfaceScale.metric(10))
                    .frame(height: InterfaceScale.metric(24))
                    .glassEffect(.regular, in: Capsule())
            }
        }
        .padding(.horizontal, InterfaceScale.metric(18))
        .padding(.vertical, InterfaceScale.metric(30))
        .frame(width: InterfaceScale.metric(236))
        .glassEffect(
            .regular,
            in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(46), style: .continuous)
        )
    }
}

private struct IncomingCallActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.interfaceSystem(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: InterfaceScale.metric(80), height: InterfaceScale.metric(46))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(tint).interactive(),
            in: Capsule()
        )
        .help(title)
        .accessibilityLabel(title)
    }
}
