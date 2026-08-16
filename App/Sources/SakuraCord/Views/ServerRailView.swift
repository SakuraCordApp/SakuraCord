import SakuraCordModels
import SwiftUI

struct ServerRailGuildPresentation: Equatable, Identifiable {
    let guild: Guild
    let notificationSettings: GuildNotificationSettings
    let isNotificationMutationPending: Bool

    var id: GuildID { guild.id }
}

enum ServerRailPresentationItem: Equatable, Identifiable {
    case guild(id: GuildID, presentation: ServerRailGuildPresentation?)
    case folder(
        GuildFolder,
        guildsByID: [GuildID: ServerRailGuildPresentation]
    )

    var id: GuildRailItem.RailIdentifier {
        switch self {
        case .guild(let id, _): .guild(id)
        case .folder(let folder, _): .folder(folder.id)
        }
    }

    static func make(
        items: [GuildRailItem],
        guildsByID: [GuildID: Guild],
        notificationSettings: (Guild) -> GuildNotificationSettings,
        isMutationPending: (GuildID) -> Bool
    ) -> [Self] {
        AppPerformanceSignposts.measureSync("ServerRailProjection") {
            items.map { item in
                switch item {
                case .guild(let id):
                    .guild(
                        id: id,
                        presentation: guildsByID[id].map { guild in
                            ServerRailGuildPresentation(
                                guild: guild,
                                notificationSettings:
                                    notificationSettings(guild),
                                isNotificationMutationPending:
                                    isMutationPending(id)
                            )
                        }
                    )
                case .folder(let folder):
                    .folder(
                        folder,
                        guildsByID: Dictionary(
                            uniqueKeysWithValues:
                                folder.guildIDs.compactMap { id in
                                    guildsByID[id].map { guild in
                                        (
                                            id,
                                            ServerRailGuildPresentation(
                                                guild: guild,
                                                notificationSettings:
                                                    notificationSettings(guild),
                                                isNotificationMutationPending:
                                                    isMutationPending(id)
                                            )
                                        )
                                    }
                                }
                        )
                    )
                }
            }
        }
    }
}

struct ServerRailView: View {
    let items: [ServerRailPresentationItem]
    let selectedGuildID: GuildID?
    let homeIsUnread: Bool
    let homeMentionCount: Int
    let selectHome: () -> Void
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    @State private var folderLayoutRevision = 0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HomeRailButton(
                    isSelected: selectedGuildID == nil,
                    isUnread: homeIsUnread,
                    mentionCount: homeMentionCount,
                    action: selectHome
                )

                Divider().padding(.horizontal, 12)

                ForEach(items) { item in
                    ServerRailItemView(
                        item: item,
                        selectedGuildID: selectedGuildID,
                        selectGuild: selectGuild,
                        contextMenuActions: contextMenuActions,
                        folderExpansionChanged: {
                            folderLayoutRevision &+= 1
                        }
                    )
                    .equatable()
                }
            }
            .padding(.bottom, 12)
            .animation(ServerRailAnimations.folderExpansion, value: folderLayoutRevision)
        }
        .scrollIndicators(.hidden)
        .background {
            ScrollInputPerformanceProbeAttachment(surface: .serverList)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth)
        .overlayPreferenceValue(ServerRailHoverPreferenceKey.self) { hoverItem in
            GeometryReader { proxy in
                if let hoverItem {
                    ServerRailHoverLabel(name: hoverItem.name)
                        .offset(
                            x: ChatChromeMetrics.serverRailWidth + 7,
                            y: proxy[hoverItem.bounds].midY - 16
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .zIndex(200)
    }
}

struct ServerRailContextMenuActions {
    let markRead: (GuildID) -> Void
    let mute: (Guild, ChannelMuteDuration) -> Void
    let unmute: (Guild) -> Void
    let setNotificationLevel: (Guild, MessageNotificationLevel) -> Void
    let setNotificationToggle: (Guild, GuildNotificationToggle, Bool) -> Void
}

private struct ServerRailItemView: View, Equatable {
    let item: ServerRailPresentationItem
    let selectedGuildID: GuildID?
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    let folderExpansionChanged: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.selectedItemGuildID == rhs.selectedItemGuildID
    }

    private var selectedItemGuildID: GuildID? {
        guard let selectedGuildID else { return nil }
        return switch item {
        case .guild(let id, _):
            id == selectedGuildID ? id : nil
        case .folder(let folder, _):
            folder.guildIDs.contains(selectedGuildID)
                ? selectedGuildID
                : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .guild(_, let presentation):
                if let presentation {
                    GuildRailButton(
                        presentation: presentation,
                        isSelected:
                            selectedGuildID == presentation.guild.id,
                        contextMenuActions: contextMenuActions
                    ) {
                        selectGuild(presentation.guild.id)
                    }
                }
            case .folder(let folder, let guildsByID):
                ServerFolderRailView(
                    folder: folder,
                    guildsByID: guildsByID,
                    selectedGuildID: selectedGuildID,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions,
                    expansionChanged: folderExpansionChanged
                )
            }
        }
    }
}

enum ServerRailAnimations {
    static let folderExpansion = Animation.spring(duration: 0.38, bounce: 0.08)
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

        HStack(spacing: 5) {
            ServerRailSelectionIndicator(
                isSelected: isSelected,
                isHovering: isHovering,
                hasNotification: guild.unreadCount > 0
            )
            Button(action: action) {
                GuildIconView(
                    name: displayName,
                    iconURL: guild.iconURL,
                    size: 44,
                    cornerRadius: 14,
                    animates: isHovering
                )
                    .overlay(alignment: .bottomTrailing) {
                        if guild.mentionCount > 0 {
                            Text(guild.mentionCount, format: .number)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(.red, in: Capsule())
                                .offset(x: 4, y: 4)
                        }
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
                    }
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
        .frame(width: ChatChromeMetrics.serverRailWidth, height: 46, alignment: .topLeading)
        .contentShape(Rectangle())
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

private struct ServerRailHoverLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 32)
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
    let isSelected: Bool
    let isUnread: Bool
    let mentionCount: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            ServerRailSelectionIndicator(
                isSelected: isSelected,
                isHovering: isHovering,
                hasNotification: isUnread
            )
            Button(action: action) {
                Image(systemName: "message.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.16), in: ConcentricRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if mentionCount > 0 {
                            Text(mentionCount, format: .number)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(.red, in: Capsule())
                                .offset(x: 4, y: 4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Direct Messages")
            .accessibilityValue(
                mentionCount > 0
                    ? "\(mentionCount) unread mentions"
                    : (isUnread ? "Unread" : "")
            )
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: 46, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("Direct Messages")
    }
}

struct ServerRailSelectionIndicator: View {
    let isSelected: Bool
    let isHovering: Bool
    let hasNotification: Bool

    var body: some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 4, height: indicatorHeight)
            .opacity(indicatorHeight == 0 ? 0 : 1)
            .frame(width: 7, height: 40)
            .animation(.snappy(duration: 0.2), value: indicatorHeight)
    }

    private var indicatorHeight: CGFloat {
        if isSelected {
            return 36
        }
        if isHovering {
            return 20
        }
        if hasNotification {
            return 8
        }
        return 0
    }
}
