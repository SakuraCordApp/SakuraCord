import Foundation
import SakuraCordModels

struct ProfileGameAutocompleteCacheEntry: Sendable {
    let games: [ProfileGame]
    let hasResults: Bool
    let expiresAt: Date
}

public extension DiscordRESTProvider {
    func uploadProfileWidgetImage(fileURL: URL, filename: String, contentType: String) async throws -> ProfileWidgetImage {
        let anonymisesNames = await anonymisesUploadFilenames()
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        guard profileApexAssignments?.widgetEligibility(for: user).canEditPersonalWidget == true else {
            throw ChatProviderError.invalidRequest("Personal widgets require Nitro and early access.")
        }
        guard fileURL.isFileURL, !filename.isEmpty,
              ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"].contains(contentType)
        else { throw ChatProviderError.invalidRequest("Choose a supported widget image.") }
        let filename = anonymisesNames ? UploadFilename.anonymised(filename) : filename
        let generation = profileEditingGeneration
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        let prepared = try await prepareUploadFile(fileURL)
        defer { prepared.discard() }
        try Task.checkCancellation()
        try validateProfileWidgetSession(userID: user.id, generation: generation)
        let attributes = try FileManager.default.attributesOfItem(atPath: prepared.url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
            throw ChatProviderError.invalidRequest("The selected widget image is empty.")
        }
        guard size <= 10 * 1024 * 1024 else { throw ChatProviderError.invalidRequest("The edited widget image must be 10 MB or smaller.") }
        let reservation: ProfileWidgetAssetReservationDTO = try await request(
            "/users/@me/widgets/assets/upload", method: "POST",
            body: ["filename": .string(filename), "file_size": .number(Double(size))]
        )
        try validateProfileWidgetSession(userID: user.id, generation: generation)
        guard let uploadURL = Self.validatedAttachmentUploadURL(from: reservation.uploadURL),
              !reservation.uploadFilename.isEmpty
        else { throw ChatProviderError.invalidRequest("Discord returned an invalid widget image upload.") }
        let response = try await performStorageUpload(
            fileURL: prepared.url, uploadURL: uploadURL, contentType: contentType,
            diagnosticTransport: "widget_storage", diagnosticPath: "/users/@me/widgets/assets/upload"
        )
        try validateProfileWidgetSession(userID: user.id, generation: generation)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw apiDiagnostics.coalescing(
                ChatProviderError.invalidRequest("Discord's image storage rejected the widget image."), with: response
            )
        }
        return ProfileWidgetImage(reference: .pendingUpload(filename: reservation.uploadFilename), url: fileURL)
    }

    func suggestedProfileWidgetGames() async throws -> ProfileWidgetGameSuggestions {
        guard let userID = currentUser?.id else { throw ChatProviderError.unauthenticated }
        guard let policy = DiscordProfileWidgetGamePolicy.bundled else { throw ChatProviderError.invalidRequest("The widget game configuration could not be loaded.") }
        let generation = profileEditingGeneration
        let response: ProfileSuggestedGamesDTO = try await request("/users/@me/widgets/suggested-games")
        try validateProfileWidgetSession(userID: userID, generation: generation)
        return ProfileWidgetGameSuggestions(gameIDs: response.suggestedGames ?? [], wantedGameIDs: response.suggestedWishlistGames ?? [], fallbackGameIDs: policy.defaultGameIDs)
    }

    func searchProfileWidgetGames(query: String) async throws -> [ProfileGame] {
        guard let userID = currentUser?.id else { throw ChatProviderError.unauthenticated }
        let normalized = DiscordProfileWidgetGameSearch.normalizedQuery(query)
        guard !normalized.isEmpty else { return [] }
        let now = Date()
        if let cached = profileWidgetGameSearches[normalized], cached.expiresAt > now { return cached.games }
        if let failure = profileWidgetGameSearchFailures[normalized], failure.expiresAt > now { throw failure.error }
        if let task = profileWidgetGameSearchTasks[normalized] {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }
        let units = Array(normalized.utf16)
        if units.count > 1 {
            for length in stride(from: units.count - 1, through: 1, by: -1) {
                let prefix = String(decoding: units.prefix(length), as: UTF16.self)
                guard let cached = profileWidgetGameSearches[prefix], cached.expiresAt > now else { continue }
                if !cached.hasResults, length >= 7 {
                    profileWidgetGameSearches[normalized] = ProfileGameAutocompleteCacheEntry(games: [], hasResults: false, expiresAt: now.addingTimeInterval(3600))
                    return []
                }
                break
            }
        }
        let generation = profileEditingGeneration
        let task = Task { try await loadProfileGameSearch(normalized, userID: userID, generation: generation) }
        profileWidgetGameSearchTasks[normalized] = task
        let games = try await task.value
        try Task.checkCancellation()
        return games
    }

    func defaultProfileWidgetGames() async throws -> [ProfileGame] {
        guard let policy = DiscordProfileWidgetGamePolicy.bundled else { throw ChatProviderError.invalidRequest("The widget game configuration could not be loaded.") }
        return try await profileWidgetGames(ids: policy.defaultGameIDs).filter {
            $0.isAllowedInDefaultWidgetPicker && !policy.excludedGameIDs.contains($0.id)
        }
    }

    func profileWidgetGames(ids: [String]) async throws -> [ProfileGame] {
        guard let userID = currentUser?.id else { throw ChatProviderError.unauthenticated }
        guard !ids.isEmpty else { return [] }
        guard ids.allSatisfy({ UInt64($0) != nil }) else { throw ChatProviderError.invalidRequest("Invalid widget game identifier.") }
        let generation = profileEditingGeneration
        var seen = Set<String>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        let missing = uniqueIDs.filter { profileWidgetGameDetails[$0] == nil }
        let batches = stride(from: 0, to: missing.count, by: 20).map { Array(missing[$0 ..< min($0 + 20, missing.count)]) }
        try await withThrowingTaskGroup(of: [ProfileGame].self) { group in
            for batch in batches {
                group.addTask { try await self.loadProfileWidgetGameBatch(batch, userID: userID, generation: generation) }
            }
            for try await games in group {
                try validateProfileWidgetSession(userID: userID, generation: generation)
                for game in games { profileWidgetGameDetails[game.id] = game }
            }
        }
        try validateProfileWidgetSession(userID: userID, generation: generation)
        return uniqueIDs.compactMap { profileWidgetGameDetails[$0] }
    }

    private func loadProfileWidgetGameBatch(_ ids: [String], userID: UserID, generation: UInt64) async throws -> [ProfileGame] {
        try validateProfileWidgetSession(userID: userID, generation: generation)
        let response: [ProfileGameDTO] = try await request("/games", query: ids.map { URLQueryItem(name: "game_ids", value: $0) })
        try validateProfileWidgetSession(userID: userID, generation: generation)
        guard response.allSatisfy({ ids.contains($0.id) }) else { throw ChatProviderError.invalidRequest("Discord returned an unexpected widget game.") }
        return response.map(\.domain)
    }

    internal func validateProfileWidgetSession(userID: UserID, generation: UInt64) throws {
        try Task.checkCancellation()
        guard currentUser?.id == userID, profileEditingGeneration == generation, !requestSafetyCircuitIsOpen else {
            throw CancellationError()
        }
    }

    private func loadProfileGameSearch(_ query: String, userID: UserID, generation: UInt64) async throws -> [ProfileGame] {
        defer { if profileEditingGeneration == generation { profileWidgetGameSearchTasks[query] = nil } }
        do {
            var backoff = 0.5
            for attempt in 0 ... 5 {
                try validateProfileWidgetSession(userID: userID, generation: generation)
                let (data, response) = try await perform("/games/autocomplete", method: "GET",
                                                        query: [URLQueryItem(name: "q", value: query)], body: nil, maximumAttempts: 1)
                try validateProfileWidgetSession(userID: userID, generation: generation)
                if (200 ..< 300).contains(response.statusCode) {
                    let records = try JSONDecoder().decode([ProfileGameDTO].self, from: data)
                    guard let policy = DiscordProfileWidgetGamePolicy.bundled else { throw ChatProviderError.invalidRequest("The widget game configuration could not be loaded.") }
                    let games = records.filter { !policy.excludedGameIDs.contains($0.id) }.map(\.domain)
                    profileWidgetGameSearches = profileWidgetGameSearches.filter { $0.value.expiresAt > Date() }
                    profileWidgetGameSearches[query] = ProfileGameAutocompleteCacheEntry(games: games, hasResults: !records.isEmpty, expiresAt: Date().addingTimeInterval(3600))
                    profileWidgetGameSearchFailures[query] = nil
                    return games
                }
                guard attempt < 5, response.statusCode == 429 || response.statusCode >= 500 && response.statusCode != 503 else {
                    throw unexplainedFailure(data, response)
                }
                backoff = min(backoff + 2 * backoff * Double.random(in: 0 ..< 1), 5)
                let retryAfter = DiscordProfileWidgetGameSearch.retryAfter(data: data, response: response)
                try await Task.sleep(for: .seconds(max(backoff, retryAfter)))
            }
            throw ChatProviderError.invalidRequest("Game search did not recover.")
        } catch is CancellationError { throw CancellationError() } catch {
            try validateProfileWidgetSession(userID: userID, generation: generation)
            profileWidgetGameSearchFailures = profileWidgetGameSearchFailures.filter { $0.value.expiresAt > Date() }
            profileWidgetGameSearchFailures[query] = ProfileGameAutocompleteFailure(error: error, expiresAt: Date().addingTimeInterval(60))
            throw error
        }
    }
}

private struct ProfileWidgetAssetReservationDTO: Decodable {
    let uploadURL: String
    let uploadFilename: String
    enum CodingKeys: String, CodingKey { case uploadURL = "upload_url", uploadFilename = "upload_filename" }
}

private struct ProfileSuggestedGamesDTO: Decodable {
    let suggestedGames: [String]?
    let suggestedWishlistGames: [String]?
    enum CodingKeys: String, CodingKey {
        case suggestedGames = "suggested_games", suggestedWishlistGames = "suggested_wishlist_games"
    }
}
