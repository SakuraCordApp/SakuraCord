import MediaPipeline
import SakuraCordModels
import SwiftUI

private enum VoiceCardID: Hashable {
    case participant(String)
    case stream(ApplicationStreamKey)
}

private struct VoiceCard: Identifiable {
    enum Kind {
        case participant(VoiceTileParticipant)
        case stream(
            owner: VoiceTileParticipant,
            key: ApplicationStreamKey,
            state: ApplicationStreamPlaybackState,
            isPaused: Bool
        )
    }

    let id: VoiceCardID
    let kind: Kind
}

private struct VoiceStreamDemand: Equatable {
    var isEnabled: Bool
    var pixelCount: Int?
}

private struct VoiceCardMetrics {
    let scale: CGFloat

    init(size: CGSize, isCompactFallback: Bool) {
        guard size.width > 0, size.height > 0 else {
            scale = isCompactFallback ? 0.62 : 1
            return
        }
        scale = min(size.width / 640, size.height / 360)
    }

    func value(_ value: CGFloat) -> CGFloat { value * scale }

    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: value(size), weight: weight)
    }
}

struct VoiceVideoGrid: View {
    let model: AppModel
    var channel: Channel?
    var isCompact = false
    var ringingUserIDs: Set<UserID> = []
    @State private var focusedCardID: VoiceCardID?
    @Namespace private var cardNamespace

    private var participants: [VoiceTileParticipant] {
        guard let activeChannel = channel ?? model.activeVoiceChannel else { return [] }
        let currentUser = model.snapshot?.currentUser
        let currentUserID = currentUser.map { String($0.id.rawValue) }
        let usesLocalVoiceSession = Self.usesLocalVoiceSession(
            displayedChannelID: activeChannel.id,
            activeVoiceChannelID: model.activeVoiceChannel?.id
        )
        let localParticipants = usesLocalVoiceSession ? model.voiceParticipants : []
        let speakingByID = Dictionary(
            uniqueKeysWithValues: localParticipants.map { ($0.userID, $0.isSpeaking) }
        )
        let volumeByID = Dictionary(
            uniqueKeysWithValues: localParticipants.map { ($0.userID, $0.volume) }
        )
        let cameraByID = Dictionary(
            uniqueKeysWithValues: localParticipants.map { ($0.userID, $0.isCameraEnabled) }
        )
        var knownUsers = Dictionary(
            uniqueKeysWithValues: activeChannel.recipients.map { ($0.id, $0) }
        )
        if let currentUser { knownUsers[currentUser.id] = currentUser }
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
                        ? model.isLocallySpeaking : (speakingByID[userID] ?? false)),
                isStreaming: state.isStreaming,
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
                frame: participant.isCameraEnabled
                    ? model.voiceVideoFrames[participant.userID] : nil,
                isLocal: participant.userID == currentUserID,
                isMuted: false,
                isDeafened: false,
                isSpeaking: participant.userID == currentUserID
                    ? model.isLocallySpeaking : participant.isSpeaking,
                isStreaming: numericID.flatMap { model.voiceStates[$0] }?.isStreaming ?? false,
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
                isStreaming: model.localApplicationStreamKey != nil,
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
                isStreaming: false,
                volume: 1,
                isRinging: true
            )
        }

        return values.values.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var cards: [VoiceCard] {
        guard let activeChannel = channel ?? model.activeVoiceChannel else { return [] }
        let participants = participants
        let participantByID = Dictionary(
            uniqueKeysWithValues: participants.map { ($0.id, $0) }
        )
        let participantCards = participants.map {
            VoiceCard(id: .participant($0.id), kind: .participant($0))
        }
        let streamKeys = model.applicationStreamKeys(in: activeChannel)
        let streams = streamKeys.compactMap { key -> VoiceCard? in
            let ownerID = String(key.ownerID.rawValue)
            guard let owner = participantByID[ownerID] else { return nil }
            let state = model.applicationStreamStates[key]
                ?? (key == model.localApplicationStreamKey ? .broadcasting : .available)
            return VoiceCard(
                id: .stream(key),
                kind: .stream(
                    owner: owner,
                    key: key,
                    state: state,
                    isPaused: key == model.localApplicationStreamKey
                        ? model.isLocalScreenSharePreviewPaused
                        : (model.applicationStreams[key]?.isPaused ?? false)
                )
            )
        }
        .sorted { lhs, rhs in
            guard case .stream(_, let lhsKey, _, _) = lhs.kind,
                  case .stream(_, let rhsKey, _, _) = rhs.kind
            else { return false }
            return lhsKey.rawValue < rhsKey.rawValue
        }
        return participantCards + streams
    }

    static func usesLocalVoiceSession(
        displayedChannelID: ChannelID,
        activeVoiceChannelID: ChannelID?
    ) -> Bool {
        displayedChannelID == activeVoiceChannelID
    }

    var body: some View {
        let cards = cards
        Group {
            if let focusedCardID,
               let focused = cards.first(where: { $0.id == focusedCardID })
            {
                focusedLayout(focused: focused, cards: cards)
            } else {
                AdaptiveVoiceGrid(cards: cards, cardNamespace: cardNamespace) { card in
                    cardView(card, isCompact: isCompact, isDemanded: true)
                        .onTapGesture { toggleFocus(card.id) }
                }
            }
        }
        .animation(.snappy(duration: 0.32), value: focusedCardID)
        .onChange(of: cards.map(\.id)) { _, ids in
            if let focusedCardID, !ids.contains(focusedCardID) {
                self.focusedCardID = nil
            }
        }
        .onDisappear {
            for (key, state) in model.applicationStreamStates
            where state == .connecting || state == .watching || state == .reconnecting
            {
                Task { await model.setApplicationStreamDemand(false, key: key) }
            }
        }
    }

    private func focusedLayout(focused: VoiceCard, cards: [VoiceCard]) -> some View {
        let secondary = cards.filter { $0.id != focused.id }
        return ZStack {
            cardView(focused, isCompact: false, isDemanded: true)
                .matchedGeometryEffect(id: focused.id, in: cardNamespace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { toggleFocus(focused.id) }

            ForEach(secondary) { card in
                if case .stream(_, let key, _, _) = card.kind {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .task(id: key) {
                            await model.setApplicationStreamDemand(false, key: key)
                        }
                }
            }
        }
        .padding(VoiceGridLayout.padding)
    }

    @ViewBuilder private func cardView(
        _ card: VoiceCard,
        isCompact: Bool,
        isDemanded: Bool
    ) -> some View {
        switch card.kind {
        case .participant(let participant):
            VoiceParticipantTile(
                participant: participant,
                isCompact: isCompact,
                tileSize: nil,
                mirrorsLocalPreview: model.voiceVideoPreferences.mirrorsLocalPreview
            ) { volume in
                Task { await model.updateParticipantVolume(volume, userID: participant.id) }
            }
        case .stream(let owner, let key, let state, let isPaused):
            VoiceStreamTile(
                owner: owner,
                key: key,
                state: state,
                isPaused: isPaused,
                isCompact: isCompact,
                model: model,
                isDemanded: isDemanded
            )
        }
    }

    private func toggleFocus(_ id: VoiceCardID) {
        focusedCardID = focusedCardID == id ? nil : id
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
    let isStreaming: Bool
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
            return VoiceGridLayout(columns: 1, rows: 0, tileSize: .zero, gridSize: .zero)
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
                if option.tileSize.width > best.tileSize.width { best = option }
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
        let availableWidth = max(1, innerWidth - CGFloat(columns - 1) * spacing)
        let availableHeight = max(1, innerHeight - CGFloat(rows - 1) * spacing)
        let cellWidth = availableWidth / CGFloat(columns)
        let cellHeight = availableHeight / CGFloat(rows)
        let tileHeight = min(cellHeight, cellWidth / targetAspectRatio)
        let tileWidth = min(cellWidth, tileHeight * targetAspectRatio)
        return VoiceGridLayout(
            columns: columns,
            rows: rows,
            tileSize: CGSize(width: tileWidth, height: tileHeight),
            gridSize: CGSize(
                width: tileWidth * CGFloat(columns) + spacing * CGFloat(columns - 1),
                height: tileHeight * CGFloat(rows) + spacing * CGFloat(rows - 1)
            )
        )
    }

    func horizontalOrigin(in containerWidth: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return containerWidth / 2 }
        let visibleItems = min(columns, itemCount)
        let rowWidth = tileSize.width * CGFloat(visibleItems)
            + Self.spacing * CGFloat(visibleItems - 1)
        return (containerWidth - rowWidth) / 2
    }
}

private struct AdaptiveVoiceGrid<CardContent: View>: View {
    let cards: [VoiceCard]
    let cardNamespace: Namespace.ID
    @ViewBuilder let cardContent: (VoiceCard) -> CardContent

    var body: some View {
        GeometryReader { geometry in
            let layout = VoiceGridLayout.fitted(
                in: geometry.size,
                participantCount: cards.count
            )
            let verticalOrigin = (geometry.size.height - layout.gridSize.height) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    let row = index / layout.columns
                    let column = index % layout.columns
                    let itemsInRow = min(layout.columns, cards.count - row * layout.columns)
                    let horizontalOrigin = layout.horizontalOrigin(
                        in: geometry.size.width,
                        itemCount: itemsInRow
                    )
                    cardContent(card)
                        .matchedGeometryEffect(id: card.id, in: cardNamespace)
                        .frame(width: layout.tileSize.width, height: layout.tileSize.height)
                        .position(
                            x: horizontalOrigin
                                + CGFloat(column) * (layout.tileSize.width + VoiceGridLayout.spacing)
                                + layout.tileSize.width / 2,
                            y: verticalOrigin
                                + CGFloat(row) * (layout.tileSize.height + VoiceGridLayout.spacing)
                                + layout.tileSize.height / 2
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VoiceStreamTile: View {
    let owner: VoiceTileParticipant
    let key: ApplicationStreamKey
    let state: ApplicationStreamPlaybackState
    let isPaused: Bool
    let isCompact: Bool
    let model: AppModel
    let isDemanded: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false
    @State private var renderedSize = CGSize.zero

    private var frame: VoiceVideoFrame? {
        key == model.localApplicationStreamKey
            ? model.screenSharePreviewFrame : model.applicationStreamFrames[key]
    }

    private var metrics: VoiceCardMetrics {
        VoiceCardMetrics(size: renderedSize, isCompactFallback: isCompact)
    }

    var body: some View {
        ZStack {
            if usesVideoSurface {
                Color.black.opacity(0.86)
            } else {
                Color.primary.opacity(0.055)
            }
            if let frame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if showsCenteredWatchAction {
                VStack(spacing: metrics.value(16)) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "tv")
                            .font(metrics.font(52, weight: .light))
                            .foregroundStyle(.secondary)
                        AvatarView(
                            name: owner.name,
                            url: owner.avatarURL,
                            size: metrics.value(30),
                            maximumPixelDimension: Int(metrics.value(72).rounded(.up))
                        )
                        .overlay {
                            Circle().stroke(
                                Color(nsColor: .windowBackgroundColor),
                                lineWidth: metrics.value(2)
                            )
                        }
                        .offset(x: metrics.value(7), y: metrics.value(6))
                    }
                    .padding(.bottom, metrics.value(4))
                    Text("\(owner.name)'s Screen")
                        .font(metrics.font(14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if case .failed(let message) = state {
                        Text(message)
                            .font(metrics.font(12))
                            .foregroundStyle(Color(hex: 0xF23F43))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, metrics.value(16))
                    }
                    streamAction(isCentered: true)
                }
            } else {
                VStack(spacing: metrics.value(13)) {
                    AvatarView(
                        name: owner.name,
                        url: owner.avatarURL,
                        size: metrics.value(76),
                        maximumPixelDimension: Int(metrics.value(176).rounded(.up))
                    )
                    if state == .connecting || state == .reconnecting {
                        ProgressView().scaleEffect(metrics.scale)
                    } else {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(metrics.font(22))
                            .foregroundStyle(.secondary)
                    }
                    if case .failed(let message) = state {
                        Text(message)
                            .font(metrics.font(12))
                            .foregroundStyle(Color(hex: 0xF23F43))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, metrics.value(16))
                    }
                }
            }

            if isPaused, !showsCenteredWatchAction {
                Label("Screen share paused", systemImage: "pause.fill")
                    .font(metrics.font(14, weight: .semibold))
                    .padding(.horizontal, metrics.value(14))
                    .frame(height: metrics.value(38))
                    .glassEffect(.regular, in: Capsule())
            }
        }
        .overlay(alignment: .bottomLeading) {
            Label("\(owner.name)'s Screen", systemImage: "display")
                .font(metrics.font(12, weight: .semibold))
                .padding(.horizontal, metrics.value(10))
                .frame(height: metrics.value(28))
                .glassEffect(.regular, in: Capsule())
                .padding(metrics.value(10))
        }
        .overlay(alignment: .topTrailing) {
            if key == model.localApplicationStreamKey {
                liveBadge
                    .padding(metrics.value(10))
            } else if !showsCenteredWatchAction, isHovering || frame == nil {
                streamAction(isCentered: false)
                    .padding(metrics.value(10))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(ConcentricRectangle(cornerRadius: metrics.value(16), style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: metrics.value(16), style: .continuous)
                .stroke(
                    isActiveStreamSurface
                        ? SakuraCordAccentColor.color.opacity(0.7)
                        : Color.primary.opacity(0.1),
                    lineWidth: metrics.value(isActiveStreamSurface ? 2 : 1)
                )
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.14)) { isHovering = hovering }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            renderedSize = size
        }
        .task(id: demand) {
            await model.setApplicationStreamDemand(
                demand.isEnabled,
                key: key,
                pixelCount: demand.pixelCount
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(owner.name)'s screen share")
    }

    private var demand: VoiceStreamDemand {
        guard isDemanded,
              state == .connecting || state == .watching || state == .reconnecting
        else {
            return VoiceStreamDemand(isEnabled: false, pixelCount: nil)
        }
        let width = max(1, Int((renderedSize.width * displayScale).rounded(.up)))
        let height = max(1, Int((renderedSize.height * displayScale).rounded(.up)))
        let pixelCount = width.multipliedReportingOverflow(by: height)
        return VoiceStreamDemand(
            isEnabled: true,
            pixelCount: pixelCount.overflow ? .max : pixelCount.partialValue
        )
    }

    private var usesVideoSurface: Bool {
        frame != nil || state == .watching || state == .broadcasting || state == .reconnecting
    }

    private var isActiveStreamSurface: Bool {
        state == .watching || state == .broadcasting
    }

    private var showsCenteredWatchAction: Bool {
        key != model.localApplicationStreamKey
            && state != .watching
            && state != .connecting
            && state != .reconnecting
    }

    @ViewBuilder private func streamAction(isCentered: Bool) -> some View {
        if state == .watching || state == .reconnecting {
            Button {
                Task { await model.stopWatchingApplicationStream(key) }
            } label: {
                Label("Stop Watching", systemImage: "rectangle.slash")
                    .font(metrics.font(12, weight: .semibold))
                    .frame(minWidth: metrics.value(132), minHeight: metrics.value(34))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Button {
                Task { await model.watchApplicationStream(key) }
            } label: {
                Label(
                    state.isFailed ? "Retry" : "Watch",
                    systemImage: "rectangle.on.rectangle.angled"
                )
                    .font(metrics.font(12, weight: .semibold))
                    .frame(
                        minWidth: metrics.value(isCentered ? 132 : 88),
                        minHeight: metrics.value(isCentered ? 42 : 34)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .glassEffect(
                .regular.tint(SakuraCordAccentColor.color).interactive(),
                in: Capsule()
            )
            .disabled(state == .connecting)
        }
    }

    private var liveBadge: some View {
        Label("Live", systemImage: "dot.radiowaves.left.and.right")
            .font(metrics.font(12, weight: .semibold))
            .padding(.horizontal, metrics.value(12))
            .frame(height: metrics.value(32))
            .glassEffect(.regular.tint(Color.red.opacity(0.2)), in: Capsule())
    }
}

private extension ApplicationStreamPlaybackState {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

private struct VoiceParticipantTile: View {
    let participant: VoiceTileParticipant
    let isCompact: Bool
    let tileSize: CGSize?
    let mirrorsLocalPreview: Bool
    let updateVolume: (Float) -> Void
    @State private var isHovering = false
    @State private var showVolume = false
    @State private var renderedSize = CGSize.zero

    private var metrics: VoiceCardMetrics {
        VoiceCardMetrics(size: renderedSize, isCompactFallback: isCompact)
    }

    var body: some View {
        ZStack {
            if participant.isRinging {
                RingingParticipantAvatar(
                    name: participant.name,
                    avatarURL: participant.avatarURL,
                    size: avatarSize,
                    maximumPixelDimension: Int(metrics.value(176).rounded(.up))
                )
            } else {
                Color.primary.opacity(0.055)
                if let frame = participant.frame {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(
                            x: participant.isLocal && mirrorsLocalPreview ? -1 : 1,
                            y: 1
                        )
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
                    isDeafened: participant.isDeafened,
                    scale: metrics.scale
                )
                .padding(metrics.value(10))
            }
        }
        .overlay(alignment: .topLeading) {
            if participant.isStreaming {
                Image(systemName: "display")
                    .font(metrics.font(12, weight: .semibold))
                    .frame(width: metrics.value(30), height: metrics.value(30))
                    .glassEffect(.regular, in: Circle())
                    .padding(metrics.value(10))
                    .accessibilityLabel("Sharing screen")
            }
        }
        .overlay(alignment: .topTrailing) {
            if !participant.isLocal,
               !participant.isRinging,
               isHovering || showVolume
            {
                Button { showVolume.toggle() } label: {
                    Image(systemName: participant.volume == 0
                        ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(metrics.font(14, weight: .semibold))
                        .frame(width: metrics.value(34), height: metrics.value(34))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .help("User Volume")
                .padding(metrics.value(10))
                .popover(isPresented: $showVolume, arrowEdge: .top) {
                    ParticipantVolumeControl(
                        name: participant.name,
                        initialVolume: participant.volume,
                        updateVolume: updateVolume
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(ConcentricRectangle(cornerRadius: metrics.value(16), style: .continuous))
        .overlay {
            if !participant.isRinging {
                ConcentricRectangle(cornerRadius: metrics.value(16), style: .continuous)
                    .stroke(
                        participant.isSpeaking
                            ? Color(hex: 0x23A55A) : Color.primary.opacity(0.08),
                        lineWidth: metrics.value(participant.isSpeaking ? 3 : 1)
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.14)) { isHovering = hovering }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            renderedSize = size
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(participant.isLocal ? "\(participant.name), you" : participant.name)
        .accessibilityValue(accessibilityValue)
    }

    private var avatarSize: CGFloat {
        metrics.value(88)
    }

    private var accessibilityValue: String {
        let camera = participant.frame == nil ? "Camera off" : "Camera on"
        let stream = participant.isStreaming ? ", sharing screen" : ""
        return participant.isRinging ? "Ringing, \(camera)\(stream)" : "\(camera)\(stream)"
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
        .onAppear { updateAnimation(reduceMotion: reduceMotion) }
        .onChange(of: reduceMotion) { _, value in updateAnimation(reduceMotion: value) }
        .accessibilityHidden(true)
    }

    private func updateAnimation(reduceMotion: Bool) {
        if reduceMotion {
            isPulsing = false
        } else {
            isPulsing = false
            withAnimation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true)) {
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
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 7 * scale) {
            if isMuted {
                Image(systemName: "mic.slash.fill").accessibilityLabel("Muted")
            }
            if isDeafened {
                Image(systemName: "headphones.slash").accessibilityLabel("Deafened")
            }
            Text(isLocal ? "\(name) (You)" : name).lineLimit(1)
        }
        .font(.system(size: 12 * scale, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10 * scale)
        .frame(height: 28 * scale)
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
            Text(name).font(.headline).lineLimit(1)
            HStack(spacing: 10) {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: $volume, in: 0 ... 2)
                    .tint(SakuraCordAccentColor.color)
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
