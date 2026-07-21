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
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.voiceSessionState == .reconnecting ? "Reconnecting…" : "Connecting…")
                        .font(.callout.weight(.medium))
                }
                .padding(18)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            VoiceVideoGrid(model: model)
        }

        VoiceCallControlDock(model: model)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
    }

    private var disconnectedContent: some View {
        let previewParticipants = previewParticipants
        return VStack(spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Text(channel?.name ?? "Voice")
                    .font(.title2.weight(.bold))
            }
            .padding(.top, 24)

            if previewParticipants.isEmpty {
                Spacer()
                Text("No one is currently in voice")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text(occupancyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VoiceChannelPreviewGrid(participants: previewParticipants)
            }

            joinButton
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var joinButton: some View {
        Button {
            guard let channel else { return }
            Task { await model.joinVoice(channel) }
        } label: {
            Label("Join Voice", systemImage: "phone.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.regular.tint(Color.accentColor).interactive(), in: Capsule())
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
        let currentUser = model.snapshot?.currentUser
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
                    isCameraEnabled: state.isVideoEnabled
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
}

private struct VoiceChannelPreviewGrid: View {
    let participants: [VoiceChannelPreviewParticipant]

    private var columns: [GridItem] {
        let count = switch participants.count {
        case 0 ... 1: 1
        case 2 ... 4: 2
        default: 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(participants) { participant in
                    VoiceChannelPreviewCard(participant: participant)
                }
            }
            .padding(14)
            .frame(maxWidth: 1020)
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
            AvatarView(name: participant.name, url: participant.avatarURL, size: 88)
        }
        .overlay(alignment: .topTrailing) {
            if participant.isCameraEnabled {
                Image(systemName: "video.fill")
                    .font(.caption.weight(.semibold))
                    .padding(8)
                    .glassEffect(.regular, in: Circle())
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            VoiceParticipantNameCapsule(
                name: participant.name,
                isLocal: participant.isLocal,
                isMuted: participant.isMuted,
                isDeafened: participant.isDeafened
            )
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(participant.isLocal ? "\(participant.name), you" : participant.name)
        .accessibilityValue(participant.isCameraEnabled ? "Camera on" : "Camera off")
    }
}
