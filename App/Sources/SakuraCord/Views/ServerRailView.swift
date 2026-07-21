import SakuraCordModels
import SwiftUI

struct ServerRailView: View {
    let guildsByID: [GuildID: Guild]
    let items: [GuildRailItem]
    let selectedGuildID: GuildID?
    let selectHome: () -> Void
    let selectGuild: (GuildID?) -> Void
    @State private var folderLayoutRevision = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HomeRailButton(isSelected: selectedGuildID == nil, action: selectHome)

                Divider().padding(.horizontal, 12)

                ForEach(items) { item in
                    ServerRailItemView(
                        item: item,
                        guildsByID: guildsByID,
                        selectedGuildID: selectedGuildID,
                        selectGuild: selectGuild,
                        folderExpansionChanged: {
                            folderLayoutRevision &+= 1
                        }
                    )
                }
            }
            .padding(.vertical, 12)
            .animation(ServerRailAnimations.folderExpansion, value: folderLayoutRevision)
        }
        .scrollIndicators(.hidden)
        .frame(width: ChatChromeMetrics.serverRailWidth)
        .background(.ultraThinMaterial)
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

private struct ServerRailItemView: View {
    let item: GuildRailItem
    let guildsByID: [GuildID: Guild]
    let selectedGuildID: GuildID?
    let selectGuild: (GuildID?) -> Void
    let folderExpansionChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case let .guild(id):
                if let guild = guildsByID[id] {
                    GuildRailButton(guild: guild, isSelected: selectedGuildID == guild.id) {
                        selectGuild(guild.id)
                    }
                }
            case let .folder(folder):
                ServerFolderRailView(
                    folder: folder,
                    guildsByID: guildsByID,
                    selectedGuildID: selectedGuildID,
                    selectGuild: selectGuild,
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
    let guild: Guild
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let displayName = guild.name.isEmpty ? "Unnamed Server" : guild.name

        HStack(spacing: 5) {
            ServerRailSelectionIndicator(
                isSelected: isSelected,
                isHovering: isHovering,
                hasNotification: guild.unreadCount > 0
            )
            Button(action: action) {
                GuildIconView(name: displayName, iconURL: guild.iconURL, size: 44, cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .help(displayName)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: 46, alignment: .leading)
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
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            ServerRailSelectionIndicator(isSelected: isSelected, isHovering: isHovering, hasNotification: false)
            Button(action: action) {
                Image(systemName: "message.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
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
