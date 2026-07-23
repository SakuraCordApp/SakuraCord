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
    let requiresTag: Bool
    let canManage: Bool
    let canArchive: Bool
    let canEditTags: Bool
    let canDelete: Bool
    let open: () -> Void
    let copyLink: () -> Void
    let copyThreadID: () -> Void
    let toggleTag: (ForumTagID) -> Void
    let toggleArchive: () -> Void
    let toggleLock: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tags: tags,
            appliedTagIDs: appliedTagIDs,
            customEmojiURLsByID: customEmojiURLsByID,
            isArchived: isArchived,
            isLocked: isLocked,
            isPinned: isPinned,
            requiresTag: requiresTag,
            canManage: canManage,
            canArchive: canArchive,
            canEditTags: canEditTags,
            canDelete: canDelete,
            open: open,
            copyLink: copyLink,
            copyThreadID: copyThreadID,
            toggleTag: toggleTag,
            toggleArchive: toggleArchive,
            toggleLock: toggleLock,
            togglePin: togglePin,
            delete: delete
        )
    }

    func makeNSView(context: Context) -> ForumPostContextMenuHitView {
        let view = ForumPostContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: ForumPostContextMenuHitView, context: Context) {
        context.coordinator.update(
            tags: tags,
            appliedTagIDs: appliedTagIDs,
            customEmojiURLsByID: customEmojiURLsByID,
            isArchived: isArchived,
            isLocked: isLocked,
            isPinned: isPinned,
            requiresTag: requiresTag,
            canManage: canManage,
            canArchive: canArchive,
            canEditTags: canEditTags,
            canDelete: canDelete,
            open: open,
            copyLink: copyLink,
            copyThreadID: copyThreadID,
            toggleTag: toggleTag,
            toggleArchive: toggleArchive,
            toggleLock: toggleLock,
            togglePin: togglePin,
            delete: delete
        )
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
        private var requiresTag: Bool
        private var canManage: Bool
        private var canArchive: Bool
        private var canEditTags: Bool
        private var canDelete: Bool
        private var open: () -> Void
        private var copyLink: () -> Void
        private var copyThreadID: () -> Void
        private var toggleTag: (ForumTagID) -> Void
        private var toggleArchive: () -> Void
        private var toggleLock: () -> Void
        private var togglePin: () -> Void
        private var delete: () -> Void
        private var customTagImages: [ForumTagID: NSImage] = [:]
        private var imageTasks: [ForumTagID: Task<Void, Never>] = [:]

        init(
            tags: [ForumTag],
            appliedTagIDs: [ForumTagID],
            customEmojiURLsByID: [String: URL],
            isArchived: Bool,
            isLocked: Bool,
            isPinned: Bool,
            requiresTag: Bool,
            canManage: Bool,
            canArchive: Bool,
            canEditTags: Bool,
            canDelete: Bool,
            open: @escaping () -> Void,
            copyLink: @escaping () -> Void,
            copyThreadID: @escaping () -> Void,
            toggleTag: @escaping (ForumTagID) -> Void,
            toggleArchive: @escaping () -> Void,
            toggleLock: @escaping () -> Void,
            togglePin: @escaping () -> Void,
            delete: @escaping () -> Void
        ) {
            self.tags = tags
            self.appliedTagIDs = appliedTagIDs
            self.customEmojiURLsByID = customEmojiURLsByID
            self.isArchived = isArchived
            self.isLocked = isLocked
            self.isPinned = isPinned
            self.requiresTag = requiresTag
            self.canManage = canManage
            self.canArchive = canArchive
            self.canEditTags = canEditTags
            self.canDelete = canDelete
            self.open = open
            self.copyLink = copyLink
            self.copyThreadID = copyThreadID
            self.toggleTag = toggleTag
            self.toggleArchive = toggleArchive
            self.toggleLock = toggleLock
            self.togglePin = togglePin
            self.delete = delete
            super.init()
        }

        deinit {
            for task in imageTasks.values { task.cancel() }
        }

        func update(
            tags: [ForumTag],
            appliedTagIDs: [ForumTagID],
            customEmojiURLsByID: [String: URL],
            isArchived: Bool,
            isLocked: Bool,
            isPinned: Bool,
            requiresTag: Bool,
            canManage: Bool,
            canArchive: Bool,
            canEditTags: Bool,
            canDelete: Bool,
            open: @escaping () -> Void,
            copyLink: @escaping () -> Void,
            copyThreadID: @escaping () -> Void,
            toggleTag: @escaping (ForumTagID) -> Void,
            toggleArchive: @escaping () -> Void,
            toggleLock: @escaping () -> Void,
            togglePin: @escaping () -> Void,
            delete: @escaping () -> Void
        ) {
            self.tags = tags
            self.appliedTagIDs = appliedTagIDs
            self.customEmojiURLsByID = customEmojiURLsByID
            self.isArchived = isArchived
            self.isLocked = isLocked
            self.isPinned = isPinned
            self.requiresTag = requiresTag
            self.canManage = canManage
            self.canArchive = canArchive
            self.canEditTags = canEditTags
            self.canDelete = canDelete
            self.open = open
            self.copyLink = copyLink
            self.copyThreadID = copyThreadID
            self.toggleTag = toggleTag
            self.toggleArchive = toggleArchive
            self.toggleLock = toggleLock
            self.togglePin = togglePin
            self.delete = delete
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            menu.addItem(
                menuItem(
                    "Open Post",
                    systemImage: "bubble.left.and.bubble.right.fill",
                    action: #selector(openPostFromMenu)
                )
            )
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
                    systemImage: "number",
                    action: #selector(copyThreadIDFromMenu)
                )
            )

            if canEditTags || canArchive || canManage {
                menu.addItem(.separator())
                if canEditTags {
                    preloadCustomTagImages()
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
                    menu.addItem(tagsItem)
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
            }
            if canDelete {
                if !menu.items.isEmpty {
                    menu.addItem(.separator())
                }
                menu.addItem(
                    menuItem(
                        "Delete Post",
                        systemImage: "trash",
                        action: #selector(deletePostFromMenu),
                        isDestructive: true
                    )
                )
            }
            return menu
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

        private func menuItem(
            _ title: String,
            systemImage: String,
            action: Selector?,
            isDestructive: Bool = false
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.isEnabled = true

            let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let configuration =
                isDestructive
                    ? baseConfiguration.applying(
                        NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                    )
                    : baseConfiguration
            if let image = NSImage(
                systemSymbolName: systemImage,
                accessibilityDescription: title
            )?.withSymbolConfiguration(configuration) {
                image.isTemplate = !isDestructive
                item.image = image
            }
            forceVisibleImage(for: item)
            if isDestructive {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.systemRed]
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
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
        }

        @objc private func openPostFromMenu() {
            open()
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
