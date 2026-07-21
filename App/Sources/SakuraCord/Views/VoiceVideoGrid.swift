import MediaPipeline
import SakuraCordModels
import SwiftUI

struct VoiceVideoGrid: View {
    let model: AppModel

    private var participants: [VoiceTileParticipant] {
        guard let activeChannel = model.activeVoiceChannel else { return [] }
        let currentUser = model.snapshot?.currentUser
        let currentUserID = currentUser.map { String($0.id.rawValue) }
        let speakingByID = Dictionary(uniqueKeysWithValues: model.voiceParticipants.map { ($0.userID, $0.isSpeaking) })
        let volumeByID = Dictionary(uniqueKeysWithValues: model.voiceParticipants.map { ($0.userID, $0.volume) })
        let cameraByID = Dictionary(uniqueKeysWithValues: model.voiceParticipants.map { ($0.userID, $0.isCameraEnabled) })
        var values: [String: VoiceTileParticipant] = [:]

        for state in model.voiceStates.values where state.channelID == activeChannel.id {
            let userID = String(state.userID.rawValue)
            let user = state.userID == currentUser?.id
                ? currentUser
                : model.membersByID[state.userID]?.user
            values[userID] = VoiceTileParticipant(
                id: userID,
                name: user?.displayName ?? "User \(userID)",
                avatarURL: user?.avatarURL,
                frame: (state.isVideoEnabled || cameraByID[userID] == true) ? model.voiceVideoFrames[userID] : nil,
                isLocal: userID == currentUserID,
                isMuted: state.isMuted || state.isSelfMuted,
                isDeafened: state.isDeafened || state.isSelfDeafened,
                isSpeaking: userID == currentUserID ? model.isLocallySpeaking : (speakingByID[userID] ?? false),
                volume: volumeByID[userID] ?? 1
            )
        }

        for participant in model.voiceParticipants where values[participant.userID] == nil {
            let numericID = UserID(participant.userID)
            let user = numericID.flatMap { id in
                id == currentUser?.id ? currentUser : model.membersByID[id]?.user
            }
            values[participant.userID] = VoiceTileParticipant(
                id: participant.userID,
                name: user?.displayName ?? "User \(participant.userID)",
                avatarURL: user?.avatarURL,
                frame: participant.isCameraEnabled ? model.voiceVideoFrames[participant.userID] : nil,
                isLocal: participant.userID == currentUserID,
                isMuted: false,
                isDeafened: false,
                isSpeaking: participant.userID == currentUserID ? model.isLocallySpeaking : participant.isSpeaking,
                volume: participant.volume
            )
        }

        if let currentUser, let currentUserID, values[currentUserID] == nil {
            values[currentUserID] = VoiceTileParticipant(
                id: currentUserID,
                name: currentUser.displayName,
                avatarURL: currentUser.avatarURL,
                frame: model.isCameraEnabled ? model.voiceVideoFrames[currentUserID] : nil,
                isLocal: true,
                isMuted: model.isVoiceMuted,
                isDeafened: model.isVoiceDeafened,
                isSpeaking: model.isLocallySpeaking,
                volume: 1
            )
        }

        return values.values.sorted {
            if $0.isLocal != $1.isLocal {
                return $0.isLocal
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func columns(participantCount: Int) -> [GridItem] {
        let columnCount = switch participantCount {
        case 0 ... 1: 1
        case 2 ... 4: 2
        default: 3
        }
        return Array(
            repeating: GridItem(.flexible(minimum: 260, maximum: 620), spacing: 12),
            count: columnCount
        )
    }

    private func gridMaximumWidth(participantCount: Int) -> CGFloat {
        switch participantCount {
        case 0 ... 1: 900
        case 2 ... 4: 1180
        default: 1420
        }
    }

    var body: some View {
        let participants = participants
        let columns = columns(participantCount: participants.count)
        let gridMaximumWidth = gridMaximumWidth(participantCount: participants.count)
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                    ForEach(participants) { participant in
                        VoiceParticipantTile(participant: participant) { volume in
                            Task { await model.updateParticipantVolume(volume, userID: participant.id) }
                        }
                    }
                }
                .frame(maxWidth: gridMaximumWidth)
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(0, geometry.size.height - 28),
                    alignment: .center
                )
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VoiceTileParticipant: Identifiable {
    let id: String
    let name: String
    let avatarURL: URL?
    let frame: VoiceVideoFrame?
    let isLocal: Bool
    let isMuted: Bool
    let isDeafened: Bool
    let isSpeaking: Bool
    let volume: Float
}

private struct VoiceParticipantTile: View {
    let participant: VoiceTileParticipant
    let updateVolume: (Float) -> Void
    @State private var isHovering = false
    @State private var showVolume = false

    var body: some View {
        ZStack {
            Color.primary.opacity(0.055)

            if let frame = participant.frame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                AvatarView(name: participant.name, url: participant.avatarURL, size: 88)
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
        .overlay(alignment: .topTrailing) {
            if !participant.isLocal, isHovering || showVolume {
                Button {
                    showVolume.toggle()
                } label: {
                    Image(systemName: participant.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.callout.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .help("User Volume")
                .padding(10)
                .popover(isPresented: $showVolume, arrowEdge: .top) {
                    ParticipantVolumeControl(
                        name: participant.name,
                        initialVolume: participant.volume,
                        updateVolume: updateVolume
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(participant.isSpeaking ? Color(hex: 0x23A55A) : Color.primary.opacity(0.08), lineWidth: participant.isSpeaking ? 3 : 1)
        }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.14)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(participant.isLocal ? "\(participant.name), you" : participant.name)
        .accessibilityValue(participant.frame == nil ? "Camera off" : "Camera on")
    }
}

struct VoiceParticipantNameCapsule: View {
    let name: String
    let isLocal: Bool
    let isMuted: Bool
    let isDeafened: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isMuted {
                Image(systemName: "mic.slash.fill")
                    .accessibilityLabel("Muted")
            }
            if isDeafened {
                Image(systemName: "headphones.slash")
                    .accessibilityLabel("Deafened")
            }

            Text(isLocal ? "\(name) (You)" : name)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .glassEffect(.regular, in: Capsule())
    }
}

private struct ParticipantVolumeControl: View {
    let name: String
    let updateVolume: (Float) -> Void
    @State private var volume: Float

    init(name: String, initialVolume: Float, updateVolume: @escaping (Float) -> Void) {
        self.name = name
        self.updateVolume = updateVolume
        _volume = State(initialValue: initialVolume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 10) {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: $volume, in: 0 ... 2)
                    .frame(width: 180)
                Text("\(Int(volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(14)
        .onChange(of: volume) { _, value in updateVolume(value) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Volume for \(name)")
    }
}
