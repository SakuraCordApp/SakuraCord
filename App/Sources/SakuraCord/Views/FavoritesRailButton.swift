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
            Button("Hide Favorites", systemImage: "eye.slash.fill") { model.setFavoritesEnabled(false) }
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
            .windowModal(item: $favorites.nameEditor, cornerRadius: 32, cornerStyle: .circular) {
                FavoritesNameEditorView(model: model, editor: $0)
            }
    }
}

/// Create Category, Rename Category and a favourite's Change Nickname, in
/// the server Change Nickname dialog. Edits apply on the action.
private struct FavoritesNameEditorView: View {
    let model: AppModel
    let editor: FavoritesNameEditor
    /// The favourite being nicknamed, as opposed to a category.
    private let favorite: FavoritesSettings.Entry?
    /// A cleared nickname shows the channel's own name.
    private let channelName: String?
    @State private var draft: String

    init(model: AppModel, editor: FavoritesNameEditor) {
        self.model = model
        self.editor = editor
        let entry: FavoritesSettings.Entry? = if case .rename(let renamed) = editor { renamed } else { nil }
        let favorite = entry?.isCategory == false ? entry : nil
        self.favorite = favorite
        channelName = favorite.flatMap { model.favoriteConversation($0)?.channel.name }
        _draft = State(initialValue: entry?.nickname ?? "")
    }

    var body: some View {
        NameEditorPanel(
            title: favorite != nil ? "Change Nickname" : editor == .createCategory ? "Create Category" : "Rename Category",
            fieldTitle: favorite != nil ? "Nickname" : "Category Name",
            placeholder: channelName ?? "New Category",
            draft: $draft,
            actionTitle: editor == .createCategory ? "Create Category" : "Save",
            save: save
        ) {
            if favorite != nil {
                Text("This name only appears in your Favorites.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            if favorite?.nickname.isEmpty == false {
                Button("Reset Nickname") { draft = "" }
                    .buttonStyle(.link)
            }
        }
    }

    private func save() {
        switch editor {
        case .createCategory:
            model.createFavoriteCategory(named: draft)
        case .rename(let entry):
            let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            // A category needs a name; a cleared nickname restores the channel's own.
            if !entry.isCategory || !name.isEmpty { model.updateFavorites(.rename(entry.id, nickname: name)) }
        }
        model.favorites.nameEditor = nil
    }
}
