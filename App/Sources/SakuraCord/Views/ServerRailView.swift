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
        let joinRequests = model.guildJoinRequests
        ServerRailView(
            sidebarWidth: sidebarWidth,
            items: model.serverRailPresentation.items,
            directMessages: model.serverRailPresentation.directMessages,
            joinRequests: model.pendingApplications.map { request in
                ServerRailJoinRequestEntry(id: request.guildID, name: model.joinRequestGuildName(request.guildID),
                                           iconURL: model.joinRequestGuildIconURL(request.guildID),
                                           status: request.status,
                                           isSelected: joinRequests.selectedGuildID == request.guildID)
            },
            joinRequestsExpanded: Bindable(joinRequests).isFolderExpanded,
            showsSubmittedTip: Bindable(joinRequests).showsSubmittedTip,
            selectJoinRequest: model.selectGuildJoinRequest,
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
            voicePreview: model.serverRailVoicePreview(for:),
            resolveVoiceParticipants: { guildID, userIDs in
                await model.resolveServerRailVoiceParticipants(userIDs, in: guildID)
            },
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
                     isConcealed: { model.captcha.challenge != nil }, content: { JoinServerView(model: model) })
        .windowModal(item: Bindable(invites.creation).presentation, cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) {
            ServerInviteCreationView(model: model, presentation: $0)
        }
        .windowModal(item: Binding(
            get: { joinRequests.modal },
            set: { modal in
                // However the approval greeting closes, it is acknowledged like the official one.
                if modal == nil, let current = joinRequests.modal, current.kind == .welcome {
                    model.finishGuildJoinApproval(current.guildID)
                } else {
                    joinRequests.modal = modal
                    model.showGuildJoinApprovalIfNeeded()
                }
            }
        ), cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular, isConcealed: { model.captcha.challenge != nil },
        content: { GuildJoinApplicationView(model: model, modal: $0) })
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
    var joinRequests: [ServerRailJoinRequestEntry] = []
    var joinRequestsExpanded: Binding<Bool> = .constant(false)
    var showsSubmittedTip: Binding<Bool> = .constant(false)
    var selectJoinRequest: (GuildID?) -> Void = { _ in }
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
    var voicePreview: (GuildID) -> ServerRailVoicePreview? = { _ in nil }
    var resolveVoiceParticipants: (GuildID, [UserID]) async -> Void = { _, _ in }
    let contextMenuActions: ServerRailContextMenuActions
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }
    @State private var folderLayoutRevision = 0
    @State private var drag = ServerRailDragController()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var staysAtTop = true

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

                if !joinRequests.isEmpty {
                    PendingApplicationsRailFolder(entries: joinRequests, isExpanded: joinRequestsExpanded,
                                                  showsSubmittedTip: showsSubmittedTip, select: { selectJoinRequest($0) })
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
            // Pending Applications also opens without a click, when an application is submitted; the rows below
            // move with it.
            .animation(reduceMotion ? nil : ServerRailAnimations.folderExpansion, value: joinRequestsExpanded.wrappedValue)
            .animation(reduceMotion ? nil : ServerRailAnimations.reorder, value: directMessages.map(\.id))
            .animation(reduceMotion ? nil : ServerRailAnimations.reorder, value: joinRequests.map(\.id))
            .animation(reduceMotion ? nil : ServerRailAnimations.reorder, value: items.map(\.id))
            .animation(reduceMotion ? nil : ServerRailAnimations.reorder, value: folderGuildIDs)
        }
        .onScrollPhaseChange { _, phase in
            if drag.isScrolling != phase.isScrolling { drag.isScrolling = phase.isScrolling }
        }
        // Unlike .hidden, .never overrides macOS's always-visible scrollbar preference.
        .scrollIndicators(.never)
        // SwiftUI keeps a visible row in place when rows appear above it, such as the Pending Applications folder,
        // which scrolls Home out of view. A rail the user left at the top returns there.
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < 1 } action: { _, isAtTop in
            if drag.isScrolling || drag.draggedID != nil {
                staysAtTop = isAtTop
            } else if staysAtTop, !isAtTop {
                scrollPosition.scrollTo(edge: .top)
            }
        }
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
                        guildID: hoverItem.guildID,
                        isMuted: hoverItem.isMuted,
                        maximumWidth: max(0, sidebarWidth - ChatChromeMetrics.serverRailWidth - 7 - InterfaceScale.metric(16)),
                        voicePreview: voicePreview,
                        resolveVoiceParticipants: resolveVoiceParticipants
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
                    isExpanded: UserDefaults.standard.bool(forKey: ServerFolderRailView.expansionKey(entry.folder.id)),
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
        .onServerRailHover { isHovering = $0 }
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
        .onServerRailHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

struct ServerRailJoinRequestEntry: Identifiable, Equatable {
    let id: GuildID
    let name: String
    let iconURL: URL?
    let status: GuildJoinRequest.Status
    let isSelected: Bool
}

/// Unapproved applications, grouped like Discord's Pending Applications folder. It opens and closes like the
/// server folders: the tile grows into the folder's container and the applications unroll beneath it.
private struct PendingApplicationsRailFolder: View {
    let entries: [ServerRailJoinRequestEntry]
    @Binding var isExpanded: Bool
    @Binding var showsSubmittedTip: Bool
    let select: (GuildID) -> Void
    @State private var isHovering = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }

    var body: some View {
        VStack(spacing: isExpanded ? InterfaceScale.metric(ServerFolderRailMetrics.guildSpacing) : 0) {
            Button {
                // Like the server folders' header, a click animates explicitly: a pointer click does not carry the
                // rail's implicit animation to the header.
                withAnimation(reduceMotion ? nil : ServerRailAnimations.folderExpansion) { isExpanded.toggle() }
            } label: {
                HStack(spacing: InterfaceScale.metric(4)) {
                    ServerRailSelectionIndicator(isSelected: !isExpanded && entries.contains(where: \.isSelected),
                                                 isHovering: isHovering && !isExpanded, hasNotification: false)
                    Image(systemName: "hourglass")
                        .font(.interfaceSystem(size: 19, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: InterfaceScale.metric(46), height: InterfaceScale.metric(46))
                }
                .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ServerRailButtonStyle())
            .accessibilityLabel("Pending Applications")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help("Pending Applications")
            .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
                isHovering ? ServerRailHoverItem(name: "Pending Applications", bounds: bounds) : nil
            }
            .onServerRailHover { isHovering = $0 }
            // A popover hosts its anchor in AppKit, which moves without the folder's animation; anchoring it on
            // an empty background keeps the visible header in the animated layout.
            .background { Color.clear.popover(isPresented: $showsSubmittedTip, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                    Text("Your application is pending!").font(.interface(.headline))
                    Text("The server admin will get back to you soon.").font(.interface(.callout)).foregroundStyle(.secondary)
                    Button("Got it") { showsSubmittedTip = false }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .tint(SakuraCordAccentColor.color)
                        .frame(maxWidth: .infinity)
                        .padding(.top, InterfaceScale.metric(6))
                }
                .padding(InterfaceScale.metric(14))
                .frame(width: InterfaceScale.metric(260))
            } }
            VStack(spacing: InterfaceScale.metric(ServerFolderRailMetrics.guildSpacing)) {
                ForEach(entries) { entry in
                    JoinRequestRailButton(entry: entry) { select(entry.id) }
                        .transition(ServerRailAnimations.membershipTransition)
                }
            }
            // The last status badge hangs below its row; the reveal keeps it whole.
            .padding(.bottom, InterfaceScale.metric(6))
            .modifier(ServerFolderRowsReveal(isExpanded: isExpanded))
            .padding(.bottom, -InterfaceScale.metric(6))
        }
        .padding(.vertical, isExpanded ? InterfaceScale.metric(ServerFolderRailMetrics.expandedPadding) : 0)
        .background {
            // The collapsed tile is the container, which grows into the open folder's outline.
            GeometryReader { geometry in
                let verticalInset = 3 / displayScale
                let tile = InterfaceScale.metric(44)
                let width = isExpanded ? InterfaceScale.metric(ServerFolderRailMetrics.containerSize) : tile
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(isExpanded ? 17 : 13), style: .continuous)
                    .fill(Color.gray.opacity(isExpanded ? 0.12 : 0.18))
                    .overlay {
                        ConcentricRectangle(cornerRadius: InterfaceScale.metric(17) - 0.5, style: .continuous)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                            .padding(0.5)
                            .opacity(isExpanded ? 1 : 0)
                    }
                    .frame(width: width, height: isExpanded ? max(0, geometry.size.height - verticalInset * 2) : tile)
                    .offset(x: (geometry.size.width - width) / 2, y: isExpanded ? verticalInset : InterfaceScale.metric(1))
            }
            .allowsHitTesting(false)
        }
    }
}

private struct JoinRequestRailButton: View {
    let entry: ServerRailJoinRequestEntry
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }

    var body: some View {
        let label = "\(entry.name), \(entry.status.membershipDescription)"
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(4)) {
                ServerRailSelectionIndicator(isSelected: entry.isSelected, isHovering: isHovering, hasNotification: false)
                GuildIconView(name: entry.name, iconURL: entry.iconURL, size: InterfaceScale.metric(44),
                              cornerRadius: InterfaceScale.metric(13), animates: isHovering, isSelected: entry.isSelected)
                    .saturation(0.4)
                    .modifier(ApplicationStatusBadge(symbol: entry.status == .rejected ? "xmark" : "hourglass",
                                                     tint: entry.status == .rejected ? Color(hex: 0xF23F43) : .gray,
                                                     diameter: 18, offset: 4, isHidden: entry.status == .started))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: entry.status)
                    .frame(width: InterfaceScale.metric(46), height: InterfaceScale.metric(46))
            }
            .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ServerRailButtonStyle())
        .accessibilityLabel(label)
        .help(label)
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: label, bounds: bounds) : nil
        }
        .onServerRailHover { isHovering = $0 }
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
        // One structure with or without a badge, so the icon keeps its
        // identity while a badge comes and goes.
        icon
            .overlay(alignment: .bottomTrailing) {
                ServerRailMentionBadge(count: mentionCount, isCutout: true)
                    .offset(x: InterfaceScale.metric(badgeOffset + 2), y: InterfaceScale.metric(badgeOffset + 2))
                    .blendMode(.destinationOut)
                    .accessibilityHidden(true)
            }
            .compositingGroup()
            .overlay(alignment: .bottomTrailing) {
                ServerRailMentionBadge(count: mentionCount)
                    .opacity(drawsBadgeInOverlay ? 0 : 1)
                    .offset(x: InterfaceScale.metric(badgeOffset), y: InterfaceScale.metric(badgeOffset))
            }
    }
}

/// A status glyph in a disc on an icon's corner. The icon is cut away around the disc, so whatever surface
/// the icon rests on shows through, as with the rail's mention badges.
struct ApplicationStatusBadge: ViewModifier {
    let symbol: String
    let tint: Color
    /// Unscaled points, like the offset.
    let diameter: CGFloat
    let offset: CGFloat
    /// Discord shows no badge on an unsubmitted application; the badge shrinks away rather than popping.
    var isHidden = false

    func body(content: Content) -> some View {
        let gap = InterfaceScale.metric(2)
        let scale = isHidden ? 0.01 : 1
        let diameter = InterfaceScale.metric(diameter)
        let offset = InterfaceScale.metric(offset)
        content
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .frame(width: diameter + gap * 2, height: diameter + gap * 2)
                    .scaleEffect(scale)
                    .offset(x: offset + gap, y: offset + gap)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.interfaceSystem(size: self.diameter / 2, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: diameter, height: diameter)
                    .background(tint, in: Circle())
                    .scaleEffect(scale)
                    .offset(x: offset, y: offset)
            }
    }
}

/// A rail icon's mention count, empty at zero. A cutout is the badge's
/// slightly larger silhouette, which `.destinationOut` cuts from the icon
/// behind the badge; both run the same motion, so they stay in step.
struct ServerRailMentionBadge: View {
    let count: Int
    var isCutout = false

    var body: some View {
        ZStack {
            if count > 0 {
                let badge = Text(count, format: .number)
                    .font(.interfaceSystem(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(count)))
                    .padding(.horizontal, InterfaceScale.metric(5))
                    .frame(minWidth: InterfaceScale.metric(18), minHeight: InterfaceScale.metric(18))
                    .background(Color(hex: MentionRed.hex), in: Capsule())
                if isCutout {
                    badge
                        .padding(InterfaceScale.metric(2))
                        .background(.black, in: Capsule())
                        .transition(MentionBadgeMotion.transition)
                } else {
                    badge.transition(MentionBadgeMotion.transition)
                }
            }
        }
        .mentionBadgeMotion(count)
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
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }
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
            isHovering
                ? ServerRailHoverItem(
                    name: displayName,
                    guildID: guild.id,
                    isMuted: presentation.notificationSettings.isMuted
                        && (presentation.notificationSettings.muteConfiguration?.isActive() ?? true),
                    bounds: bounds
                )
                : nil
        }
        .onScrollVisibilityChange(threshold: 0.01) { iconIsVisible = $0 }
        .onServerRailHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

private struct ServerRailHoverLabel: View {
    let name: String
    let guildID: GuildID?
    let isMuted: Bool
    let maximumWidth: CGFloat
    // Called here rather than by the rail so voice-state changes re-render
    // only the visible card.
    let voicePreview: (GuildID) -> ServerRailVoicePreview?
    let resolveVoiceParticipants: (GuildID, [UserID]) async -> Void

    var body: some View {
        content
            // Centre the label or card on the hovered row, whatever its height.
            .frame(height: 32)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        let voice = guildID.flatMap(voicePreview)
        if voice != nil || isMuted {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    title
                    if isMuted {
                        Text("Muted")
                            .font(.interface(.subheadline).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let voice {
                    ServerRailVoicePreviewRow(preview: voice)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(11))
            .padding(.vertical, InterfaceScale.metric(9))
            .frame(maxWidth: maximumWidth, alignment: .leading)
            .fixedSize()
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous)
            )
            // Runs each time the card opens. Keyed by guild too: moving between
            // guilds that show the same users must still read the new guild's.
            .task(id: VoiceResolution(guildID: guildID, userIDs: voice?.providerUserIDs ?? [])) {
                guard let guildID, let userIDs = voice?.providerUserIDs else { return }
                await resolveVoiceParticipants(guildID, userIDs)
            }
        } else {
            title
                .padding(.horizontal, InterfaceScale.metric(11))
                .frame(maxWidth: maximumWidth)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: InterfaceScale.metric(32))
                .glassEffect(.regular, in: Capsule())
        }
    }

    private struct VoiceResolution: Hashable {
        let guildID: GuildID?
        let userIDs: [UserID]
    }

    private var title: some View {
        Text(name)
            .font(.interface(.callout).weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A speaker, the first participants' overlapping avatars and a count of the
/// rest. Each avatar is cut away beneath the one that overlaps it.
private struct ServerRailVoicePreviewRow: View {
    let preview: ServerRailVoicePreview

    private var avatarSize: CGFloat { InterfaceScale.metric(24) }
    private var overlap: CGFloat { InterfaceScale.metric(6) }
    private var cutoutGap: CGFloat { InterfaceScale.metric(2) }

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.interfaceSystem(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: -overlap) {
                ForEach(Array(preview.participants.enumerated()), id: \.element.id) { index, participant in
                    let isOverlapped = index < preview.participants.count - 1 || preview.overflowCount > 0
                    avatar(participant)
                        .mask { cutout(isActive: isOverlapped) }
                }
                if preview.overflowCount > 0 {
                    Text("+\(preview.overflowCount.formatted())")
                        .font(.interfaceSystem(size: 11, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, InterfaceScale.metric(7))
                        .frame(minWidth: avatarSize, minHeight: avatarSize)
                        .background(Color.secondary.opacity(0.25), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func avatar(_ participant: ServerRailVoiceParticipant) -> some View {
        if let name = participant.name {
            AvatarView(name: name, url: participant.avatarURL, size: avatarSize, animates: false)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: avatarSize, height: avatarSize)
        }
    }

    /// The avatar's full square, less a slightly larger circle where the
    /// next avatar or count starts.
    private func cutout(isActive: Bool) -> some View {
        Rectangle()
            .overlay(alignment: .leading) {
                Circle()
                    .frame(width: avatarSize + cutoutGap * 2, height: avatarSize + cutoutGap * 2)
                    .offset(x: avatarSize - overlap - cutoutGap)
                    .opacity(isActive ? 1 : 0)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }
}

struct ServerRailHoverItem {
    let name: String
    var guildID: GuildID?
    var isMuted = false
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
        .onServerRailHover { isHovering = $0 }
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
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.reducesSidebarMotion) private var reducesSidebarMotion
    private var reduceMotion: Bool { systemReducesMotion || reducesSidebarMotion }

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

extension View {
    /// Hover for a server rail row, which ignores the pointer arriving over
    /// it while the rail scrolls.
    func onServerRailHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(ServerRailHover(action: action))
    }
}

private struct ServerRailHover: ViewModifier {
    let action: (Bool) -> Void
    @Environment(ServerRailDragController.self) private var drag
    @State private var pointer = ServerRailPointer()

    func body(content: Content) -> some View {
        content
            .onModalHover { isInside in
                pointer.isInside = isInside
                if !isInside || !drag.isScrolling { action(isInside) }
            }
            .onChange(of: drag.isScrolling) { _, isScrolling in
                if !isScrolling, pointer.isInside { action(true) }
            }
    }
}

/// Where the pointer is over a rail row, kept out of view state so
/// following it while the rail scrolls re-renders nothing.
final class ServerRailPointer {
    var isInside = false
    var location: CGPoint?
}

/// Rail selection is drawn by the indicator; pressing must not tint the icon.
struct ServerRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
