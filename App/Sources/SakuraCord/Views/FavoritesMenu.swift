import AppKit
import SakuraCordModels

/// Favorites server items for channel, thread and DM context menus.
@MainActor
enum FavoritesMenu {
    /// Outside Favorites: Add to Favorites, or Remove for a favourite.
    static func toggleItems(for channelID: ChannelID, channelType: Int?, model: AppModel) -> [NSMenuItem] {
        guard model.favorites.settings != nil else { return [] }
        let isFavorite = model.isFavorite(channelID)
        return [item(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                     systemImage: isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(channelID, channelType: channelType)
        }]
    }

    /// A favourite's own menu inside Favorites, as Discord offers it.
    static func manageItems(for favorite: FavoriteConversation, model: AppModel) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let guildID = favorite.channel.guildID {
            items.append(item("Go to Server", systemImage: "arrow.uturn.right") {
                model.setFavoritesPresented(false)
                model.navigate(to: guildID, linkedChannelID: favorite.id)
            })
        }
        let move = item("Move To", systemImage: "folder", action: nil)
        move.submenu = NSMenu(title: "Move To")
        move.submenu?.autoenablesItems = false
        let destinations = [(nil, "Uncategorized")] + (model.favorites.settings?.categories ?? []).map {
            (Optional($0.id), $0.nickname)
        }
        for (categoryID, name) in destinations {
            let destination = item(name, systemImage: nil) {
                model.updateFavorites(.move(favorite.id, categoryID: categoryID))
            }
            let isCurrent = favorite.entry.parentID == categoryID
            destination.state = isCurrent ? .on : .off
            destination.isEnabled = !isCurrent
            move.submenu?.addItem(destination)
        }
        items.append(move)
        if favorite.channel.guildID != nil {
            items.append(item("Change Nickname…", systemImage: "pencil") {
                model.favorites.renaming = favorite.entry
            })
        }
        items.append(item("Remove from Favorites", systemImage: "star.slash", isDestructive: true) {
            model.updateFavorites(.remove(favorite.id))
        })
        return items
    }

    static func item(
        _ title: String, systemImage: String?, isDestructive: Bool = false, action: (() -> Void)?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let action {
            let target = NativeTimelineMenuAction(action)
            item.target = target
            item.representedObject = target
            item.action = #selector(NativeTimelineMenuAction.performAction)
        }
        if let systemImage {
            ContextMenuItemSupport.configure(item, title: title, systemImage: systemImage, isDestructive: isDestructive)
        }
        return item
    }
}
