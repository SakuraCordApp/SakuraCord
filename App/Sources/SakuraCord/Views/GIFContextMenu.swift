import AppKit
import SakuraCordModels

struct GIFContextMenuActions {
    let isFavorite: Bool
    let isFavoriteMutationPending: Bool
    let toggleFavorite: () -> Void
    let copyMediaLink: () -> Void
}

@MainActor
enum GIFContextMenuBuilder {
    static func make(actions: GIFContextMenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(actionItem(
            actions.isFavorite
                ? "Remove from Favorites"
                : "Add to Favorites",
            systemImage: actions.isFavorite ? "star" : "star.fill",
            isEnabled: !actions.isFavoriteMutationPending,
            action: actions.toggleFavorite
        ))
        menu.addItem(actionItem(
            "Copy Media Link",
            systemImage: "link",
            action: actions.copyMediaLink
        ))
        return menu
    }

    private static func actionItem(
        _ title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let target = NativeTimelineMenuAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(NativeTimelineMenuAction.performAction),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        item.isEnabled = isEnabled
        ContextMenuItemSupport.configure(
            item,
            title: title,
            systemImage: systemImage
        )
        return item
    }
}

enum NativeTimelineGIFContextMenuPlan {
    static func result(
        in message: Message,
        layout: NativeTimelineRowLayout,
        at point: CGPoint
    ) -> GIFSearchResult? {
        guard let region = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(point) == true
        }),
        let embed = message.embeds.first(where: {
            $0.id == region.embedID
        }),
        embed.type?.lowercased() == "gifv",
        let canonicalURL = embed.url,
        let media = embed.video ?? embed.image,
        let mediaURL = media.url
        else { return nil }

        return GIFSearchResult(
            id: embed.id,
            title: embed.title ?? "GIF",
            url: canonicalURL,
            previewURL: embed.image?.url ?? embed.thumbnail?.url,
            width: media.width ?? embed.thumbnail?.width,
            height: media.height ?? embed.thumbnail?.height,
            thumbnailURL: embed.thumbnail?.url,
            mediaURL: mediaURL,
            mediaKind: embed.video == nil ? .image : .video
        )
    }
}
