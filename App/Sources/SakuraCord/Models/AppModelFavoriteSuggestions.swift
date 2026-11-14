import DiscordProtocol
import Foundation
import SakuraCordModels

/// Suggested Channels and the Add to Favorites picker, which share Discord's
/// destination search without the account's favourites. See
/// docs/protocol/SETTINGS.md, Favorites server.
extension AppModel {
    static let favoriteSuggestionLimit = 4
    /// Candidates kept per kind beyond those shown, so rows refill without a recompute.
    static let favoriteSuggestionPoolDepth = 12
    /// Discord files an added suggestion under this category.
    static let favoriteSuggestionsCategoryName = "Channels"
    static let favoritesPickerSelectionLimit = 20

    var favoriteIDs: Set<ChannelID> {
        Set(displayedFavorites?.entries.filter { !$0.isCategory }.map(\.id) ?? [])
    }

    /// Recomputes Suggested Channels while Favorites is open and they are not
    /// dismissed, as Discord does whenever a store they read changes. A
    /// change during a recompute runs one more pass after it rather than
    /// cancelling it, so a busy launch still shows suggestions.
    func refreshFavoriteSuggestions() {
        guard favorites.isPresented, favorites.suggestionsDismissed == false else {
            favorites.suggestionsTask?.cancel()
            favorites.suggestionsTask = nil
            favorites.suggestions = []
            return
        }
        // Discord re-picks while rendering, so an added or removed favourite
        // reshapes the rows in the same frame; the pool refresh follows.
        favorites.suggestions = favorites.suggestionPool.pick(excluding: favoriteIDs)
        guard favorites.suggestionsTask == nil else {
            favorites.suggestionsNeedRefresh = true
            return
        }
        favorites.suggestionsTask = startAccountChildTask(account: accountSession()) { model, account in
            await model.recomputeFavoriteSuggestions(account: account)
            guard model.isCurrentAccountSession(account) else { return }
            model.favorites.suggestionsTask = nil
            if model.favorites.suggestionsNeedRefresh {
                model.favorites.suggestionsNeedRefresh = false
                model.refreshFavoriteSuggestions()
            }
        }
    }

    /// Discord's affinity stores persist, so suggestions come from the stored
    /// copy at once; the network is read only once a ranking's lifetime has
    /// passed. The destination index is needed only when affinities run out.
    private func recomputeFavoriteSuggestions(account: AppModelAccountSession) async {
        // Frecency orders the fallback; its arrival advances the source revision.
        if !hasLoadedDiscordEmojiSettings { Task { await loadDiscordEmojiSettings() } }
        let stored = storedFavoriteAffinities
        async let fetched = account.provider.conversationAffinities(restoring: stored)
        if let stored { await publishFavoriteSuggestions(affinities: stored, account: account) }
        let fresh = await fetched
        guard isCurrentAccountSession(account) else { return }
        if fresh != stored {
            storedFavoriteAffinities = fresh
            await publishFavoriteSuggestions(affinities: fresh, account: account)
        }
    }

    /// Publishes the affinity pick at once; the destination index, needed only
    /// for the fallback after both affinity rankings, follows when it's needed.
    private func publishFavoriteSuggestions(affinities: ConversationAffinities, account: AppModelAccountSession) async {
        var pool = favoriteSuggestionPool(affinities: affinities)
        publish(pool)
        guard pool.channels.count + pool.users.count < Self.favoriteSuggestionPoolDepth else { return }
        let history = forwardDestinationHistory
        let favoriteIDs = favoriteIDs
        guard let index = await ForwardDestinationSearchIndexCache.shared.prepare(
            for: self, priority: .userInitiated, corpus: .favorites
        ) else { return }
        // Discord's favourites filter applies before the list is capped.
        let fallback = await Task.detached(priority: .userInitiated) {
            index.results(query: "", recentChannelIDs: history, excludedChannelIDs: favoriteIDs)
        }.value
        guard isCurrentAccountSession(account) else { return }
        pool.fallback = Array(fallback.lazy.filter(isListableFavoriteCandidate).prefix(Self.favoriteSuggestionPoolDepth))
        publish(pool)
    }

    private func publish(_ pool: FavoriteSuggestionPool) {
        guard favorites.isPresented, favorites.suggestionsDismissed == false else { return }
        favorites.suggestionPool = pool
        let suggestions = pool.pick(excluding: favoriteIDs)
        if favorites.suggestions != suggestions { favorites.suggestions = suggestions }
    }

    /// The account's affinities as last fetched, kept across launches and
    /// read from disk once per session.
    private var storedFavoriteAffinities: ConversationAffinities? {
        get {
            if let loaded = favorites.affinities { return loaded }
            let stored = currentUser
                .flatMap { UserDefaults.standard.data(forKey: Self.favoriteAffinitiesKey($0.id.description)) }
                .flatMap { try? JSONDecoder().decode(ConversationAffinities.self, from: $0) }
            favorites.affinities = stored
            return stored
        }
        set {
            favorites.affinities = newValue
            guard let accountID = currentUser?.id.description else { return }
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.favoriteAffinitiesKey(accountID))
        }
    }

    static func favoriteAffinitiesKey(_ accountID: String) -> String {
        "dev.sakuracord.favorite-affinities.\(accountID)"
    }

    /// The resolved candidates Suggested Channels pick from, enough beyond
    /// the four shown that adding or dismissing rows refills them at once.
    private func favoriteSuggestionPool(affinities: ConversationAffinities) -> FavoriteSuggestionPool {
        let excludedUsers = blockedOrIgnoredUserIDs
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
        // The depth counts candidates that aren't favourites already, so many
        // favourited top channels never leave the pool short.
        let depth = Self.favoriteSuggestionPoolDepth
        let favoriteIDs = favoriteIDs
        func resolved(_ ids: [ChannelID]) -> [ForwardDestination] {
            Array(ids.lazy.filter { !favoriteIDs.contains($0) }
                .compactMap { self.favoriteSuggestion(channelID: $0, channelsByID: channelsByID) }.prefix(depth))
        }
        return FavoriteSuggestionPool(
            channels: resolved(affinities.channelIDs),
            users: resolved(affinities.userIDs.compactMap { directMessageIDs[$0] })
        )
    }

    /// A conversation Discord's favourites filter accepts, favourites aside:
    /// for a server channel or thread, one the account can view.
    private func favoriteSuggestion(channelID: ChannelID, channelsByID: [ChannelID: Channel]) -> ForwardDestination? {
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
        guard let thread = favoriteThread(channelID),
              let parent = thread.parentID.flatMap({ channelsByID[$0] ?? knownRootChannel($0) }),
              canViewFavoriteCandidate(parent)
        else { return nil }
        return ForwardDestination(kind: .thread(thread, parent: parent), guild: thread.guildID.flatMap { serverRailGuildsByID[$0] })
    }

    /// A picker candidate the Favorites list would show once added.
    private func isListableFavoriteCandidate(_ destination: ForwardDestination) -> Bool {
        switch destination.kind {
        case .channel(let channel): channel.guildID == nil || canViewFavoriteCandidate(channel)
        case .thread(_, let parent): parent.map(canViewFavoriteCandidate) ?? false
        case .user: true
        }
    }

    /// The Favorites list hides conversations without View Channel and Read
    /// Message History, so suggestions skip them too.
    private func canViewFavoriteCandidate(_ channel: Channel) -> Bool {
        conversationAccess(for: channel) != .hidden
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
                additions.append(FavoriteAddition(id: thread.id, channelType: thread.favoriteChannelType))
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
        let wasPresented = favorites.isPresented
        updateFavorites(.reset)
        if !favorites.localEntries.isEmpty { clearLocalFavorites() }
        // After the reset, whose fallback to an empty Favorites would cancel this.
        if wasPresented { openFriends() }
    }
}

/// Suggested Channels' resolved candidates: affine channels and DM partners
/// in rank order, then the picker's default order.
struct FavoriteSuggestionPool: Equatable {
    var channels: [ForwardDestination] = []
    var users: [ForwardDestination] = []
    var fallback: [ForwardDestination] = []

    /// Discord's pick: up to four, alternating the most affine channel and
    /// DM partner (the other kind when one runs out), then the fallback,
    /// skipping favourites. Pure array work, cheap enough for every change.
    func pick(excluding favoriteIDs: Set<ChannelID>) -> [ForwardDestination] {
        var channels = channels[...], users = users[...], fallback = fallback[...]
        var chosen: [ForwardDestination] = []
        func next(_ queue: inout ArraySlice<ForwardDestination>) -> ForwardDestination? {
            while let candidate = queue.popFirst() {
                if candidate.resolvedChannelID.map(favoriteIDs.contains) != true, !chosen.contains(where: { $0.id == candidate.id }) {
                    return candidate
                }
            }
            return nil
        }
        while chosen.count < AppModel.favoriteSuggestionLimit {
            let prefersChannels = chosen.count.isMultiple(of: 2)
            guard let destination = (prefersChannels ? next(&channels) : next(&users))
                ?? (prefersChannels ? next(&users) : next(&channels))
                ?? next(&fallback)
            else { break }
            chosen.append(destination)
        }
        return chosen
    }
}
