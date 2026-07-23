import SakuraCordModels
import SwiftUI

struct ChannelSidebarView: View {
    let voiceModel: AppModel
    let guild: Guild?
    let channels: [Channel]
    @Binding var selection: ChannelID?
    let currentUser: User?
    let connectionState: ConnectionState
    let currentStatus: PresenceStatus
    let isAuthenticated: Bool
    let isOfflineTesting: Bool
    let activeVoiceChannelID: ChannelID?
    let connectAccount: () -> Void
    let logout: () async -> Void
    let updateStatus: (PresenceStatus) async -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(ChannelGroup.make(from: channels)) { group in
                    ChannelGroupRows(
                        group: group,
                        rulesChannelID: guild?.rulesChannelID,
                        activeVoiceChannelID: activeVoiceChannelID,
                        hiddenChannelIDs: hiddenChannelIDs,
                        voiceParticipantsByChannel: voiceSidebarParticipantsByChannel
                    )
                }
            }
            .listStyle(.sidebar)

            AccountControlView(
                voiceModel: voiceModel,
                user: currentUser,
                connectionState: connectionState,
                currentStatus: currentStatus,
                isAuthenticated: isAuthenticated,
                isOfflineTesting: isOfflineTesting,
                connectAccount: connectAccount,
                logout: logout,
                updateStatus: updateStatus
            )
        }
        .navigationTitle("")
    }

    private var hiddenChannelIDs: Set<ChannelID> {
        Set(channels.lazy.filter { voiceModel.conversationAccess(for: $0) == .hidden }.map(\.id))
    }

    private var voiceSidebarParticipantsByChannel: [ChannelID: [VoiceSidebarParticipant]] {
        let currentUserID = currentUser?.id
        let voiceChannelIDs = Set(channels.filter { $0.kind == .voice }.map(\.id))
        var statesByChannel: [ChannelID: [UserID: VoiceParticipantState]] = [:]
        for state in voiceModel.voiceStates.values {
            guard let channelID = state.channelID, voiceChannelIDs.contains(channelID) else { continue }
            statesByChannel[channelID, default: [:]][state.userID] = state
        }

        if let channelID = activeVoiceChannelID,
           let currentUserID,
           statesByChannel[channelID]?[currentUserID] == nil
        {
            statesByChannel[channelID, default: [:]][currentUserID] = VoiceParticipantState(
                userID: currentUserID,
                channelID: channelID,
                guildID: voiceModel.activeVoiceChannel?.guildID,
                sessionID: "local",
                isSelfMuted: voiceModel.isVoiceMuted,
                isSelfDeafened: voiceModel.isVoiceDeafened,
                isVideoEnabled: voiceModel.isCameraEnabled
            )
        }

        return statesByChannel.mapValues { statesByUser in statesByUser.map { userID, state in
            let user = currentUser?.id == userID
                ? currentUser
                : voiceModel.membersByID[userID]?.user
            return VoiceSidebarParticipant(
                id: userID,
                name: user?.displayName ?? "User \(userID.rawValue)",
                avatarURL: user?.avatarURL,
                isCurrentUser: userID == currentUserID,
                isMuted: state.isMuted || state.isSelfMuted,
                isDeafened: state.isDeafened || state.isSelfDeafened,
                isStreaming: state.isStreaming,
                isVideoEnabled: state.isVideoEnabled
            )
        }.sorted {
            if $0.isCurrentUser != $1.isCurrentUser {
                return $0.isCurrentUser
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }}
    }
}

struct SidebarServerIdentity: View {
    let guild: Guild?

    var body: some View {
        HStack(spacing: 7) {
            if let guild {
                let displayName = guild.name.isEmpty ? "Unnamed Server" : guild.name
                GuildIconView(name: displayName, iconURL: guild.iconURL, size: 22, cornerRadius: 7)
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Image(systemName: "message.fill")
                    .frame(width: 22, height: 22)
                Text("Messages")
                    .lineLimit(1)
            }
        }
        .font(.callout.weight(.semibold))
        .frame(maxWidth: 150, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct VoiceSidebarParticipant: Identifiable {
    let id: UserID
    let name: String
    let avatarURL: URL?
    let isCurrentUser: Bool
    let isMuted: Bool
    let isDeafened: Bool
    let isStreaming: Bool
    let isVideoEnabled: Bool
}

struct ChannelGroup: Identifiable {
    let id: String
    let name: String?
    let position: Int
    var channels: [Channel]

    static func make(from channels: [Channel]) -> [ChannelGroup] {
        var result: [ChannelGroup] = []
        for channel in channels {
            let groupID = channel.categoryID?.description ?? "uncategorized"
            if let index = result.firstIndex(where: { $0.id == groupID }) {
                result[index].channels.append(channel)
            } else {
                result.append(ChannelGroup(
                    id: groupID,
                    name: channel.category,
                    position: channel.categoryPosition,
                    channels: [channel]
                ))
            }
        }
        for index in result.indices {
            result[index].channels.sort(by: channelOrder)
        }
        return result.sorted { lhs, rhs in
            if lhs.name == nil, rhs.name != nil {
                return true
            }
            if lhs.name != nil, rhs.name == nil {
                return false
            }
            return lhs.position < rhs.position
        }
    }

    private static func channelOrder(_ lhs: Channel, _ rhs: Channel) -> Bool {
        let lhsIsVoice = lhs.kind == .voice
        let rhsIsVoice = rhs.kind == .voice
        if lhsIsVoice != rhsIsVoice {
            return !lhsIsVoice
        }
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        return lhs.id < rhs.id
    }
}

private struct ChannelGroupRows: View {
    let group: ChannelGroup
    let rulesChannelID: ChannelID?
    let activeVoiceChannelID: ChannelID?
    let hiddenChannelIDs: Set<ChannelID>
    let voiceParticipantsByChannel: [ChannelID: [VoiceSidebarParticipant]]
    @SceneStorage private var isExpanded: Bool

    init(
        group: ChannelGroup,
        rulesChannelID: ChannelID?,
        activeVoiceChannelID: ChannelID?,
        hiddenChannelIDs: Set<ChannelID>,
        voiceParticipantsByChannel: [ChannelID: [VoiceSidebarParticipant]]
    ) {
        self.group = group
        self.rulesChannelID = rulesChannelID
        self.activeVoiceChannelID = activeVoiceChannelID
        self.hiddenChannelIDs = hiddenChannelIDs
        self.voiceParticipantsByChannel = voiceParticipantsByChannel
        _isExpanded = SceneStorage(wrappedValue: true, "dev.sakuracord.channel-category.\(group.id).expanded")
    }

    var body: some View {
        Section {
            if group.name == nil || isExpanded {
                ForEach(group.channels) { channel in
                    if channel.kind == .voice {
                        ChannelRow(
                            channel: channel,
                            rulesChannelID: rulesChannelID,
                            isVoiceConnected: activeVoiceChannelID == channel.id,
                            isHidden: hiddenChannelIDs.contains(channel.id)
                        )
                        .tag(channel.id)
                        ForEach(voiceParticipantsByChannel[channel.id] ?? []) { participant in
                            VoiceParticipantRow(participant: participant)
                        }
                    } else {
                        ChannelRow(
                            channel: channel,
                            rulesChannelID: rulesChannelID,
                            isHidden: hiddenChannelIDs.contains(channel.id)
                        )
                        .tag(channel.id)
                    }
                }
            }
        } header: {
            if let name = group.name {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 8)
                        Text(name)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse \(name)" : "Expand \(name)")
            }
        }
    }
}

private struct VoiceParticipantRow: View {
    let participant: VoiceSidebarParticipant

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(name: participant.name, url: participant.avatarURL, size: 24)
            Text(participant.name)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            if participant.isStreaming {
                Image(systemName: "display")
                    .foregroundStyle(Color(hex: 0x23A55A))
            }
            if participant.isVideoEnabled {
                Image(systemName: "video.fill")
                    .foregroundStyle(.secondary)
            }
            if participant.isMuted {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.secondary)
            }
            if participant.isDeafened {
                Image(systemName: "headphones.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .padding(.leading, 24)
        .padding(.vertical, 1)
        .accessibilityLabel(participant.name)
        .accessibilityValue(
            participant.isMuted && participant.isDeafened ? "Muted, Deafened"
                : participant.isMuted ? "Muted"
                : participant.isDeafened ? "Deafened"
                : "Connected"
        )
    }
}

private struct AccountControlView: View {
    let voiceModel: AppModel
    let user: User?
    let connectionState: ConnectionState
    let currentStatus: PresenceStatus
    let isAuthenticated: Bool
    let isOfflineTesting: Bool
    let connectAccount: () -> Void
    let logout: () async -> Void
    let updateStatus: (PresenceStatus) async -> Void
    @State private var confirmLogout = false

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                if voiceModel.activeVoiceChannel != nil {
                    VoiceSidebarStatus(model: voiceModel)
                    Divider().padding(.horizontal, 10)
                }

                HStack(spacing: 9) {
                    AccountAvatar(name: displayName, avatarURL: user?.avatarURL, status: currentStatus)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(accountSubtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    AccountMenu(
                        isAuthenticated: isAuthenticated,
                        isOfflineTesting: isOfflineTesting,
                        currentStatus: currentStatus,
                        connectAccount: connectAccount,
                        requestLogout: { confirmLogout = true },
                        updateStatus: updateStatus
                    )
                }
                .padding(.horizontal, 10)
                .frame(height: ChatChromeMetrics.controlHeight)
            }
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: ChatChromeMetrics.controlCornerRadius, style: .continuous)
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .confirmationDialog("Log out of Discord?", isPresented: $confirmLogout) {
            Button("Log Out", role: .destructive) { Task { await logout() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SakuraCord will remove this account's saved session from Keychain.")
        }
    }

    private var displayName: String {
        if isOfflineTesting {
            return "Offline Testing"
        }
        return isAuthenticated ? (user?.displayName ?? "Discord Account") : "Connect Account"
    }

    private var accountSubtitle: String {
        if isOfflineTesting {
            return "Mock data • networking disabled"
        }
        if isAuthenticated {
            return user.map { "@\($0.username)" } ?? connectionState.rawValue
        }
        return "Sign in to Discord"
    }
}

private struct AccountAvatar: View {
    let name: String
    let avatarURL: URL?
    let status: PresenceStatus

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AvatarView(name: name, url: avatarURL, size: 34)
            Circle()
                .fill(status.color)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.background, lineWidth: 2))
        }
    }
}

private struct AccountMenu: View {
    let isAuthenticated: Bool
    let isOfflineTesting: Bool
    let currentStatus: PresenceStatus
    let connectAccount: () -> Void
    let requestLogout: () -> Void
    let updateStatus: (PresenceStatus) async -> Void

    var body: some View {
        Menu {
            if isOfflineTesting {
                Text("Discord networking is disabled")
            } else if isAuthenticated {
                Menu("Set Status", systemImage: "circle.dotted") {
                    ForEach(PresenceStatus.allCases.filter { $0 != .offline }, id: \.self) { status in
                        Button {
                            Task { await updateStatus(status) }
                        } label: {
                            if status == currentStatus {
                                Label(status.label, systemImage: "checkmark")
                            } else {
                                Text(status.label)
                            }
                        }
                    }
                }
                Button("Switch Account…", systemImage: "person.2", action: connectAccount)
                Divider()
                Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: requestLogout)
            } else {
                Button("Connect Discord Account…", systemImage: "person.crop.circle.badge.plus", action: connectAccount)
            }
            Divider()
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Account and Settings")
    }
}

private extension PresenceStatus {
    var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .dnd: "Do Not Disturb"
        case .invisible: "Invisible"
        case .offline: "Offline"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .idle: .orange
        case .dnd: .red
        case .invisible, .offline: .gray
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    var rulesChannelID: ChannelID?
    var isVoiceConnected = false
    var isHidden = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(isVoiceConnected ? Color.green : Color.secondary)
                .frame(width: 16)
            Text(channel.name).lineLimit(1)
            Spacer()
            if isVoiceConnected {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if channel.unreadCount > 0 {
                Text(channel.unreadCount, format: .number)
                    .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.red, in: Capsule())
            }
        }
    }

    private var systemImage: String {
        ChannelIconPresentation.systemImage(
            for: channel,
            isHidden: isHidden,
            rulesChannelID: rulesChannelID
        )
    }
}
