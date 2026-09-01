import AppKit
import SakuraCordModels
import SwiftUI

@MainActor
final class ChannelSidebarSelectionCommitter {
    private enum PendingSelection: Equatable {
        case none
        case value(ChannelID?)
    }

    private var pendingTask: Task<Void, Never>?
    private var pendingSelectionState = PendingSelection.none

    var pendingSelection: ChannelID? {
        guard case let .value(selection) = pendingSelectionState else {
            return nil
        }
        return selection
    }

    var hasPendingSelection: Bool {
        if case .value = pendingSelectionState {
            return true
        }
        return false
    }

    func presentedSelection(fallback: ChannelID?) -> ChannelID? {
        guard case let .value(selection) = pendingSelectionState else {
            return fallback
        }
        return selection
    }

    func schedule(
        _ selection: ChannelID?,
        currentSelection: @escaping @MainActor () -> ChannelID?,
        commit: @escaping @MainActor (ChannelID?) -> Void
    ) {
        pendingTask?.cancel()
        let selectionBeforeDeferral = currentSelection()
        let pendingSelection = PendingSelection.value(selection)
        pendingSelectionState = pendingSelection
        pendingTask = Task { @MainActor [weak self] in
            // Let NSOutlineView finish its selection transaction before the
            // model publishes the conversation-wide state change. Performing
            // both operations reentrantly makes AppKit lay out the complete
            // split view while its sidebar selection guard is still active.
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.pendingSelectionState == pendingSelection
            else { return }
            guard currentSelection() == selectionBeforeDeferral else {
                self.cancel()
                return
            }
            commit(selection)
        }
    }

    func selectedValueChanged(to selection: ChannelID?) {
        guard case let .value(pendingSelection) = pendingSelectionState else {
            return
        }
        if pendingSelection == selection {
            pendingTask = nil
            pendingSelectionState = .none
        } else {
            cancel()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingSelectionState = .none
    }

    deinit {
        pendingTask?.cancel()
    }
}

struct ChannelSidebarView: View {
    let voiceModel: AppModel
    let guild: Guild?
    let channels: [Channel]
    let channelGroups: [ChannelGroup]
    let unreadCategoryIDs: Set<ChannelID>
    @Binding var selection: ChannelID?
    let currentUser: User?
    let connectionState: ConnectionState
    let currentStatus: PresenceStatus
    let isAuthenticated: Bool
    let isOfflineTesting: Bool
    let activeVoiceChannelID: ChannelID?
    let showsChannelsAndRoles: Bool
    let openChannelsAndRoles: () -> Void
    let connectAccount: () -> Void
    let updateStatus: (PresenceStatus) async -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var selectionCommitter =
        ChannelSidebarSelectionCommitter()
    @State private var accountControlHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if guild == nil {
                DirectMessageInboxView(
                    model: voiceModel,
                    channels: channels,
                    membersByID: voiceModel.membersByID,
                    privateCallsByChannel: voiceModel.privateCallsByChannel.filter {
                        !$0.value.isUnavailable
                    },
                    animatesAvatars: true,
                    selection: directMessageSelection,
                    bottomContentInset: accountControlHeight
                )
            } else {
                GuildChannelList(
                    input: GuildChannelListInput(
                        modelIdentity: ObjectIdentifier(voiceModel),
                        channelGroups: channelGroups,
                        rulesChannelID: guild?.rulesChannelID,
                        activeVoiceChannelID: activeVoiceChannelID,
                        hiddenChannelIDs: hiddenChannelIDs,
                        checkingChannelIDs: checkingChannelIDs,
                        unreadCategoryIDs: unreadCategoryIDs,
                        selectedChannelID: selection,
                        bottomContentInset: accountControlHeight
                    ),
                    model: voiceModel,
                    selection: deferredGuildSelection
                )
                .equatable()
                .onChange(of: selection) { _, newSelection in
                    selectionCommitter.selectedValueChanged(
                        to: newSelection
                    )
                }
            }

            AccountControlView(
                voiceModel: voiceModel,
                user: currentUser,
                connectionState: connectionState,
                currentStatus: currentStatus,
                isAuthenticated: isAuthenticated,
                isOfflineTesting: isOfflineTesting,
                connectAccount: connectAccount,
                updateStatus: updateStatus
            )
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard height.isFinite, height >= 0 else { return }
                accountControlHeight = height
            }
            .zIndex(1)
        }
        .overlay {
            SidebarChromeSeparator(
                cornerRadius: ChatChromeMetrics.sidebarContentCornerRadius,
                strokeInset: separatorLineWidth / 2
            )
            .stroke(Color(nsColor: .separatorColor), lineWidth: separatorLineWidth)
            .allowsHitTesting(false)
        }
    }

    private var separatorLineWidth: CGFloat {
        1 / max(displayScale, 1)
    }

    private var deferredGuildSelection: Binding<ChannelID?> {
        Binding(
            // During the one-run-loop handoff, report the sidebar's accepted
            // value back to NSOutlineView instead of the still-old model
            // value. Otherwise AppKit sees the selection snap backward and
            // performs a second complete selection/layout transaction when
            // the model commit arrives.
            get: {
                selectionCommitter.presentedSelection(fallback: selection)
            },
            set: { newSelection in
                guard selection != newSelection else { return }
                if let newSelection {
                    AppPerformanceSignposts.beginConversationNavigation(
                        to: newSelection
                    )
                } else {
                    AppPerformanceSignposts.cancelConversationNavigation()
                }
                selectionCommitter.schedule(
                    newSelection,
                    currentSelection: { selection },
                    commit: { newSelection in
                        if let newSelection {
                            voiceModel.recordForwardDestinationVisit(newSelection)
                        }
                        selection = newSelection
                    }
                )
            }
        )
    }

    private var directMessageSelection: Binding<ChannelID?> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard selection != newSelection else { return }
                if let newSelection {
                    voiceModel.recordForwardDestinationVisit(newSelection)
                }
                selection = newSelection
            }
        )
    }

    private var hiddenChannelIDs: Set<ChannelID> {
        voiceModel.hiddenChannelIDs
    }

    private var checkingChannelIDs: Set<ChannelID> {
        voiceModel.checkingChannelIDs
    }

    private var displayedChannels: [Channel] {
        guard let guildID = guild?.id else { return channels }
        let hidden = voiceModel.personalizationHiddenChannelIDs(guildID: guildID)
        return channels.filter { !hidden.contains($0.id) }
    }

}

private struct ChannelsAndRolesSidebarRow: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 8, height: 8)
                Image(systemName: ChannelIconPresentation.channelsAndRolesSystemImage)
                    .frame(width: 16)
                Text("Channels & Roles")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                isSelected ? Color.primary : Color.primary.opacity(0.78)
            )
            .contentShape(.rect)
            .overlay {
                ChannelSidebarRowHighlightBridge(isSelected: isSelected)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Customize roles and visible channels")
    }
}

/// An explicit invalidation boundary around SwiftUI's native outline keeps
/// unrelated timeline/member publications from recursively diffing every
/// channel row. All list-level presentation inputs participate in equality;
/// observable row leaves continue to receive their own model updates.
nonisolated private struct GuildChannelListInput: Equatable, Sendable {
    let modelIdentity: ObjectIdentifier
    let channelGroups: [ChannelGroup]
    let rulesChannelID: ChannelID?
    let activeVoiceChannelID: ChannelID?
    let hiddenChannelIDs: Set<ChannelID>
    let checkingChannelIDs: Set<ChannelID>
    let unreadCategoryIDs: Set<ChannelID>
    let selectedChannelID: ChannelID?
    let bottomContentInset: CGFloat
}

private struct GuildChannelList: View, Equatable {
    let input: GuildChannelListInput
    let model: AppModel
    @Binding var selection: ChannelID?

    nonisolated static func == (
        lhs: GuildChannelList,
        rhs: GuildChannelList
    ) -> Bool {
        lhs.input == rhs.input
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(input.channelGroups) { group in
                ChannelGroupRows(
                    model: model,
                    group: group,
                    bottomContentInset:
                        group.id == input.channelGroups.last?.id
                            ? input.bottomContentInset
                            : 0,
                    rulesChannelID: input.rulesChannelID,
                    activeVoiceChannelID: input.activeVoiceChannelID,
                    hiddenChannelIDs: input.hiddenChannelIDs,
                    checkingChannelIDs: input.checkingChannelIDs,
                    isUnread: group.categoryID.map(
                        input.unreadCategoryIDs.contains
                    ) ?? false
                )
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollClipDisabled()
        .padding(.top, ChatChromeMetrics.channelListTopPadding)
        .clipped()
        .background {
            ScrollInputPerformanceProbeAttachment(surface: .channelList)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct SidebarBottomScrollSpacer: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: height)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

nonisolated struct ChannelGroup: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: ChannelID?
    let guildID: GuildID?
    let name: String?
    let position: Int
    var channels: [Channel]

    static func make(from channels: [Channel]) -> [ChannelGroup] {
        var result: [ChannelGroup] = []
        var indexByID: [String: Int] = [:]
        result.reserveCapacity(min(channels.count, 32))
        indexByID.reserveCapacity(min(channels.count, 32))
        for channel in channels {
            let groupID = channel.categoryID?.description ?? "uncategorized"
            if let index = indexByID[groupID] {
                result[index].channels.append(channel)
            } else {
                indexByID[groupID] = result.count
                result.append(ChannelGroup(
                    id: groupID,
                    categoryID: channel.categoryID,
                    guildID: channel.guildID,
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

nonisolated enum ChannelCategoryPresentation {
    static func initiallyExpanded(isCollapsedByDefault: Bool) -> Bool {
        !isCollapsedByDefault
    }
}

struct SidebarChromeSeparator: Shape {
    let cornerRadius: CGFloat
    let strokeInset: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: strokeInset, y: rect.maxY))
        path.addLine(to: CGPoint(x: strokeInset, y: radius + strokeInset))
        path.addQuadCurve(
            to: CGPoint(x: radius + strokeInset, y: strokeInset),
            control: CGPoint(x: strokeInset, y: strokeInset)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: strokeInset))
        return path
    }
}

private struct ChannelGroupRows: View {
    let model: AppModel
    let group: ChannelGroup
    let bottomContentInset: CGFloat
    let rulesChannelID: ChannelID?
    let activeVoiceChannelID: ChannelID?
    let hiddenChannelIDs: Set<ChannelID>
    let checkingChannelIDs: Set<ChannelID>
    let isUnread: Bool
    let voiceParticipantEntriesByChannel:
        [ChannelID: VoiceSidebarChannelEntry]
    @State private var isExpanded: Bool

    init(
        model: AppModel,
        group: ChannelGroup,
        bottomContentInset: CGFloat,
        rulesChannelID: ChannelID?,
        activeVoiceChannelID: ChannelID?,
        hiddenChannelIDs: Set<ChannelID>,
        checkingChannelIDs: Set<ChannelID>,
        isUnread: Bool
    ) {
        self.model = model
        self.group = group
        self.bottomContentInset = bottomContentInset
        self.rulesChannelID = rulesChannelID
        self.activeVoiceChannelID = activeVoiceChannelID
        self.hiddenChannelIDs = hiddenChannelIDs
        self.checkingChannelIDs = checkingChannelIDs
        self.isUnread = isUnread
        voiceParticipantEntriesByChannel = Dictionary(
            uniqueKeysWithValues: group.channels.lazy
                .filter { $0.kind == .voice }
                .map { channel in
                    (
                        channel.id,
                        model.voiceSidebarPresentation.entry(for: channel.id)
                    )
                }
        )
        let isCollapsed = group.categoryID.flatMap { categoryID in
            group.guildID.map {
                model.isCategoryCollapsed(guildID: $0, categoryID: categoryID)
            }
        } ?? false
        _isExpanded = State(
            initialValue: ChannelCategoryPresentation.initiallyExpanded(
                isCollapsedByDefault: isCollapsed
            )
        )
    }

    var body: some View {
        Section {
            if group.name == nil || isExpanded {
                ForEach(group.channels) { channel in
                    if channel.kind == .voice {
                        ChannelRow(
                            model: model,
                            channel: channel,
                            rulesChannelID: rulesChannelID,
                            isVoiceConnected: activeVoiceChannelID == channel.id,
                            isHidden: hiddenChannelIDs.contains(channel.id),
                            isChecking: checkingChannelIDs.contains(channel.id)
                        )
                        .tag(channel.id)
                        ForEach(
                            voiceParticipantEntriesByChannel[channel.id]?.participants
                                ?? []
                        ) { participant in
                            VoiceParticipantRow(participant: participant)
                        }
                    } else {
                        ChannelRow(
                            model: model,
                            channel: channel,
                            rulesChannelID: rulesChannelID,
                            isHidden: hiddenChannelIDs.contains(channel.id),
                            isChecking: checkingChannelIDs.contains(channel.id)
                        )
                        .tag(channel.id)
                    }
                }
            }

            if bottomContentInset > 0 {
                SidebarBottomScrollSpacer(height: bottomContentInset)
            }
        } header: {
            VStack(spacing: 0) {
                if let name = group.name,
                   let categoryID = group.categoryID,
                   let guildID = group.guildID
                {
                    Button {
                        let nextValue = !isExpanded
                        withAnimation(.snappy(duration: 0.18)) {
                            isExpanded = nextValue
                        }
                        model.setCategoryCollapsed(
                            !nextValue,
                            guildID: guildID,
                            categoryID: categoryID
                        )
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
                    .overlay {
                        ChannelContextMenuBridge(
                            subject: .category,
                            isSelected: false,
                            isUnread: isUnread,
                            isMutationPending:
                                model.isChannelNotificationMutationPending(
                                    categoryID
                                ),
                            directOverride: model.categoryNotificationOverride(
                                guildID: guildID,
                                categoryID: categoryID
                            ),
                            inheritedLevel:
                                model.inheritedCategoryNotificationLevel(
                                    guildID: guildID
                                ),
                            inheritanceSource: .server,
                            markRead: {
                                model.markCategoryRead(
                                    categoryID: categoryID,
                                    guildID: guildID
                                )
                            },
                            mute: { duration in
                                model.setCategoryMute(
                                    true,
                                    until: duration.endDate(),
                                    guildID: guildID,
                                    categoryID: categoryID
                                )
                            },
                            unmute: {
                                model.setCategoryMute(
                                    false,
                                    until: nil,
                                    guildID: guildID,
                                    categoryID: categoryID
                                )
                            },
                            setNotificationLevel: { level in
                                model.setCategoryNotificationLevel(
                                    level,
                                    guildID: guildID,
                                    categoryID: categoryID
                                )
                            },
                            copyChannelID: {
                                ChannelContextMenuValue.copy(
                                    categoryID.description
                                )
                            },
                            copyLink: {}
                        )
                    }
                }
            }
        }
        .onChange(of: isCollapsedInModel) { _, isCollapsed in
            guard isExpanded == isCollapsed else { return }
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded = !isCollapsed
            }
        }
    }

    private var isCollapsedInModel: Bool {
        guard let categoryID = group.categoryID,
              let guildID = group.guildID
        else { return false }
        return model.isCategoryCollapsed(
            guildID: guildID,
            categoryID: categoryID
        )
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
    let updateStatus: (PresenceStatus) async -> Void

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
                        savedAccounts: voiceModel.savedAccounts,
                        activeAccountID: voiceModel.activeAccountID,
                        manageAccounts: connectAccount,
                        switchAccount: { accountID in
                            await voiceModel.switchAccount(to: accountID)
                        },
                        updateStatus: updateStatus
                    )
                }
                .padding(.horizontal, 10)
                .frame(height: ChatChromeMetrics.controlHeight)
            }
            .glassEffect(
                .regular.interactive(),
                in: ConcentricRectangle(
                    corners: .concentric(
                        minimum: .fixed(
                            ChatChromeMetrics.composerMinimumCornerRadius
                        )
                    ),
                    isUniform: true
                )
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    private var displayName: String {
        if isOfflineTesting {
            return "Offline Testing"
        }
        return isAuthenticated
            ? (user?.displayName ?? "Discord Account")
            : "Connect Account"
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
    let savedAccounts: [SavedAccount]
    let activeAccountID: String?
    let manageAccounts: () -> Void
    let switchAccount: (String) async -> Bool
    let updateStatus: (PresenceStatus) async -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            Image(systemName: "gearshape.fill")
                .font(.body)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            NativeAccountMenuButton(
                isAuthenticated: isAuthenticated,
                isOfflineTesting: isOfflineTesting,
                currentStatus: currentStatus,
                savedAccounts: savedAccounts,
                activeAccountID: activeAccountID,
                manageAccounts: manageAccounts,
                switchAccount: switchAccount,
                updateStatus: updateStatus,
                openSettings: { openSettings() }
            )
        }
        .frame(width: 28, height: 28)
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
    let model: AppModel
    let channel: Channel
    var rulesChannelID: ChannelID?
    var isVoiceConnected = false
    var isHidden = false
    var isChecking = false

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.white)
                .frame(width: 4, height: 8)
                .opacity(showsUnread ? 1 : 0)
                .frame(width: 8)
            Image(systemName: systemImage)
                .fontWeight(
                    showsUnread && !isMuted
                        ? .medium
                        : .regular
                )
                .foregroundStyle(
                    isVoiceConnected ? Color.green
                        : channelIconForegroundStyle
                )
                .frame(width: 16)
            Text(channel.name)
                .fontWeight(
                    showsUnread && !isMuted
                        ? .medium
                        : .regular
                )
                .foregroundStyle(channelNameForegroundStyle)
                .lineLimit(1)
            Spacer()
            if hasActiveScreenShare {
                Image(systemName: "display")
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x23A55A))
                    .accessibilityLabel("Active screen share")
            }
            if isVoiceConnected {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if channel.kind == .forum, showsUnread {
                Text("\(channel.unreadCount) New")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x5865F2))
            }
            if !isChecking, channel.mentionCount > 0 {
                Text(channel.mentionCount, format: .number)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .overlay {
            ChannelContextMenuBridge(
                isSelected: model.selectedChannelID == channel.id,
                isUnread: channel.unreadCount > 0,
                isMutationPending:
                    model.isChannelNotificationMutationPending(channel.id),
                allowsMutations: !isChecking,
                directOverride: model.channelNotificationOverride(for: channel),
                inheritedLevel:
                    model.inheritedChannelNotificationLevel(for: channel),
                inheritanceSource:
                    channel.categoryID == nil ? .server : .category,
                markRead: {
                    model.markConversationRead(channelID: channel.id)
                },
                mute: { duration in
                    model.setChannelMute(
                        true,
                        until: duration.endDate(),
                        for: channel
                    )
                },
                unmute: {
                    model.setChannelMute(false, until: nil, for: channel)
                },
                setNotificationLevel: { level in
                    model.setChannelNotificationLevel(level, for: channel)
                },
                copyChannelID: {
                    ChannelContextMenuValue.copy(channel.id.description)
                },
                copyLink: {
                    ChannelContextMenuValue.copy(
                        ChannelContextMenuValue.link(
                            guildID: channel.guildID,
                            channelID: channel.id
                        )
                    )
                }
            )
        }
    }

    private var hasActiveScreenShare: Bool {
        guard channel.kind == .voice else { return false }
        return model.applicationStreams.keys.contains { $0.channelID == channel.id }
            || model.localApplicationStreamKey?.channelID == channel.id
            || model.voiceStates.values.contains {
                $0.channelID == channel.id && $0.isStreaming
            }
    }

    private var systemImage: String {
        if isChecking { return "lock.fill" }
        return ChannelIconPresentation.systemImage(
            for: channel,
            isHidden: isHidden,
            rulesChannelID: rulesChannelID
        )
    }

    private var isMuted: Bool {
        model.isChannelMuted(channel)
    }

    private var showsUnread: Bool {
        !isChecking && channel.unreadCount > 0
    }

    private var channelIconForegroundStyle: Color {
        if isMuted {
            return .primary.opacity(0.32)
        }
        return showsUnread
            ? .primary
            : .primary.opacity(0.66)
    }

    private var channelNameForegroundStyle: Color {
        if isMuted {
            return .primary.opacity(0.35)
        }
        return showsUnread
            ? .primary
            : .primary.opacity(0.78)
    }

    private var accessibilityValue: String {
        if isChecking { return "Checking access" }
        var values: [String] = []
        if channel.kind == .forum, channel.unreadCount > 0 {
            values.append(
                channel.unreadCount == 1
                    ? "1 new post"
                    : "\(channel.unreadCount) new posts"
            )
        } else if channel.unreadCount > 0 {
            values.append("Unread")
        }
        if channel.mentionCount > 0 {
            values.append(
                channel.mentionCount == 1
                    ? "1 unread mention"
                    : "\(channel.mentionCount) unread mentions"
            )
        }
        return values.joined(separator: ", ")
    }
}
