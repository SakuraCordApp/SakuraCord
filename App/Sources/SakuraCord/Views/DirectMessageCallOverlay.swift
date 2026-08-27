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
    static let defaultHeight: CGFloat = 340
    static let preferredMinimumHeight: CGFloat = 210
    static let absoluteMinimumHeight: CGFloat = 150
    static let maximumHeight: CGFloat = 640
    static let minimumChatHeight: CGFloat = 220
    static let resizeHandleHeight: CGFloat = 12

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
                .frame(width: 42, height: 4)
        }
        .frame(height: DirectMessageCallLayout.resizeHandleHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in onChanged(value.translation.height) }
                .onEnded { _ in onEnded() }
        )
        .onHover { hovering in
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
        guard let currentUserID = model.snapshot?.currentUser.id else { return false }
        return call?.isRinging(currentUserID) == true
    }

    private var animatedRingingUserIDs: Set<UserID> {
        guard let call else { return [] }
        if isIncoming, let currentUserID = model.snapshot?.currentUser.id {
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
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
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
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint).interactive(), in: Capsule())
    }
}

struct IncomingPrivateCallOverlay: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if let call = model.incomingPrivateCalls.first,
               let channel = model.snapshot?.channels.first(where: {
                   $0.id == call.channelID
               })
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
        VStack(spacing: 13) {
            DirectMessageAvatar(
                channel: channel,
                size: 92,
                status: nil,
                animates: true
            )
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.22), lineWidth: 4)
                        .padding(-5)
                }
                .padding(.top, 2)

            VStack(spacing: 2) {
                Text(channel.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(
                    channel.kind == .groupDirectMessage
                        ? "Incoming Group Call…" : "Incoming Call…"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 12) {
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
            .padding(.top, 10)
            .disabled(isDisabled)

            if additionalCallCount > 0 {
                Text("\(additionalCallCount) more incoming")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .glassEffect(.regular, in: Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 30)
        .frame(width: 236)
        .glassEffect(
            .regular,
            in: ConcentricRectangle(cornerRadius: 46, style: .continuous)
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
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 80, height: 46)
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
