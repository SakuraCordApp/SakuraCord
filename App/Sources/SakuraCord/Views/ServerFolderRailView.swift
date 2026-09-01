import SakuraCordModels
import SwiftUI

struct ServerFolderRailView: View {
    let entry: ServerRailFolderEntry
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    let expansionChanged: () -> Void

    @AppStorage private var isExpanded: Bool
    @State private var isHovering = false

    init(
        entry: ServerRailFolderEntry,
        selectGuild: @escaping (GuildID?) -> Void,
        contextMenuActions: ServerRailContextMenuActions,
        expansionChanged: @escaping () -> Void
    ) {
        self.entry = entry
        self.selectGuild = selectGuild
        self.contextMenuActions = contextMenuActions
        self.expansionChanged = expansionChanged
        _isExpanded = AppStorage(
            wrappedValue: false,
            "GuildFolders.\(entry.folder.id).isExpanded"
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            folderButton

            if isExpanded {
                ExpandedFolderGuilds(
                    guildEntries: entry.guildEntries,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions
                )
                .transition(.offset(y: -10).combined(with: .opacity))
            }
        }
        .padding(.vertical, isExpanded ? 5 : 0)
        .background {
            if isExpanded {
                ConcentricRectangle(cornerRadius: 18, style: .continuous)
                    .fill(folderColor.opacity(0.12))
                    .padding(.horizontal, 7)
                    .transition(.opacity)
            }
        }
    }

    private var folderButton: some View {
        HStack(spacing: 5) {
            ServerRailSelectionIndicator(
                isSelected: entry.containsSelectedGuild,
                isHovering: isHovering,
                hasNotification: showsUnreadIndicators && entry.hasUnreadGuild
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
                .clipShape(ConcentricRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if showsUnreadIndicators, entry.mentionCount > 0 {
                        Text(entry.mentionCount, format: .number)
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
            .accessibilityLabel(displayName)
            .accessibilityValue(
                "\(isExpanded ? "Expanded" : "Collapsed")"
                    + (showsUnreadIndicators && entry.mentionCount > 0
                        ? ", \(entry.mentionCount) unread mentions" : "")
                    + (showsUnreadIndicators && entry.mentionCount == 0
                        && entry.hasUnreadGuild ? ", Unread" : "")
            )
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
        let preview = entry.previewGuilds
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
        guard let name = entry.folder.name, !name.isEmpty else { return "Server Folder" }
        return name
    }

    private var showsUnreadIndicators: Bool {
        !isExpanded
    }

    private var folderColor: Color {
        Color(hex: entry.folder.colorHex ?? 0x5865F2)
    }
}

private struct ExpandedFolderGuilds: View {
    let guildEntries: [ServerRailGuildEntry]
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions

    var body: some View {
        VStack(spacing: 8) {
            ForEach(guildEntries) { entry in
                ServerRailGuildItemView(
                    entry: entry,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions
                )
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
