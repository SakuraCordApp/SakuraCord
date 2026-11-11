import SakuraCordModels
import SwiftUI

/// Discord's Favorites server channel list: uncategorised favourites, then
/// each favourites category, using the server channel list's row styling.
struct FavoritesSidebarView: View {
    let model: AppModel
    let bottomContentInset: CGFloat
    /// Collapse is local, as the official client's collapse is not saved.
    @State private var collapsedCategoryIDs: Set<ChannelID> = []

    var body: some View {
        if let settings = model.favorites.settings {
            List(selection: selection) {
                Button {
                    model.favorites.isCreatingCategory = true
                } label: {
                    HStack(spacing: InterfaceScale.metric(8)) {
                        Image(systemName: "folder.badge.plus")
                            .fontWeight(.medium)
                            .frame(width: ChannelSidebarLayoutMetrics.iconWidth)
                        Text("Create Category")
                            .font(.interfaceSystem(size: 14, weight: .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
                .selectionDisabled()
                ForEach(settings.sections) { section in
                    if let category = section.category {
                        Section {
                            if !collapsedCategoryIDs.contains(category.id) { rows(section) }
                        } header: {
                            categoryHeader(category)
                        }
                    } else {
                        rows(section)
                    }
                }
                if model.favoriteConversations().isEmpty {
                    Text("Right-click any channel or DM and choose Add to Favorites.")
                        .font(.interface(.callout))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, InterfaceScale.metric(6))
                        .selectionDisabled()
                }
                SidebarBottomScrollSpacer(height: bottomContentInset)
            }
        } else {
            // Settings load with the session; the rows wait like a server's.
            VStack(alignment: .leading, spacing: InterfaceScale.metric(14)) {
                ForEach(0 ..< 6, id: \.self) { index in
                    SkeletonShape(cornerRadius: InterfaceScale.metric(4))
                        .frame(width: InterfaceScale.metric(index.isMultiple(of: 2) ? 140 : 110), height: InterfaceScale.metric(12))
                }
            }
            .padding(InterfaceScale.metric(18))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel("Loading Favorites")
        }
    }

    private var selection: Binding<ChannelID?> {
        Binding(
            get: { model.presentedFavoriteChannelID },
            set: { id in
                guard let id, id != model.presentedFavoriteChannelID,
                      let favorite = model.favoriteConversations().first(where: { $0.id == id })
                else { return }
                model.selectFavorite(favorite)
            }
        )
    }

    @ViewBuilder
    private func rows(_ section: FavoritesSettings.Section) -> some View {
        ForEach(section.entries.compactMap(model.favoriteConversation)) { favorite in
            FavoriteRow(model: model, favorite: favorite, isSelected: model.presentedFavoriteChannelID == favorite.id)
                .tag(favorite.id)
        }
    }

    private func categoryHeader(_ category: FavoritesSettings.Entry) -> some View {
        let isCollapsed = collapsedCategoryIDs.contains(category.id)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if isCollapsed { collapsedCategoryIDs.remove(category.id) } else { collapsedCategoryIDs.insert(category.id) }
            }
        } label: {
            HStack(spacing: InterfaceScale.metric(5)) {
                Text(category.nickname)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.interface(.caption2).weight(.semibold))
                    .frame(width: InterfaceScale.metric(8))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary.opacity(0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interfaceFontOverride(.interface(.subheadline).weight(.bold))
        .help(isCollapsed ? "Expand \(category.nickname)" : "Collapse \(category.nickname)")
        .contextMenu {
            Button("Rename Category…", systemImage: "pencil") { model.favorites.renaming = category }
            Button("Delete Category", systemImage: "trash", role: .destructive) {
                model.updateFavorites(.remove(category.id))
            }
        }
    }
}

private struct FavoriteRow: View {
    let model: AppModel
    let favorite: FavoriteConversation
    let isSelected: Bool

    var body: some View {
        let channel = favorite.channel
        let mentions = model.readState.mentions(channelID: favorite.id)
        let isMuted = model.isChannelMuted(channel)
        let showsUnread = model.readState.unread(channelID: favorite.id) && !isMuted
        HStack(spacing: InterfaceScale.metric(8)) {
            icon
                .frame(width: ChannelSidebarLayoutMetrics.iconWidth)
            Text(favorite.name)
                .font(.interfaceSystem(size: 14, weight: showsUnread ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if mentions > 0 { SidebarMentionBadge(count: mentions) }
        }
        .foregroundStyle(isSelected || showsUnread ? Color.primary : isMuted ? .primary.opacity(0.32) : .primary.opacity(0.7))
        .mentionBadgeMotion(mentions)
        .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
        .accessibilityElement(children: .combine)
        .accessibilityValue(mentions > 0 ? "\(mentions) unread mentions" : showsUnread ? "Unread" : "")
        .overlay {
            ChannelContextMenuBridge(
                isSelected: isSelected,
                isUnread: showsUnread || mentions > 0,
                isMutationPending: model.isChannelNotificationMutationPending(channel.id),
                directOverride: model.channelNotificationOverride(for: channel),
                inheritedLevel: model.inheritedChannelNotificationLevel(for: channel),
                inheritanceSource: channel.guildID == nil ? .directMessages : channel.categoryID == nil ? .server : .category,
                markRead: { model.markConversationRead(channelID: channel.id) },
                mute: { model.setChannelMute(true, until: $0.endDate(), for: channel) },
                unmute: { model.setChannelMute(false, until: nil, for: channel) },
                setNotificationLevel: { model.setChannelNotificationLevel($0, for: channel) },
                copyChannelID: { ChannelContextMenuValue.copy(channel.id.description) },
                copyLink: {
                    ChannelContextMenuValue.copy(ChannelContextMenuValue.link(guildID: channel.guildID, channelID: channel.id))
                },
                favoriteItems: { FavoritesMenu.manageItems(for: favorite, model: model) }
            )
        }
    }

    @ViewBuilder private var icon: some View {
        let channel = favorite.channel
        if channel.guildID == nil {
            DirectMessageAvatar(channel: channel, size: InterfaceScale.metric(20), status: nil, animates: false)
        } else {
            Image(systemName: favorite.thread != nil ? "text.bubble.fill"
                : favorite.entry.channelType == 13 ? "person.wave.2.fill"
                : ChannelIconPresentation.systemImage(for: channel, isHidden: false, rulesChannelID: nil))
                .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
                .fontWeight(.medium)
        }
    }
}
