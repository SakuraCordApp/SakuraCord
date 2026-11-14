import AppKit
import SakuraCordModels
import SwiftUI

@MainActor
enum UserContextMenu {
    static func make(for user: User, context: UserMenuContext, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let actions = model.userMenuActions(for: user, context: context)
        for group in UserMenuAction.Group.allCases {
            if group == .copy {
                appendVoice(to: menu, user: user, model: model)
                if let apps = appsItem(for: user, context: context, model: model) {
                    append([apps], to: menu)
                }
            }
            append(items(actions.filter { $0.group == group }), to: menu)
        }
        return menu
    }

    static func items(_ actions: [UserMenuAction]) -> [NSMenuItem] {
        actions.map { action in
            let target = NativeTimelineMenuAction(action.perform)
            let item = NSMenuItem(title: action.title, action: #selector(NativeTimelineMenuAction.performAction), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.isEnabled = action.isEnabled
            item.identifier = NSUserInterfaceItemIdentifier("user-\(action.group.rawValue)")
            ContextMenuItemSupport.configure(item, title: action.title, systemImage: action.systemImage,
                                             isDestructive: action.isDestructive)
            return item
        }
    }

    static func append(_ items: [NSMenuItem], to menu: NSMenu) {
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        items.forEach(menu.addItem)
    }

    static func accessibilityActions(for user: User, context: UserMenuContext, model: AppModel) -> [NSAccessibilityCustomAction] {
        let session = model.accountSession()
        return model.userMenuActions(for: user, context: context).filter(\.isEnabled).map { action in
            NSAccessibilityCustomAction(name: action.title) { [weak model] in
                guard let model, model.isCurrentAccountSession(session),
                      let current = model.userMenuActions(for: user, context: context)
                    .first(where: { $0.id == action.id && $0.isEnabled }) else { return false }
                current.perform()
                return true
            }
        }
    }

    private static func appsItem(for user: User, context: UserMenuContext, model: AppModel) -> NSMenuItem? {
        guard !context.isLocalIdentity, !user.isWebhookIdentity, !user.isSystem, model.supportsCapability(.slashCommands),
              let channelID = context.channelID,
              let destination = model.userMenuMentionDestination(in: context) else { return nil }
        model.ensureApplicationCommandsLoaded(in: destination)
        let composer = model.commandComposer(for: destination)
        guard composer.isLoading || !composer.contextMenuCommands(of: .user).isEmpty else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let populator = ApplicationCommandAppsMenuPopulator(model: model, type: .user, targetID: user.id.description, channelID: channelID)
        submenu.delegate = populator
        let item = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.representedObject = populator
        ContextMenuItemSupport.configure(item, title: "Apps", systemImage: SakuraCordSystemSymbol.applicationCommands)
        return item
    }

    private static func appendVoice(to menu: NSMenu, user: User, model: AppModel) {
        guard user.id != model.currentUser?.id,
              let channelID = model.activeVoiceChannel?.id,
              model.voiceParticipants.contains(where: { $0.userID == user.id.description }) else { return }
        let session = model.accountSession()
        let item = NSMenuItem()
        item.view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 6) {
            Text("User Volume").font(.system(size: 13))
            Slider(value: Binding(get: {
                Double(model.voiceParticipants.first { $0.userID == user.id.description }?.volume ?? 1)
            }, set: { value in
                guard model.isCurrentAccountSession(session), model.activeVoiceChannel?.id == channelID else { return }
                Task {
                    guard model.isCurrentAccountSession(session), model.activeVoiceChannel?.id == channelID else { return }
                    await model.updateParticipantVolume(Float(value), userID: user.id.description)
                }
            }), in: 0 ... 2)
                .accessibilityLabel("User Volume")
        }.padding(10).frame(width: 220))
        item.view?.setFrameSize(NSSize(width: 220, height: 65))
        append([item], to: menu)
    }
}

/// Intercepts only secondary clicks; normal selection and profile buttons keep
/// their existing responder behavior.
struct UserContextMenuBridge: NSViewRepresentable {
    var makeMenu: () -> NSMenu?

    func makeNSView(context: Context) -> UserContextMenuHitView { UserContextMenuHitView() }
    func updateNSView(_ view: UserContextMenuHitView, context: Context) { view.makeMenu = makeMenu }
}

final class UserContextMenuHitView: NSView {
    var makeMenu: (() -> NSMenu?)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent, bounds.contains(convert(point, from: superview)),
              event.isContextClick else { return nil }
        return self
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard WindowModalCoordinator.allowsInput(for: self) else { return nil }
        return makeMenu?()
    }
}

struct UserContextMenuButton: NSViewRepresentable {
    var makeMenu: () -> NSMenu?
    func makeNSView(context: Context) -> UserMenuButton {
        let button = UserMenuButton()
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        button.isBordered = false
        button.setAccessibilityLabel("More")
        button.target = button
        button.action = #selector(UserMenuButton.openMenu)
        return button
    }
    func updateNSView(_ button: UserMenuButton, context: Context) { button.makeMenu = makeMenu }
}

final class UserMenuButton: NSButton {
    var makeMenu: (() -> NSMenu?)?
    @objc func openMenu() {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        makeMenu?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
}
