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
        private var actions: [() -> Void] = []

        init(_ bridge: ThreadContextMenuBridge) { self.bridge = bridge }

        func makeMenu() -> NSMenu {
            actions.removeAll()
            let model = bridge.model
            let row = bridge.row
            let thread = model.sidebarThread(row.id) ?? row.thread
            let permissions = model.threadActionPolicy(thread)
            let isForum = thread.parentID.flatMap { model.messagePresentationChannelsByID[$0] }?.kind == .forum
            let noun = isForum ? "Post" : "Thread"
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(item("Mark as Read", symbol: "envelope.open.fill", enabled: permissions.canRead && (row.isUnread || row.mentionCount > 0)) {
                guard model.threadActionPolicy(thread).canRead else { return }
                model.markConversationRead(channelID: thread.id)
            })
            menu.addItem(.separator())
            let pending = model.isForumNotificationMutationPending(thread.id)
            if SidebarThreadPolicy.isMuted(thread, now: .now) {
                menu.addItem(item("Unmute \(noun)", symbol: "bell.fill", enabled: permissions.canChangeNotifications && !pending) {
                    model.setSidebarThreadMute(thread, isMuted: false, until: nil)
                })
            } else {
                let mute = item("Mute \(noun)", symbol: "bell.slash.fill", enabled: permissions.canChangeNotifications && !pending)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for duration in ChannelMuteDuration.allCases {
                    submenu.addItem(item(duration.title) {
                        model.setSidebarThreadMute(thread, isMuted: true, until: duration.endDate())
                    })
                }
                mute.submenu = submenu
                menu.addItem(mute)
            }
            let notifications = item("Notification Settings", symbol: "bell.badge.fill", enabled: permissions.canChangeNotifications && !pending)
            let levels = NSMenu()
            levels.autoenablesItems = false
            for level: MessageNotificationLevel in [.inherit, .allMessages, .onlyMentions, .nothing] {
                let choice = item(level.menuTitle) { model.setSidebarThreadNotificationLevel(thread, level: level) }
                choice.state = (thread.notificationSettings?.notificationLevel ?? .inherit) == level ? .on : .off
                levels.addItem(choice)
            }
            notifications.submenu = levels
            menu.addItem(notifications)
            menu.addItem(.separator())
            let joined = thread.notificationSettings != nil
            menu.addItem(item(joined ? "Leave \(noun)" : "Follow \(noun)", symbol: joined ? "rectangle.portrait.and.arrow.right" : "plus.circle", enabled: permissions.canChangeMembership) {
                model.setSidebarThreadMembership(thread, isJoined: !joined)
            })
            if model.canArchiveSidebarThread(thread) {
                menu.addItem(item(thread.isArchived ? "Reopen \(noun)" : "Close \(noun)", symbol: "archivebox.fill") {
                    model.updateSidebarThread(thread, mutation: .archived(!thread.isArchived))
                })
            }
            if model.canManageSidebarThread(thread) {
                menu.addItem(item(thread.isLocked ? "Unlock \(noun)" : "Lock \(noun)", symbol: thread.isLocked ? "lock.open.fill" : "lock.fill") {
                    model.updateSidebarThread(thread, mutation: .locked(!thread.isLocked))
                })
                if isForum {
                    menu.addItem(item(thread.isPinned ? "Unpin Post" : "Pin Post", symbol: "pin.fill") {
                        model.updateSidebarThread(thread, mutation: .pinned(!thread.isPinned))
                    })
                }
            }
            menu.addItem(.separator())
            menu.addItem(item("Copy Link", symbol: "link") {
                ChannelContextMenuValue.copy(ChannelContextMenuValue.link(guildID: thread.guildID, channelID: thread.id))
            })
            menu.addItem(item("Copy \(noun) ID", symbol: "number") {
                ChannelContextMenuValue.copy(thread.id.description)
            })
            if permissions.canDelete {
                menu.addItem(.separator())
                menu.addItem(item("Delete \(noun)…", symbol: "trash", isDestructive: true) {
                    guard let window = NSApp.keyWindow else { return }
                    let alert = NSAlert()
                    alert.messageText = "Delete \(thread.name)?"
                    alert.informativeText = "This permanently deletes the \(noun.lowercased()) and its messages."
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    alert.buttons.first?.hasDestructiveAction = true
                    alert.beginSheetModal(for: window) { response in
                        if response == .alertFirstButtonReturn { model.deleteSidebarThread(thread) }
                    }
                })
            }
            return menu
        }

        private func item(_ title: String, symbol: String? = nil, enabled: Bool = true, isDestructive: Bool = false, action: @escaping () -> Void = {}) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = self
            item.tag = actions.count
            item.isEnabled = enabled
            actions.append(action)
            if let symbol { ContextMenuItemSupport.configure(item, title: title, systemImage: symbol, isDestructive: isDestructive) }
            return item
        }

        @objc private func invoke(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}
