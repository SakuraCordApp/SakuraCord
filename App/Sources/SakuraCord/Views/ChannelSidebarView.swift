import AppKit
import SakuraCordModels
import SwiftUI

nonisolated enum ChannelSidebarLayoutMetrics {
    static var minimumRowHeight: CGFloat { InterfaceScale.metric(24) }
    static var iconWidth: CGFloat { InterfaceScale.metric(16) }
}

nonisolated enum SidebarAccountControlMetrics {
    static var capsuleHeight: CGFloat { ChatChromeMetrics.controlHeight }
    static var cornerRadius: CGFloat { capsuleHeight / 2 }
    static var contentInset: CGFloat { InterfaceScale.metric(8) }
    static var avatarSize: CGFloat { InterfaceScale.metric(32) }
    static var settingsIconSize: CGFloat { InterfaceScale.metric(14) }
    static var settingsDiameter: CGFloat { InterfaceScale.metric(30) }
    static var settingsInset: CGFloat { (capsuleHeight - settingsDiameter) / 2 }
    static var surfaceSpacing: CGFloat { InterfaceScale.metric(6) }

    static func bottomInset(for appearance: ComposerBarAppearance) -> CGFloat {
        let composerHeight = appearance == .defaultStyle
            ? ChatChromeMetrics.composerControlHeight
            : ChatChromeMetrics.controlHeight
        return ChatChromeMetrics.composerWindowInset - (capsuleHeight - composerHeight) / 2
    }

    static func settingsCornerRadius(for appearance: ComposerBarAppearance) -> CGFloat {
        appearance == .defaultStyle ? settingsDiameter / 2 : 9
    }

    static func shape(for appearance: ComposerBarAppearance) -> RoundedRectangle {
        RoundedRectangle(
            cornerRadius: appearance == .defaultStyle
                ? cornerRadius
                : ChatChromeMetrics.composerMinimumCornerRadius,
            style: .continuous
        )
    }
}

@MainActor
final class ChannelSidebarSelectionCommitter<Selection: Equatable> {
    private enum PendingSelection: Equatable {
        case none
        case value(Selection?)
    }

    private var pendingTask: Task<Void, Never>?
    private var pendingSelectionState = PendingSelection.none

    var pendingSelection: Selection? {
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

    func presentedSelection(fallback: Selection?) -> Selection? {
        guard case let .value(selection) = pendingSelectionState else {
            return fallback
        }
        return selection
    }

    func schedule(
        _ selection: Selection?,
        currentSelection: @escaping @MainActor () -> Selection?,
        commit: @escaping @MainActor (Selection?) -> Void
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

    func selectedValueChanged(to selection: Selection?) {
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
    let connectAccount: () -> Void
    let updateStatus: (PresenceStatus) async -> Void
    @Environment(\.displayScale) private var displayScale
    @Environment(\.sakuraCordWindowIsFullScreen) private var isFullScreen
    @State private var selectionCommitter =
        ChannelSidebarSelectionCommitter<GuildSidebarSelection>()
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
                // Re-evaluate when a timed-relevant thread expires. An explicit
                // schedule reports its next entry as `context.date`, so read the clock.
                TimelineView(.explicit(threadRelevanceDeadlines)) { _ in
                    GuildChannelList(
                        input: GuildChannelListInput(
                            modelIdentity: ObjectIdentifier(voiceModel),
                            guildID: guild?.id,
                            customizationTitle: voiceModel.customizationTitle(in: guild?.id),
                            hasCustomization: guild.map { voiceModel.hasChannelsAndRoles(in: $0.id) } ?? false,
                            hasGuide: guild.map { voiceModel.hasGuildGuide(in: $0.id) } ?? false,
                            page: voiceModel.guildWorkspacePage,
                            channelGroups: voiceModel.selectedChannelGroups(channelGroups, guildID: guild?.id),
                            rulesChannelID: guild?.rulesChannelID,
                            activeVoiceChannelID: activeVoiceChannelID,
                            hiddenChannelIDs: hiddenChannelIDs,
                            checkingChannelIDs: checkingChannelIDs,
                            unreadCategoryIDs: unreadCategoryIDs,
                            selectedChannelID: selection,
                            threadsByParentID: threadLayout(at: .now).threadsByParentID,
                            bottomContentInset: accountControlHeight
                        ),
                        model: voiceModel,
                        selection: deferredGuildSelection
                    )
                    .equatable()
                }
                .onChange(of: guildSelection) { _, newSelection in
                    selectionCommitter.selectedValueChanged(
                        to: newSelection
                    )
                }
                .onChange(of: guild?.id) { _, _ in selectionCommitter.cancel() }
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
        .font(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
        .environment(
            \.defaultMinListRowHeight,
            ChannelSidebarLayoutMetrics.minimumRowHeight
        )
        .overlay {
            SidebarChromeSeparator(
                cornerRadius: ChatChromeMetrics.sidebarContentCornerRadius,
                strokeInset: separatorLineWidth / 2,
                showsTopEdge: !isFullScreen
            )
            .stroke(Color(nsColor: .separatorColor), lineWidth: separatorLineWidth)
            .ignoresSafeArea(.container, edges: isFullScreen ? .top : [])
            .allowsHitTesting(false)
        }
    }

    private var separatorLineWidth: CGFloat {
        1 / max(displayScale, 1)
    }

    private var guildSelection: GuildSidebarSelection? {
        if let page = voiceModel.guildWorkspacePage { return .page(page) }
        if voiceModel.isThreadFullWidth, let thread = voiceModel.openThread, thread.parentID == selection {
            return .thread(thread.id)
        }
        return selection.map(GuildSidebarSelection.channel)
    }

    private func threadLayout(at date: Date) -> SidebarThreadPolicy.Layout {
        voiceModel.sidebarThreadLayout(
            guildID: guild?.id,
            channelGroups: channelGroups,
            now: date
        )
    }

    private var threadRelevanceDeadlines: [Date] {
        threadLayout(at: .now).relevanceDeadlines
    }

    private var deferredGuildSelection: Binding<GuildSidebarSelection?> {
        Binding(
            // Keep every destination on the same deferred NSOutlineView handoff.
            // Finish the native selection transaction before changing the
            // conversation and toolbar structure.
            get: { selectionCommitter.presentedSelection(fallback: guildSelection) },
            set: { newSelection in
                guard guildSelection != newSelection else { return }
                if case let .channel(channelID) = newSelection {
                    AppPerformanceSignposts.beginConversationNavigation(to: channelID)
                } else {
                    AppPerformanceSignposts.cancelConversationNavigation()
                }
                let guildID = guild?.id
                selectionCommitter.schedule(
                    newSelection,
                    currentSelection: { guildSelection },
                    commit: { newSelection in
                        guard guild?.id == guildID else { return }
                        switch newSelection {
                        case .channel(let channelID):
                            voiceModel.recordForwardDestinationVisit(channelID)
                            if selection == channelID {
                                // The parent row leaves its open thread, as in Discord.
                                voiceModel.closeThread()
                            }
                            selection = channelID
                        case .thread(let threadID):
                            if let thread = threadLayout(at: .now).threadsByParentID.values
                                .lazy.flatMap(\.self).first(where: { $0.id == threadID })?.thread
                            {
                                voiceModel.openSidebarThread(thread)
                            }
                        case .page(let page):
                            guard let guildID else { return }
                            if page == .guide {
                                voiceModel.openGuildGuide(in: guildID)
                            } else {
                                voiceModel.openChannelsAndRoles(in: guildID)
                            }
                        case nil: break
                        }
                    }
                )
            }
        )
    }

    private var directMessageSelection: Binding<DirectMessageSidebarSelection?> {
        Binding(
            get: { voiceModel.isFriendsPresented ? .friends : selection.map(DirectMessageSidebarSelection.channel) },
            set: { newSelection in
                switch newSelection {
                case .friends:
                    guard !voiceModel.isFriendsPresented else { return }
                    voiceModel.openFriends()
                case .channel(let channelID):
                    guard selection != channelID || voiceModel.isFriendsPresented else { return }
                    voiceModel.recordForwardDestinationVisit(channelID)
                    selection = channelID
                case nil:
                    break
                }
            }
        )
    }

    private var hiddenChannelIDs: Set<ChannelID> {
        voiceModel.hiddenChannelIDs
    }

    private var checkingChannelIDs: Set<ChannelID> {
        voiceModel.checkingChannelIDs
    }

}

/// An explicit invalidation boundary around SwiftUI's native outline keeps
/// unrelated timeline/member publications from recursively diffing every
/// channel row. All list-level presentation inputs participate in equality;
/// observable row leaves continue to receive their own model updates.
nonisolated private struct GuildChannelListInput: Equatable, Sendable {
    let modelIdentity: ObjectIdentifier
    let guildID: GuildID?
    var customizationTitle: String = "Channels & Roles"
    let hasCustomization: Bool
    let hasGuide: Bool
    let page: GuildWorkspacePage?
    let channelGroups: [ChannelGroup]
    let rulesChannelID: ChannelID?
    let activeVoiceChannelID: ChannelID?
    let hiddenChannelIDs: Set<ChannelID>
    let checkingChannelIDs: Set<ChannelID>
    let unreadCategoryIDs: Set<ChannelID>
    let selectedChannelID: ChannelID?
    let threadsByParentID: [ChannelID: [SidebarThreadRow]]
    let bottomContentInset: CGFloat
}

nonisolated private enum GuildSidebarSelection: Hashable {
    case channel(ChannelID)
    case thread(ChannelID)
    case page(GuildWorkspacePage)
}

private struct GuildChannelList: View, Equatable {
    let input: GuildChannelListInput
    let model: AppModel
    @Binding var selection: GuildSidebarSelection?

    nonisolated static func == (
        lhs: GuildChannelList,
        rhs: GuildChannelList
    ) -> Bool {
        lhs.input == rhs.input
    }

    var body: some View {
        List(selection: $selection) {
            if input.guildID != nil {
                if input.hasGuide {
                    guildPageRow("Server Guide", symbol: "signpost.right", page: .guide)
                }
                if input.hasCustomization {
                    guildPageRow(input.customizationTitle, symbol: "slider.horizontal.3", page: .channelsAndRoles)
                }
            }
            if input.hasGuide || input.hasCustomization {
                Divider()
                    .padding(.horizontal, InterfaceScale.metric(16))
                    .listRowInsets(EdgeInsets())
                    .selectionDisabled()
                    .accessibilityHidden(true)
            }
            ForEach(input.channelGroups) { group in
                ChannelGroupRows(
                    model: model,
                    group: group,
                    followsPageDestinations: (input.hasGuide || input.hasCustomization) && group.id == input.channelGroups.first?.id,
                    bottomContentInset:
                        group.id == input.channelGroups.last?.id
                            ? input.bottomContentInset
                            : 0,
                    rulesChannelID: input.rulesChannelID,
                    activeVoiceChannelID: input.activeVoiceChannelID,
                    selectedChannelID: input.selectedChannelID,
                    hiddenChannelIDs: input.hiddenChannelIDs,
                    checkingChannelIDs: input.checkingChannelIDs,
                    threadsByParentID: input.threadsByParentID,
                    isUnread: group.categoryID.map(
                        input.unreadCategoryIDs.contains
                    ) ?? false
                )
            }

        }
        .listStyle(.sidebar)
        .font(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
        .environment(\.defaultMinListRowHeight, ChannelSidebarLayoutMetrics.minimumRowHeight)
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
    private func guildPageRow(_ title: String, symbol: String, page: GuildWorkspacePage) -> some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Color.clear.frame(width: InterfaceScale.metric(8), height: InterfaceScale.metric(8))
            Image(systemName: symbol)
                .foregroundStyle(.primary.opacity(0.66))
                .frame(width: ChannelSidebarLayoutMetrics.iconWidth)
            Text(title).interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize)).foregroundStyle(.primary.opacity(0.78)).lineLimit(1)
            Spacer()
        }
        .frame(minHeight: ChannelSidebarLayoutMetrics.minimumRowHeight)
        .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
        .accessibilityElement(children: .combine)
        .tag(GuildSidebarSelection.page(page))
        .overlay { ChannelRowHoverBridge(isSelected: input.page == page) }
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
    var showsTopEdge = true

    nonisolated func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: strokeInset, y: rect.maxY))
        guard showsTopEdge else {
            path.addLine(to: CGPoint(x: strokeInset, y: rect.minY))
            return path
        }
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
    let followsPageDestinations: Bool
    let bottomContentInset: CGFloat
    let rulesChannelID: ChannelID?
    let activeVoiceChannelID: ChannelID?
    let selectedChannelID: ChannelID?
    let hiddenChannelIDs: Set<ChannelID>
    let checkingChannelIDs: Set<ChannelID>
    let threadsByParentID: [ChannelID: [SidebarThreadRow]]
    let isUnread: Bool
    let voiceParticipantEntriesByChannel:
        [ChannelID: VoiceSidebarChannelEntry]
    @State private var isExpanded: Bool

    init(
        model: AppModel,
        group: ChannelGroup,
        followsPageDestinations: Bool = false,
        bottomContentInset: CGFloat,
        rulesChannelID: ChannelID?,
        activeVoiceChannelID: ChannelID?,
        selectedChannelID: ChannelID?,
        hiddenChannelIDs: Set<ChannelID>,
        checkingChannelIDs: Set<ChannelID>,
        threadsByParentID: [ChannelID: [SidebarThreadRow]],
        isUnread: Bool
    ) {
        self.model = model
        self.group = group
        self.followsPageDestinations = followsPageDestinations
        self.bottomContentInset = bottomContentInset
        self.rulesChannelID = rulesChannelID
        self.activeVoiceChannelID = activeVoiceChannelID
        self.selectedChannelID = selectedChannelID
        self.hiddenChannelIDs = hiddenChannelIDs
        self.checkingChannelIDs = checkingChannelIDs
        self.threadsByParentID = threadsByParentID
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
        Group {
            if group.name == nil {
                channelRows
            } else if followsPageDestinations {
                categoryHeader
                    .font(.interface(.subheadline).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
                channelRows
            } else {
                Section { channelRows } header: {
                    categoryHeader
                        .interfaceFontOverride(.interface(.subheadline).weight(.bold))
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
    @ViewBuilder private var channelRows: some View {
            ForEach(visibleChannels) { channel in
                if channel.kind == .voice {
                    ChannelRow(
                        model: model,
                        channel: channel,
                        rulesChannelID: rulesChannelID,
                        isVoiceConnected: activeVoiceChannelID == channel.id,
                        isHidden: hiddenChannelIDs.contains(channel.id),
                        isChecking: checkingChannelIDs.contains(channel.id)
                    )
                    .tag(GuildSidebarSelection.channel(channel.id))
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
                    .tag(GuildSidebarSelection.channel(channel.id))
                    let threads = threadsByParentID[channel.id] ?? []
                    ForEach(threads) { row in
                        ThreadRow(
                            model: model,
                            row: row,
                            continuesBelow: row.id != threads.last?.id
                        )
                        .tag(GuildSidebarSelection.thread(row.id))
                    }
                }
            }

            if bottomContentInset > 0 {
                SidebarBottomScrollSpacer(height: bottomContentInset)
            }
    }

    private var categoryHeader: some View {
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
                        HStack(spacing: InterfaceScale.metric(5)) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.interface(.caption2).weight(.semibold))
                                .frame(width: InterfaceScale.metric(8))
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

    private var visibleChannels: [Channel] {
        guard group.name != nil, !isExpanded else { return group.channels }
        let isCategoryMuted = if let guildID = group.guildID,
                                 let categoryID = group.categoryID
        {
            model.isCategoryMuted(guildID: guildID, categoryID: categoryID)
        } else {
            false
        }
        return group.channels.filter { channel in
            channel.id == selectedChannelID
                || threadsByParentID[channel.id]?.isEmpty == false
                || channel.mentionCount > 0
                || (!isCategoryMuted && channel.unreadCount > 0)
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
        HStack(spacing: InterfaceScale.metric(8)) {
            AvatarView(name: participant.name, url: participant.avatarURL, size: InterfaceScale.metric(24))
            Text(participant.name)
                .font(.interface(.caption))
                .lineLimit(1)
            Spacer(minLength: InterfaceScale.metric(4))
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
        .font(.interface(.caption2))
        .padding(.leading, InterfaceScale.metric(24))
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
        GlassEffectContainer(spacing: SidebarAccountControlMetrics.surfaceSpacing) {
            VStack(spacing: SidebarAccountControlMetrics.surfaceSpacing) {
                if voiceModel.activeVoiceChannel != nil {
                    VoiceSidebarControlPanel(model: voiceModel) {
                        guard let channelID = voiceModel.activeVoiceChannel?.id else {
                            return
                        }
                        voiceModel.navigate(to: channelID)
                    }
                }

                CurrentUserCapsule(
                    model: voiceModel,
                    user: user.map(voiceModel.cosmeticPolicy.user),
                    displayName: displayName,
                    subtitle: accountSubtitle,
                    currentStatus: currentStatus,
                    isAuthenticated: isAuthenticated,
                    isOfflineTesting: isOfflineTesting,
                    connectAccount: connectAccount,
                    updateStatus: updateStatus
                )
            }
        }
        .padding(.horizontal, InterfaceScale.metric(8))
        .padding(
            .bottom,
            SidebarAccountControlMetrics.bottomInset(
                for: voiceModel.appearanceSettings.composerBarAppearance
            )
        )
    }

    private var displayName: String {
        user?.displayName ?? (isAuthenticated ? "Discord Account" : "Connect Account")
    }

    private var accountSubtitle: String {
        if user != nil {
            return currentStatus.label
        }
        return isOfflineTesting
            ? "Mock data • networking disabled"
            : (isAuthenticated ? connectionState.rawValue : "Sign in to Discord")
    }
}

private struct CurrentUserCapsule: View {
    let model: AppModel
    let user: User?
    let displayName: String
    let subtitle: String
    let currentStatus: PresenceStatus
    let isAuthenticated: Bool
    let isOfflineTesting: Bool
    let connectAccount: () -> Void
    let updateStatus: (PresenceStatus) async -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var isMainHovering = false
    @State private var isSettingsHovering = false
    @State private var isYouPopoverPresented = false
    @State private var profileRequestID: UUID?

    var body: some View {
        let appearance = model.appearanceSettings.composerBarAppearance
        let height = SidebarAccountControlMetrics.capsuleHeight
        let shape = SidebarAccountControlMetrics.shape(for: appearance)

        ZStack {
            if let nameplate = user?.nameplate {
                NameplateBackground(
                    nameplate: nameplate,
                    isAnimated: isProfileHovering
                )
                .opacity(
                    NameplatePresentationPolicy.opacity(
                        isHovered: isProfileHovering
                    )
                )
            }

            Color.primary.opacity(isProfileHovering ? 0.09 : 0)
                .allowsHitTesting(false)

            Button(action: presentYouPopover) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    accountAvatar

                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayName)
                            .font(.interfaceSystem(
                                size: InterfaceTypographyMetrics.interfaceTextSize,
                                weight: .semibold
                            ))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.interfaceSystem(
                                size: max(
                                    10,
                                    InterfaceTypographyMetrics.interfaceTextSize - 2
                                )
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: InterfaceScale.metric(4))
                }
                .padding(.leading, SidebarAccountControlMetrics.contentInset)
                .padding(
                    .trailing,
                    SidebarAccountControlMetrics.settingsDiameter
                        + SidebarAccountControlMetrics.settingsInset
                        + SidebarAccountControlMetrics.contentInset
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: height,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onModalHover { isMainHovering = $0 }
            .stableMemberProfilePopover(isPresented: $isYouPopoverPresented) {
                youPopover
            }

            ComposerActionButton(
                icon: Image(systemName: "gearshape.fill"),
                help: "Settings",
                iconSize: SidebarAccountControlMetrics.settingsIconSize,
                size: SidebarAccountControlMetrics.settingsDiameter,
                appearance: appearance,
                cornerRadius: SidebarAccountControlMetrics.settingsCornerRadius(for: appearance),
                onHoverChanged: { isSettingsHovering = $0 },
                action: { openSettings() }
            )
            .accessibilityLabel("Settings")
            .padding(.trailing, SidebarAccountControlMetrics.settingsInset)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .trailing
            )
        }
        .frame(height: height)
        .containerShape(shape)
        .clipShape(shape)
        .contentShape(shape)
        .glassEffect(.regular, in: shape)
        .animation(.snappy(duration: 0.16), value: isProfileHovering)
        .onChange(of: isYouPopoverPresented) { _, isPresented in
            guard !isPresented, let profileRequestID else { return }
            model.dismissContextualProfile(requestID: profileRequestID)
            self.profileRequestID = nil
        }
        .accessibilityElement(children: .contain)
    }

    private var isProfileHovering: Bool {
        isMainHovering && !isSettingsHovering
    }

    private var accountAvatar: some View {
        AvatarPresenceView(
            status: currentStatus,
            avatarSize: SidebarAccountControlMetrics.avatarSize,
            indicatorSize: InterfaceScale.metric(10)
        ) {
            DecoratedAvatarView(
                name: displayName,
                avatarURL: user?.avatarURL,
                decorationURL: user?.avatarDecorationURL,
                size: SidebarAccountControlMetrics.avatarSize,
                playback: .hover(isProfileHovering)
            )
        }
        .frame(
            width: SidebarAccountControlMetrics.avatarSize,
            height: SidebarAccountControlMetrics.avatarSize
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(currentStatus.label)")
    }

    @ViewBuilder
    private var youPopover: some View {
        if let profileRequestID,
           let presentation = model.liveProfilePresentation(for: .contextual),
           presentation.requestID == profileRequestID
        {
            ProfilePresentationContent(
                presentation: presentation,
                maximumPopoverHeight: InterfaceScale.metric(720),
                showsRoles: false,
                openProfile: model.expandProfile,
            footer: {
                YouPopoverOptions(
                    currentStatus: currentStatus,
                    isStatusEnabled: isAuthenticated && !isOfflineTesting,
                    isAccountSwitchingEnabled: !isOfflineTesting,
                    savedAccounts: model.savedAccounts,
                    activeAccountID: model.activeAccountID,
                    updateStatus: updateStatus,
                    switchAccount: { accountID in
                        await model.switchAccount(to: accountID)
                    },
                    manageAccounts: {
                        isYouPopoverPresented = false
                        connectAccount()
                    },
                    accountActivated: {
                        isYouPopoverPresented = false
                    }
                )
            })
            .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
            .environment(\.serverTagCardModel, model)
        } else {
            ProgressView("Loading profile…")
                .padding(InterfaceScale.metric(24))
                .frame(width: MemberProfilePopover<EmptyView>.preferredWidth)
        }
    }

    private func presentYouPopover() {
        if isYouPopoverPresented {
            isYouPopoverPresented = false
            return
        }
        guard let user else {
            connectAccount()
            return
        }
        let member = model.membersByID[user.id]
            ?? Member(user: user, roleName: "You", status: currentStatus)
        profileRequestID = model.presentProfile(
            for: member,
            in: model.selectedGuildID,
            destination: .contextual
        )
        isYouPopoverPresented = true
    }
}

private struct YouPopoverOptions: View {
    let currentStatus: PresenceStatus
    let isStatusEnabled: Bool
    let isAccountSwitchingEnabled: Bool
    let savedAccounts: [SavedAccount]
    let activeAccountID: String?
    let updateStatus: (PresenceStatus) async -> Void
    let switchAccount: (String) async -> Bool
    let manageAccounts: () -> Void
    let accountActivated: () -> Void

    @State private var isStatusPopoverPresented = false
    @State private var isAccountPopoverPresented = false

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            Divider()
                .padding(.horizontal, InterfaceScale.metric(8))
                .padding(.bottom, InterfaceScale.metric(4))

            Button {
                isStatusPopoverPresented.toggle()
            } label: {
                HStack(spacing: InterfaceScale.metric(10)) {
                    PresenceIndicator(status: currentStatus, size: InterfaceScale.metric(13))
                        .frame(width: InterfaceScale.metric(18))
                    Text(currentStatus.label)
                    Spacer(minLength: InterfaceScale.metric(24))
                    Image(systemName: "chevron.right")
                        .font(.interface(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, InterfaceScale.metric(8))
                .frame(maxWidth: .infinity)
                .frame(height: InterfaceScale.metric(38))
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .disabled(!isStatusEnabled)
            .opacity(isStatusEnabled ? 1 : 0.45)
            .escapeDismissiblePopover(
                isPresented: $isStatusPopoverPresented,
                arrowEdge: .trailing
            ) {
                StatusSelectionPopover(
                    currentStatus: currentStatus,
                    updateStatus: updateStatus
                )
            }

            Button {
                isAccountPopoverPresented.toggle()
            } label: {
                HStack(spacing: InterfaceScale.metric(10)) {
                    Image(systemName: "person.crop.circle")
                        .frame(width: InterfaceScale.metric(18))
                    Text("Switch Accounts")
                    Spacer(minLength: InterfaceScale.metric(24))
                    Image(systemName: "chevron.right")
                        .font(.interface(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, InterfaceScale.metric(8))
                .frame(maxWidth: .infinity)
                .frame(height: InterfaceScale.metric(38))
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .disabled(!isAccountSwitchingEnabled)
            .opacity(isAccountSwitchingEnabled ? 1 : 0.45)
            .escapeDismissiblePopover(
                isPresented: $isAccountPopoverPresented,
                arrowEdge: .trailing
            ) {
                AccountSelectionPopover(
                    savedAccounts: savedAccounts,
                    activeAccountID: activeAccountID,
                    switchAccount: switchAccount,
                    manageAccounts: manageAccounts,
                    accountActivated: accountActivated
                )
            }
        }
        .font(.interface(.callout))
        .padding(.horizontal, InterfaceScale.metric(10))
        .padding(.top, InterfaceScale.metric(2))
    }
}

private struct StatusSelectionPopover: View {
    let currentStatus: PresenceStatus
    let updateStatus: (PresenceStatus) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            ForEach(PresenceStatus.allCases.filter { $0 != .offline }, id: \.self) { status in
                Button {
                    Task {
                        await updateStatus(status)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: InterfaceScale.metric(10)) {
                        PresenceIndicator(status: status, size: InterfaceScale.metric(13))
                            .frame(width: InterfaceScale.metric(18))
                        Text(status.label)
                        Spacer()
                        if status == currentStatus {
                            Image(systemName: "checkmark")
                                .foregroundStyle(SakuraCordAccentColor.color)
                        }
                    }
                    .padding(.horizontal, InterfaceScale.metric(8))
                    .frame(maxWidth: .infinity)
                    .frame(height: InterfaceScale.metric(34))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PopoverRowButtonStyle())
            }
        }
        .font(.interface(.callout))
        .padding(InterfaceScale.metric(12))
        .frame(width: InterfaceScale.metric(220))
    }
}

private struct AccountSelectionPopover: View {
    let savedAccounts: [SavedAccount]
    let activeAccountID: String?
    let switchAccount: (String) async -> Bool
    let manageAccounts: () -> Void
    let accountActivated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var switchingAccountID: String?

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            if savedAccounts.isEmpty {
                Text("No saved accounts")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34), alignment: .leading)
                    .padding(.horizontal, InterfaceScale.metric(8))
            } else {
                ForEach(savedAccounts) { account in
                    accountButton(account)
                }
                Divider().padding(.horizontal, InterfaceScale.metric(8))
            }

            Button {
                dismiss()
                manageAccounts()
            } label: {
                Label("Manage Accounts…", systemImage: "person.crop.circle")
                    .padding(.horizontal, InterfaceScale.metric(8))
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34), alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
        }
        .font(.interface(.callout))
        .padding(InterfaceScale.metric(12))
        .frame(width: InterfaceScale.metric(250))
    }

    private func accountButton(_ account: SavedAccount) -> some View {
        Button {
            guard switchingAccountID == nil,
                  account.accountID != activeAccountID
            else { return }
            switchingAccountID = account.accountID
            Task {
                let switched = await switchAccount(account.accountID)
                switchingAccountID = nil
                guard switched else { return }
                dismiss()
                accountActivated()
            }
        } label: {
            HStack(spacing: InterfaceScale.metric(9)) {
                AvatarView(
                    name: account.resolvedDisplayName,
                    url: account.avatarURL,
                    size: InterfaceScale.metric(20),
                    maximumPixelDimension: 40,
                    animates: false
                )
                Text(account.username ?? account.resolvedDisplayName)
                    .lineLimit(1)
                Spacer()
                if account.accountID == activeAccountID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(8))
            .frame(maxWidth: .infinity)
            .frame(height: InterfaceScale.metric(36))
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
        .disabled(switchingAccountID != nil)
        .authenticationLoading(switchingAccountID == account.accountID, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(8)))
        .accessibilityValue(switchingAccountID == account.accountID ? "Switching account" : "")
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
}

private struct ChannelRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: AppModel
    let channel: Channel
    var rulesChannelID: ChannelID?
    var isVoiceConnected = false
    var isHidden = false
    var isChecking = false

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Capsule()
                .fill(colorScheme == .dark ? Color.white : Color.black)
                .frame(width: InterfaceScale.metric(4), height: InterfaceScale.metric(8))
                .opacity(showsUnread ? 1 : 0)
                .frame(width: InterfaceScale.metric(8))
            Image(systemName: systemImage)
                .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
                .fontWeight(
                    showsUnread && !isMuted
                        ? .medium
                        : .regular
                )
                .foregroundStyle(
                    isVoiceConnected ? Color.green
                        : channelIconForegroundStyle
                )
                .frame(width: ChannelSidebarLayoutMetrics.iconWidth)
            Text(channel.name)
                .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
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
                    .font(.interface(.caption))
                    .foregroundStyle(Color(hex: 0x23A55A))
                    .accessibilityLabel("Active screen share")
            }
            if isVoiceConnected {
                Image(systemName: "waveform")
                    .font(.interface(.caption))
                    .foregroundStyle(.green)
            }
            if channel.kind == .forum, showsUnread {
                Text("\(channel.unreadCount) New")
                    .font(.interface(.caption).weight(.semibold))
                    .foregroundStyle(Color(hex: 0x5865F2))
            }
            if !isChecking, channel.mentionCount > 0 {
                Text(channel.mentionCount, format: .number)
                    .font(.interface(.caption2).bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, InterfaceScale.metric(6))
                    .padding(.vertical, InterfaceScale.metric(2))
                    .background(Color(hex: 0xF23F43), in: Capsule())
            }
        }
        .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
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

private struct ThreadRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: AppModel
    let row: SidebarThreadRow
    let continuesBelow: Bool

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Capsule()
                .fill(colorScheme == .dark ? Color.white : Color.black)
                .frame(width: InterfaceScale.metric(4), height: InterfaceScale.metric(8))
                .opacity(row.isUnread ? 1 : 0)
                .frame(width: InterfaceScale.metric(8))
            ThreadConnector(continuesBelow: continuesBelow)
                .stroke(
                    .primary.opacity(0.32),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .frame(width: ChannelSidebarLayoutMetrics.iconWidth)
            Text(row.thread.name)
                .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
                .fontWeight(row.isUnread && !row.isMuted ? .medium : .regular)
                .foregroundStyle(nameForegroundStyle)
                .lineLimit(1)
            Spacer()
            if row.mentionCount > 0 {
                Text(row.mentionCount, format: .number)
                    .font(.interface(.caption2).bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, InterfaceScale.metric(6))
                    .padding(.vertical, InterfaceScale.metric(2))
                    .background(Color(hex: 0xF23F43), in: Capsule())
            }
        }
        .frame(minHeight: ChannelSidebarLayoutMetrics.minimumRowHeight)
        .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
        .accessibilityElement(children: .combine)
        .overlay { ThreadContextMenuBridge(model: model, row: row) }
        .accessibilityLabel("\(row.thread.name), thread")
        .accessibilityValue(accessibilityValue)
    }

    private var nameForegroundStyle: Color {
        if row.isMuted { return .primary.opacity(0.35) }
        return row.isUnread ? .primary : .primary.opacity(0.78)
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if row.isUnread { values.append("Unread") }
        if row.mentionCount > 0 {
            values.append(
                row.mentionCount == 1
                    ? "1 unread mention"
                    : "\(row.mentionCount) unread mentions"
            )
        }
        return values.joined(separator: ", ")
    }
}

/// The spine joining a thread to its parent channel's icon column.
private struct ThreadConnector: Shape {
    let continuesBelow: Bool

    nonisolated func path(in rect: CGRect) -> Path {
        let radius: CGFloat = InterfaceScale.metric(5)
        // Reach into the row spacing so consecutive spines join.
        let top = rect.minY - 6
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: top))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + radius, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.midY)
        )
        path.addLine(to: CGPoint(x: rect.maxX + InterfaceScale.metric(2), y: rect.midY))
        if continuesBelow {
            path.move(to: CGPoint(x: rect.midX, y: rect.midY - radius))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + InterfaceScale.metric(6)))
        }
        return path
    }
}
