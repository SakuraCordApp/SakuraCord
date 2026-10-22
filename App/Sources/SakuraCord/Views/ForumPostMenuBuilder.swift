import AppKit
import SakuraCordModels

/// SwiftUI context menus currently discard item images in the macOS 27 menu
/// adaptation. This builds the shared thread actions as a native right-click
/// menu and adds the forum card's tag picker with its emoji.
@MainActor
final class ForumPostMenuBuilder: NSObject {
    private let renderer = ThreadActionsMenuRenderer()
    private var customTagImages: [ForumTagID: NSImage] = [:]
    private var imageTasks: [ForumTagID: Task<Void, Never>] = [:]
    private var toggleTag: (ForumTagID) -> Void = { _ in }

    deinit {
        for task in imageTasks.values { task.cancel() }
    }

    func makeMenu(
        actionsMenu: ThreadActionsMenu,
        tags: [ForumTag],
        appliedTagIDs: [ForumTagID],
        customEmojiURLsByID: CustomEmojiImageURLs,
        requiresTag: Bool,
        canManage: Bool,
        toggleTag: @escaping (ForumTagID) -> Void
    ) -> NSMenu {
        self.toggleTag = toggleTag
        return renderer.makeMenu(actionsMenu) { [self] entry in
            guard entry.id == ThreadActionsMenu.tagsSlotID else { return nil }
            preloadCustomTagImages(for: tags, customEmojiURLsByID: customEmojiURLsByID)
            return tagsMenuItem(tags: tags, appliedTagIDs: appliedTagIDs, requiresTag: requiresTag, canManage: canManage)
        }
    }

    private func tagsMenuItem(
        tags: [ForumTag],
        appliedTagIDs: [ForumTagID],
        requiresTag: Bool,
        canManage: Bool
    ) -> NSMenuItem {
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

    private func preloadCustomTagImages(for tags: [ForumTag], customEmojiURLsByID: CustomEmojiImageURLs) {
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
