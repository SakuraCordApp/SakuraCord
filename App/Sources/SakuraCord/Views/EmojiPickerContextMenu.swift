import AppKit
import SwiftUI

struct EmojiPickerContextMenuBridge: NSViewRepresentable {
    let item: EmojiPickerItem
    let skinTone: NativeEmojiSkinTone
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    init(
        item: EmojiPickerItem,
        skinTone: NativeEmojiSkinTone,
        isFavorite: Bool,
        toggleFavorite: @escaping () -> Void
    ) {
        self.item = item
        self.skinTone = skinTone
        self.isFavorite = isFavorite
        self.toggleFavorite = toggleFavorite
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(from: self)
    }

    func makeNSView(context: Context) -> MediaImageContextMenuHitView {
        let view = MediaImageContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(
        _ nsView: MediaImageContextMenuHitView,
        context: Context
    ) {
        context.coordinator.update(from: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        private var item: EmojiPickerItem
        private var skinTone: NativeEmojiSkinTone
        private var isFavorite: Bool
        private var toggleFavorite: () -> Void

        init(from bridge: EmojiPickerContextMenuBridge) {
            item = bridge.item
            skinTone = bridge.skinTone
            isFavorite = bridge.isFavorite
            toggleFavorite = bridge.toggleFavorite
        }

        func update(from bridge: EmojiPickerContextMenuBridge) {
            item = bridge.item
            skinTone = bridge.skinTone
            isFavorite = bridge.isFavorite
            toggleFavorite = bridge.toggleFavorite
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(menuItem(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "star" : "star.fill",
                action: #selector(toggleFavoriteFromMenu)
            ))
            menu.addItem(.separator())

            switch item {
            case let .native(emoji):
                menu.addItem(menuItem(
                    "Copy Emoji",
                    systemImage: "document.on.document.fill",
                    action: #selector(copyEmojiFromMenu),
                    representedObject: emoji.value(for: skinTone)
                ))
            case let .custom(emoji):
                menu.addItem(menuItem(
                    "Copy Emoji ID",
                    systemImage: "number.square.fill",
                    action: #selector(copyEmojiIDFromMenu),
                    representedObject: emoji.id
                ))
                if let imageURL = emoji.imageURL {
                    menu.addItem(menuItem(
                        "Copy Emoji Image Link",
                        systemImage: "link",
                        action: #selector(copyEmojiImageLinkFromMenu),
                        representedObject: imageURL.absoluteString
                    ))
                }
            }

            return menu
        }

        private func menuItem(
            _ title: String,
            systemImage: String,
            action: Selector,
            representedObject: Any? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: action,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = representedObject
            item.isEnabled = true
            ContextMenuItemSupport.configure(
                item,
                title: title,
                systemImage: systemImage
            )
            return item
        }

        @objc private func toggleFavoriteFromMenu() {
            toggleFavorite()
        }

        @objc private func copyEmojiFromMenu(_ sender: NSMenuItem) {
            copy(sender.representedObject as? String)
        }

        @objc private func copyEmojiIDFromMenu(_ sender: NSMenuItem) {
            copy(sender.representedObject as? String)
        }

        @objc private func copyEmojiImageLinkFromMenu(_ sender: NSMenuItem) {
            copy(sender.representedObject as? String)
        }

        private func copy(_ value: String?) {
            guard let value else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }
}
