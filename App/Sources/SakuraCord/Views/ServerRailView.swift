import Observation
import SakuraCordModels
import SwiftUI

/// Keeps rail observation out of the workspace root. Timeline, member-list,
/// composer, and loading publications can invalidate `ChatRootView` without
/// rebuilding or comparing every server row.
struct ServerRailContainer: View {
    let model: AppModel
    @State private var folderSettings: GuildFolder?

    var body: some View {
        @Bindable var invites = model.serverInvites
        ServerRailView(
            items: model.serverRailPresentation.items,
            directMessages: model.serverRailPresentation.directMessages,
            home: model.serverRailPresentation.home,
            selectHome: { model.selectGuild(nil) },
            selectDirectMessage: { model.navigate(to: $0) },
            selectGuild: model.selectGuild,
            joinServer: { invites.showsJoinDialog = true },
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
    let items: [ServerRailPresentationItem]
    let directMessages: [ServerRailDirectMessageEntry]
    let home: ServerRailHomeEntry
    let selectHome: () -> Void
    let selectDirectMessage: (ChannelID) -> Void
    let selectGuild: (GuildID?) -> Void
    var joinServer: () -> Void = {}
    var moveItems: ([GuildRailItem.RailIdentifier], GuildRailDestination) -> Void = { _, _ in }
    var combineGuilds: (GuildID, GuildID) -> Void = { _, _ in }
    let contextMenuActions: ServerRailContextMenuActions
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
                }

                Divider().padding(.horizontal, InterfaceScale.metric(12))

                ForEach(items) { item in
                    ServerRailItemView(
                        item: item,
                        selectGuild: selectDraggableGuild,
                        contextMenuActions: contextMenuActions,
                        folderExpansionChanged: {
                            folderLayoutRevision &+= 1
                        }
                    )
                }
                Button(action: joinServer) {
                    Image(systemName: "plus").font(.interfaceSystem(size: 22, weight: .medium))
                        .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
                        .foregroundStyle(.green)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: InterfaceScale.metric(16)))
                }
                .buttonStyle(.plain)
                .help("Add a Server")
                .accessibilityLabel("Add a Server")
                .accessibilityIdentifier("add-server")
            }
            .padding(.bottom, InterfaceScale.metric(12))
            .animation(ServerRailAnimations.folderExpansion, value: folderLayoutRevision)
        }
        // Unlike .hidden, .never overrides macOS's always-visible scrollbar preference.
        .scrollIndicators(.never)
        .background {
            ScrollInputPerformanceProbeAttachment(surface: .serverList)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth)
        .overlayPreferenceValue(ServerRailHoverPreferenceKey.self) { hoverItem in
            GeometryReader { proxy in
                if let hoverItem, drag.draggedID == nil {
                    ServerRailHoverLabel(name: hoverItem.name)
                        .offset(
                            x: ChatChromeMetrics.serverRailWidth + 7,
                            y: proxy[hoverItem.bounds].midY - 16
                        )
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
                    preview: dragPreview
                )
            }
            .allowsHitTesting(false)
        }
        .zIndex(200)
        .environment(drag)
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
                ServerRailGuildItemView(entry: entry, selectGuild: { _ in }, contextMenuActions: contextMenuActions)
            }
        case .folder:
            if let entry = items.lazy.compactMap({ item -> ServerRailFolderEntry? in
                if case .folder(let entry) = item, entry.id == id { entry } else { nil }
            }).first {
                ServerFolderRailHeader(
                    entry: entry,
                    isExpanded: UserDefaults.standard.bool(forKey: ServerFolderRailView.expansionKey(entry.folder.id)),
                    contextMenuActions: contextMenuActions,
                    toggle: {}
                )
            }
        }
    }
}

private struct DirectMessageRailButton: View {
    let entry: ServerRailDirectMessageEntry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let channel = entry.channel
        let displayName = channel.name.isEmpty ? "Group Direct Message" : channel.name

        HStack(spacing: InterfaceScale.metric(5)) {
            ServerRailSelectionIndicator(
                isSelected: entry.isSelected,
                isHovering: isHovering,
                hasNotification: true
            )
            Button(action: action) {
                ServerRailBadgedIcon(mentionCount: channel.mentionCount) {
                    DirectMessageAvatar(
                        channel: channel,
                        size: InterfaceScale.metric(44),
                        status: nil,
                        animates: true,
                        isHovered: isHovering
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .accessibilityValue(
                channel.mentionCount > 0
                    ? "\(channel.mentionCount) unread mentions"
                    : "Unread"
            )
            .help(displayName)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .topLeading)
        .contentShape(Rectangle())
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onModalHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

struct ServerRailBadgedIcon<Icon: View>: View {
    let mentionCount: Int
    let icon: Icon

    init(mentionCount: Int, @ViewBuilder icon: () -> Icon) {
        self.mentionCount = mentionCount
        self.icon = icon()
    }

    var body: some View {
        if mentionCount > 0 {
            icon
                .overlay(alignment: .bottomTrailing) {
                    badge
                        .padding(InterfaceScale.metric(2))
                        .background(.black, in: Capsule())
                        .offset(x: InterfaceScale.metric(6), y: InterfaceScale.metric(6))
                        .blendMode(.destinationOut)
                        .accessibilityHidden(true)
                }
                .compositingGroup()
                .overlay(alignment: .bottomTrailing) {
                    badge.offset(x: InterfaceScale.metric(4), y: InterfaceScale.metric(4))
                }
        } else {
            icon
        }
    }

    private var badge: some View {
        Text(mentionCount, format: .number)
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

    var body: some View {
        if let presentation = entry.presentation {
            GuildRailButton(
                presentation: presentation,
                isSelected: entry.isSelected,
                contextMenuActions: contextMenuActions
            ) {
                selectGuild(entry.id)
            }
        }
    }
}

enum ServerRailAnimations {
    static let folderExpansion = Animation.spring(duration: 0.38, bounce: 0.08)
    static let reorder = Animation.snappy(duration: 0.28)
}

struct GuildRailButton: View {
    let presentation: ServerRailGuildPresentation
    let isSelected: Bool
    let contextMenuActions: ServerRailContextMenuActions
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let guild = presentation.guild
        let displayName = guild.name.isEmpty ? "Unnamed Server" : guild.name

        HStack(spacing: InterfaceScale.metric(5)) {
            ServerRailSelectionIndicator(
                isSelected: isSelected,
                isHovering: isHovering,
                hasNotification: guild.unreadCount > 0
            )
            Button(action: action) {
                ServerRailBadgedIcon(mentionCount: guild.mentionCount) {
                    GuildIconView(
                        name: displayName,
                        iconURL: guild.iconURL,
                        size: InterfaceScale.metric(44),
                        cornerRadius: InterfaceScale.metric(14),
                        animates: isHovering,
                        isSelected: isSelected
                    )
                }
            }
            .buttonStyle(.plain)
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
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .topLeading)
        .contentShape(Rectangle())
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onModalHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

private struct ServerRailHoverLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.interface(.callout).weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, InterfaceScale.metric(11))
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
        HStack(spacing: InterfaceScale.metric(5)) {
            ServerRailSelectionIndicator(
                isSelected: home.isSelected,
                isHovering: isHovering,
                hasNotification: false
            )
            Button(action: action) {
                Image(systemName: "message.fill")
                    .font(.interface(.title2))
                    .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
                    .background(
                        home.isSelected
                            ? SakuraCordAccentColor.color
                            : Color.secondary.opacity(0.16),
                        in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Direct Messages")
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .leading)
        .contentShape(Rectangle())
        .onModalHover { isHovering = $0 }
        .help("Direct Messages")
    }
}

struct ServerRailSelectionIndicator: View {
    let isSelected: Bool
    let isHovering: Bool
    let hasNotification: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(colorScheme == .dark ? Color.white : Color.black)
            .frame(width: InterfaceScale.metric(4), height: indicatorHeight)
            .opacity(indicatorHeight == 0 ? 0 : 1)
            .frame(width: InterfaceScale.metric(7), height: InterfaceScale.metric(40))
            .animation(.snappy(duration: 0.2), value: indicatorHeight)
    }

    private var indicatorHeight: CGFloat {
        if isSelected {
            return InterfaceScale.metric(36)
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
