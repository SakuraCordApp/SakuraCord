import Observation
import SakuraCordModels
import SwiftUI

/// Keeps rail observation out of the workspace root. Timeline, member-list,
/// composer, and loading publications can invalidate `ChatRootView` without
/// rebuilding or comparing every server row.
struct ServerRailContainer: View {
    let model: AppModel
    let sidebarWidth: CGFloat
    @State private var folderSettings: GuildFolder?
    @State private var readAllConfirmationSession: AppModelAccountSession?

    var body: some View {
        @Bindable var invites = model.serverInvites
        ServerRailView(
            sidebarWidth: sidebarWidth,
            items: model.serverRailPresentation.items,
            directMessages: model.serverRailPresentation.directMessages,
            home: model.serverRailPresentation.home,
            selectHome: { model.selectGuild(nil) },
            selectDirectMessage: { model.navigate(to: $0) },
            selectGuild: model.selectGuild,
            joinServer: { invites.showsJoinDialog = true },
            showsReadAllButton: model.featuresSettings.readAllButton,
            isReadingAll: model.isMarkingAllServersRead,
            hasUnreadServers: { model.hasUnreadServers },
            readAll: { readAllConfirmationSession = model.accountSession() },
            moveItems: model.moveServerRailItems,
            combineGuilds: model.combineServerRailGuild,
            contextMenuActions: ServerRailContextMenuActions(
                markRead: model.markGuildRead,
                canInvite: { model.serverInviteChannel(for: $0.id) != nil },
                invite: model.presentServerInviteCreation,
                mute: { guild, duration in
                    model.setGuildMute(
                        true,
                        until: duration.endDate(),
                        for: guild
                    )
                },
                unmute: { guild in
                    model.setGuildMute(false, until: nil, for: guild)
                },
                setNotificationLevel: { guild, level in
                    model.setGuildNotificationLevel(level, for: guild)
                },
                setNotificationToggle: { guild, toggle, isEnabled in
                    model.setGuildNotificationToggle(
                        toggle,
                        isEnabled: isEnabled,
                        for: guild
                    )
                },
                leaveServer: { guild in invites.leaveConfirmation = guild },
                showsAllChannels: { guild in
                    guard model.featuresSettings.channelManagement, model.hasChannelsAndRoles(in: guild.id) else { return nil }
                    return model.showsAllChannels(in: guild.id)
                },
                setShowsAllChannels: { guild, all in
                    model.setChannelSelectionEnabled(!all, guildID: guild.id)
                },
                markFolderRead: model.markServerFolderRead,
                openFolderSettings: { folderSettings = $0 }
            )
        )
        .windowModal(item: $folderSettings, title: "Folder Settings", cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) { folder in
            ServerFolderSettingsView(folder: folder) { name, colorHex in
                model.updateServerFolder(folder.id, name: name, colorHex: colorHex)
            }
        }
        .windowModal(isPresented: $invites.showsJoinDialog, cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular,
                     isConcealed: { model.serverInvites.captcha.challenge != nil }, content: { JoinServerView(model: model) })
        .windowModal(item: Bindable(invites.creation).presentation, cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) {
            ServerInviteCreationView(model: model, presentation: $0)
        }
        .modifier(HumanCaptchaPresentation(store: invites.captcha))
        .alert("Mark All Servers as Read?",
               isPresented: Binding(get: { readAllConfirmationSession != nil },
                                    set: { if !$0 { readAllConfirmationSession = nil } }),
               presenting: readAllConfirmationSession) { session in
            Button("Mark All as Read") {
                guard model.isCurrentAccountSession(session) else { return }
                model.markAllServersRead()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This will mark unread channels and joined threads in all servers as read, including muted channels.")
        }
        .alert("Leave \(invites.leaveConfirmation?.name ?? "Server")?",
               isPresented: Binding(get: { invites.leaveConfirmation != nil },
                                    set: { if !$0 { invites.leaveConfirmation = nil } }),
               presenting: invites.leaveConfirmation) { guild in
            Button("Leave Server", role: .destructive) {
                model.startAccountChildTask(account: model.accountSession()) { model, _ in
                    _ = await model.leaveServer(guild)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You won’t be able to rejoin this server unless you have a new or existing invite.")
        }
        .alert("Unable to Leave Server",
               isPresented: Binding(get: { invites.leaveError != nil }, set: { if !$0 { invites.leaveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(invites.leaveError ?? "")
        }
    }
}

struct ServerRailView: View {
    let sidebarWidth: CGFloat
    let items: [ServerRailPresentationItem]
    let directMessages: [ServerRailDirectMessageEntry]
    let home: ServerRailHomeEntry
    let selectHome: () -> Void
    let selectDirectMessage: (ChannelID) -> Void
    let selectGuild: (GuildID?) -> Void
    var joinServer: () -> Void = {}
    var showsReadAllButton = false
    var isReadingAll = false
    var hasUnreadServers: () -> Bool = { false }
    var readAll: () -> Void = {}
    var moveItems: ([GuildRailItem.RailIdentifier], GuildRailDestination) -> Void = { _, _ in }
    var combineGuilds: (GuildID, GuildID) -> Void = { _, _ in }
    let contextMenuActions: ServerRailContextMenuActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var folderLayoutRevision = 0
    @State private var drag = ServerRailDragController()

    var body: some View {
        ScrollView {
            // Expanded folders make rail rows variable-height. Lazy layout
            // corrects its content estimate while reverse-scrolling, which
            // disrupts AppKit's elastic rebound at the top boundary.
            VStack(spacing: InterfaceScale.metric(10)) {
                HomeRailButton(
                    home: home,
                    action: selectHome
                )

                ForEach(directMessages) { entry in
                    DirectMessageRailButton(entry: entry) {
                        selectDirectMessage(entry.id)
                    }
                    .geometryGroup()
                    .transition(ServerRailAnimations.membershipTransition)
                }

                VStack(spacing: InterfaceScale.metric(showsReadAllButton ? ReadAllServersButton.verticalPadding : 10)) {
                    Divider().padding(.horizontal, InterfaceScale.metric(12))
                    if showsReadAllButton {
                        ReadAllServersButton(isReadingAll: isReadingAll, hasUnreadServers: hasUnreadServers, action: readAll)
                    }
                    if !items.isEmpty { serverItems }
                }
                AddServerRailButton(action: joinServer)
            }
            .padding(.bottom, InterfaceScale.metric(12))
            .animation(reduceMotion ? nil : ServerRailAnimations.folderExpansion, value: folderLayoutRevision)
            .animation(reduceMotion ? nil : ServerRailAnimations.reorder, value: directMessages.map(\.id))
            .animation(reduceMotion ? nil : ServerRailAnimations.reorder, value: items.map(\.id))
            .animation(reduceMotion ? nil : ServerRailAnimations.reorder, value: folderGuildIDs)
        }
        // Unlike .hidden, .never overrides macOS's always-visible scrollbar preference.
        .scrollIndicators(.never)
        // Scrolled icons must not draw beneath the window's traffic lights.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background {
            ScrollInputPerformanceProbeAttachment(surface: .serverList)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth)
        .overlayPreferenceValue(ServerRailHoverPreferenceKey.self) { hoverItem in
            GeometryReader { proxy in
                if let hoverItem, drag.draggedID == nil {
                    ServerRailHoverLabel(
                        name: hoverItem.name,
                        maximumWidth: max(0, sidebarWidth - ChatChromeMetrics.serverRailWidth - 7 - InterfaceScale.metric(16))
                    )
                        .offset(
                            x: ChatChromeMetrics.serverRailWidth + 7,
                            y: proxy[hoverItem.bounds].midY - 16
                        )
                        .transaction { $0.animation = nil }
                }
            }
            .allowsHitTesting(false)
        }
        // Like the hover label, the dragged row is drawn outside the scroll
        // view so neither it nor the neighbouring panes can clip it.
        .overlayPreferenceValue(ServerRailRowsPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                ServerRailDragOverlay(
                    rows: anchors.map {
                        ServerRailRow(
                            id: $0.id,
                            folderID: $0.folderID,
                            isExpandedFolder: $0.isExpandedFolder,
                            frame: proxy[$0.bounds]
                        )
                    },
                    viewport: proxy.frame(in: .global),
                    rootIDs: items.map(\.id),
                    enclosingFolder: enclosingFolder,
                    drag: drag,
                    preview: { id in
                        dragPreview(id).environment(\.serverRailIsDragPreview, true)
                    }
                )
            }
            .allowsHitTesting(false)
        }
        .zIndex(200)
        .environment(drag)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onAppear {
            drag.perform = { id, target in
                switch target {
                case .insert(let destination, _):
                    moveItems([id], destination)
                case .addToFolder(let folderID, _):
                    moveItems([id], GuildRailDestination(container: .folder(folderID)))
                case .combine(let target, _):
                    if case .guild(let source) = id { combineGuilds(source, target) }
                }
            }
        }
    }

    private var serverItems: some View {
        VStack(spacing: InterfaceScale.metric(10)) {
            ForEach(items) { item in
                ServerRailItemView(
                    item: item,
                    selectGuild: selectDraggableGuild,
                    contextMenuActions: contextMenuActions,
                    folderExpansionChanged: {
                        folderLayoutRevision &+= 1
                    }
                )
                // Keep native images and their clipping shapes together as
                // a preceding folder changes the row's position.
                .geometryGroup()
                .transition(ServerRailAnimations.membershipTransition)
            }
        }
    }

    // Observe folder membership, without observing per-guild unread or selection updates.
    private var folderGuildIDs: [[GuildID]] {
        items.compactMap { item in
            if case .folder(let entry) = item { entry.guildEntries.map(\.id) } else { nil }
        }
    }

    private func selectDraggableGuild(_ id: GuildID?) {
        guard !drag.swallowsClick else { return }
        selectGuild(id)
    }

    private func enclosingFolder(_ id: GuildRailItem.RailIdentifier) -> GuildRailItem.RailIdentifier? {
        guard case .guild(let guildID) = id else { return nil }
        for case .folder(let entry) in items where entry.guildEntries.contains(where: { $0.id == guildID }) {
            return entry.id
        }
        return nil
    }

    @ViewBuilder
    private func dragPreview(_ id: GuildRailItem.RailIdentifier) -> some View {
        switch id {
        case .guild(let guildID):
            let entry = items.lazy.compactMap { item -> ServerRailGuildEntry? in
                switch item {
                case .guild(let entry): entry.id == guildID ? entry : nil
                case .folder(let folder): folder.guildEntries.first { $0.id == guildID }
                }
            }.first
            if let entry {
                ServerRailGuildItemView(entry: entry, selectGuild: { _ in }, contextMenuActions: contextMenuActions, loadsImageWhenOffscreen: true)
            }
        case .folder:
            if let entry = items.lazy.compactMap({ item -> ServerRailFolderEntry? in
                if case .folder(let entry) = item, entry.id == id { entry } else { nil }
            }).first {
                ServerFolderRailHeader(
                    entry: entry,
                    isExpanded: PRBuildProfile.defaults.bool(forKey: ServerFolderRailView.expansionKey(entry.folder.id)),
                    contextMenuActions: contextMenuActions,
                    toggle: {},
                    loadsImageWhenOffscreen: true
                )
            }
        }
    }
}

private struct ReadAllServersButton: View {
    static let verticalPadding: CGFloat = 3

    let isReadingAll: Bool
    // Observe unread state here so incoming read updates do not rebuild the whole rail.
    let hasUnreadServers: () -> Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let isEnabled = !isReadingAll && hasUnreadServers()
        let showsHover = isEnabled && isHovering
        Button(action: action) {
            Text("Read All")
                .font(.interfaceSystem(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Color.primary.opacity(showsHover ? 1 : 0.8) : Color.secondary.opacity(0.5))
                .padding(.vertical, InterfaceScale.metric(Self.verticalPadding))
                .frame(width: ChatChromeMetrics.serverRailWidth)
                .overlay(alignment: .leading) {
                    ServerRailSelectionIndicator(isSelected: false, isHovering: showsHover, hasNotification: false)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onModalHover { isHovering = $0 }
        .accessibilityIdentifier("read-all-servers")
    }
}

private struct DirectMessageRailButton: View {
    let entry: ServerRailDirectMessageEntry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let channel = entry.channel
        let displayName = channel.name.isEmpty ? "Group Direct Message" : channel.name

        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(4)) {
                ServerRailSelectionIndicator(
                    isSelected: entry.isSelected,
                    isHovering: isHovering,
                    hasNotification: true
                )
                ServerRailBadgedIcon(mentionCount: channel.mentionCount) {
                    DirectMessageAvatar(
                        channel: channel,
                        size: InterfaceScale.metric(44),
                        status: nil,
                        animates: true,
                        isHovered: isHovering
                    )
                    .frame(width: InterfaceScale.metric(46), height: InterfaceScale.metric(46))
                }
            }
            .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ServerRailButtonStyle())
        .accessibilityLabel(displayName)
        .accessibilityValue(
            channel.mentionCount > 0
                ? "\(channel.mentionCount) unread mentions"
                : "Unread"
        )
        .help(displayName)
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onModalHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

struct ServerRailBadgedIcon<Icon: View>: View {
    let mentionCount: Int
    let badgeOffset: CGFloat
    let icon: Icon
    @Environment(\.serverRailMentionBadgesInOverlay) private var drawsBadgeInOverlay

    init(mentionCount: Int, badgeOffset: CGFloat = 4, @ViewBuilder icon: () -> Icon) {
        self.mentionCount = mentionCount
        self.badgeOffset = badgeOffset
        self.icon = icon()
    }

    var body: some View {
        if mentionCount > 0 {
            icon
                .overlay(alignment: .bottomTrailing) {
                    badge
                        .padding(InterfaceScale.metric(2))
                        .background(.black, in: Capsule())
                        .offset(x: InterfaceScale.metric(badgeOffset + 2), y: InterfaceScale.metric(badgeOffset + 2))
                        .blendMode(.destinationOut)
                        .accessibilityHidden(true)
                }
                .compositingGroup()
                .overlay(alignment: .bottomTrailing) {
                    badge
                        .opacity(drawsBadgeInOverlay ? 0 : 1)
                        .offset(x: InterfaceScale.metric(badgeOffset), y: InterfaceScale.metric(badgeOffset))
                }
        } else {
            icon
        }
    }

    private var badge: some View { ServerRailMentionBadge(count: mentionCount) }
}

struct ServerRailMentionBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(.interfaceSystem(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, InterfaceScale.metric(5))
            .frame(minWidth: InterfaceScale.metric(18), minHeight: InterfaceScale.metric(18))
            .background(Color(hex: 0xF23F43), in: Capsule())
    }
}

struct ServerRailContextMenuActions {
    let markRead: (GuildID) -> Void
    var canInvite: (Guild) -> Bool = { _ in false }
    var invite: (Guild) -> Void = { _ in }
    let mute: (Guild, ChannelMuteDuration) -> Void
    let unmute: (Guild) -> Void
    let setNotificationLevel: (Guild, MessageNotificationLevel) -> Void
    let setNotificationToggle: (Guild, GuildNotificationToggle, Bool) -> Void
    var leaveServer: (Guild) -> Void = { _ in }
    var showsAllChannels: (Guild) -> Bool? = { _ in nil }
    var setShowsAllChannels: (Guild, Bool) -> Void = { _, _ in }
    var markFolderRead: ([GuildID]) -> Void = { _ in }
    var openFolderSettings: (GuildFolder) -> Void = { _ in }
}

private struct ServerRailItemView: View {
    let item: ServerRailPresentationItem
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    let folderExpansionChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .guild(let entry):
                ServerRailGuildItemView(
                    entry: entry,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions
                )
                .modifier(ServerRailDraggableRow(id: item.id))
            case .folder(let entry):
                ServerFolderRailView(
                    entry: entry,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions,
                    expansionChanged: folderExpansionChanged
                )
            }
        }
    }
}

struct ServerRailGuildItemView: View {
    let entry: ServerRailGuildEntry
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    var loadsImageWhenOffscreen = false
    var morphsInFolder = false

    var body: some View {
        if let presentation = entry.presentation {
            GuildRailButton(
                presentation: presentation,
                isSelected: entry.isSelected,
                contextMenuActions: contextMenuActions,
                loadsImageWhenOffscreen: loadsImageWhenOffscreen,
                morphsInFolder: morphsInFolder
            ) {
                selectGuild(entry.id)
            }
        }
    }
}

enum ServerRailAnimations {
    static let folderExpansion = Animation.spring(duration: 0.38, bounce: 0)
    static let reorder = Animation.snappy(duration: 0.28)
    static let membershipTransition = AnyTransition.scale(scale: 0.7).combined(with: .opacity)
}

struct GuildRailButton: View {
    let presentation: ServerRailGuildPresentation
    let isSelected: Bool
    let contextMenuActions: ServerRailContextMenuActions
    var loadsImageWhenOffscreen = false
    var morphsInFolder = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ServerRailDragController.self) private var drag
    @Environment(\.serverRailIsDragPreview) private var isDragPreview
    @Environment(\.serverRailFolderIndicatorsInOverlay) private var folderIndicatorsInOverlay
    @State private var isHovering = false
    @State private var iconIsVisible = false

    var body: some View {
        let guild = presentation.guild
        let displayName = guild.name.isEmpty ? "Unnamed Server" : guild.name
        let hidesIndicator = isDragPreview || drag.draggedID == .guild(guild.id) || drag.flight?.id == .guild(guild.id)

        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(4)) {
                ServerRailSelectionIndicator(
                    isSelected: isSelected,
                    isHovering: isHovering,
                    hasNotification: guild.unreadCount > 0
                )
                .opacity(hidesIndicator || folderIndicatorsInOverlay ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: hidesIndicator)
                ServerRailBadgedIcon(mentionCount: guild.mentionCount) {
                    GuildIconView(
                        name: displayName,
                        iconURL: guild.iconURL,
                        size: InterfaceScale.metric(44),
                        cornerRadius: InterfaceScale.metric(13),
                        animates: isHovering,
                        isSelected: isSelected,
                        loadsImage: !(morphsInFolder && !reduceMotion) && (loadsImageWhenOffscreen || iconIsVisible),
                        morphsInFolder: morphsInFolder && !reduceMotion,
                        morphID: guild.id
                    )
                    .transformAnchorPreference(key: ServerFolderIconBounds.self, value: .bounds) { anchors, anchor in
                        if folderIndicatorsInOverlay, !morphsInFolder {
                            anchors[guild.id] = anchor
                        }
                    }
                    .frame(width: InterfaceScale.metric(46), height: InterfaceScale.metric(46))
                }
                .contentShape(Rectangle())
            }
            .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ServerRailButtonStyle())
        .overlay {
            ServerContextMenuBridge(
                isUnread: guild.unreadCount > 0,
                isMutationPending:
                    presentation.isNotificationMutationPending,
                notificationSettings: presentation.notificationSettings,
                markRead: { contextMenuActions.markRead(guild.id) },
                canInvite: { contextMenuActions.canInvite(guild) },
                invite: { contextMenuActions.invite(guild) },
                mute: { contextMenuActions.mute(guild, $0) },
                unmute: { contextMenuActions.unmute(guild) },
                setNotificationLevel: {
                    contextMenuActions.setNotificationLevel(guild, $0)
                },
                setNotificationToggle: { toggle, isEnabled in
                    contextMenuActions.setNotificationToggle(
                        guild,
                        toggle,
                        isEnabled
                    )
                },
                copyServerID: {
                    ChannelContextMenuValue.copy(guild.id.description)
                },
                leaveServer: guild.isOwnedByCurrentUser == false && !guild.isUnavailable
                    ? { contextMenuActions.leaveServer(guild) } : nil,
                showsAllChannels: { contextMenuActions.showsAllChannels(guild) },
                setShowsAllChannels: { contextMenuActions.setShowsAllChannels(guild, $0) }
            )
        }
        .accessibilityLabel(displayName)
        .accessibilityValue(
            guild.mentionCount > 0
                ? "\(guild.mentionCount) unread mentions"
                : (guild.unreadCount > 0 ? "Unread" : "")
        )
        .help(displayName)
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onScrollVisibilityChange(threshold: 0.01) { iconIsVisible = $0 }
        .onModalHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

private struct ServerRailHoverLabel: View {
    let name: String
    let maximumWidth: CGFloat

    var body: some View {
        Text(name)
            .font(.interface(.callout).weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, InterfaceScale.metric(11))
            .frame(maxWidth: maximumWidth)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: InterfaceScale.metric(32))
            .glassEffect(.regular, in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ServerRailHoverItem {
    let name: String
    let bounds: Anchor<CGRect>
}

struct ServerRailHoverPreferenceKey: PreferenceKey {
    static let defaultValue: ServerRailHoverItem? = nil

    static func reduce(value: inout ServerRailHoverItem?, nextValue: () -> ServerRailHoverItem?) {
        value = nextValue() ?? value
    }
}

private struct HomeRailButton: View {
    let home: ServerRailHomeEntry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(4)) {
                ServerRailSelectionIndicator(
                    isSelected: home.isSelected,
                    isHovering: isHovering,
                    hasNotification: false
                )
                Image(systemName: "message.fill")
                    .font(.interface(.title2))
                    .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
                    .background(
                        home.isSelected
                            ? SakuraCordAccentColor.color
                            : Color.secondary.opacity(0.16),
                        in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(13), style: .continuous)
                    )
                    .frame(width: InterfaceScale.metric(46), height: InterfaceScale.metric(46))
            }
            .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ServerRailButtonStyle())
        .accessibilityLabel("Direct Messages")
        .onModalHover { isHovering = $0 }
        .help("Direct Messages")
    }
}

struct ServerRailSelectionIndicator: View {
    let isSelected: Bool
    let isHovering: Bool
    let hasNotification: Bool
    var isVisible = true
    var animatesStateChanges = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ServerRailIndicatorShape(
            width: indicatorWidth,
            height: indicatorHeight,
            cornerRadius: InterfaceScale.metric(4)
        )
            .fill(colorScheme == .dark ? Color.white : Color.black)
            .frame(width: InterfaceScale.metric(7), height: InterfaceScale.metric(46))
            .opacity(indicatorHeight == 0 ? 0 : 1)
            .animation(reduceMotion || !animatesStateChanges ? nil : .smooth(duration: 0.22), value: CGSize(width: indicatorWidth, height: indicatorHeight))
            .transaction { $0.animation = nil }
    }

    private var indicatorWidth: CGFloat {
        indicatorHeight == 0 ? 0 : InterfaceScale.metric(4)
    }

    private var indicatorHeight: CGFloat {
        guard isVisible else { return 0 }
        if isSelected {
            return InterfaceScale.metric(42)
        }
        if isHovering {
            return InterfaceScale.metric(20)
        }
        if hasNotification {
            return InterfaceScale.metric(8)
        }
        return 0
    }
}

nonisolated private struct ServerRailIndicatorShape: Shape {
    var width: CGFloat
    var height: CGFloat
    let cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set {
            width = newValue.first
            height = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard width > 0, height > 0 else { return Path() }
        return UnevenRoundedRectangle(
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: cornerRadius
        ).path(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: width, height: height))
    }
}

extension EnvironmentValues {
    @Entry var serverRailMentionBadgesInOverlay = false
    @Entry var serverRailFolderIndicatorsInOverlay = false
    @Entry var serverRailIsDragPreview = false
}

/// Rail selection is drawn by the indicator; pressing must not tint the icon.
struct ServerRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
