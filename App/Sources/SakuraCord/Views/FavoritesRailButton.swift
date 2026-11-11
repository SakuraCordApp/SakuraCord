import SakuraCordModels
import SwiftUI

/// The Favorites server's rail tile, locked below Direct Messages. It reads
/// the model itself so unread changes re-render only this tile.
struct FavoritesRailButton: View {
    let model: AppModel
    @State private var isHovering = false

    var body: some View {
        let isSelected = model.favorites.isPresented
        let unread = model.favoritesUnread
        Button(action: model.openFavorites) {
            HStack(spacing: InterfaceScale.metric(4)) {
                ServerRailSelectionIndicator(isSelected: isSelected, isHovering: isHovering, hasNotification: unread.isUnread)
                ServerRailBadgedIcon(mentionCount: unread.mentions) {
                    Image(systemName: "star.fill")
                        .font(.interface(.title2))
                        .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
                        .background(
                            isSelected || isHovering ? SakuraCordAccentColor.color : Color.secondary.opacity(0.16),
                            in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(13), style: .continuous)
                        )
                        .frame(width: InterfaceScale.metric(46), height: InterfaceScale.metric(46))
                }
            }
            .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ServerRailButtonStyle())
        .contextMenu {
            Button("Hide Favorites", systemImage: "eye.slash") { model.setFavoritesEnabled(false) }
        }
        .accessibilityLabel("Favorites")
        .accessibilityValue(unread.mentions > 0 ? "\(unread.mentions) unread mentions" : unread.isUnread ? "Unread" : "")
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: "Favorites", bounds: bounds) : nil
        }
        .onServerRailHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
    }
}

/// Favorites dialogs, hosted by the rail so channel menus anywhere can open them.
struct FavoritesDialogs: ViewModifier {
    let model: AppModel
    @State private var name = ""

    func body(content: Content) -> some View {
        @Bindable var favorites = model.favorites
        content
            .alert("Need more Favorites?",
                   isPresented: Binding(get: { favorites.limitReached != nil }, set: { if !$0 { favorites.limitReached = nil } }),
                   presenting: favorites.limitReached) { _ in
                Button("OK", role: .cancel) {}
            } message: { limit in
                Text(limit == FavoritesSettings.maximumEntries
                    ? "Favorites are limited to \(limit) channels and DMs."
                    : "Free Favorites are limited to \(limit). Get Nitro to add up to \(FavoritesSettings.maximumEntries) channels and DMs.")
            }
            .alert(favorites.renaming?.isCategory == true ? "Rename Category" : "Change Nickname",
                   isPresented: Binding(get: { favorites.renaming != nil }, set: { if !$0 { favorites.renaming = nil } }),
                   presenting: favorites.renaming) { entry in
                TextField(entry.isCategory ? "Category Name" : "Nickname", text: $name)
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A category needs a name; a cleared nickname restores the channel's own.
                    if !entry.isCategory || !trimmed.isEmpty { model.updateFavorites(.rename(entry.id, nickname: trimmed)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                if !entry.isCategory { Text("This name only appears in your Favorites.") }
            }
            .alert("Create Category", isPresented: $favorites.isCreatingCategory) {
                TextField("New Category", text: $name)
                Button("Create Category") { model.createFavoriteCategory(named: name) }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: favorites.renaming?.id) { name = favorites.renaming?.nickname ?? "" }
            .onChange(of: favorites.isCreatingCategory) { name = "" }
    }
}
