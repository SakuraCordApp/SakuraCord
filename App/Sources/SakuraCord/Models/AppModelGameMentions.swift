import DiscordProtocol
import Foundation
import SakuraCordModels

struct GameMentionState {
    var gamesByID: [String: ProfileGame] = [:]
    var hydratedIDs: Set<String> = []
    var pendingIDs: Set<String> = []
    var failedIDs: [String: Date] = [:]
    var loadTask: Task<Void, Never>?

    /// A game that failed to load is asked for again after this long.
    static let retryDelay: TimeInterval = 60

    mutating func store(_ games: [ProfileGame]) {
        for game in games {
            gamesByID[game.id] = game
            hydratedIDs.insert(game.id)
        }
    }
}

extension AppModel {
    func searchGameMentions(query: String) async throws -> [ProfileGame] {
        let session = accountSession()
        let normalized = DiscordProfileWidgetGameSearch.normalizedQuery(query)
        let games = try await session.provider.searchProfileWidgetGames(query: normalized)
        try Task.checkCancellation()
        guard isCurrentAccountSession(session) else { throw CancellationError() }
        return games
    }

    func hydrateGameMentionSuggestions(_ suggestions: [ProfileGame]) async throws -> [ProfileGame] {
        let missingIDs = suggestions.filter {
            $0.artworkURL == nil && !gameMentions.hydratedIDs.contains($0.id)
        }.map(\.id)
        if !missingIDs.isEmpty {
            let session = accountSession()
            let games = try await session.provider.profileWidgetGames(ids: missingIDs)
            try Task.checkCancellation()
            guard isCurrentAccountSession(session) else { throw CancellationError() }
            gameMentions.store(games)
            if !games.isEmpty { timelinePresentationRevision &+= 1 }
        }
        return suggestions.map { suggestion in
            guard let detailed = gameMentions.gamesByID[suggestion.id] else { return suggestion }
            return detailed.artworkURL != nil ? detailed : suggestion
        }
    }

    func rememberGameMention(_ game: ProfileGame) {
        guard UInt64(game.id) != nil else { return }
        gameMentions.failedIDs[game.id] = nil
        if !gameMentions.hydratedIDs.contains(game.id) {
            gameMentions.gamesByID[game.id] = game
            requestGameMentionDetails(id: game.id)
        }
        timelinePresentationRevision &+= 1
    }

    func requestGameMentionDetails(id: String) {
        guard isGameMentionLookupEligible(id) else { return }
        gameMentions.pendingIDs.insert(id)
        startGameMentionLoad()
    }

    private func isGameMentionLookupEligible(_ id: String) -> Bool {
        UInt64(id) != nil
            && !gameMentions.hydratedIDs.contains(id)
            && gameMentions.failedIDs[id].map { $0 < .now } ?? true
    }

    private func startGameMentionLoad() {
        guard gameMentions.loadTask == nil, !gameMentions.pendingIDs.isEmpty else { return }
        gameMentions.loadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await loadPendingGameMentions()
        }
    }

    private func loadPendingGameMentions() async {
        // An ID queued again while its lookup ran may since have resolved or failed.
        let ids = gameMentions.pendingIDs.filter(isGameMentionLookupEligible).sorted()
        gameMentions.pendingIDs.removeAll()
        guard !ids.isEmpty else {
            gameMentions.loadTask = nil
            return
        }
        let session = accountSession()
        do {
            let games = try await session.provider.profileWidgetGames(ids: ids)
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            let resolved = Set(games.map(\.id))
            gameMentions.store(games)
            let retryAt = Date.now.addingTimeInterval(GameMentionState.retryDelay)
            for id in ids where !resolved.contains(id) { gameMentions.failedIDs[id] = retryAt }
            if !games.isEmpty { timelinePresentationRevision &+= 1 }
        } catch is CancellationError {
            // An account reset cancels this task and clears its state; a fresh
            // READY cancels only the request, so its games are asked for again.
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            gameMentions.pendingIDs.formUnion(ids)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            let retryAt = Date.now.addingTimeInterval(GameMentionState.retryDelay)
            for id in ids { gameMentions.failedIDs[id] = retryAt }
        }
        gameMentions.loadTask = nil
        startGameMentionLoad()
    }
}
