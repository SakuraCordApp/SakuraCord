import AppKit
import SwiftUI

/// The right-click menu of a server folder, hosted like the server menu so a
/// left click still reaches the folder's button.
struct ServerFolderContextMenuBridge: NSViewRepresentable {
    let isUnread: Bool
    let markRead: () -> Void
    let openSettings: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ServerContextMenuHitView {
        let view = ServerContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: ServerContextMenuHitView, context: Context) {
        context.coordinator.bridge = self
    }

    @MainActor
    final class Coordinator {
        var bridge: ServerFolderContextMenuBridge

        init(_ bridge: ServerFolderContextMenuBridge) {
            self.bridge = bridge
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ContextMenuItemSupport.item(
                "Mark Folder as Read",
                systemImage: "envelope.open.fill",
                isEnabled: bridge.isUnread
            ) { self.bridge.markRead() })
            menu.addItem(.separator())
            menu.addItem(ContextMenuItemSupport.item(
                "Folder Settings",
                systemImage: "folder.fill.badge.gearshape"
            ) { self.bridge.openSettings() })
            return menu
        }
    }
}
