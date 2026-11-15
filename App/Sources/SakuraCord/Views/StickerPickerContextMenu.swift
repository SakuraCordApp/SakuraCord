import AppKit
import SakuraCordModels
import SwiftUI

struct StickerPickerContextMenuBridge: NSViewRepresentable {
    let sticker: MessageSticker
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(bridge: self) }

    func makeNSView(context: Context) -> ContextClickMenuHitView {
        let view = ContextClickMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: ContextClickMenuHitView, context: Context) {
        context.coordinator.bridge = self
        nsView.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
    }

    @MainActor
    final class Coordinator {
        var bridge: StickerPickerContextMenuBridge

        init(bridge: StickerPickerContextMenuBridge) {
            self.bridge = bridge
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ContextMenuItemSupport.item(
                bridge.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: bridge.isFavorite ? "star" : "star.fill",
                action: { [self] in bridge.toggleFavorite() }
            ))
            menu.addItem(.separator())
            menu.addItem(ContextMenuItemSupport.item("Copy Sticker ID", systemImage: "number.square.fill") { [self] in
                Pasteboard.copy(bridge.sticker.id)
            })
            if bridge.sticker.pickerImageLink != nil {
                menu.addItem(ContextMenuItemSupport.item("Copy Sticker Image Link", systemImage: "link") { [self] in
                    bridge.sticker.pickerImageLink.map { Pasteboard.copy($0.absoluteString) }
                })
            }
            return menu
        }
    }
}
