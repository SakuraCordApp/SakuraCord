import AppKit
import SakuraCordModels
import SwiftUI

/// The actions for one thread or forum post, defined once for the channel
/// list, forum cards and the side chat's overflow menu. Entries only invoke
/// AppModel actions, which recheck ThreadActionPolicy when they run. Sections
/// follow the channel menu's order, with leaving and deleting last; Mute and
/// Notification Settings appear only for a joined thread.
@MainActor
struct ThreadActionsMenu {
    static let tagsSlotID = "tags"
    static let favoriteID = "favorite"

    let sections: [[ActionMenuEntry]]

    /// Menus outlive the state they were built from, so every action rechecks
    /// the thread's current policy when it is invoked.
    private static func guarded(
        _ model: AppModel,
        _ thread: MessageThreadSummary,
        _ allows: @escaping (ThreadActionPolicy) -> Bool,
        _ action: @escaping @MainActor () -> Void
    ) -> ActionMenuEntry.Content {
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
        let noun = AppModel.threadNoun(isForumPost: isForumPost)
        let isJoined = thread.notificationSettings != nil
        var sections: [[ActionMenuEntry]] = []

        if surface == .sidePane {
            sections.append([ActionMenuEntry(
                id: "full-view", title: "Open in Full View", systemImage: "arrow.up.left.and.arrow.down.right",
                // Widening only changes the layout; opening rechecks access.
                content: .action { model.openSidebarThread(thread) }
            )])
        }
        if surface == .channelList || surface == .forumCard {
            sections.append([ActionMenuEntry(
                id: "read", title: "Mark as Read", systemImage: "envelope.open.fill",
                isEnabled: policy.canRead && isUnread,
                content: Self.guarded(model, thread, \.canRead) { model.markConversationRead(channelID: thread.id) }
            )])
            if model.favorites.settings != nil {
                let isFavorite = model.isFavorite(thread.id)
                sections.append([ActionMenuEntry(
                    id: Self.favoriteID, title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.slash.fill" : "star.fill",
                    content: .action { model.toggleFavorite(thread.id, channelType: model.favoriteChannelType(for: thread)) }
                )])
            }
        }
        if policy.canManage, isForumPost {
            sections.append([ActionMenuEntry(
                id: "pin", title: thread.isPinned ? "Unpin Post" : "Pin Post",
                systemImage: thread.isPinned ? "pin.slash.fill" : "pin.fill",
                content: Self.guarded(model, thread, \.canManage) {
                    model.updateThread(thread, mutation: .pinned(!thread.isPinned))
                }
            )])
        }
        let membership: ActionMenuEntry? = policy.canRead ? ActionMenuEntry(
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

        var management: [ActionMenuEntry] = []
        if policy.canRename {
            management.append(ActionMenuEntry(
                id: "rename", title: "Edit \(noun)…", systemImage: "pencil",
                content: Self.guarded(model, thread, \.canRename) { model.presentThreadRename(thread) }
            ))
        }
        if offersTags, policy.canEditTags {
            management.append(ActionMenuEntry(id: Self.tagsSlotID, title: "Tags", systemImage: "tag.fill", content: .slot))
        }
        if policy.canChangeArchive {
            management.append(ActionMenuEntry(
                id: "archive", title: thread.isArchived ? "Reopen \(noun)" : "Close \(noun)",
                systemImage: thread.isArchived ? "arrow.uturn.backward.circle.fill" : "archivebox.fill",
                content: Self.guarded(model, thread, \.canChangeArchive) {
                    model.updateThread(thread, mutation: .archived(!thread.isArchived))
                }
            ))
        }
        if policy.canManage {
            management.append(ActionMenuEntry(
                id: "lock", title: thread.isLocked ? "Unlock \(noun)" : "Lock \(noun)",
                systemImage: thread.isLocked ? "lock.open.fill" : "lock.fill",
                content: Self.guarded(model, thread, \.canManage) { model.updateThread(thread, mutation: .locked(!thread.isLocked)) }
            ))
        }
        if !management.isEmpty { sections.append(management) }

        if policy.canChangeNotifications {
            sections.append(Self.notificationEntries(model: model, thread: thread, noun: noun))
        }

        let guildID = thread.guildID ?? thread.parentID.flatMap { model.messagePresentationChannelsByID[$0] }?.guildID
        sections.append([
            ActionMenuEntry(id: "copy-id", title: "Copy \(noun) ID", systemImage: "number.square.fill", content: Self.guarded(model, thread, \.canRead) {
                Pasteboard.copy(thread.id.description)
            }),
            ActionMenuEntry(id: "copy-link", title: "Copy Link", systemImage: "link", content: Self.guarded(model, thread, \.canRead) {
                Pasteboard.copy(DiscordLink.channel(guildID: guildID, channelID: thread.id))
            }),
        ])

        var destructive: [ActionMenuEntry] = []
        if let membership, isJoined { destructive.append(membership) }
        if policy.canDelete {
            destructive.append(ActionMenuEntry(
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
    ) -> [ActionMenuEntry] {
        let settings = thread.notificationSettings
        let isPending = model.isNotificationMutationPending(.forumPost(thread.id))
        let isMuted = SidebarThreadPolicy.isMuted(thread, now: .now)
        let mute = if isMuted {
            NotificationMenuItems.unmuteEntry(
                "Unmute \(noun)", until: settings?.muteConfiguration?.endTime, isEnabled: !isPending,
                content: Self.guarded(model, thread, \.canChangeNotifications) {
                    model.setThreadMute(thread, isMuted: false, until: nil)
                }
            )
        } else {
            NotificationMenuItems.muteEntry("Mute \(noun)", isEnabled: !isPending) { duration in
                Self.guarded(model, thread, \.canChangeNotifications) {
                    model.setThreadMute(thread, isMuted: true, until: duration.endDate())
                }
            }
        }
        let inherited = model.inheritedForumPostNotificationLevel(ForumPost(thread: thread))
        let configured = settings?.notificationLevel ?? .inherit
        // Default clears the thread's override so the parent's level applies again.
        let levels: [MessageNotificationLevel] = [.inherit, .allMessages, .onlyMentions, .nothing]
        let notifications = NotificationMenuItems.settingsEntry(
            selection: ChannelContextMenuSubtitle.notificationSelection(configured: configured, inherited: inherited),
            isEnabled: !isPending,
            levels: levels.map { level in
                NotificationMenuItems.levelEntry(
                    level,
                    // Named for its source with the inherited level beneath,
                    // as the channel menu presents its default.
                    title: level == .inherit ? "Use Channel Default" : level.menuTitle,
                    subtitle: level == .inherit ? inherited.menuTitle : nil,
                    selected: configured,
                    content: Self.guarded(model, thread, \.canChangeNotifications) {
                        model.setThreadNotificationLevel(thread, level: level)
                    }
                )
            }
        )
        return [mute, notifications]
    }
}
