import AppKit
import SakuraCordModels
import SwiftUI

/// SwiftUI context menus currently discard item images in the macOS 27 menu
/// adaptation. This bridge keeps forum state in SwiftUI while AppKit owns only
/// the native right-click menu presentation and checked item state.
struct ForumPostContextMenuBridge: NSViewRepresentable {
    let tags: [ForumTag]
    let appliedTagIDs: [ForumTagID]
    let customEmojiURLsByID: [String: URL]
    let isArchived: Bool
    let isLocked: Bool
    let isPinned: Bool
    let isUnread: Bool
    let isMutationPending: Bool
    let notificationSettings: ThreadNotificationSettings?
    let inheritedNotificationLevel: MessageNotificationLevel
    let requiresTag: Bool
    let canManage: Bool
    let canArchive: Bool
    let canEditTags: Bool
    let canDelete: Bool
    let markRead: () -> Void
    let mute: (ChannelMuteDuration) -> Void
    let unmute: () -> Void
    let setNotificationLevel: (MessageNotificationLevel) -> Void
    let copyLink: () -> Void
    let copyThreadID: () -> Void
    let toggleTag: (ForumTagID) -> Void
    let toggleArchive: () -> Void
    let toggleLock: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(from: self)
    }

    func makeNSView(context: Context) -> ForumPostContextMenuHitView {
        let view = ForumPostContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: ForumPostContextMenuHitView, context: Context) {
        context.coordinator.update(from: self)
        nsView.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var tags: [ForumTag]
        private var appliedTagIDs: [ForumTagID]
        private var customEmojiURLsByID: [String: URL]
        private var isArchived: Bool
        private var isLocked: Bool
        private var isPinned: Bool
        private var isUnread: Bool
        private var isMutationPending: Bool
        private var notificationSettings: ThreadNotificationSettings?
        private var inheritedNotificationLevel: MessageNotificationLevel
        private var requiresTag: Bool
        private var canManage: Bool
        private var canArchive: Bool
        private var canEditTags: Bool
        private var canDelete: Bool
        private var markRead: () -> Void
        private var mute: (ChannelMuteDuration) -> Void
        private var unmute: () -> Void
        private var setNotificationLevel: (MessageNotificationLevel) -> Void
        private var copyLink: () -> Void
        private var copyThreadID: () -> Void
        private var toggleTag: (ForumTagID) -> Void
        private var toggleArchive: () -> Void
        private var toggleLock: () -> Void
        private var togglePin: () -> Void
        private var delete: () -> Void
        private var customTagImages: [ForumTagID: NSImage] = [:]
        private var imageTasks: [ForumTagID: Task<Void, Never>] = [:]

        init(from bridge: ForumPostContextMenuBridge) {
            tags = bridge.tags
            appliedTagIDs = bridge.appliedTagIDs
            customEmojiURLsByID = bridge.customEmojiURLsByID
            isArchived = bridge.isArchived
            isLocked = bridge.isLocked
            isPinned = bridge.isPinned
            isUnread = bridge.isUnread
            isMutationPending = bridge.isMutationPending
            notificationSettings = bridge.notificationSettings
            inheritedNotificationLevel = bridge.inheritedNotificationLevel
            requiresTag = bridge.requiresTag
            canManage = bridge.canManage
            canArchive = bridge.canArchive
            canEditTags = bridge.canEditTags
            canDelete = bridge.canDelete
            markRead = bridge.markRead
            mute = bridge.mute
            unmute = bridge.unmute
            setNotificationLevel = bridge.setNotificationLevel
            copyLink = bridge.copyLink
            copyThreadID = bridge.copyThreadID
            toggleTag = bridge.toggleTag
            toggleArchive = bridge.toggleArchive
            toggleLock = bridge.toggleLock
            togglePin = bridge.togglePin
            delete = bridge.delete
            super.init()
        }

        deinit {
            for task in imageTasks.values { task.cancel() }
        }

        func update(from bridge: ForumPostContextMenuBridge) {
            tags = bridge.tags
            appliedTagIDs = bridge.appliedTagIDs
            customEmojiURLsByID = bridge.customEmojiURLsByID
            isArchived = bridge.isArchived
            isLocked = bridge.isLocked
            isPinned = bridge.isPinned
            isUnread = bridge.isUnread
            isMutationPending = bridge.isMutationPending
            notificationSettings = bridge.notificationSettings
            inheritedNotificationLevel = bridge.inheritedNotificationLevel
            requiresTag = bridge.requiresTag
            canManage = bridge.canManage
            canArchive = bridge.canArchive
            canEditTags = bridge.canEditTags
            canDelete = bridge.canDelete
            markRead = bridge.markRead
            mute = bridge.mute
            unmute = bridge.unmute
            setNotificationLevel = bridge.setNotificationLevel
            copyLink = bridge.copyLink
            copyThreadID = bridge.copyThreadID
            toggleTag = bridge.toggleTag
            toggleArchive = bridge.toggleArchive
            toggleLock = bridge.toggleLock
            togglePin = bridge.togglePin
            delete = bridge.delete
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            menu.addItem(
                menuItem(
                    "Mark as Read",
                    systemImage: "envelope.open.fill",
                    action: #selector(markReadFromMenu),
                    isEnabled: isUnread
                )
            )
            menu.addItem(.separator())

            addMuteItems(to: menu)
            addManagementItems(to: menu)
            addCopyAndDeleteItems(to: menu)
            return menu
        }

        private func addMuteItems(to menu: NSMenu) {
            if isDirectlyMuted {
                let unmuteItem = menuItem(
                    "Unmute Post",
                    systemImage: "bell.fill",
                    action: #selector(unmuteFromMenu),
                    isEnabled: !isMutationPending
                )
                if let subtitle = ChannelContextMenuSubtitle.muteRemaining(
                    until: notificationSettings?.muteConfiguration?.endTime
                ) {
                    unmuteItem.subtitle = subtitle
                }
                menu.addItem(unmuteItem)
            } else {
                let muteItem = menuItem(
                    "Mute Post",
                    systemImage: "bell.slash.fill",
                    action: nil,
                    isEnabled: !isMutationPending
                )
                let muteMenu = NSMenu(title: "Mute Post")
                muteMenu.autoenablesItems = false
                for (index, duration) in ChannelMuteDuration.allCases.enumerated() {
                    let item = menuItem(
                        duration.title,
                        action: #selector(muteFromMenu(_:)),
                        isEnabled: !isMutationPending
                    )
                    item.representedObject = NSNumber(value: index)
                    muteMenu.addItem(item)
                }
                muteItem.submenu = muteMenu
                menu.addItem(muteItem)
            }

            let notificationItem = menuItem(
                "Notification Settings",
                systemImage: "bell.badge.fill",
                action: nil,
                isEnabled: !isMutationPending
            )
            notificationItem.subtitle =
                ChannelContextMenuSubtitle.notificationSelection(
                    configured: notificationSettings?.notificationLevel ?? .inherit,
                    inherited: inheritedNotificationLevel
                )
            notificationItem.submenu = notificationMenu()
            menu.addItem(notificationItem)
            menu.addItem(.separator())
        }

        private func addManagementItems(to menu: NSMenu) {
            if canEditTags || canArchive || canManage {
                if canEditTags {
                    preloadCustomTagImages()
                    menu.addItem(tagsMenuItem())
                }
                if canArchive {
                    menu.addItem(
                        menuItem(
                            isArchived ? "Reopen Post" : "Close Post",
                            systemImage: isArchived
                                ? "arrow.uturn.backward.circle.fill"
                                : "archivebox.fill",
                            action: #selector(toggleArchiveFromMenu)
                        )
                    )
                }
                if canManage {
                    menu.addItem(
                        menuItem(
                            isLocked ? "Unlock Post" : "Lock Post",
                            systemImage: isLocked ? "lock.open.fill" : "lock.fill",
                            action: #selector(toggleLockFromMenu)
                        )
                    )
                    menu.addItem(
                        menuItem(
                            isPinned ? "Unpin Post" : "Pin Post",
                            systemImage: isPinned ? "pin.slash.fill" : "pin.fill",
                            action: #selector(togglePinFromMenu)
                        )
                    )
                }
                menu.addItem(.separator())
            }
        }

        private func tagsMenuItem() -> NSMenuItem {
            let tagsItem = menuItem("Tags", systemImage: "tag.fill", action: nil)
            let tagsMenu = NSMenu(title: "Tags")
            tagsMenu.autoenablesItems = false
            for tag in tags {
                let item = NSMenuItem(
                    title: tag.name,
                    action: #selector(toggleTagFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                let isApplied = appliedTagIDs.contains(tag.id)
                let wouldRemoveRequiredLastTag =
                    requiresTag && isApplied && appliedTagIDs.count == 1
                item.isEnabled = (canManage || !tag.isModerated)
                    && !wouldRemoveRequiredLastTag
                item.state = isApplied ? .on : .off
                item.representedObject = NSNumber(value: tag.id.rawValue)
                item.image = menuImage(for: tag)
                forceVisibleImage(for: item)
                tagsMenu.addItem(item)
            }
            tagsItem.submenu = tagsMenu
            return tagsItem
        }

        private func addCopyAndDeleteItems(to menu: NSMenu) {
            menu.addItem(
                menuItem(
                    "Copy Link",
                    systemImage: "link",
                    action: #selector(copyLinkFromMenu)
                )
            )
            menu.addItem(
                menuItem(
                    "Copy Thread ID",
                    systemImage: "number.square.fill",
                    action: #selector(copyThreadIDFromMenu)
                )
            )

            if canDelete {
                menu.addItem(.separator())
                menu.addItem(
                    menuItem(
                        "Delete Post",
                        systemImage: "trash",
                        action: #selector(deletePostFromMenu),
                        isDestructive: true
                    )
                )
            }
        }

        private func preloadCustomTagImages() {
            for tag in tags {
                guard customTagImages[tag.id] == nil, imageTasks[tag.id] == nil,
                      let emojiID = tag.emojiID,
                      let url = customEmojiURLsByID[emojiID]
                      ?? EmojiReference(
                          id: emojiID,
                          name: tag.emojiName ?? "emoji"
                      ).imageURL(size: 64)
                else { continue }
                imageTasks[tag.id] = Task { [weak self] in
                    defer { self?.imageTasks[tag.id] = nil }
                    guard let image = await ForumTagMenuImageStore.shared.image(for: url),
                          !Task.isCancelled
                    else { return }
                    self?.customTagImages[tag.id] = image
                }
            }
        }

        private func menuImage(for tag: ForumTag) -> NSImage? {
            if tag.emojiID != nil {
                return customTagImages[tag.id]
                    ?? symbolImage("tag", accessibilityDescription: tag.name)
            }
            if let emoji = tag.emojiName, !emoji.isEmpty {
                return nativeEmojiImage(emoji)
            }
            return symbolImage("tag", accessibilityDescription: tag.name)
        }

        private var isDirectlyMuted: Bool {
            notificationSettings?.isMuted == true
                && (notificationSettings?.muteConfiguration?.isActive() ?? true)
        }

        private func notificationMenu() -> NSMenu {
            let menu = NSMenu(title: "Notification Settings")
            menu.autoenablesItems = false
            let configured = notificationSettings?.notificationLevel ?? .inherit
            let selected =
                configured == .inherit ? inheritedNotificationLevel : configured
            let levels: [MessageNotificationLevel] = [
                .allMessages, .onlyMentions, .nothing,
            ]
            for level in levels {
                let item = menuItem(
                    level.menuTitle,
                    action: #selector(setNotificationFromMenu(_:)),
                    isEnabled: !isMutationPending
                )
                item.state = selected == level ? .on : .off
                item.representedObject = NSNumber(value: level.rawValue)
                menu.addItem(item)
            }
            return menu
        }

        private func menuItem(
            _ title: String,
            systemImage: String? = nil,
            action: Selector?,
            isDestructive: Bool = false,
            isEnabled: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.isEnabled = isEnabled
            if let systemImage {
                ContextMenuItemSupport.configure(
                    item,
                    title: title,
                    systemImage: systemImage,
                    isDestructive: isDestructive
                )
            }
            return item
        }

        private func symbolImage(
            _ name: String,
            accessibilityDescription: String
        ) -> NSImage? {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: accessibilityDescription
            )?.withSymbolConfiguration(configuration)
            image?.isTemplate = true
            return image
        }

        private func nativeEmojiImage(_ emoji: String) -> NSImage {
            let image = NSImage(size: NSSize(width: 18, height: 18))
            image.lockFocus()
            let value = NSAttributedString(
                string: emoji,
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
            let size = value.size()
            value.draw(
                at: NSPoint(
                    x: (18 - size.width) / 2,
                    y: (18 - size.height) / 2
                )
            )
            image.unlockFocus()
            image.isTemplate = false
            return image
        }

        private func forceVisibleImage(for item: NSMenuItem) {
            item.preferredImageVisibility = .visible
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

        @objc private func copyLinkFromMenu() {
            copyLink()
        }

        @objc private func copyThreadIDFromMenu() {
            copyThreadID()
        }

        @objc private func toggleTagFromMenu(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? NSNumber else { return }
            toggleTag(ForumTagID(rawValue: value.uint64Value))
        }

        @objc private func toggleLockFromMenu() {
            toggleLock()
        }

        @objc private func toggleArchiveFromMenu() {
            toggleArchive()
        }

        @objc private func togglePinFromMenu() {
            togglePin()
        }

        @objc private func deletePostFromMenu() {
            delete()
        }
    }
}

@MainActor
private final class ForumTagMenuImageStore {
    static let shared = ForumTagMenuImageStore()

    private let images = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        images.countLimit = 256
        images.totalCostLimit = 256 * 16 * 16 * 4
    }

    func image(for url: URL) async -> NSImage? {
        let cacheKey = url as NSURL
        if let image = images.object(forKey: cacheKey) { return image }
        if let task = inFlight[url] { return await task.value }

        let task = Task<NSImage?, Never> {
            guard let data = try? await SharedMediaDataLoader.shared.data(for: url),
                  !Task.isCancelled,
                  let image = NSImage(data: data)
            else { return nil }
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            images.setObject(image, forKey: cacheKey, cost: 16 * 16 * 4)
        }
        return image
    }
}

final class ForumPostContextMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent else { return nil }
        if event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        {
            return self
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
