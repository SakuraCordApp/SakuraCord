import AppKit
import SwiftUI

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
        if let image = symbolImage(systemImage, accessibilityDescription: title, isDestructive: isDestructive) {
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

    /// A menu item's symbol at the menu's size; red for a destructive item.
    static func symbolImage(_ name: String, accessibilityDescription: String, isDestructive: Bool = false) -> NSImage? {
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
        let image = SakuraCordSystemSymbol.image(
            named: name,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = !isDestructive
        return image
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
/// which keep item images and subtitles.
@MainActor
enum ActionMenuRenderer {
    static func makeMenu(_ sections: [[ActionMenuEntry]], slot: (ActionMenuEntry) -> NSMenuItem? = { _ in nil }) -> NSMenu {
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

    private static func menuItem(_ entry: ActionMenuEntry, slot: (ActionMenuEntry) -> NSMenuItem?) -> NSMenuItem? {
        let action: (() -> Void)?
        switch entry.content {
        case .slot: return slot(entry)
        case .action(let entryAction): action = entryAction
        case .submenu: action = nil
        }
        let item = ContextMenuItemSupport.item(
            entry.title,
            systemImage: entry.systemImage,
            isEnabled: entry.isEnabled,
            isDestructive: entry.isDestructive,
            action: action
        )
        item.state = entry.isChecked ? .on : .off
        if let subtitle = entry.subtitle { item.subtitle = subtitle }
        if case .submenu(let children) = entry.content {
            let submenu = NSMenu(title: entry.title)
            submenu.autoenablesItems = false
            for child in children {
                if let childItem = menuItem(child, slot: slot) { submenu.addItem(childItem) }
            }
            item.submenu = submenu
        }
        return item
    }
}

/// Pops an action menu below the view it is anchored to.
@MainActor
final class ActionMenuPresenter {
    weak var anchor: NSView?

    func show(_ sections: [[ActionMenuEntry]]) {
        guard let anchor else { return }
        ActionMenuRenderer.makeMenu(sections).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchor)
    }
}

struct ActionMenuAnchor: NSViewRepresentable {
    let presenter: ActionMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchor = nsView
    }
}
