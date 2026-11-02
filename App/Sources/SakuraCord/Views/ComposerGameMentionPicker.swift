import DiscordProtocol
import SakuraCordModels
import SwiftUI

/// The games matching what is typed after `@game `, searched as it changes.
@Observable
final class ComposerGameMentionSearch {
    private(set) var games: [ProfileGame] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    func search(_ query: String, model: AppModel) async {
        let input = DiscordProfileWidgetGameSearch.normalizedQuery(query)
        games = []
        errorMessage = nil
        guard !input.isEmpty else { isSearching = false; return }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(220))
            let results = try await model.searchGameMentions(query: input)
            try Task.checkCancellation()
            games = results
            isSearching = false
            do {
                games = try await model.hydrateGameMentionSuggestions(results)
            } catch is CancellationError {
                return
            } catch {
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            }
        } catch is CancellationError {
            // A fresh READY cancels only the provider's search; ask again.
            guard !Task.isCancelled else { return }
            return await search(query, model: model)
        } catch {
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            // A newer query owns the menu once this one is cancelled.
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }
}

/// The `@game` menu, in the composer's option menu.
struct ComposerGameMentionPicker: View {
    let search: ComposerGameMentionSearch
    let query: String
    let selectedIndex: Int
    let cornerRadius: CGFloat
    let keyboardSelectionRevision: Int
    let select: (ProfileGame) -> Void
    let highlight: (Int) -> Void

    var body: some View {
        ComposerOptionPanel(
            title: "Games",
            rows: search.games,
            selectedIndex: selectedIndex,
            status: status,
            cornerRadius: cornerRadius,
            keyboardSelectionRevision: keyboardSelectionRevision,
            select: select,
            highlight: highlight,
            accessibilityLabel: \.name,
            label: { game in
                gameIcon(for: game)
                Text(game.name).foregroundStyle(.primary).lineLimit(1)
            }
        )
    }

    private var status: ApplicationCommandSuggestionContent.Status {
        if !search.games.isEmpty { return .ready }
        if search.isSearching { return .loading }
        if let errorMessage = search.errorMessage { return .message(errorMessage, isError: true) }
        let isEmptyQuery = DiscordProfileWidgetGameSearch.normalizedQuery(query).isEmpty
        return .message(isEmptyQuery ? "Search for a game to mention." : "No games found.", isError: false)
    }

    private func gameIcon(for game: ProfileGame) -> some View {
        ZStack {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let url = game.artworkURL {
                StaticRemoteImage(url: url, maximumPixelDimension: 96, contentMode: .fill)
            }
        }
        .frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(22))
        .background(.primary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}
