import SakuraCordModels
import SwiftUI

struct ServerFolderRailView: View {
    let folder: GuildFolder
    let guildsByID: [GuildID: Guild]
    let selectedGuildID: GuildID?
    let selectGuild: (GuildID?) -> Void
    let expansionChanged: () -> Void

    @AppStorage private var isExpanded: Bool
    @State private var isHovering = false

    init(
        folder: GuildFolder,
        guildsByID: [GuildID: Guild],
        selectedGuildID: GuildID?,
        selectGuild: @escaping (GuildID?) -> Void,
        expansionChanged: @escaping () -> Void
    ) {
        self.folder = folder
        self.guildsByID = guildsByID
        self.selectedGuildID = selectedGuildID
        self.selectGuild = selectGuild
        self.expansionChanged = expansionChanged
        _isExpanded = AppStorage(
            wrappedValue: false,
            "GuildFolders.\(folder.id).isExpanded"
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            folderButton

            if isExpanded {
                ExpandedFolderGuilds(
                    guildIDs: folder.guildIDs,
                    guildsByID: guildsByID,
                    selectedGuildID: selectedGuildID,
                    selectGuild: selectGuild
                )
                .transition(.offset(y: -10).combined(with: .opacity))
            }
        }
        .padding(.vertical, isExpanded ? 5 : 0)
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(folderColor.opacity(0.12))
                    .padding(.horizontal, 7)
                    .transition(.opacity)
            }
        }
    }

    private var folderButton: some View {
        HStack(spacing: 5) {
            ServerRailSelectionIndicator(
                isSelected: containsSelectedGuild,
                isHovering: isHovering,
                hasNotification: hasUnreadGuild
            )
            Button {
                withAnimation(ServerRailAnimations.folderExpansion) {
                    isExpanded.toggle()
                    expansionChanged()
                }
            } label: {
                Group {
                    if isExpanded {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(folderColor)
                            .frame(width: 44, height: 44)
                    } else {
                        collapsedPreview
                    }
                }
                .background(folderColor.opacity(isExpanded ? 0.18 : 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Toggles the server folder")
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

    private var collapsedPreview: some View {
        let preview = folder.guildIDs.prefix(4).compactMap { guildsByID[$0] }
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                previewIcon(preview[safe: 0])
                previewIcon(preview[safe: 1])
            }
            HStack(spacing: 2) {
                previewIcon(preview[safe: 2])
                previewIcon(preview[safe: 3])
            }
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private func previewIcon(_ guild: Guild?) -> some View {
        if let guild {
            GuildIconView(
                name: guild.name,
                iconURL: guild.iconURL,
                size: 18,
                cornerRadius: 5,
                animates: false
            )
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }

    private var displayName: String {
        guard let name = folder.name, !name.isEmpty else { return "Server Folder" }
        return name
    }

    private var folderColor: Color {
        Color(hex: folder.colorHex ?? 0x5865F2)
    }

    private var containsSelectedGuild: Bool {
        selectedGuildID.map(folder.guildIDs.contains) ?? false
    }

    private var hasUnreadGuild: Bool {
        folder.guildIDs.contains { guildsByID[$0]?.unreadCount ?? 0 > 0 }
    }
}

private struct ExpandedFolderGuilds: View {
    let guildIDs: [GuildID]
    let guildsByID: [GuildID: Guild]
    let selectedGuildID: GuildID?
    let selectGuild: (GuildID?) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(guildIDs, id: \.self) { guildID in
                if let guild = guildsByID[guildID] {
                    GuildRailButton(guild: guild, isSelected: selectedGuildID == guild.id) {
                        selectGuild(guild.id)
                    }
                }
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
