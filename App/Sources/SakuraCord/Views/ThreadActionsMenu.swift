import AppKit
import SakuraCordModels
import SwiftUI

/// One item of a thread's action menu.
struct ThreadMenuEntry: Identifiable {
    enum Content {
        case action(@MainActor () -> Void)
        case submenu([ThreadMenuEntry])
        /// A surface-specific item, such as a forum card's tag picker, that the
        /// renderer supplies in this position.
        case slot
    }

    let id: String
    var title: String
    var systemImage: String?
    var subtitle: String?
    var isEnabled = true
    /// A choice among siblings; `isChecked` marks the current one.
    var isCheckable = false
    var isChecked = false
    var isDestructive = false
    var content: Content
}

/// The actions for one thread or forum post, defined once for the channel
/// list, forum cards and the side chat's overflow menu. Entries only invoke
/// AppModel actions, which recheck ThreadActionPolicy when they run. Sections
/// follow the channel menu's order, with leaving and deleting last; Mute and
/// Notification Settings appear only for a joined thread.
@MainActor
struct ThreadActionsMenu {
    static let tagsSlotID = "tags"

    let sections: [[ThreadMenuEntry]]

    init(sections: [[ThreadMenuEntry]]) {
        self.sections = sections
    }

    /// Menus outlive the state they were built from, so every action rechecks
    /// the thread's current policy when it is invoked.
    private static func guarded(
        _ model: AppModel,
        _ thread: MessageThreadSummary,
        _ allows: @escaping (ThreadActionPolicy) -> Bool,
        _ action: @escaping @MainActor () -> Void
    ) -> ThreadMenuEntry.Content {
        .action {
            guard allows(model.threadActionPolicy(model.currentThreadSummary(thread))) else { return }
            action()
        }
    }

    init(
        model: AppModel,
        thread: MessageThreadSummary,
        surface: ThreadActionSurface,
        isUnread: Bool = false,
        offersTags: Bool = false
    ) {
        let thread = model.currentThreadSummary(thread)
        let policy = model.threadActionPolicy(thread)
        let isForumPost = model.isForumThread(thread)
        let noun = isForumPost ? "Post" : "Thread"
        let isJoined = thread.notificationSettings != nil
        var sections: [[ThreadMenuEntry]] = []

        if surface == .sidePane {
            sections.append([ThreadMenuEntry(
                id: "full-view", title: "Open in Full View", systemImage: "arrow.up.left.and.arrow.down.right",
                // Widening only changes the layout; opening rechecks access.
                content: .action { model.openSidebarThread(thread) }
            )])
        }
        if surface == .channelList || surface == .forumCard {
            sections.append([ThreadMenuEntry(
                id: "read", title: "Mark as Read", systemImage: "envelope.open.fill",
                isEnabled: policy.canRead && isUnread,
                content: Self.guarded(model, thread, \.canRead) { model.markConversationRead(channelID: thread.id) }
            )])
        }
        if policy.canManage, isForumPost {
            sections.append([ThreadMenuEntry(
                id: "pin", title: thread.isPinned ? "Unpin Post" : "Pin Post",
                systemImage: thread.isPinned ? "pin.slash.fill" : "pin.fill",
                content: Self.guarded(model, thread, \.canManage) {
                    model.updateThread(thread, mutation: .pinned(!thread.isPinned))
                }
            )])
        }
        let membership: ThreadMenuEntry? = policy.canRead ? ThreadMenuEntry(
            id: "membership",
            title: isJoined
                ? (isForumPost ? "Unfollow Post" : "Leave Thread")
                : (isForumPost ? "Follow Post" : "Join Thread"),
            systemImage: isJoined ? "rectangle.portrait.and.arrow.right" : "plus.circle",
            isEnabled: policy.canChangeMembership,
            isDestructive: isJoined,
            content: Self.guarded(model, thread, \.canChangeMembership) {
                model.setThreadMembership(thread, isJoined: !isJoined, surface: surface)
            }
        ) : nil
        if let membership, !isJoined { sections.append([membership]) }

        var management: [ThreadMenuEntry] = []
        if policy.canRename {
            management.append(ThreadMenuEntry(
                id: "rename", title: "Edit \(noun)…", systemImage: "pencil",
                content: Self.guarded(model, thread, \.canRename) { model.presentThreadRename(thread) }
            ))
        }
        if offersTags, policy.canEditTags {
            management.append(ThreadMenuEntry(id: Self.tagsSlotID, title: "Tags", systemImage: "tag.fill", content: .slot))
        }
        if policy.canChangeArchive {
            management.append(ThreadMenuEntry(
                id: "archive", title: thread.isArchived ? "Reopen \(noun)" : "Close \(noun)",
                systemImage: thread.isArchived ? "arrow.uturn.backward.circle.fill" : "archivebox.fill",
                content: Self.guarded(model, thread, \.canChangeArchive) {
                    model.updateThread(thread, mutation: .archived(!thread.isArchived))
                }
            ))
        }
        if policy.canManage {
            management.append(ThreadMenuEntry(
                id: "lock", title: thread.isLocked ? "Unlock \(noun)" : "Lock \(noun)",
                systemImage: thread.isLocked ? "lock.open.fill" : "lock.fill",
                content: Self.guarded(model, thread, \.canLock) { model.updateThread(thread, mutation: .locked(!thread.isLocked)) }
            ))
        }
        if !management.isEmpty { sections.append(management) }

        if policy.canChangeNotifications {
            sections.append(Self.notificationEntries(model: model, thread: thread, noun: noun))
        }

        let guildID = thread.guildID ?? thread.parentID.flatMap { model.messagePresentationChannelsByID[$0] }?.guildID
        sections.append([
            ThreadMenuEntry(id: "copy-id", title: "Copy \(noun) ID", systemImage: "number.square.fill", content: Self.guarded(model, thread, \.canRead) {
                ChannelContextMenuValue.copy(thread.id.description)
            }),
            ThreadMenuEntry(id: "copy-link", title: "Copy Link", systemImage: "link", content: Self.guarded(model, thread, \.canRead) {
                ChannelContextMenuValue.copy(ChannelContextMenuValue.link(guildID: guildID, channelID: thread.id))
            }),
        ])

        var destructive: [ThreadMenuEntry] = []
        if let membership, isJoined { destructive.append(membership) }
        if policy.canDelete {
            destructive.append(ThreadMenuEntry(
                id: "delete", title: "Delete \(noun)…", systemImage: "trash", isDestructive: true,
                content: Self.guarded(model, thread, \.canDelete) { model.requestThreadDeletion(thread) }
            ))
        }
        if !destructive.isEmpty { sections.append(destructive) }
        self.sections = sections
    }

    private static func notificationEntries(
        model: AppModel,
        thread: MessageThreadSummary,
        noun: String
    ) -> [ThreadMenuEntry] {
        let settings = thread.notificationSettings
        let isPending = model.isForumNotificationMutationPending(thread.id)
        let isMuted = settings?.isMuted == true && (settings?.muteConfiguration?.isActive() ?? true)
        let mute: ThreadMenuEntry = if isMuted {
            ThreadMenuEntry(
                id: "mute", title: "Unmute \(noun)", systemImage: "bell.fill",
                subtitle: ChannelContextMenuSubtitle.muteRemaining(until: settings?.muteConfiguration?.endTime),
                isEnabled: !isPending,
                content: Self.guarded(model, thread, \.canChangeNotifications) {
                    model.setThreadMute(thread, isMuted: false, until: nil)
                }
            )
        } else {
            ThreadMenuEntry(
                id: "mute", title: "Mute \(noun)", systemImage: "bell.slash.fill", isEnabled: !isPending,
                content: .submenu(ChannelMuteDuration.allCases.map { duration in
                    ThreadMenuEntry(
                        id: "mute-\(duration.title)", title: duration.title,
                        content: Self.guarded(model, thread, \.canChangeNotifications) {
                            model.setThreadMute(thread, isMuted: true, until: duration.endDate())
                        }
                    )
                })
            )
        }
        let inherited = model.inheritedForumPostNotificationLevel(ForumPost(thread: thread))
        let configured = settings?.notificationLevel ?? .inherit
        // Default clears the thread's override so the parent's level applies again.
        let levels: [MessageNotificationLevel] = [.inherit, .allMessages, .onlyMentions, .nothing]
        let notifications = ThreadMenuEntry(
            id: "notifications", title: "Notification Settings", systemImage: "bell.badge.fill",
            subtitle: ChannelContextMenuSubtitle.notificationSelection(configured: configured, inherited: inherited),
            isEnabled: !isPending,
            content: .submenu(levels.map { level in
                ThreadMenuEntry(
                    id: "notifications-\(level.rawValue)",
                    // Named for its source with the inherited level beneath,
                    // as the channel menu presents its default.
                    title: level == .inherit ? "Use Channel Default" : level.menuTitle,
                    subtitle: level == .inherit ? inherited.menuTitle : nil,
                    isCheckable: true, isChecked: configured == level,
                    content: Self.guarded(model, thread, \.canChangeNotifications) {
                        model.setThreadNotificationLevel(thread, level: level)
                    }
                )
            })
        )
        return [mute, notifications]
    }
}

/// Renders a ThreadActionsMenu as a native AppKit menu for right-click menus,
/// which keep item images and subtitles. Keep the renderer alive while its
/// menu is open; it owns the item actions.
@MainActor
final class ThreadActionsMenuRenderer: NSObject {
    private var actions: [@MainActor () -> Void] = []

    func makeMenu(_ actionsMenu: ThreadActionsMenu, slot: (ThreadMenuEntry) -> NSMenuItem? = { _ in nil }) -> NSMenu {
        actions.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, section) in actionsMenu.sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in section {
                if let item = menuItem(entry, slot: slot) { menu.addItem(item) }
            }
        }
        return menu
    }

    private func menuItem(_ entry: ThreadMenuEntry, slot: (ThreadMenuEntry) -> NSMenuItem?) -> NSMenuItem? {
        if case .slot = entry.content { return slot(entry) }
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        item.isEnabled = entry.isEnabled
        item.state = entry.isChecked ? .on : .off
        if let systemImage = entry.systemImage {
            ContextMenuItemSupport.configure(
                item, title: entry.title, systemImage: systemImage, isDestructive: entry.isDestructive
            )
        }
        if let subtitle = entry.subtitle { item.subtitle = subtitle }
        switch entry.content {
        case .action(let action):
            item.action = #selector(invoke(_:))
            item.target = self
            item.tag = actions.count
            actions.append(action)
        case .submenu(let children):
            let submenu = NSMenu(title: entry.title)
            submenu.autoenablesItems = false
            for child in children {
                if let childItem = menuItem(child, slot: slot) { submenu.addItem(childItem) }
            }
            item.submenu = submenu
        case .slot:
            break
        }
        return item
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
