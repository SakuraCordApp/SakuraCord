import SakuraCordModels
import SwiftUI

struct VoiceChannelView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if isActiveCall {
                connectedContent
            } else {
                disconnectedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var connectedContent: some View {
        if model.voiceSessionState == .connecting || model.voiceSessionState == .reconnecting {
            ZStack {
                VoiceVideoGrid(model: model)
                VStack(spacing: InterfaceScale.metric(10)) {
                    ProgressView()
                    Text(model.voiceSessionState == .reconnecting ? "Reconnecting…" : "Connecting…")
                        .font(.interface(.callout).weight(.medium))
                }
                .padding(InterfaceScale.metric(18))
                .glassEffect(.regular, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous))
            }
        } else if model.voiceSessionState == .failed
            || model.voiceSessionState == .disconnected
        {
            ZStack {
                VoiceVideoGrid(model: model)
                    .opacity(0.45)
                VStack(spacing: InterfaceScale.metric(10)) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.interfaceSystem(size: 28, weight: .medium))
                        .foregroundStyle(Color(hex: 0xDA373C))
                    Text("Voice disconnected")
                        .font(.interface(.headline))
                    Text("SakuraCord is no longer receiving call audio.")
                        .font(.interface(.callout))
                        .foregroundStyle(.secondary)
                }
                .padding(InterfaceScale.metric(20))
                .glassEffect(
                    .regular.tint(Color(hex: 0xDA373C).opacity(0.16)),
                    in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous)
                )
            }
        } else {
            VoiceVideoGrid(model: model)
        }

        VoiceCallControlDock(model: model)
            .padding(.horizontal, InterfaceScale.metric(18))
            .padding(.bottom, InterfaceScale.metric(18))
    }

    private var disconnectedContent: some View {
        let previewParticipants = previewParticipants
        return VStack(spacing: InterfaceScale.metric(16)) {
            HStack(spacing: InterfaceScale.metric(9)) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Text(channel?.name ?? "Voice")
                    .font(.interface(.title2).weight(.bold))
            }
            .padding(.top, InterfaceScale.metric(24))

            if previewParticipants.isEmpty {
                Spacer()
                VStack(spacing: InterfaceScale.metric(16)) {
                    Text("No one is currently in voice")
                        .font(.interface(.callout))
                        .foregroundStyle(.secondary)
                    joinButton
                }
                Spacer()
            } else {
                Text(occupancyText)
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                VoiceChannelPreviewGrid(participants: previewParticipants)

                joinButton
                    .padding(.bottom, InterfaceScale.metric(24))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var joinButton: some View {
        Button {
            guard let channel else { return }
            Task { await model.joinVoice(channel) }
        } label: {
            Label("Join Voice", systemImage: "phone.fill")
                .font(.interface(.callout).weight(.semibold))
                .padding(.horizontal, InterfaceScale.metric(18))
                .frame(height: InterfaceScale.metric(40))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(
            .regular.tint(SakuraCordAccentColor.color).interactive(),
            in: Capsule()
        )
        .disabled(channel.map(model.canJoinVoice) != true)
    }

    private var channel: Channel? {
        guard model.selectedChannel?.kind == .voice else { return nil }
        return model.selectedChannel
    }

    private var isActiveCall: Bool {
        channel?.id == model.activeVoiceChannel?.id
    }

    private var occupancyText: String {
        guard let channel else { return "No one is currently in voice" }
        let count = model.voiceStates.values.filter { $0.channelID == channel.id }.count
        return switch count {
        case 0: "No one is currently in voice"
        case 1: "1 person is currently in voice"
        default: "\(count) people are currently in voice"
        }
    }

    private var previewParticipants: [VoiceChannelPreviewParticipant] {
        guard let channel else { return [] }
        let currentUser = model.currentUser
        return model.voiceStates.values
            .filter { $0.channelID == channel.id }
            .map { state in
                let user = state.userID == currentUser?.id
                    ? currentUser
                    : model.membersByID[state.userID]?.user
                return VoiceChannelPreviewParticipant(
                    id: state.userID,
                    name: user?.displayName ?? "User \(state.userID.rawValue)",
                    avatarURL: user?.avatarURL,
                    isLocal: state.userID == currentUser?.id,
                    isMuted: state.isMuted || state.isSelfMuted,
                    isDeafened: state.isDeafened || state.isSelfDeafened,
                    isCameraEnabled: state.isVideoEnabled,
                    isStreaming: state.isStreaming
                )
            }
            .sorted {
                if $0.isLocal != $1.isLocal {
                    return $0.isLocal
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }
}

private struct VoiceChannelPreviewParticipant: Identifiable {
    let id: UserID
    let name: String
    let avatarURL: URL?
    let isLocal: Bool
    let isMuted: Bool
    let isDeafened: Bool
    let isCameraEnabled: Bool
    let isStreaming: Bool
}

private struct VoiceChannelPreviewGrid: View {
    let participants: [VoiceChannelPreviewParticipant]

    private var columns: [GridItem] {
        let count = switch participants.count {
        case 0 ... 1: 1
        case 2 ... 4: 2
        default: 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: InterfaceScale.metric(12)), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: InterfaceScale.metric(12)) {
                ForEach(participants) { participant in
                    VoiceChannelPreviewCard(participant: participant)
                }
            }
            .padding(InterfaceScale.metric(14))
            .frame(maxWidth: InterfaceScale.metric(1020))
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VoiceChannelPreviewCard: View {
    let participant: VoiceChannelPreviewParticipant

    var body: some View {
        ZStack {
            Color.primary.opacity(0.055)
            AvatarView(name: participant.name, url: participant.avatarURL, size: InterfaceScale.metric(88))
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: InterfaceScale.metric(6)) {
                if participant.isStreaming {
                    Image(systemName: "display")
                        .foregroundStyle(Color(hex: 0x23A55A))
                        .accessibilityLabel("Sharing screen")
                }
                if participant.isCameraEnabled {
                    Image(systemName: "video.fill")
                        .accessibilityLabel("Camera on")
                }
            }
            .font(.interface(.caption).weight(.semibold))
            .padding(InterfaceScale.metric(8))
            .glassEffect(.regular, in: Capsule())
            .padding(InterfaceScale.metric(10))
            .opacity(participant.isCameraEnabled || participant.isStreaming ? 1 : 0)
        }
        .overlay(alignment: .bottomLeading) {
            VoiceParticipantNameCapsule(
                name: participant.name,
                isLocal: participant.isLocal,
                isMuted: participant.isMuted,
                isDeafened: participant.isDeafened
            )
            .padding(InterfaceScale.metric(10))
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(participant.isLocal ? "\(participant.name), you" : participant.name)
        .accessibilityValue(
            (participant.isCameraEnabled ? "Camera on" : "Camera off")
                + (participant.isStreaming ? ", sharing screen" : "")
        )
    }
}
