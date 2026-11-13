import AppKit
import SakuraCordModels

/// Favorites server items for channel, thread and DM context menus.
@MainActor
enum FavoritesMenu {
    /// Outside Favorites: Add to Favorites, or Remove for a favourite. While
    /// the channel's access is still being checked only removal is offered.
    static func toggleItems(
        for channelID: ChannelID, channelType: Int, model: AppModel, isChecking: Bool = false
    ) -> [NSMenuItem] {
        let isFavorite = model.isFavorite(channelID)
        guard model.favorites.settings != nil, isFavorite || model.canAddFavorite(channelID) else { return [] }
        let toggle = item(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: isFavorite ? "star.slash.fill" : "star.fill") {
            model.toggleFavorite(channelID, channelType: channelType)
        }
        toggle.isEnabled = isFavorite || !isChecking
        return [toggle]
    }

    /// A favourite's own menu inside Favorites, as Discord offers it.
    static func manageItems(for favorite: FavoriteConversation, model: AppModel) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let guildID = favorite.channel.guildID {
            items.append(item("Go to Server", systemImage: "arrow.uturn.right") {
                // Leaves Favorites even though the destination is a favourite.
                model.navigate(to: guildID, linkedChannelID: favorite.id, presentsFavorites: false)
            })
        }
        let move = item("Move To", systemImage: "folder.fill", action: nil)
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
                model.favorites.nameEditor = .rename(favorite.entry)
            })
        }
        items.append(item("Remove from Favorites", systemImage: "star.slash.fill", isDestructive: true) {
            model.updateFavorites(.remove(favorite.id))
        })
        return items
    }

    /// The rail tile's menu, Discord's items with Hide neither set apart nor red.
    static func railMenu(model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Thread Settings", systemImage: SakuraCordSystemSymbol.thread) {
            model.favorites.isEditingThreadSettings = true
        })
        menu.addItem(item("Hide Favorites", systemImage: "eye.slash.fill") { model.setFavoritesEnabled(false) })
        menu.addItem(.separator())
        menu.addItem(item("Reset Favorites", systemImage: "trash.fill", isDestructive: true, action: model.resetFavorites))
        return menu
    }

    /// Discord's menu for the Favorites channel list outside its rows.
    static func listMenu(model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Add to Favorites", systemImage: "plus") { model.favorites.isPickerPresented = true })
        menu.addItem(.separator())
        menu.addItem(item("Create Category", systemImage: "folder.fill.badge.plus") {
            model.favorites.nameEditor = .createCategory
        })
        return menu
    }

    /// A Favorites category's menu: Mark as Read, then Rename and Delete.
    static func categoryMenu(for category: FavoritesSettings.Entry, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let markRead = item("Mark as Read", systemImage: "envelope.open.fill") { model.markFavoriteCategoryRead(category.id) }
        markRead.isEnabled = model.isFavoriteCategoryUnread(category.id)
        menu.addItem(markRead)
        menu.addItem(.separator())
        menu.addItem(item("Rename Category…", systemImage: "pencil") { model.favorites.nameEditor = .rename(category) })
        menu.addItem(item("Delete Category", systemImage: "trash", isDestructive: true) {
            model.updateFavorites(.remove(category.id))
        })
        return menu
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
