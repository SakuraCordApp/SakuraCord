import AppKit
import SakuraCordModels
import SwiftUI

/// SwiftUI context menus currently discard item images in the macOS 27 menu
/// adaptation. This bridge renders the shared thread actions as a native
/// right-click menu and adds the forum card's tag picker with its emoji.
struct ForumPostContextMenuBridge: NSViewRepresentable {
    let actionsMenu: ThreadActionsMenu
    let tags: [ForumTag]
    let appliedTagIDs: [ForumTagID]
    let customEmojiURLsByID: CustomEmojiImageURLs
    let requiresTag: Bool
    let canManage: Bool
    let toggleTag: (ForumTagID) -> Void

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
        private var actionsMenu: ThreadActionsMenu
        private var tags: [ForumTag]
        private var appliedTagIDs: [ForumTagID]
        private var customEmojiURLsByID: CustomEmojiImageURLs
        private var requiresTag: Bool
        private var canManage: Bool
        private var toggleTag: (ForumTagID) -> Void
        private let renderer = ThreadActionsMenuRenderer()
        private var customTagImages: [ForumTagID: NSImage] = [:]
        private var imageTasks: [ForumTagID: Task<Void, Never>] = [:]

        init(from bridge: ForumPostContextMenuBridge) {
            actionsMenu = bridge.actionsMenu
            tags = bridge.tags
            appliedTagIDs = bridge.appliedTagIDs
            customEmojiURLsByID = bridge.customEmojiURLsByID
            requiresTag = bridge.requiresTag
            canManage = bridge.canManage
            toggleTag = bridge.toggleTag
            super.init()
        }

        deinit {
            for task in imageTasks.values { task.cancel() }
        }

        func update(from bridge: ForumPostContextMenuBridge) {
            actionsMenu = bridge.actionsMenu
            tags = bridge.tags
            appliedTagIDs = bridge.appliedTagIDs
            customEmojiURLsByID = bridge.customEmojiURLsByID
            requiresTag = bridge.requiresTag
            canManage = bridge.canManage
            toggleTag = bridge.toggleTag
        }

        func makeMenu() -> NSMenu {
            renderer.makeMenu(actionsMenu) { [self] entry in
                guard entry.id == ThreadActionsMenu.tagsSlotID else { return nil }
                preloadCustomTagImages()
                return tagsMenuItem()
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

        @objc private func toggleTagFromMenu(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? NSNumber else { return }
            toggleTag(ForumTagID(rawValue: value.uint64Value))
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
