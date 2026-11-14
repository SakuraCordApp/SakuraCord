import AppKit
import SwiftUI

/// Both widget entry points use the same native menu and forced-visible icons.
struct ProfileWidgetMenu: NSViewRepresentable {
    let editor: ProfileEditorState
    let widgetID: String
    let title: String
    var isButton = false
    let remove: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeNSView(context: Context) -> NSView {
        if isButton {
            let button = MediaViewerMenuNSControl(frame: .zero)
            button.target = context.coordinator
            button.action = #selector(Coordinator.showMenu(_:))
            return button
        }
        let view = MediaImageContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator, weak view] in
            guard let view, WindowModalCoordinator.allowsInput(for: view) else { return nil }
            return coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.configuration = self
        if let button = view as? MediaViewerMenuNSControl {
            button.isEnabled = isEnabled && editor.canEditWidgets
            button.setAccessibilityLabel("Manage widget: \(title)")
            button.toolTip = String(localized: "Manage Widget", bundle: #bundle)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? InterfaceScale.metric(24), height: proposal.height ?? InterfaceScale.metric(24))
    }

    final class Coordinator: NSObject {
        var configuration: ProfileWidgetMenu
        private var isTrackingMenu = false

        init(configuration: ProfileWidgetMenu) { self.configuration = configuration }

        @objc func showMenu(_ sender: NSControl) {
            guard sender.isEnabled, WindowModalCoordinator.allowsInput(for: sender), !isTrackingMenu else { return }
            isTrackingMenu = true
            defer { isTrackingMenu = false }
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let index = widgetIndex
            let canEdit = configuration.isEnabled && configuration.editor.canEditWidgets && index != nil
            menu.addItem(ContextMenuItemSupport.item(
                String(localized: "Move Up", bundle: #bundle), systemImage: "arrow.up", isEnabled: canEdit && index != 0
            ) { [self] in move(by: -1) })
            menu.addItem(ContextMenuItemSupport.item(
                String(localized: "Move Down", bundle: #bundle), systemImage: "arrow.down",
                isEnabled: canEdit && index != configuration.editor.widgets.count - 1
            ) { [self] in move(by: 1) })
            menu.addItem(.separator())
            menu.addItem(ContextMenuItemSupport.item(
                String(localized: "Remove Widget", bundle: #bundle), systemImage: "trash", isEnabled: canEdit, isDestructive: true
            ) { [self] in removeWidget() })
            return menu
        }

        private var widgetIndex: Int? {
            configuration.editor.widgets.firstIndex { $0.id == configuration.widgetID }
        }

        private func move(by offset: Int) {
            guard configuration.isEnabled, configuration.editor.canEditWidgets, let index = widgetIndex,
                  configuration.editor.widgets.indices.contains(index + offset) else { return }
            configuration.editor.moveWidget(id: configuration.widgetID, to: index + offset)
        }

        private func removeWidget() {
            guard configuration.isEnabled, configuration.editor.canEditWidgets, widgetIndex != nil else { return }
            configuration.remove()
        }
    }
}
