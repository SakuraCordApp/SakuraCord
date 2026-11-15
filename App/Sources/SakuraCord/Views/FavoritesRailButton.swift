import SakuraCordModels
import SwiftUI

/// The Favorites server's rail tile, locked below Direct Messages. It reads
/// the model itself so unread changes re-render only this tile.
struct FavoritesRailButton: View {
    let model: AppModel

    var body: some View {
        let unread = model.favoritesUnread
        ServerRailSymbolButton(
            title: "Favorites", systemImage: "star.fill", isSelected: model.favorites.isPresented,
            hasNotification: unread.isUnread, mentionCount: unread.mentions, action: model.openFavorites
        )
        .overlay { ServerRailContextMenuBridge { FavoritesMenu.railMenu(model: model) } }
        .accessibilityValue(unread.mentions > 0 ? "\(unread.mentions) unread mentions" : unread.isUnread ? "Unread" : "")
    }
}
