import DiscordProtocol
import Foundation
import SakuraCordModels

/// Suggested Channels and the Add to Favorites picker, which share Discord's
/// destination search without the account's favourites. See
/// docs/protocol/SETTINGS.md, Favorites server.
extension AppModel {
    static let favoriteSuggestionLimit = 4
    /// Discord files an added suggestion under this category.
    static let favoriteSuggestionsCategoryName = "Channels"
    static let favoritesPickerSelectionLimit = 20

    var favoriteIDs: Set<ChannelID> {
        Set(displayedFavorites?.entries.filter { !$0.isCategory }.map(\.id) ?? [])
    }

    /// Recomputes Suggested Channels while Favorites is open and they are not
    /// dismissed, as Discord does whenever a store they read changes.
    func refreshFavoriteSuggestions() {
        favorites.suggestionsTask?.cancel()
        guard favorites.isPresented, favorites.suggestionsDismissed == false else {
            favorites.suggestions = []
            return
        }
        let favoriteIDs = favoriteIDs
        // A suggestion just added leaves in the same frame; the rest follow the recompute.
        favorites.suggestions.removeAll { $0.resolvedChannelID.map(favoriteIDs.contains) == true }
        let history = forwardDestinationHistory
        favorites.suggestionsTask = startAccountChildTask(account: accountSession()) { model, account in
            async let affinities = account.provider.conversationAffinities()
            // The picker's order falls back on frecency, which Discord keeps loaded.
            await model.loadDiscordEmojiSettings()
            let index = await ForwardDestinationSearchIndexCache.shared.favoritesIndex(for: model)
            let fallback = await Task.detached(priority: .userInitiated) {
                index.results(query: "", recentChannelIDs: history, excludedChannelIDs: favoriteIDs)
            }.value
            let resolvedAffinities = await affinities
            // A newer recompute supersedes this one; skip its main-actor work.
            guard !Task.isCancelled else { return }
            let suggestions = model.favoriteSuggestions(affinities: resolvedAffinities, fallback: fallback)
            guard !Task.isCancelled, model.isCurrentAccountSession(account) else { return }
            model.favorites.suggestions = suggestions
        }
    }

    /// Discord's pick: up to four, alternating the most affine channel and
    /// DM partner (the other kind when one runs out), then the picker's own
    /// default order.
    private func favoriteSuggestions(
        affinities: ConversationAffinities, fallback: [ForwardDestination]
    ) -> [ForwardDestination] {
        let excludedUsers = ignoredUsers.blockedUserIDs.union(ignoredUsers.ignoredUserIDs)
        let wantedChannelIDs = Set(affinities.channelIDs)
        let wantedUserIDs = Set(affinities.userIDs).subtracting(excludedUsers)
        // One pass collects just the affine channels and DMs.
        var channelsByID: [ChannelID: Channel] = [:]
        var directMessageIDs: [UserID: ChannelID] = [:]
        for channel in snapshot?.channels ?? [] {
            var isWanted = wantedChannelIDs.contains(channel.id)
            if channel.kind == .directMessage, let recipient = channel.recipients.first?.id, wantedUserIDs.contains(recipient) {
                if directMessageIDs[recipient] == nil { directMessageIDs[recipient] = channel.id }
                isWanted = true
            }
            if isWanted { channelsByID[channel.id] = channel }
        }
        var channels = affinities.channelIDs[...]
        var users = affinities.userIDs.compactMap { directMessageIDs[$0] }[...]
        var fallback = fallback[...]
        var chosen: [ForwardDestination] = []
        func next(_ queue: inout ArraySlice<ChannelID>) -> ForwardDestination? {
            while let id = queue.popFirst() {
                if let destination = favoriteSuggestion(channelID: id, channelsByID: channelsByID),
                   !chosen.contains(where: { $0.id == destination.id }) {
                    return destination
                }
            }
            return nil
        }
        while chosen.count < Self.favoriteSuggestionLimit {
            let prefersChannels = chosen.count.isMultiple(of: 2)
            var destination = prefersChannels ? next(&channels) : next(&users)
            if destination == nil { destination = prefersChannels ? next(&users) : next(&channels) }
            while destination == nil, let candidate = fallback.popFirst() {
                if !chosen.contains(where: { $0.id == candidate.id }) { destination = candidate }
            }
            guard let destination else { break }
            chosen.append(destination)
        }
        return chosen
    }

    /// A conversation Discord's favourites filter accepts: not a favourite,
    /// and for a server channel or thread, one the account can view.
    private func favoriteSuggestion(channelID: ChannelID, channelsByID: [ChannelID: Channel]) -> ForwardDestination? {
        guard !isFavorite(channelID) else { return nil }
        if let channel = channelsByID[channelID] {
            switch channel.kind {
            case .directMessage:
                return channel.recipients.first.map { ForwardDestination(kind: .user($0, directMessage: channel), guild: nil) }
            case .groupDirectMessage:
                return ForwardDestination(kind: .channel(channel), guild: nil)
            default:
                guard canViewFavoriteCandidate(channel) else { return nil }
                return ForwardDestination(kind: .channel(channel), guild: channel.guildID.flatMap { serverRailGuildsByID[$0] })
            }
        }
        guard let thread = sidebarThread(channelID) ?? favorites.threads[channelID],
              let parent = thread.parentID.flatMap({ channelsByID[$0] ?? knownRootChannel($0) }),
              canViewFavoriteCandidate(parent)
        else { return nil }
        return ForwardDestination(kind: .thread(thread, parent: parent), guild: thread.guildID.flatMap { serverRailGuildsByID[$0] })
    }

    private func canViewFavoriteCandidate(_ channel: Channel) -> Bool {
        (effectiveMessagePermissions(in: channel) ?? 0) & DiscordPermissionBits.viewChannel != 0
    }

    func dismissFavoriteSuggestions() {
        setFavoriteSuggestionsDismissed(true)
    }

    func setFavoriteSuggestionsDismissed(_ isDismissed: Bool) {
        favorites.suggestionsDismissed = isDismissed
        refreshFavoriteSuggestions()
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                try await account.provider.setFavoritesSuggestionsDismissed(isDismissed)
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// A suggestion is filed under Channels, created when missing.
    func addFavoriteSuggestion(_ destination: ForwardDestination) {
        addFavoriteDestinations([destination], categoryName: Self.favoriteSuggestionsCategoryName)
    }

    /// Adds picked or suggested conversations at once; a person without a
    /// DM gets one first, as Discord opens it before favouriting.
    func addFavoriteDestinations(_ destinations: [ForwardDestination], parentID: ChannelID? = nil, categoryName: String? = nil) {
        var additions: [FavoriteAddition] = []
        var usersWithoutDirectMessage: [UserID] = []
        for destination in destinations {
            switch destination.kind {
            case .channel(let channel):
                additions.append(FavoriteAddition(id: channel.id, channelType: channel.favoriteChannelType))
            case .thread(let thread, _):
                additions.append(FavoriteAddition(id: thread.id, channelType: thread.isPrivate ? 12 : 11))
            case .user(let user, let directMessage):
                if let directMessage {
                    additions.append(FavoriteAddition(id: directMessage.id, channelType: 1))
                } else {
                    usersWithoutDirectMessage.append(user.id)
                }
            }
        }
        guard !usersWithoutDirectMessage.isEmpty else {
            return addFavorites(additions, parentID: parentID, categoryName: categoryName)
        }
        startAccountChildTask(account: accountSession()) { model, account in
            for userID in usersWithoutDirectMessage {
                if let channel = try? await account.provider.ensurePrivateChannel(for: userID) {
                    additions.append(FavoriteAddition(id: channel.id, channelType: 1))
                }
            }
            guard model.isCurrentAccountSession(account) else { return }
            guard !additions.isEmpty else {
                model.errorMessage = "Oops, something went wrong..."
                return
            }
            model.addFavorites(additions, parentID: parentID, categoryName: categoryName)
        }
    }

    /// Reset Favorites: Discord's first-run state, Suggested Channels back
    /// included (the provider saves both together), and the device's
    /// Unlimited favorites cleared. Like Discord, it asks nothing and leaves
    /// for Friends.
    func resetFavorites() {
        if favorites.isPresented { openFriends() }
        updateFavorites(.reset)
        if !favorites.localEntries.isEmpty { clearLocalFavorites() }
    }
}
