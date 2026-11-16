import AppKit
import SakuraCordModels
import SwiftUI

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
        let toggle = ContextMenuItemSupport.item(isFavorite ? "Remove from Favorites" : "Add to Favorites",
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
            items.append(ContextMenuItemSupport.item("Go to Server", systemImage: "arrow.uturn.right") {
                // Leaves Favorites even though the destination is a favourite.
                model.navigate(to: guildID, linkedChannelID: favorite.id, presentsFavorites: false)
            })
        }
        let move = ContextMenuItemSupport.item("Move To", systemImage: "folder.fill", action: nil)
        move.submenu = NSMenu(title: "Move To")
        move.submenu?.autoenablesItems = false
        let destinations = [(nil, "Uncategorized")] + (model.favorites.settings?.categories ?? []).map {
            (Optional($0.id), $0.nickname)
        }
        for (categoryID, name) in destinations {
            let destination = ContextMenuItemSupport.item(name, systemImage: nil) {
                model.updateFavorites(.move(favorite.id, categoryID: categoryID))
            }
            let isCurrent = favorite.entry.parentID == categoryID
            destination.state = isCurrent ? .on : .off
            destination.isEnabled = !isCurrent
            move.submenu?.addItem(destination)
        }
        items.append(move)
        if favorite.channel.guildID != nil {
            items.append(ContextMenuItemSupport.item("Change Nickname…", systemImage: "pencil") {
                model.favorites.nameEditor = .rename(favorite.entry)
            })
        }
        items.append(ContextMenuItemSupport.item("Remove from Favorites", systemImage: "star.slash.fill", isDestructive: true) {
            model.updateFavorites(.remove(favorite.id))
        })
        return items
    }

    /// The rail tile's menu, Discord's items with Hide neither set apart nor red.
    static func railMenu(model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ContextMenuItemSupport.item("Thread Settings", systemImage: SakuraCordSystemSymbol.thread) {
            model.favorites.isEditingThreadSettings = true
        })
        menu.addItem(ContextMenuItemSupport.item("Hide Favorites", systemImage: "eye.slash.fill") { model.setFavoritesEnabled(false) })
        menu.addItem(.separator())
        menu.addItem(ContextMenuItemSupport.item("Reset Favorites", systemImage: "trash.fill", isDestructive: true, action: model.resetFavorites))
        return menu
    }

    /// Discord's menu for the Favorites channel list outside its rows.
    static func listMenu(model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ContextMenuItemSupport.item("Add to Favorites", systemImage: "plus") { model.favorites.isPickerPresented = true })
        menu.addItem(.separator())
        menu.addItem(ContextMenuItemSupport.item("Create Category", systemImage: "folder.fill.badge.plus") {
            model.favorites.nameEditor = .createCategory
        })
        return menu
    }

    /// A Favorites category's menu: Mark as Read, then Rename and Delete.
    static func categoryMenu(for category: FavoritesSettings.Entry, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let markRead = ContextMenuItemSupport.item("Mark as Read", systemImage: "envelope.open.fill") { model.markFavoriteCategoryRead(category.id) }
        markRead.isEnabled = model.isFavoriteCategoryUnread(category.id)
        menu.addItem(markRead)
        menu.addItem(.separator())
        menu.addItem(ContextMenuItemSupport.item("Rename Category…", systemImage: "pencil") { model.favorites.nameEditor = .rename(category) })
        menu.addItem(ContextMenuItemSupport.item("Delete Category", systemImage: "trash", isDestructive: true) {
            model.updateFavorites(.remove(category.id))
        })
        return menu
    }
}

/// The native menu for secondary clicks on a SwiftUI List outside the rows
/// that bring their own menu. SwiftUI's list table doesn't consult an
/// AppKit menu itself, so this background watches the clicks within its
/// bounds and defers to any view under the pointer that has a menu.
struct ListBackgroundMenuBridge: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> ListBackgroundMenuView {
        let view = ListBackgroundMenuView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: ListBackgroundMenuView, context: Context) {
        nsView.menuProvider = menu
    }
}

final class ListBackgroundMenuView: NSView {
    var menuProvider: (() -> NSMenu)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = window == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            self?.presentMenu(for: event) == true ? nil : event
        }
    }

    private func presentMenu(for event: NSEvent) -> Bool {
        guard event.isContextClick,
              let window, event.window === window, let menuProvider,
              WindowModalCoordinator.allowsInput(for: self),
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return false }
        var view = window.contentView?.hitTest(event.locationInWindow)
        while let current = view, current !== self {
            if current.menu(for: event)?.items.isEmpty == false { return false }
            view = current.superview
        }
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        return true
    }
}
