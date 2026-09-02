import AppKit

struct MediaSaveMenuActions {
    let saveAs: () -> Void
    let saveToDefaultFolder: () -> Void
}

@MainActor
enum MediaSaveMenuBuilder {
    static func make(
        actions: MediaSaveMenuActions,
        defaultFolderName: String? = StorageDownloadsSettingsStore.shared.defaultFolderName
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(
            actionItem(
                String(localized: LocalizedStringResource("Save As…", bundle: #bundle)),
                systemImage: "square.and.arrow.down",
                action: actions.saveAs
            )
        )

        let folderTitle = if let defaultFolderName {
            String(localized: LocalizedStringResource(
                "Save to \(defaultFolderName)",
                bundle: #bundle
            ))
        } else {
            String(localized: LocalizedStringResource(
                "Save to Default Folder",
                bundle: #bundle
            ))
        }
        let folderItem = actionItem(
            folderTitle,
            systemImage: "folder",
            action: actions.saveToDefaultFolder
        )
        folderItem.isEnabled = defaultFolderName != nil
        menu.addItem(folderItem)
        return menu
    }

    static func submenuItem(
        _ title: String,
        systemImage: String,
        actions: MediaSaveMenuActions
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = make(actions: actions)
        item.isEnabled = true
        ContextMenuItemSupport.configure(
            item,
            title: title,
            systemImage: systemImage
        )
        return item
    }

    static func popUp(actions: MediaSaveMenuActions) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView
        else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        make(actions: actions).popUp(
            positioning: nil,
            at: viewPoint,
            in: contentView
        )
    }

    private static func actionItem(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let target = NativeTimelineMenuAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(NativeTimelineMenuAction.performAction),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        ContextMenuItemSupport.configure(
            item,
            title: title,
            systemImage: systemImage
        )
        return item
    }
}
