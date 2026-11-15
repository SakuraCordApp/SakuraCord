import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func favoritesSettings() async -> FavoritesSettings? {
        favoritesSync.pendingFavorites ?? favoritesSync.favoritesMessage.map(DiscordFavoritesProto.settings(from:))
    }

    /// Applies edits optimistically and saves them at once, like the
    /// first-party `INFREQUENT_USER_ACTION` (0 s) settings write. The edits of
    /// one call always share a save; edits made while a save is in flight are
    /// coalesced into one follow-up save of the newest state instead of being
    /// discarded with the response.
    public func updateFavorites(_ edits: [FavoritesSettings.Edit]) async throws {
        guard let favoritesMessage = favoritesSync.favoritesMessage else {
            throw ChatProviderError.invalidRequest("Wait for your account settings to finish loading.")
        }
        var next = favoritesSync.pendingFavorites ?? DiscordFavoritesProto.settings(from: favoritesMessage)
        for edit in edits {
            if case let .add(id, channelType, categoryID) = edit {
                next.apply(.add(id, channelType: storedChannelType(id) ?? channelType, categoryID: categoryID))
            } else {
                next.apply(edit)
            }
        }
        favoritesSync.pendingFavorites = next
        continuation?.yield(.favoritesChanged(next, isConfirmed: false))
        // Reset also restores Suggested Channels, in the same write.
        if edits.contains(.reset), let content = favoritesSync.userContentMessage,
           DiscordUserContentProto.isDismissed(DiscordUserContentProto.favoritesSuggestions, in: content) {
            let restored = DiscordUserContentProto.setting(DiscordUserContentProto.favoritesSuggestions, dismissed: false, in: content)
            favoritesSync.pendingUserContent = restored
            favoritesSync.userContentMessage = restored
            continuation?.yield(.favoritesSuggestionsDismissed(false))
        }
        startFavoritesSave()
    }

    /// Favorites and Suggested Channels writes share one queue, so they reach
    /// Discord in order and only the newest state of each is sent.
    func startFavoritesSave() {
        guard favoritesSaveTask == nil else { return }
        let generation = favoritesGeneration
        favoritesSaveTask = Task { await saveFavorites(generation: generation) }
    }

    func applyFavoritesSettingsProto(_ encoded: String?, replacesAllSettings: Bool) {
        guard let stored = DiscordSettingsProto.acceptedField(
            in: encoded, replacesAllSettings: replacesAllSettings, dataVersion: &favoritesSync.favoritesDataVersion,
            field: DiscordFavoritesProto.message(inSettings:)
        ), stored != favoritesSync.favoritesMessage else { return }
        favoritesSync.favoritesMessage = stored
        // A pending edit stays presented; its save reconciles with this copy.
        guard favoritesSync.pendingFavorites == nil else { return }
        publishStoredFavorites()
    }

    private func publishStoredFavorites() {
        continuation?.yield(.favoritesChanged(DiscordFavoritesProto.settings(from: favoritesSync.favoritesMessage ?? Data()), isConfirmed: true))
    }

    /// The official client removes a deleted channel from Favorites itself.
    func removeDeletedFavorite(_ channelID: ChannelID) async {
        guard let settings = await favoritesSettings(), settings.contains(channelID) else { return }
        try? await updateFavorites([.remove(channelID)])
    }

    func finishFavoritesEdits() async {
        while let save = favoritesSaveTask { await save.value }
        favoritesGeneration &+= 1
        favoritesSync = FavoritesSyncState()
    }

    private func saveFavorites(generation: UInt64) async {
        defer { if generation == favoritesGeneration { favoritesSaveTask = nil } }
        while generation == favoritesGeneration, favoritesSync.pendingFavorites != nil || favoritesSync.pendingUserContent != nil {
            let target = favoritesSync.pendingFavorites
            let userContent = favoritesSync.pendingUserContent
            favoritesSync.pendingUserContent = nil
            var settings = userContent.map { DiscordSettingsProto.protoLengthDelimitedField(DiscordUserContentProto.settingsField, $0) } ?? Data()
            if let target, let stored = favoritesSync.favoritesMessage {
                settings += DiscordSettingsProto.protoLengthDelimitedField(
                    DiscordFavoritesProto.settingsField, DiscordFavoritesProto.message(for: target, preserving: stored)
                )
            }
            do {
                let response = try await patchUserSettings(
                    ["settings": .string(settings.base64EncodedString())],
                    retriesRateLimit: true
                )
                guard generation == favoritesGeneration else { return }
                if target != nil { applyFavoritesSettingsProto(response.settings, replacesAllSettings: true) }
                if userContent != nil { applyUserContentSettingsProto(response.settings, replacesAllSettings: true) }
            } catch {
                guard generation == favoritesGeneration else { return }
                if error is UserSettingsRejection { await reloadUserSettings() }
                gatewayLogger.error("Could not save Favorites: \(error.localizedDescription, privacy: .public)")
                // Edits queued behind this save are dropped with it.
                if favoritesSync.pendingFavorites != nil {
                    favoritesSync.pendingFavorites = nil
                    publishStoredFavorites()
                }
                // Suggested Channels queued behind this save are dropped with
                // it and return to what Discord confirmed.
                let unsavedContent = favoritesSync.pendingUserContent ?? userContent
                favoritesSync.pendingUserContent = nil
                if let unsavedContent, favoritesSync.userContentMessage == unsavedContent, let confirmed = favoritesSync.confirmedUserContentMessage {
                    favoritesSync.userContentMessage = confirmed
                    continuation?.yield(.favoritesSuggestionsDismissed(
                        DiscordUserContentProto.isDismissed(DiscordUserContentProto.favoritesSuggestions, in: confirmed)
                    ))
                }
                continuation?.yield(.favoritesSaveFailed(reason: error.localizedDescription))
                return
            }
            // A Reset made since may have returned the Favorites to this
            // target while its Suggested Channels still need saving.
            guard let target, favoritesSync.pendingFavorites == target, favoritesSync.pendingUserContent == nil else { continue }
            favoritesSync.pendingFavorites = nil
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

/// The session's Favorites and Suggested Channels settings: what Discord
/// confirmed, what a save still holds, and the affinities suggestions rank by.
struct FavoritesSyncState {
    /// The confirmed settings-proto/1 Favorites message; nil until settings load.
    var favoritesMessage: Data?
    var favoritesDataVersion: UInt32?
    /// The settings data version of `userContentMessage`; older copies, such as
    /// a late response to an earlier write, are ignored.
    var userContentDataVersion: UInt32?
    /// The optimistic Favorites state while a save is pending or in flight.
    var pendingFavorites: FavoritesSettings?
    /// The settings-proto/1 UserContentSettings message, with any write still
    /// awaiting Discord's answer applied.
    var userContentMessage: Data?
    /// The UserContentSettings Discord last confirmed, which a failed write
    /// rolls back to.
    var confirmedUserContentMessage: Data?
    /// UserContentSettings waiting in the Favorites save queue: a Suggested
    /// Channels dismissal, or the restore Reset sends in its own write.
    var pendingUserContent: Data?
    var personalizationConsented = false
    /// Each ranking is loaded once its fetch date is set.
    var affinities = ConversationAffinities()
}
