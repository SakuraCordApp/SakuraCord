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
        menu.addItem(ContextMenuItemSupport.item(
            actions.isFavorite
                ? "Remove from Favorites"
                : "Add to Favorites",
            systemImage: actions.isFavorite ? "star" : "star.fill",
            isEnabled: !actions.isFavoriteMutationPending,
            action: actions.toggleFavorite
        ))
        menu.addItem(ContextMenuItemSupport.item(
            "Copy Media Link",
            systemImage: "link",
            action: actions.copyMediaLink
        ))
        return menu
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
        embed.isGIFV,
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
