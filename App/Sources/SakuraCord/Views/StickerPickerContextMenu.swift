import AppKit
import SakuraCordModels
import SwiftUI

struct StickerPickerContextMenuBridge: NSViewRepresentable {
    let sticker: MessageSticker
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(from: self) }

    func makeNSView(context: Context) -> MediaImageContextMenuHitView {
        let view = MediaImageContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: MediaImageContextMenuHitView, context: Context) {
        context.coordinator.update(from: self)
        nsView.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var sticker: MessageSticker
        private var isFavorite: Bool
        private var toggleFavorite: () -> Void

        init(from bridge: StickerPickerContextMenuBridge) {
            sticker = bridge.sticker
            isFavorite = bridge.isFavorite
            toggleFavorite = bridge.toggleFavorite
        }

        func update(from bridge: StickerPickerContextMenuBridge) {
            sticker = bridge.sticker
            isFavorite = bridge.isFavorite
            toggleFavorite = bridge.toggleFavorite
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(item(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                image: isFavorite ? "star" : "star.fill",
                action: #selector(toggleFavoriteFromMenu)
            ))
            menu.addItem(.separator())
            menu.addItem(item(
                "Copy Sticker ID",
                image: "number.square.fill",
                action: #selector(copyStickerID)
            ))
            if sticker.pickerImageLink != nil {
                menu.addItem(item(
                    "Copy Sticker Image Link",
                    image: "link",
                    action: #selector(copyStickerImageLink)
                ))
            }
            return menu
        }

        private func item(_ title: String, image: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            ContextMenuItemSupport.configure(item, title: title, systemImage: image)
            return item
        }

        @objc private func toggleFavoriteFromMenu() { toggleFavorite() }
        @objc private func copyStickerID() { copy(sticker.id) }
        @objc private func copyStickerImageLink() { copy(sticker.pickerImageLink?.absoluteString) }

        private func copy(_ value: String?) {
            guard let value else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }
}
