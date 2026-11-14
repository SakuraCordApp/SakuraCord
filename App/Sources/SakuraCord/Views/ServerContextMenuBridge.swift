import AppKit
import SakuraCordModels
import SwiftUI

struct ServerContextMenuBridge: NSViewRepresentable {
    let isUnread: Bool
    let isMutationPending: Bool
    let notificationSettings: GuildNotificationSettings
    let markRead: () -> Void
    var canInvite: () -> Bool = { false }
    var invite: () -> Void = {}
    let mute: (ChannelMuteDuration) -> Void
    let unmute: () -> Void
    let setNotificationLevel: (MessageNotificationLevel) -> Void
    let setNotificationToggle: (GuildNotificationToggle, Bool) -> Void
    let copyServerID: () -> Void
    var leaveServer: (() -> Void)?
    var showsAllChannels: () -> Bool? = { nil }
    var setShowsAllChannels: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(from: self)
    }

    func makeNSView(context: Context) -> ServerContextMenuHitView {
        let view = ServerContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: ServerContextMenuHitView, context: Context) {
        context.coordinator.update(from: self)
        nsView.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
    }

    @MainActor
    final class Coordinator {
        private var bridge: ServerContextMenuBridge

        init(from bridge: ServerContextMenuBridge) {
            self.bridge = bridge
        }

        func update(from bridge: ServerContextMenuBridge) {
            self.bridge = bridge
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let canMutate = !bridge.isMutationPending
            menu.addItem(
                ContextMenuItemSupport.item("Mark as Read", systemImage: "envelope.open.fill", isEnabled: bridge.isUnread && canMutate) {
                    self.bridge.markRead()
                }
            )
            menu.addItem(.separator())
            menu.addItem(ContextMenuItemSupport.item("Invite to Server", systemImage: "person.badge.plus.fill", isEnabled: bridge.canInvite()) { self.bridge.invite() })
            menu.addItem(.separator())

            let settings = bridge.notificationSettings
            if settings.isActivelyMuted() {
                menu.addItem(
                    NotificationMenuItems.unmute(
                        "Unmute Server",
                        until: settings.muteConfiguration?.endTime,
                        isEnabled: canMutate
                    ) { self.bridge.unmute() }
                )
            } else {
                menu.addItem(NotificationMenuItems.mute("Mute Server", isEnabled: canMutate) { self.bridge.mute($0) })
            }

            menu.addItem(
                NotificationMenuItems.settings(
                    selection: settings.messageNotifications.menuTitle,
                    isEnabled: canMutate,
                    submenu: notificationMenu(isEnabled: canMutate)
                )
            )

            let hideMutedItem = ContextMenuItemSupport.item("Hide Muted Channels", systemImage: "eye.slash.fill", isEnabled: canMutate) {
                self.bridge.setNotificationToggle(.hideMutedChannels, !self.bridge.notificationSettings.hideMutedChannels)
            }
            hideMutedItem.state = settings.hideMutedChannels ? .on : .off
            menu.addItem(hideMutedItem)

            if let all = bridge.showsAllChannels() {
                let allItem = ContextMenuItemSupport.item("Show All Channels", systemImage: "list.bullet") {
                    guard let all = self.bridge.showsAllChannels() else { return }
                    self.bridge.setShowsAllChannels(!all)
                }
                allItem.state = all ? .on : .off
                menu.addItem(allItem)
            }

            menu.addItem(.separator())
            menu.addItem(ContextMenuItemSupport.item("Copy Server ID", systemImage: "number.square.fill") { self.bridge.copyServerID() })
            if bridge.leaveServer != nil {
                menu.addItem(.separator())
                menu.addItem(
                    ContextMenuItemSupport.item("Leave Server", systemImage: "rectangle.portrait.and.arrow.right", isDestructive: true) {
                        self.bridge.leaveServer?()
                    }
                )
            }
            return menu
        }

        private func notificationMenu(isEnabled: Bool) -> NSMenu {
            let menu = NotificationMenuItems.submenu()
            let settings = bridge.notificationSettings
            let levels: [MessageNotificationLevel] = [
                .allMessages, .onlyMentions, .nothing,
            ]
            for level in levels {
                menu.addItem(
                    NotificationMenuItems.level(
                        level, title: level.menuTitle, selected: settings.messageNotifications, isEnabled: isEnabled
                    ) { self.bridge.setNotificationLevel($0) }
                )
            }
            menu.addItem(.separator())
            for toggle in GuildNotificationToggle.allCases where toggle != .hideMutedChannels {
                if toggle == .mobilePush {
                    menu.addItem(.separator())
                }
                let toggleItem = ContextMenuItemSupport.item(toggle.menuTitle, isEnabled: isEnabled) {
                    self.bridge.setNotificationToggle(toggle, !self.bridge.notificationSettings.isEnabled(toggle))
                }
                toggleItem.state = settings.isEnabled(toggle) ? .on : .off
                menu.addItem(toggleItem)
            }
            return menu
        }
    }
}

private extension GuildNotificationToggle {
    var menuTitle: String {
        switch self {
        case .suppressEveryone: "Suppress @everyone and @here"
        case .suppressRoles: "Suppress All Role @mentions"
        case .suppressHighlights: "Suppress Highlights"
        case .muteScheduledEvents: "Mute New Events"
        case .mobilePush: "Mobile Push Notifications"
        case .hideMutedChannels: "Hide Muted Channels"
        }
    }
}

/// A rail tile's native context menu, built when it opens.
struct ServerRailContextMenuBridge: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> ServerContextMenuHitView {
        let view = ServerContextMenuHitView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: ServerContextMenuHitView, context: Context) {
        nsView.menuProvider = menu
    }
}

/// The native menu for secondary clicks on a SwiftUI List outside the rows
/// that bring their own menu. SwiftUI's list table doesn't consult an
/// AppKit menu itself, so this background watches the clicks within its
/// bounds and defers to any view under the pointer that has a menu.
struct ListBackgroundMenuBridge: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> ListBackgroundMenuView {
        let view = ListBackgroundMenuView()
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ nsView: ListBackgroundMenuView, context: Context) {
        nsView.menuProvider = menu
    }
}

final class ListBackgroundMenuView: NSView {
    var menuProvider: (() -> NSMenu)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = window == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            self?.presentMenu(for: event) == true ? nil : event
        }
    }

    private func presentMenu(for event: NSEvent) -> Bool {
        guard event.isContextClick,
              let window, event.window === window, let menuProvider,
              WindowModalCoordinator.allowsInput(for: self),
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return false }
        var view = window.contentView?.hitTest(event.locationInWindow)
        while let current = view, current !== self {
            if current.menu(for: event)?.items.isEmpty == false { return false }
            view = current.superview
        }
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
        return true
    }
}

final class ServerContextMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil,
              let event = window?.currentEvent ?? NSApp.currentEvent
        else { return nil }
        return event.isContextClick ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
