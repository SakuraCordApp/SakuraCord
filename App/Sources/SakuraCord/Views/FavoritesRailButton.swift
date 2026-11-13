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
        .contextMenu {
            Button("Hide Favorites", systemImage: "eye.slash.fill") { model.setFavoritesEnabled(false) }
        }
        .accessibilityValue(unread.mentions > 0 ? "\(unread.mentions) unread mentions" : unread.isUnread ? "Unread" : "")
    }
}

/// Favorites dialogs, hosted by the rail so channel menus anywhere can open them.
struct FavoritesDialogs: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        @Bindable var favorites = model.favorites
        content
            .windowModal(item: $favorites.limitReached, cornerRadius: 32, cornerStyle: .circular) { blocked in
                ModalDialogPanel(title: "Need more Favorites?", actionTitle: "Turn On Unlimited Favorites", actionSymbol: "infinity") {
                    model.addFavoriteBeyondLimit(blocked)
                } notice: {
                    Text("Discord allows \(blocked.limit) Favorites on your account. Unlimited favorites keeps the rest on this Mac only.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } content: {
                    EmptyView()
                }
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
