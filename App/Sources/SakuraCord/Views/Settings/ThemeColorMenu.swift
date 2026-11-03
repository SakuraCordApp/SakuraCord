import AppKit
import SwiftUI

struct ThemeColorMenu: ViewModifier {
    let themeStore: SakuraCordThemeStore
    let colorIndex: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEnteringHexCode = false
    @State private var hexCode = ""
    @State private var transitionTask: Task<Void, Never>?

    private var canInputColor: Bool {
        if let colorIndex {
            return themeStore.activeTheme.activeColors.indices.contains(colorIndex)
        }
        return themeStore.activeTheme.activeColorCount < SakuraCordGradientTheme.maximumColorCount
    }

    private var canRemoveColor: Bool {
        colorIndex != nil && themeStore.activeTheme.activeColorCount > SakuraCordGradientTheme.minimumColorCount
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                ThemeColorContextMenuBridge(
                    canInputColor: canInputColor,
                    canRemoveColor: canRemoveColor,
                    input: beginHexEntry,
                    remove: colorIndex == nil ? nil : { removeColor() }
                )
            }
            .onDisappear { transitionTask?.cancel() }
            .accessibilityActions {
                Button("Input Hex Code…", systemImage: "number", action: beginHexEntry)
                    .disabled(!canInputColor)
                if colorIndex != nil {
                    Button("Remove Color", systemImage: "trash", role: .destructive, action: removeColor)
                        .disabled(!canRemoveColor)
                }
            }
            .alert("Input Hex Code", isPresented: $isEnteringHexCode) {
                TextField("#RRGGBB", text: $hexCode)
                Button("Cancel", role: .cancel) { hexCode = "" }
                Button("Apply", action: applyHexColor)
                    .disabled(SakuraCordThemeColor(hexCode: hexCode) == nil || !canInputColor)
            }
    }

    private func beginHexEntry() {
        guard canInputColor else { return }
        hexCode = ""
        isEnteringHexCode = true
    }

    private func applyHexColor() {
        guard canInputColor, let color = SakuraCordThemeColor(hexCode: hexCode) else { return }
        transitionTask?.cancel()
        if let colorIndex {
            transitionTask = Task {
                await themeStore.applyColor(color, at: colorIndex, reduceMotion: reduceMotion)
            }
        } else {
            withAnimation(reduceMotion ? nil : .themeControlResponse) {
                themeStore.addColor(color)
            }
        }
    }

    private func removeColor() {
        guard canRemoveColor, let colorIndex else { return }
        // The handles use palette indices as identity. Renumber them atomically
        // so surviving colors never animate between the old numbered slots.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            themeStore.removeColor(at: colorIndex)
        }
    }
}

private struct ThemeColorContextMenuBridge: NSViewRepresentable {
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
    final class Coordinator: NSObject {
        var bridge: ThemeColorContextMenuBridge

        init(bridge: ThemeColorContextMenuBridge) { self.bridge = bridge }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(item(
                String(localized: "Input Hex Code…", bundle: #bundle),
                image: "number",
                action: #selector(inputHexCode),
                isEnabled: bridge.canInputColor
            ))
            if bridge.remove != nil {
                menu.addItem(.separator())
                menu.addItem(item(
                    String(localized: "Remove Color", bundle: #bundle),
                    image: "trash",
                    action: #selector(removeColor),
                    isEnabled: bridge.canRemoveColor,
                    isDestructive: true
                ))
            }
            return menu
        }

        private func item(
            _ title: String,
            image: String,
            action: Selector,
            isEnabled: Bool,
            isDestructive: Bool = false
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = isEnabled
            ContextMenuItemSupport.configure(item, title: title, systemImage: image, isDestructive: isDestructive)
            return item
        }

        @objc private func inputHexCode() {
            guard bridge.canInputColor else { return }
            bridge.input()
        }

        @objc private func removeColor() {
            guard bridge.canRemoveColor else { return }
            bridge.remove?()
        }
    }
}
