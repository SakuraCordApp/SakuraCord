import AppKit
import SakuraCordModels
import SwiftUI

/// Shares the channel list's native tracking, selection and menu hit region.
struct ThreadContextMenuBridge: NSViewRepresentable {
    let model: AppModel
    let row: SidebarThreadRow
    let isSelected: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChannelContextMenuHitView {
        let view = ChannelContextMenuHitView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ChannelContextMenuHitView, context: Context) {
        context.coordinator.bridge = self
        view.isSelected = isSelected
        view.menuProvider = { [weak coordinator = context.coordinator] in coordinator?.makeMenu() }
    }

    static func dismantleNSView(_ view: ChannelContextMenuHitView, coordinator: Coordinator) {
        view.uninstallFromNativeRow()
    }

    @MainActor final class Coordinator: NSObject {
        var bridge: ThreadContextMenuBridge
        private let renderer = ThreadActionsMenuRenderer()

        init(_ bridge: ThreadContextMenuBridge) { self.bridge = bridge }

        func makeMenu() -> NSMenu {
            let row = bridge.row
            let menu = renderer.makeMenu(ThreadActionsMenu(
                model: bridge.model,
                thread: bridge.model.sidebarThread(row.id) ?? row.thread,
                surface: .channelList,
                isUnread: row.isUnread || row.mentionCount > 0
            ))
            // Favorites follow Mark as Read, as in Discord's thread menu.
            let favorites = FavoritesMenu.toggleItems(
                for: row.id, channelType: row.thread.isPrivate ? 12 : 11, model: bridge.model
            )
            if !favorites.isEmpty, let separator = menu.items.firstIndex(where: \.isSeparatorItem) {
                for (offset, item) in (favorites + [.separator()]).enumerated() {
                    menu.insertItem(item, at: separator + 1 + offset)
                }
            }
            return menu
        }
    }
}
