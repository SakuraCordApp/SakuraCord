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
        if let settings = model.displayedFavorites {
            // Discord's first-run sidebar: no favourite shown and no category.
            let isEmpty = settings.categories.isEmpty
                && !settings.entries.contains { !$0.isCategory && model.favoriteConversation($0) != nil }
            List(selection: selection) {
                FavoriteSuggestionsSection(model: model)
                if isEmpty { FavoritesEmptySidebarHint(model: model) }
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
                SidebarBottomScrollSpacer(height: bottomContentInset)
            }
            .modifier(ChannelSidebarListStyle())
            .background { if model.favorites.isPresented { ListBackgroundMenuBridge { FavoritesMenu.listMenu(model: model) } } }
            .padding(.top, ChatChromeMetrics.channelListTopPadding)
            .clipped()
            // Discord recomputes suggestions whenever a source they read changes.
            .onChange(of: model.forwardSearchSourceRevision) { model.refreshFavoriteSuggestions() }
        }
    }

    private var selection: Binding<ChannelID?> {
        // The list stays mounted while Favorites is closed; hidden, it neither
        // follows nor changes the open conversation.
        Binding(
            get: { model.favorites.isPresented ? model.presentedFavoriteChannelID : nil },
            set: { id in
                guard model.favorites.isPresented, let id else { return }
                // Choosing the shown favourite again supersedes a navigation in flight, as in a server's channel list.
                guard id != model.presentedFavoriteChannelID else { return model.cancelConversationNavigation() }
                guard let favorite = model.favoriteConversations().first(where: { $0.id == id }) else { return }
                model.selectFavorite(favorite)
            }
        )
    }

    @ViewBuilder
    private func rows(_ section: FavoritesSettings.Section) -> some View {
        ForEach(section.entries.compactMap(model.favoriteConversation)) { favorite in
            FavoriteRow(model: model, favorite: favorite, isSelected: model.favorites.isPresented && model.presentedFavoriteChannelID == favorite.id)
                .tag(favorite.id)
        }
    }

    private func categoryHeader(_ category: FavoritesSettings.Entry) -> some View {
        let isCollapsed = collapsedCategoryIDs.contains(category.id)
        return ChannelCategoryHeaderButton(name: category.nickname, isExpanded: !isCollapsed) {
            withAnimation(.snappy(duration: 0.18)) {
                if isCollapsed { collapsedCategoryIDs.remove(category.id) } else { collapsedCategoryIDs.insert(category.id) }
            }
        } menu: {
            ChannelRowHoverBridge(isSelected: false) { FavoritesMenu.categoryMenu(for: category, model: model) }
        }
        .interfaceFontOverride(.interface(.subheadline).weight(.bold))
    }
}

private struct FavoriteRow: View {
    let model: AppModel
    let favorite: FavoriteConversation
    let isSelected: Bool

    var body: some View {
        let mentions = model.readState.mentions(channelID: favorite.id)
        let isMuted = model.isFavoriteMuted(favorite)
        let isUnread = model.readState.unread(channelID: favorite.id)
        let showsUnread = isUnread && !isMuted
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
        // A muted favourite still offers Mark as Read, as a muted channel does.
        .overlay { contextMenu(isUnread: isUnread || mentions > 0, mentions: mentions, isMuted: isMuted) }
    }

    /// A thread keeps its own thread menu, whose notification actions write
    /// thread-member settings rather than channel overrides.
    @ViewBuilder
    private func contextMenu(isUnread: Bool, mentions: Int, isMuted: Bool) -> some View {
        let channel = favorite.channel
        if let thread = favorite.thread {
            ThreadContextMenuBridge(
                model: model,
                row: SidebarThreadRow(thread: thread, isUnread: isUnread, mentionCount: mentions, isMuted: isMuted),
                isSelected: isSelected,
                favoriteItems: { FavoritesMenu.manageItems(for: favorite, model: model) }
            )
        } else {
            ChannelContextMenuBridge(
                isSelected: isSelected,
                isUnread: isUnread,
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
                : ChannelIconPresentation.systemImage(
                    for: channel, isHidden: false,
                    rulesChannelID: channel.guildID.flatMap { model.serverRailGuildsByID[$0]?.rulesChannelID }
                ))
                .interfaceFontOverride(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize))
                .fontWeight(.medium)
        }
    }
}
