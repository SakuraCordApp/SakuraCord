import AppKit
import SakuraCordModels
import SwiftUI

struct ServerContextMenuBridge: NSViewRepresentable {
    let isUnread: Bool
    let isMutationPending: Bool
    let notificationSettings: GuildNotificationSettings
    let markRead: () -> Void
    let mute: (ChannelMuteDuration) -> Void
    let unmute: () -> Void
    let setNotificationLevel: (MessageNotificationLevel) -> Void
    let setNotificationToggle: (GuildNotificationToggle, Bool) -> Void
    let copyServerID: () -> Void

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
    final class Coordinator: NSObject {
        private var isUnread: Bool
        private var isMutationPending: Bool
        private var notificationSettings: GuildNotificationSettings
        private var markRead: () -> Void
        private var mute: (ChannelMuteDuration) -> Void
        private var unmute: () -> Void
        private var setNotificationLevel: (MessageNotificationLevel) -> Void
        private var setNotificationToggle: (GuildNotificationToggle, Bool) -> Void
        private var copyServerID: () -> Void

        init(from bridge: ServerContextMenuBridge) {
            isUnread = bridge.isUnread
            isMutationPending = bridge.isMutationPending
            notificationSettings = bridge.notificationSettings
            markRead = bridge.markRead
            mute = bridge.mute
            unmute = bridge.unmute
            setNotificationLevel = bridge.setNotificationLevel
            setNotificationToggle = bridge.setNotificationToggle
            copyServerID = bridge.copyServerID
        }

        func update(from bridge: ServerContextMenuBridge) {
            isUnread = bridge.isUnread
            isMutationPending = bridge.isMutationPending
            notificationSettings = bridge.notificationSettings
            markRead = bridge.markRead
            mute = bridge.mute
            unmute = bridge.unmute
            setNotificationLevel = bridge.setNotificationLevel
            setNotificationToggle = bridge.setNotificationToggle
            copyServerID = bridge.copyServerID
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(
                menuItem(
                    "Mark as Read",
                    systemImage: "envelope.open.fill",
                    action: #selector(markReadFromMenu),
                    isEnabled: isUnread && !isMutationPending
                )
            )
            menu.addItem(.separator())

            if isDirectlyMuted {
                let item = menuItem(
                    "Unmute Server",
                    systemImage: "bell.fill",
                    action: #selector(unmuteFromMenu),
                    isEnabled: !isMutationPending
                )
                if let subtitle = ChannelContextMenuSubtitle.muteRemaining(
                    until: notificationSettings.muteConfiguration?.endTime
                ) {
                    item.subtitle = subtitle
                }
                menu.addItem(item)
            } else {
                let item = menuItem(
                    "Mute Server",
                    systemImage: "bell.slash.fill",
                    action: nil,
                    isEnabled: !isMutationPending
                )
                let submenu = NSMenu(title: "Mute Server")
                submenu.autoenablesItems = false
                for (index, duration) in ChannelMuteDuration.allCases.enumerated() {
                    let durationItem = menuItem(
                        duration.title,
                        action: #selector(muteFromMenu(_:)),
                        isEnabled: !isMutationPending
                    )
                    durationItem.representedObject = NSNumber(value: index)
                    submenu.addItem(durationItem)
                }
                item.submenu = submenu
                menu.addItem(item)
            }

            let notificationItem = menuItem(
                "Notification Settings",
                systemImage: "bell.badge.fill",
                action: nil,
                isEnabled: !isMutationPending
            )
            notificationItem.subtitle = notificationSettings.messageNotifications.menuTitle
            notificationItem.submenu = notificationMenu()
            menu.addItem(notificationItem)

            menu.addItem(.separator())
            menu.addItem(
                menuItem(
                    "Copy Server ID",
                    systemImage: "number.square.fill",
                    action: #selector(copyServerIDFromMenu)
                )
            )
            return menu
        }

        private var isDirectlyMuted: Bool {
            notificationSettings.isMuted
                && (notificationSettings.muteConfiguration?.isActive() ?? true)
        }

        private func notificationMenu() -> NSMenu {
            let menu = NSMenu(title: "Notification Settings")
            menu.autoenablesItems = false
            let levels: [MessageNotificationLevel] = [
                .allMessages, .onlyMentions, .nothing,
            ]
            for level in levels {
                let item = menuItem(
                    level.menuTitle,
                    action: #selector(setNotificationFromMenu(_:)),
                    isEnabled: !isMutationPending
                )
                item.state = notificationSettings.messageNotifications == level ? .on : .off
                item.representedObject = NSNumber(value: level.rawValue)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for toggle in GuildNotificationToggle.allCases {
                if toggle == .mobilePush {
                    menu.addItem(.separator())
                }
                let item = menuItem(
                    toggle.menuTitle,
                    action: #selector(setNotificationToggleFromMenu(_:)),
                    isEnabled: !isMutationPending
                )
                item.state = notificationSettings.isEnabled(toggle) ? .on : .off
                item.representedObject = NSNumber(value: toggle.rawValue)
                menu.addItem(item)
            }
            return menu
        }

        private func menuItem(
            _ title: String,
            systemImage: String? = nil,
            action: Selector?,
            isEnabled: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.isEnabled = isEnabled
            if let systemImage {
                ContextMenuItemSupport.configure(
                    item,
                    title: title,
                    systemImage: systemImage
                )
            }
            return item
        }

        @objc private func markReadFromMenu() {
            markRead()
        }

        @objc private func muteFromMenu(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue,
                  ChannelMuteDuration.allCases.indices.contains(index)
            else { return }
            mute(ChannelMuteDuration.allCases[index])
        }

        @objc private func unmuteFromMenu() {
            unmute()
        }

        @objc private func setNotificationFromMenu(_ sender: NSMenuItem) {
            guard let rawValue = (sender.representedObject as? NSNumber)?.intValue,
                  let level = MessageNotificationLevel(rawValue: rawValue)
            else { return }
            setNotificationLevel(level)
        }

        @objc private func setNotificationToggleFromMenu(_ sender: NSMenuItem) {
            guard let rawValue = (sender.representedObject as? NSNumber)?.intValue,
                  let toggle = GuildNotificationToggle(rawValue: rawValue)
            else { return }
            setNotificationToggle(toggle, !notificationSettings.isEnabled(toggle))
        }

        @objc private func copyServerIDFromMenu() {
            copyServerID()
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
        }
    }
}

final class ServerContextMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let eventType = window?.currentEvent?.type ?? NSApp.currentEvent?.type
        return eventType == .rightMouseDown ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
