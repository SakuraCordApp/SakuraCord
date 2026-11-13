import SakuraCordModels
import SwiftUI

/// Discord's Add to Favorites picker: its destination search without the
/// account's favourites, up to 20 picks, added together.
struct FavoritesPickerView: View {
    let model: AppModel
    @Environment(\.windowModalContext) private var modal
    @State private var query = ""
    @State private var selection: [ForwardDestination] = []
    /// The picks as of the last query change, which Discord lists first.
    @State private var pinnedIDs: [ForwardDestinationID] = []
    @State private var index: ForwardDestinationSearchPolicy.Index?
    @State private var results: [ForwardDestination] = []
    @FocusState private var isSearchFocused: Bool

    private var isAtLimit: Bool { selection.count >= AppModel.favoritesPickerSelectionLimit }

    var body: some View {
        ModalDialogPanel(
            title: "Add to Favorites",
            actionTitle: selection.count >= 2 ? "Add to Favorites (\(selection.count))" : "Add to Favorites",
            actionSymbol: "star.fill",
            isActionDisabled: selection.isEmpty,
            action: add
        ) {
            EmptyView()
        } content: {
            VStack(spacing: InterfaceScale.metric(8)) {
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .padding(InterfaceScale.metric(14))
                    .modifier(ModalInputSurface(isFocused: isSearchFocused) { isSearchFocused = true })
                ScrollView {
                    VStack(spacing: InterfaceScale.metric(2)) {
                        ForEach(results) { destination in
                            let isSelected = selection.contains { $0.id == destination.id }
                            ForwardDestinationRow(destination: destination, isSelected: isSelected) { toggle(destination) }
                                .disabled(!isSelected && isAtLimit)
                        }
                    }
                }
                .frame(height: InterfaceScale.metric(360))
                .overlay {
                    if index == nil {
                        ProgressView().controlSize(.small)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        // Discord reads the latest frecency when the picker opens; the index
        // follows the destination sources as Forward's does.
        .task(id: model.forwardSearchSourceRevision) {
            if !model.hasLoadedDiscordEmojiSettings { Task { await model.loadDiscordEmojiSettings() } }
            let built = await ForwardDestinationSearchIndexCache.shared.favoritesIndex(for: model)
            // A newer source revision's task owns the index now.
            guard !Task.isCancelled else { return }
            index = built
            await refreshResults()
            isSearchFocused = true
        }
        .task(id: SearchRequest(query: query, pinnedIDs: pinnedIDs)) { await refreshResults() }
        .onChange(of: query) { pinnedIDs = selection.map(\.id) }
    }

    private struct SearchRequest: Hashable {
        let query: String
        let pinnedIDs: [ForwardDestinationID]
    }

    private func refreshResults() async {
        guard let index else { return }
        let request = SearchRequest(query: query, pinnedIDs: pinnedIDs)
        let history = model.forwardDestinationHistory
        let favoriteIDs = model.favoriteIDs
        let found = await Task.detached(priority: .userInitiated) {
            index.results(
                query: request.query, recentChannelIDs: history,
                pinnedDestinationIDs: request.pinnedIDs, excludedChannelIDs: favoriteIDs
            )
        }.value
        guard !Task.isCancelled, request == SearchRequest(query: query, pinnedIDs: pinnedIDs) else { return }
        results = found
    }

    private func toggle(_ destination: ForwardDestination) {
        if let position = selection.firstIndex(where: { $0.id == destination.id }) {
            selection.remove(at: position)
        } else if !isAtLimit {
            selection.append(destination)
        }
    }

    private func add() {
        model.addFavoriteDestinations(selection)
        modal?.dismiss()
    }
}

/// Discord's Thread Settings: whether joined threads are added and when read
/// ones are removed.
struct FavoritesThreadSettingsView: View {
    let model: AppModel
    @Environment(\.windowModalContext) private var modal
    @State private var choice: FavoritesThreadSettingsChoice

    init(model: AppModel) {
        self.model = model
        _choice = State(initialValue: model.favoritesThreadSettingsChoice)
    }

    var body: some View {
        ModalDialogPanel(
            title: "Thread Settings",
            isActionDisabled: choice == model.favoritesThreadSettingsChoice,
            action: save
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
                group("Auto-add joined threads") {
                    Picker("Auto-add joined threads", selection: $choice.autoAdd) {
                        option("To per-server category", detail: "Each server gets a category with its name")
                            .tag(FavoritesThreadSettingsChoice.AutoAdd.perServer)
                        option("To their own category", detail: "All go to Auto-Added Threads")
                            .tag(FavoritesThreadSettingsChoice.AutoAdd.ownCategory)
                        Text("Never").tag(FavoritesThreadSettingsChoice.AutoAdd.never)
                    }
                }
                Divider()
                group("Remove read threads", detail: "Threads with unread messages are never removed.") {
                    Picker("Remove read threads", selection: $choice.removalDays) {
                        ForEach(FavoritesThreadSettingsChoice.removalDayChoices, id: \.self) { days in
                            Text(days == 0 ? "When archived" : "When archived or after \(days) days without activity")
                                .tag(UInt32?.some(days))
                        }
                        Text("Never").tag(UInt32?.none)
                    }
                }
                group("Remove from") {
                    Picker("Remove from", selection: $choice.scope) {
                        Text("Categories used for auto-add").tag(FavoritesThreadSettingsChoice.Scope.autoAddCategories)
                        Text("All favorited threads").tag(FavoritesThreadSettingsChoice.Scope.all)
                    }
                }
                .disabled(choice.removalDays == nil)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private func group(_ title: String, detail: String? = nil, @ViewBuilder picker: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                Text(title).font(.headline)
                if let detail { Text(detail).foregroundStyle(.secondary) }
            }
            picker()
        }
    }

    private func option(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func save() {
        model.saveFavoritesThreadSettings(choice)
        modal?.dismiss()
    }
}
