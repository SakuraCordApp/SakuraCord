import MediaPipeline
import SakuraCordModels
import SwiftUI

struct VoiceVideoGrid: View {
    let model: AppModel
    var channel: Channel?
    var isCompact = false
    var ringingUserIDs: Set<UserID> = []

    private var participants: [VoiceTileParticipant] {
        guard let activeChannel = channel ?? model.activeVoiceChannel else { return [] }
        let currentUser = model.snapshot?.currentUser
        let currentUserID = currentUser.map { String($0.id.rawValue) }
        let usesLocalVoiceSession = Self.usesLocalVoiceSession(
            displayedChannelID: activeChannel.id,
            activeVoiceChannelID: model.activeVoiceChannel?.id
        )
        let localParticipants = usesLocalVoiceSession
            ? model.voiceParticipants : []
        let speakingByID = Dictionary(uniqueKeysWithValues: localParticipants.map { ($0.userID, $0.isSpeaking) })
        let volumeByID = Dictionary(uniqueKeysWithValues: localParticipants.map { ($0.userID, $0.volume) })
        let cameraByID = Dictionary(uniqueKeysWithValues: localParticipants.map { ($0.userID, $0.isCameraEnabled) })
        var knownUsers = Dictionary(
            uniqueKeysWithValues: activeChannel.recipients.map { ($0.id, $0) }
        )
        if let currentUser {
            knownUsers[currentUser.id] = currentUser
        }
        var values: [String: VoiceTileParticipant] = [:]
        var statesByUserID = Dictionary(
            uniqueKeysWithValues: model.voiceStates.values
                .filter { $0.channelID == activeChannel.id }
                .map { ($0.userID, $0) }
        )
        if activeChannel.kind == .directMessage || activeChannel.kind == .groupDirectMessage {
            for state in model.privateCall(in: activeChannel.id)?.voiceStates ?? [] {
                statesByUserID[state.userID] = state
            }
        }

        for state in statesByUserID.values {
            let userID = String(state.userID.rawValue)
            let user = knownUsers[state.userID] ?? model.membersByID[state.userID]?.user
            values[userID] = VoiceTileParticipant(
                id: userID,
                name: user?.displayName ?? "User \(userID)",
                avatarURL: user?.avatarURL,
                frame: usesLocalVoiceSession
                    && (state.isVideoEnabled || cameraByID[userID] == true)
                    ? model.voiceVideoFrames[userID] : nil,
                isLocal: userID == currentUserID,
                isMuted: state.isMuted || state.isSelfMuted,
                isDeafened: state.isDeafened || state.isSelfDeafened,
                isSpeaking: usesLocalVoiceSession
                    && (userID == currentUserID
                        ? model.isLocallySpeaking
                        : (speakingByID[userID] ?? false)),
                volume: volumeByID[userID] ?? 1,
                isRinging: ringingUserIDs.contains(state.userID)
            )
        }

        for participant in localParticipants where values[participant.userID] == nil {
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
                volume: participant.volume,
                isRinging: numericID.map(ringingUserIDs.contains) ?? false
            )
        }

        if usesLocalVoiceSession,
           let currentUser,
           let currentUserID,
           values[currentUserID] == nil
        {
            values[currentUserID] = VoiceTileParticipant(
                id: currentUserID,
                name: currentUser.displayName,
                avatarURL: currentUser.avatarURL,
                frame: model.isCameraEnabled ? model.voiceVideoFrames[currentUserID] : nil,
                isLocal: true,
                isMuted: model.isVoiceMuted,
                isDeafened: model.isVoiceDeafened,
                isSpeaking: model.isLocallySpeaking,
                volume: 1,
                isRinging: ringingUserIDs.contains(currentUser.id)
            )
        }

        for user in activeChannel.recipients
        where ringingUserIDs.contains(user.id)
            && values[String(user.id.rawValue)] == nil
        {
            values[String(user.id.rawValue)] = VoiceTileParticipant(
                id: String(user.id.rawValue),
                name: user.displayName,
                avatarURL: user.avatarURL,
                frame: nil,
                isLocal: false,
                isMuted: false,
                isDeafened: false,
                isSpeaking: false,
                volume: 1,
                isRinging: true
            )
        }

        return values.values.sorted {
            if $0.isLocal != $1.isLocal {
                return $0.isLocal
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func usesLocalVoiceSession(
        displayedChannelID: ChannelID,
        activeVoiceChannelID: ChannelID?
    ) -> Bool {
        displayedChannelID == activeVoiceChannelID
    }

    var body: some View {
        let participants = participants
        if isCompact {
            AdaptiveVoiceGrid(participants: participants) { participant, volume in
                Task {
                    await model.updateParticipantVolume(
                        volume,
                        userID: participant.id
                    )
                }
            }
        } else {
            ScrollableVoiceGrid(participants: participants) { participant, volume in
                Task {
                    await model.updateParticipantVolume(
                        volume,
                        userID: participant.id
                    )
                }
            }
        }
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
    let isRinging: Bool
}

struct VoiceGridLayout: Equatable {
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 8
    static let targetAspectRatio: CGFloat = 16 / 9

    let columns: Int
    let rows: Int
    let tileSize: CGSize
    let gridSize: CGSize

    static func fitted(in size: CGSize, participantCount: Int) -> VoiceGridLayout {
        guard participantCount > 0 else {
            return VoiceGridLayout(
                columns: 1,
                rows: 0,
                tileSize: .zero,
                gridSize: .zero
            )
        }

        let innerWidth = max(1, size.width - padding * 2)
        let innerHeight = max(1, size.height - padding * 2)
        var best = candidate(
            innerWidth: innerWidth,
            innerHeight: innerHeight,
            participantCount: participantCount,
            columns: 1
        )
        if participantCount > 1 {
            for columns in 2 ... participantCount {
                let option = candidate(
                    innerWidth: innerWidth,
                    innerHeight: innerHeight,
                    participantCount: participantCount,
                    columns: columns
                )
                // Fixed-aspect tiles are largest when their width is largest.
                if option.tileSize.width > best.tileSize.width {
                    best = option
                }
            }
        }
        return best
    }

    private static func candidate(
        innerWidth: CGFloat,
        innerHeight: CGFloat,
        participantCount: Int,
        columns: Int
    ) -> VoiceGridLayout {
        let rows = Int(ceil(Double(participantCount) / Double(columns)))
        let availableWidth = max(
            1,
            innerWidth - CGFloat(columns - 1) * spacing
        )
        let availableHeight = max(
            1,
            innerHeight - CGFloat(rows - 1) * spacing
        )
        let cellWidth = availableWidth / CGFloat(columns)
        let cellHeight = availableHeight / CGFloat(rows)
        let tileHeight = min(cellHeight, cellWidth / targetAspectRatio)
        let tileWidth = min(cellWidth, tileHeight * targetAspectRatio)

        return VoiceGridLayout(
            columns: columns,
            rows: rows,
            tileSize: CGSize(width: tileWidth, height: tileHeight),
            gridSize: CGSize(
                width: tileWidth * CGFloat(columns)
                    + spacing * CGFloat(columns - 1),
                height: tileHeight * CGFloat(rows)
                    + spacing * CGFloat(rows - 1)
            )
        )
    }
}

private struct AdaptiveVoiceGrid: View {
    let participants: [VoiceTileParticipant]
    let updateVolume: (VoiceTileParticipant, Float) -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = VoiceGridLayout.fitted(
                in: geometry.size,
                participantCount: participants.count
            )
            let verticalOrigin = (geometry.size.height - layout.gridSize.height) / 2

            ZStack(alignment: .topLeading) {
                ForEach(Array(participants.enumerated()), id: \.element.id) {
                    index,
                    participant in
                    let row = index / layout.columns
                    let column = index % layout.columns
                    let itemsInRow = min(
                        layout.columns,
                        participants.count - row * layout.columns
                    )
                    let rowWidth = layout.tileSize.width * CGFloat(itemsInRow)
                        + VoiceGridLayout.spacing * CGFloat(itemsInRow - 1)
                    let horizontalOrigin = (geometry.size.width - rowWidth) / 2

                    VoiceParticipantTile(
                        participant: participant,
                        isCompact: true,
                        tileSize: layout.tileSize
                    ) { volume in
                        updateVolume(participant, volume)
                    }
                    .frame(
                        width: layout.tileSize.width,
                        height: layout.tileSize.height
                    )
                    .position(
                        x: horizontalOrigin
                            + CGFloat(column)
                                * (layout.tileSize.width + VoiceGridLayout.spacing)
                            + layout.tileSize.width / 2,
                        y: verticalOrigin
                            + CGFloat(row)
                                * (layout.tileSize.height + VoiceGridLayout.spacing)
                            + layout.tileSize.height / 2
                    )
                    .animation(nil, value: layout.tileSize)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScrollableVoiceGrid: View {
    let participants: [VoiceTileParticipant]
    let updateVolume: (VoiceTileParticipant, Float) -> Void

    private var columns: [GridItem] {
        let columnCount = switch participants.count {
        case 0 ... 1: 1
        case 2 ... 4: 2
        default: 3
        }
        return Array(
            repeating: GridItem(
                .flexible(minimum: 260, maximum: 620),
                spacing: 12
            ),
            count: columnCount
        )
    }

    private var gridMaximumWidth: CGFloat {
        switch participants.count {
        case 0 ... 1: 900
        case 2 ... 4: 1180
        default: 1420
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                    ForEach(participants) { participant in
                        VoiceParticipantTile(
                            participant: participant,
                            isCompact: false,
                            tileSize: nil
                        ) { volume in
                            updateVolume(participant, volume)
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

private struct VoiceParticipantTile: View {
    let participant: VoiceTileParticipant
    let isCompact: Bool
    let tileSize: CGSize?
    let updateVolume: (Float) -> Void
    @State private var isHovering = false
    @State private var showVolume = false

    var body: some View {
        ZStack {
            if participant.isRinging {
                RingingParticipantAvatar(
                    name: participant.name,
                    avatarURL: participant.avatarURL,
                    size: avatarSize,
                    maximumPixelDimension: isCompact ? 144 : 176
                )
            } else {
                Color.primary.opacity(0.055)

                if let frame = participant.frame {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    AvatarView(
                        name: participant.name,
                        url: participant.avatarURL,
                        size: avatarSize,
                        maximumPixelDimension: isCompact ? 144 : 176
                    )
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !participant.isRinging {
                VoiceParticipantNameCapsule(
                    name: participant.name,
                    isLocal: participant.isLocal,
                    isMuted: participant.isMuted,
                    isDeafened: participant.isDeafened
                )
                .padding(isCompact ? 7 : 10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !participant.isLocal,
               !participant.isRinging,
               isHovering || showVolume
            {
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
                .padding(isCompact ? 7 : 10)
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
        .clipShape(
            ConcentricRectangle(cornerRadius: isCompact ? 12 : 16, style: .continuous)
        )
        .overlay {
            if !participant.isRinging {
                ConcentricRectangle(
                    cornerRadius: isCompact ? 12 : 16,
                    style: .continuous
                )
                .stroke(
                    participant.isSpeaking
                        ? Color(hex: 0x23A55A) : Color.primary.opacity(0.08),
                    lineWidth: participant.isSpeaking ? 3 : 1
                )
            }
        }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.14)) { isHovering = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(participant.isLocal ? "\(participant.name), you" : participant.name)
        .accessibilityValue(accessibilityValue)
    }

    private var avatarSize: CGFloat {
        guard let tileSize else { return isCompact ? 54 : 88 }
        return min(72, max(30, tileSize.height * 0.46))
    }

    private var accessibilityValue: String {
        let camera = participant.frame == nil ? "Camera off" : "Camera on"
        return participant.isRinging ? "Ringing, \(camera)" : camera
    }
}

private struct RingingParticipantAvatar: View {
    let name: String
    let avatarURL: URL?
    let size: CGFloat
    let maximumPixelDimension: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: 0x23A55A), lineWidth: max(2, size * 0.035))
                .frame(width: size * 1.18, height: size * 1.18)
                .scaleEffect(isPulsing ? 1.12 : 0.92)
                .opacity(isPulsing ? 0.12 : 0.68)

            AvatarView(
                name: name,
                url: avatarURL,
                size: size,
                maximumPixelDimension: maximumPixelDimension
            )
            .scaleEffect(isPulsing ? 1.04 : 0.97)
        }
        .frame(width: size * 1.36, height: size * 1.36)
        .shadow(
            color: Color(hex: 0x23A55A).opacity(isPulsing ? 0.34 : 0.12),
            radius: isPulsing ? 9 : 3
        )
        .onAppear {
            updateAnimation(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, value in
            updateAnimation(reduceMotion: value)
        }
        .accessibilityHidden(true)
    }

    private func updateAnimation(reduceMotion: Bool) {
        if reduceMotion {
            isPulsing = false
        } else {
            isPulsing = false
            withAnimation(
                .easeInOut(duration: 0.82)
                    .repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
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
