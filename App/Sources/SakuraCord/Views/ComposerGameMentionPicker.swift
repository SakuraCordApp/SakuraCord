import DiscordProtocol
import SakuraCordModels
import SwiftUI

struct ComposerGameMentionPicker: View {
    let model: AppModel
    let select: (ProfileGame) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var games: [ProfileGame] = []
    @State private var selectedIndex = 0
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    private var normalizedQuery: String {
        DiscordProfileWidgetGameSearch.normalizedQuery(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("GAMES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 5)
            TextField("Search games", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onSubmit(chooseCurrent)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
            Divider().padding(.horizontal, 9)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                        Button { select(game) } label: {
                            HStack(spacing: 9) {
                                gameIcon(for: game)
                                Text(game.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 40)
                            .background(
                                index == selectedIndex ? Color.primary.opacity(0.10) : .clear,
                                in: ConcentricRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onModalHover { if $0 { selectedIndex = index } }
                    }
                    if isSearching {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary).padding(12)
                    } else if games.isEmpty {
                        Text(normalizedQuery.isEmpty ? "Search for a game to mention." : "No games found.")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
            }
            .frame(height: min(340, CGFloat(max(2, games.count)) * 42))
        }
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular.interactive(),
            in: ConcentricRectangle(cornerRadius: ChatChromeMetrics.composerMinimumCornerRadius)
        )
        .task {
            await Task.yield()
            searchFocused = true
        }
        .task(id: normalizedQuery) { await search() }
    }

    @ViewBuilder
    private func gameIcon(for game: ProfileGame) -> some View {
        ZStack {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            if let url = game.iconURL ?? game.coverURL {
                StaticRemoteImage(url: url, maximumPixelDimension: 96, contentMode: .fill)
            }
        }
        .frame(width: 26, height: 26)
        .background(.primary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 5))
        .accessibilityHidden(true)
    }

    private func chooseCurrent() {
        guard games.indices.contains(selectedIndex) else { return }
        select(games[selectedIndex])
    }

    private func moveSelection(by offset: Int) {
        guard !games.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + games.count) % games.count
    }

    private func search() async {
        let input = normalizedQuery
        games = []
        selectedIndex = 0
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
            return
        } catch {
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }
}
