import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func searchGameMentions(query: String) async throws -> [ProfileGame] {
        let session = accountSession()
        let normalized = DiscordProfileWidgetGameSearch.normalizedQuery(query)
        let games = try await normalized.isEmpty
            ? session.provider.defaultProfileWidgetGames()
            : session.provider.searchProfileWidgetGames(query: normalized)
        try Task.checkCancellation()
        guard isCurrentAccountSession(session) else { throw CancellationError() }
        return games
    }

    func hydrateGameMentionSuggestions(_ suggestions: [ProfileGame]) async throws -> [ProfileGame] {
        let missingIDs = suggestions.filter {
            $0.iconURL == nil && $0.coverURL == nil && !hydratedGameMentionIDs.contains($0.id)
        }.map(\.id)
        if !missingIDs.isEmpty {
            let session = accountSession()
            let games = try await session.provider.profileWidgetGames(ids: missingIDs)
            try Task.checkCancellation()
            guard isCurrentAccountSession(session) else { throw CancellationError() }
            for game in games {
                gameMentionsByID[game.id] = game
                hydratedGameMentionIDs.insert(game.id)
            }
            if !games.isEmpty { timelinePresentationRevision &+= 1 }
        }
        return suggestions.map { suggestion in
            guard let detailed = gameMentionsByID[suggestion.id] else { return suggestion }
            return detailed.iconURL != nil || detailed.coverURL != nil ? detailed : suggestion
        }
    }

    func rememberGameMention(_ game: ProfileGame) {
        guard UInt64(game.id) != nil else { return }
        failedGameMentionIDs[game.id] = nil
        if !hydratedGameMentionIDs.contains(game.id) {
            gameMentionsByID[game.id] = game
            requestGameMentionDetails(id: game.id)
        }
        timelinePresentationRevision &+= 1
    }

    func requestGameMentionDetails(id: String) {
        guard UInt64(id) != nil,
              !hydratedGameMentionIDs.contains(id),
              failedGameMentionIDs[id].map({ $0 < .now }) ?? true
        else { return }
        pendingGameMentionIDs.insert(id)
        guard gameMentionLoadTask == nil else { return }
        gameMentionLoadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await loadPendingGameMentions()
        }
    }

    private func loadPendingGameMentions() async {
        let ids = pendingGameMentionIDs.sorted()
        pendingGameMentionIDs.removeAll()
        let session = accountSession()
        do {
            let games = try await session.provider.profileWidgetGames(ids: ids)
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            let resolved = Set(games.map(\.id))
            for game in games {
                gameMentionsByID[game.id] = game
                hydratedGameMentionIDs.insert(game.id)
            }
            let retryAt = Date.now.addingTimeInterval(60)
            for id in ids where !resolved.contains(id) { failedGameMentionIDs[id] = retryAt }
            if !games.isEmpty { timelinePresentationRevision &+= 1 }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccountSession(session) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            let retryAt = Date.now.addingTimeInterval(60)
            for id in ids { failedGameMentionIDs[id] = retryAt }
        }
        gameMentionLoadTask = nil
        if let next = pendingGameMentionIDs.first {
            pendingGameMentionIDs.remove(next)
            requestGameMentionDetails(id: next)
        }
    }
}
