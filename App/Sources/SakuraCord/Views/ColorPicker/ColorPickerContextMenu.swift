import AppKit
import SwiftUI

// Keep the theme designer’s native right-click hit testing and menu behavior.
struct ColorPickerContextMenuBridge: NSViewRepresentable {
    let canInputColor: Bool
    let canRemoveColor: Bool
    let input: () -> Void
    let remove: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(bridge: self) }

    func makeNSView(context: Context) -> MediaImageContextMenuHitView {
        let view = MediaImageContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: MediaImageContextMenuHitView, context: Context) {
        context.coordinator.bridge = self
    }

    @MainActor
    final class Coordinator {
        var bridge: ColorPickerContextMenuBridge

        init(bridge: ColorPickerContextMenuBridge) { self.bridge = bridge }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ContextMenuItemSupport.item(
                String(localized: "Input Hex Code…", bundle: #bundle),
                systemImage: "number",
                isEnabled: bridge.canInputColor
            ) { [self] in
                guard bridge.canInputColor else { return }
                bridge.input()
            })
            if bridge.canRemoveColor, bridge.remove != nil {
                menu.addItem(.separator())
                menu.addItem(ContextMenuItemSupport.item(
                    String(localized: "Remove Color", bundle: #bundle),
                    systemImage: "trash",
                    isEnabled: bridge.canRemoveColor,
                    isDestructive: true
                ) { [self] in
                    guard bridge.canRemoveColor else { return }
                    bridge.remove?()
                })
            }
            return menu
        }
    }
}
