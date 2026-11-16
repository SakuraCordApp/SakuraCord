import AppKit

@MainActor
final class EmojiPickerContextMenu {
    private var item: EmojiPickerItem
    private var skinTone: NativeEmojiSkinTone
    private var isFavorite: Bool
    private var toggleFavorite: () -> Void

    init(item: EmojiPickerItem, skinTone: NativeEmojiSkinTone, isFavorite: Bool, toggleFavorite: @escaping () -> Void) {
        self.item = item
        self.skinTone = skinTone
        self.isFavorite = isFavorite
        self.toggleFavorite = toggleFavorite
    }

    func update(item: EmojiPickerItem, skinTone: NativeEmojiSkinTone, isFavorite: Bool, toggleFavorite: @escaping () -> Void) {
        self.item = item
        self.skinTone = skinTone
        self.isFavorite = isFavorite
        self.toggleFavorite = toggleFavorite
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ContextMenuItemSupport.item(
            isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: isFavorite ? "star" : "star.fill",
            action: { [self] in toggleFavorite() }
        ))
        menu.addItem(.separator())

        switch item {
        case let .native(emoji):
            let value = emoji.value(for: skinTone)
            menu.addItem(ContextMenuItemSupport.item("Copy Emoji", systemImage: "document.on.document.fill") {
                Pasteboard.copy(value)
            })
        case let .custom(emoji):
            menu.addItem(ContextMenuItemSupport.item("Copy Emoji ID", systemImage: "number.square.fill") {
                Pasteboard.copy(emoji.id)
            })
            if let imageURL = emoji.imageURL {
                menu.addItem(ContextMenuItemSupport.item("Copy Emoji Image Link", systemImage: "link") {
                    Pasteboard.copy(imageURL.absoluteString)
                })
            }
        }

        return menu
    }
}
