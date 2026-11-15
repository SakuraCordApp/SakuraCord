import AppKit
import SakuraCordModels
import SwiftUI

extension ServerRailContextMenuActions {
    /// A server tile's menu.
    func serverMenu(for guild: Guild, notificationSettings settings: GuildNotificationSettings, isMutationPending: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canMutate = !isMutationPending
        menu.addItem(
            ContextMenuItemSupport.item("Mark as Read", systemImage: "envelope.open.fill", isEnabled: guild.unreadCount > 0 && canMutate) {
                markRead(guild.id)
            }
        )
        menu.addItem(.separator())
        menu.addItem(ContextMenuItemSupport.item("Invite to Server", systemImage: "person.badge.plus.fill", isEnabled: canInvite(guild)) { invite(guild) })
        menu.addItem(.separator())

        let muteEntry = if settings.isActivelyMuted() {
            NotificationMenuItems.unmuteEntry(
                "Unmute Server",
                until: settings.muteConfiguration?.endTime,
                isEnabled: canMutate,
                content: .action { unmute(guild) }
            )
        } else {
            NotificationMenuItems.muteEntry("Mute Server", isEnabled: canMutate) { duration in
                .action { mute(guild, duration) }
            }
        }
        menu.addItem(ActionMenuRenderer.item(muteEntry))

        let notificationItem = ActionMenuRenderer.item(NotificationMenuItems.settingsEntry(
            selection: settings.messageNotifications.menuTitle,
            isEnabled: canMutate,
            levels: [MessageNotificationLevel.allMessages, .onlyMentions, .nothing].map { level in
                NotificationMenuItems.levelEntry(
                    level, title: level.menuTitle, subtitle: nil, selected: settings.messageNotifications,
                    content: .action { setNotificationLevel(guild, level) }
                )
            }
        ))
        if let submenu = notificationItem.submenu {
            appendNotificationToggles(to: submenu, guild: guild, settings: settings, isEnabled: canMutate)
        }
        menu.addItem(notificationItem)

        let hideMutedItem = ContextMenuItemSupport.item("Hide Muted Channels", systemImage: "eye.slash.fill", isEnabled: canMutate) {
            setNotificationToggle(guild, .hideMutedChannels, !settings.hideMutedChannels)
        }
        hideMutedItem.state = settings.hideMutedChannels ? .on : .off
        menu.addItem(hideMutedItem)

        if let all = showsAllChannels(guild) {
            let allItem = ContextMenuItemSupport.item("Show All Channels", systemImage: "list.bullet") {
                guard let all = showsAllChannels(guild) else { return }
                setShowsAllChannels(guild, !all)
            }
            allItem.state = all ? .on : .off
            menu.addItem(allItem)
        }

        menu.addItem(.separator())
        menu.addItem(ContextMenuItemSupport.item("Copy Server ID", systemImage: "number.square.fill") { Pasteboard.copy(guild.id.description) })
        if guild.isOwnedByCurrentUser == false, !guild.isUnavailable {
            menu.addItem(.separator())
            menu.addItem(
                ContextMenuItemSupport.item("Leave Server", systemImage: "rectangle.portrait.and.arrow.right", isDestructive: true) {
                    leaveServer(guild)
                }
            )
        }
        return menu
    }

    /// The server's suppression and push toggles, below the levels.
    private func appendNotificationToggles(to menu: NSMenu, guild: Guild, settings: GuildNotificationSettings, isEnabled: Bool) {
        menu.addItem(.separator())
        for toggle in GuildNotificationToggle.allCases where toggle != .hideMutedChannels {
            if toggle == .mobilePush {
                menu.addItem(.separator())
            }
            let toggleItem = ContextMenuItemSupport.item(toggle.menuTitle, isEnabled: isEnabled) {
                setNotificationToggle(guild, toggle, !settings.isEnabled(toggle))
            }
            toggleItem.state = settings.isEnabled(toggle) ? .on : .off
            menu.addItem(toggleItem)
        }
    }

    /// A server folder's menu.
    func folderMenu(for entry: ServerRailFolderEntry) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ContextMenuItemSupport.item(
            "Mark Folder as Read",
            systemImage: "envelope.open.fill",
            isEnabled: entry.hasUnreadGuild || entry.mentionCount > 0
        ) { markFolderRead(entry.guildEntries.map(\.id)) })
        menu.addItem(.separator())
        menu.addItem(ContextMenuItemSupport.item(
            "Folder Settings",
            systemImage: "folder.fill.badge.gearshape"
        ) { openFolderSettings(entry.folder) })
        return menu
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

/// A rail tile's native context menu, built when it opens, hosted so a left
/// click still reaches the tile's button.
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
