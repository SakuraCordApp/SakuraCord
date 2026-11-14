import AppKit
import SakuraCordModels
import SwiftUI

/// Shares the channel list's native tracking, selection and menu hit region.
struct ThreadContextMenuBridge: NSViewRepresentable {
    let model: AppModel
    let row: SidebarThreadRow
    let isSelected: Bool
    /// A favourite's actions inside the Favorites server.
    var favoriteItems: (() -> [NSMenuItem])?

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
        private let renderer = ActionMenuRenderer()

        init(_ bridge: ThreadContextMenuBridge) { self.bridge = bridge }

        func makeMenu() -> NSMenu {
            let row = bridge.row
            let actions = ThreadActionsMenu(
                model: bridge.model,
                thread: row.thread,
                surface: .channelList,
                isUnread: row.isUnread || row.mentionCount > 0
            )
            guard let favoriteItems = bridge.favoriteItems?() else { return renderer.makeMenu(actions.sections) }
            // Inside Favorites the favourite's own actions replace Add/Remove.
            let menu = renderer.makeMenu(actions.sections.filter {
                !$0.contains { $0.id == ThreadActionsMenu.favoriteID }
            })
            if let separator = menu.items.firstIndex(where: \.isSeparatorItem) {
                for (offset, item) in (favoriteItems + [.separator()]).enumerated() {
                    menu.insertItem(item, at: separator + 1 + offset)
                }
            }
            return menu
        }
    }
}
