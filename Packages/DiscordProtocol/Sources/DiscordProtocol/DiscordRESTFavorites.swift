import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func favoritesSettings() async -> FavoritesSettings? {
        pendingFavorites ?? favoritesMessage.map(DiscordFavoritesProto.settings(from:))
    }

    /// Applies edits optimistically and saves them at once, like the
    /// first-party `INFREQUENT_USER_ACTION` (0 s) settings write. The edits of
    /// one call always share a save; edits made while a save is in flight are
    /// coalesced into one follow-up save of the newest state instead of being
    /// discarded with the response.
    public func updateFavorites(_ edits: [FavoritesSettings.Edit]) async throws {
        guard let favoritesMessage else {
            throw ChatProviderError.invalidRequest("Wait for your account settings to finish loading.")
        }
        var next = pendingFavorites ?? DiscordFavoritesProto.settings(from: favoritesMessage)
        for edit in edits {
            if case let .add(id, channelType, categoryID) = edit {
                next.apply(.add(id, channelType: storedChannelType(id) ?? channelType, categoryID: categoryID))
            } else {
                next.apply(edit)
            }
        }
        pendingFavorites = next
        continuation?.yield(.favoritesChanged(next, isConfirmed: false))
        // Reset also restores Suggested Channels, in the same write.
        if edits.contains(.reset), let content = userContentMessage,
           DiscordUserContentProto.isDismissed(DiscordUserContentProto.favoritesSuggestions, in: content) {
            let restored = DiscordUserContentProto.setting(DiscordUserContentProto.favoritesSuggestions, dismissed: false, in: content)
            pendingUserContent = restored
            userContentMessage = restored
            continuation?.yield(.favoritesSuggestionsDismissed(false))
        }
        guard favoritesSaveTask == nil else { return }
        let generation = favoritesGeneration
        favoritesSaveTask = Task { await saveFavorites(generation: generation) }
    }

    func applyFavoritesSettingsProto(_ encoded: String?, replacesAllSettings: Bool) {
        guard let encoded, let data = Data(base64Encoded: encoded) else { return }
        let message = DiscordFavoritesProto.message(inSettings: data)
        guard message != nil || replacesAllSettings else { return }
        let version = DiscordSettingsProto.dataVersion(in: data)
        if let version, let current = favoritesDataVersion, version < current { return }
        if let version { favoritesDataVersion = version }
        let stored = message ?? Data()
        guard stored != favoritesMessage else { return }
        favoritesMessage = stored
        // A pending edit stays presented; its save reconciles with this copy.
        guard pendingFavorites == nil else { return }
        publishStoredFavorites()
    }

    private func publishStoredFavorites() {
        continuation?.yield(.favoritesChanged(DiscordFavoritesProto.settings(from: favoritesMessage ?? Data()), isConfirmed: true))
    }

    /// The official client removes a deleted channel from Favorites itself.
    func removeDeletedFavorite(_ channelID: ChannelID) async {
        guard let settings = await favoritesSettings(), settings.contains(channelID) else { return }
        try? await updateFavorites([.remove(channelID)])
    }

    func finishFavoritesEdits() async {
        while let save = favoritesSaveTask { await save.value }
        favoritesGeneration &+= 1
        favoritesMessage = nil
        favoritesDataVersion = nil
        pendingFavorites = nil
        pendingUserContent = nil
        userContentMessage = nil
        userContentDataVersion = nil
        personalizationConsented = false
        channelAffinities = nil
        userAffinities = nil
    }

    private func saveFavorites(generation: UInt64) async {
        defer { if generation == favoritesGeneration { favoritesSaveTask = nil } }
        while generation == favoritesGeneration, let target = pendingFavorites, let stored = favoritesMessage {
            let message = DiscordFavoritesProto.message(for: target, preserving: stored)
            let userContent = pendingUserContent
            pendingUserContent = nil
            do {
                let response = try await patchUserSettings(
                    ["settings": .string(
                        ((userContent.map { DiscordSettingsProto.protoLengthDelimitedField(DiscordUserContentProto.settingsField, $0) } ?? Data())
                            + DiscordSettingsProto.protoLengthDelimitedField(DiscordFavoritesProto.settingsField, message))
                            .base64EncodedString()
                    )],
                    retriesRateLimit: true
                )
                guard generation == favoritesGeneration else { return }
                applyFavoritesSettingsProto(response.settings, replacesAllSettings: true)
                if userContent != nil { applyUserContentSettingsProto(response.settings, replacesAllSettings: true) }
            } catch {
                guard generation == favoritesGeneration else { return }
                if error is UserSettingsRejection { await reloadUserSettings() }
                gatewayLogger.error("Could not save Favorites: \(error.localizedDescription, privacy: .public)")
                pendingFavorites = nil
                publishStoredFavorites()
                if let userContent, userContentMessage == userContent {
                    userContentMessage = DiscordUserContentProto.setting(
                        DiscordUserContentProto.favoritesSuggestions, dismissed: true, in: userContent
                    )
                    continuation?.yield(.favoritesSuggestionsDismissed(true))
                }
                continuation?.yield(.favoritesSaveFailed(reason: error.localizedDescription))
                return
            }
            guard pendingFavorites == target else { continue }
            pendingFavorites = nil
            publishStoredFavorites()
        }
    }

    /// The Discord channel type the server reported, which distinguishes
    /// stage and media channels that share a local kind.
    private func storedChannelType(_ id: ChannelID) -> Int? {
        for store in cachedGuildChannelDTOs.values {
            if let dto = store[id.description] { return dto.type }
        }
        return nil
    }
}
