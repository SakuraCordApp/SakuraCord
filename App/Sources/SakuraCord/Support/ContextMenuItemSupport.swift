import AppKit

extension NSEvent {
    /// A secondary click: the right button, or the left with Control held.
    var isContextClick: Bool {
        type == .rightMouseDown || (type == .leftMouseDown && modifierFlags.contains(.control))
    }
}

@MainActor
enum ContextMenuItemSupport {
    static func configure(
        _ item: NSMenuItem,
        title: String,
        systemImage: String,
        isDestructive: Bool = false
    ) {
        let baseConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular
        )
        let configuration = isDestructive
            ? baseConfiguration.applying(
                NSImage.SymbolConfiguration(
                    paletteColors: [.systemRed]
                )
            )
            : baseConfiguration
        if let image = SakuraCordSystemSymbol.image(
            named: systemImage,
            accessibilityDescription: title
        )?.withSymbolConfiguration(configuration) {
            image.isTemplate = !isDestructive
            item.image = image
        }
        item.preferredImageVisibility = .visible
        if isDestructive {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
    }

    /// An item that runs `action`, with its symbol when it has one. Without an
    /// action it only titles a submenu.
    static func item(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: (() -> Void)?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let action {
            let target = MenuItemAction(action)
            item.target = target
            item.representedObject = target
            item.action = #selector(MenuItemAction.performAction)
        }
        item.isEnabled = isEnabled
        if let systemImage {
            configure(item, title: title, systemImage: systemImage, isDestructive: isDestructive)
        }
        return item
    }

    static func configure(_ item: NSMenuItem, image: NSImage) {
        image.isTemplate = false
        item.image = image
        item.preferredImageVisibility = .visible
    }
}

/// A menu item's closure. The item keeps it as its represented object, since
/// a menu item holds its target weakly.
final class MenuItemAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func performAction() {
        handler()
    }
}

/// One item of an action menu, such as a thread's or the toolbar's More menu.
struct ActionMenuEntry: Identifiable {
    enum Content {
        case action(@MainActor () -> Void)
        case submenu([ActionMenuEntry])
        /// A surface-specific item, such as a forum card's tag picker, that the
        /// renderer supplies in this position.
        case slot
    }

    let id: String
    var title: String
    var systemImage: String?
    var subtitle: String?
    var isEnabled = true
    /// Marks the current choice among siblings.
    var isChecked = false
    var isDestructive = false
    var content: Content
}

/// Renders ActionMenuEntry sections as a native AppKit menu for right-click menus,
/// which keep item images and subtitles. Keep the renderer alive while its
/// menu is open; it owns the item actions.
@MainActor
final class ActionMenuRenderer: NSObject {
    private var actions: [@MainActor () -> Void] = []

    func makeMenu(_ sections: [[ActionMenuEntry]], slot: (ActionMenuEntry) -> NSMenuItem? = { _ in nil }) -> NSMenu {
        actions.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in section {
                if let item = menuItem(entry, slot: slot) { menu.addItem(item) }
            }
        }
        return menu
    }

    private func menuItem(_ entry: ActionMenuEntry, slot: (ActionMenuEntry) -> NSMenuItem?) -> NSMenuItem? {
        if case .slot = entry.content { return slot(entry) }
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        item.isEnabled = entry.isEnabled
        item.state = entry.isChecked ? .on : .off
        if let systemImage = entry.systemImage {
            ContextMenuItemSupport.configure(
                item, title: entry.title, systemImage: systemImage, isDestructive: entry.isDestructive
            )
        }
        if let subtitle = entry.subtitle { item.subtitle = subtitle }
        switch entry.content {
        case .action(let action):
            item.action = #selector(invoke(_:))
            item.target = self
            item.tag = actions.count
            actions.append(action)
        case .submenu(let children):
            let submenu = NSMenu(title: entry.title)
            submenu.autoenablesItems = false
            for child in children {
                if let childItem = menuItem(child, slot: slot) { submenu.addItem(childItem) }
            }
            item.submenu = submenu
        case .slot:
            break
        }
        return item
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
