import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// Discord's Favorites server; see docs/protocol/SETTINGS.md, Favorites server.
/// The provider owns the synced settings; this store presents them.
@Observable
final class FavoritesStore {
    /// nil until the account's settings load.
    var settings: FavoritesSettings?
    /// Whether the rail's Favorites server is the open destination.
    var isPresented = false
    /// The channel limit an addition just hit, shown as Discord's upsell notice.
    var limitReached: Int?
    var renaming: FavoritesSettings.Entry?
    var isCreatingCategory = false
    @ObservationIgnored var lastChannelID: ChannelID?
    /// Favourited threads the session's active-thread lists don't carry, such
    /// as archived ones, fetched once each when Favorites opens.
    var threads: [ChannelID: MessageThreadSummary] = [:]
    @ObservationIgnored var requestedThreadIDs: Set<ChannelID> = []

    func reset() {
        settings = nil
        isPresented = false
        limitReached = nil
        renaming = nil
        isCreatingCategory = false
        lastChannelID = nil
        threads = [:]
        requestedThreadIDs = []
    }
}

/// A favourite resolved to the conversation it opens.
struct FavoriteConversation: Identifiable, Equatable {
    var entry: FavoritesSettings.Entry
    var channel: Channel
    var thread: MessageThreadSummary?
    var id: ChannelID { entry.id }
    /// The favourite's nickname replaces a channel's name; DMs keep theirs.
    var name: String {
        entry.nickname.isEmpty || channel.guildID == nil ? channel.name : entry.nickname
    }
}

extension AppModel {
    func consumeFavoritesEvent(_ event: ClientEvent) -> Bool {
        switch event {
        case .favoritesChanged(let settings): presentFavorites(settings)
        case .favoritesSaveFailed(let reason): errorMessage = "Discord did not save your Favorites. \(reason)"
        default: return false
        }
        return true
    }

    /// Hidden elsewhere, an open Favorites server stays until it is left, as
    /// in Discord. Removing the open favourite opens the one above it.
    private func presentFavorites(_ settings: FavoritesSettings?) {
        let previous = favoriteConversations()
        favorites.settings = settings
        guard favorites.isPresented, let settings, let current = presentedFavoriteChannelID,
              !settings.contains(current), let index = previous.firstIndex(where: { $0.id == current })
        else { return }
        let remaining = favoriteConversations(in: settings)
        let above = previous[..<index].last { settings.contains($0.id) }
        openFavorite(remaining.first { $0.id == above?.id } ?? remaining.first)
    }

    /// Opens a favourite, or leaves no conversation open when none is listed.
    private func openFavorite(_ conversation: FavoriteConversation?) {
        if let conversation {
            selectFavorite(conversation)
        } else {
            cancelConversationNavigation()
            closeThread()
            selectedChannelID = nil
        }
    }

    var favoritesAreEnabled: Bool { favorites.settings?.isEnabled ?? false }

    var showsFavoritesRailItem: Bool { favoritesAreEnabled || favorites.isPresented }

    /// The conversation the Favorites list shows as selected.
    var presentedFavoriteChannelID: ChannelID? {
        isThreadFullWidth ? openThread?.id ?? selectedChannelID : selectedChannelID
    }

    func favoriteConversations(in settings: FavoritesSettings? = nil) -> [FavoriteConversation] {
        (settings ?? favorites.settings)?.sections.flatMap(\.entries).compactMap(favoriteConversation) ?? []
    }

    /// Unknown or hidden channels stay stored but unlisted, like Discord's
    /// list; a favourited thread shows once the account knows it and can
    /// view its parent.
    func favoriteConversation(_ entry: FavoritesSettings.Entry) -> FavoriteConversation? {
        if let channel = knownRootChannel(entry.id) {
            guard conversationAccess(for: channel) != .hidden else { return nil }
            return FavoriteConversation(entry: entry, channel: channel)
        }
        guard let thread = sidebarThread(entry.id) ?? favorites.threads[entry.id],
              let parent = thread.parentID.flatMap(knownRootChannel),
              conversationAccess(for: parent) != .hidden
        else { return nil }
        // A private thread is listed only to members or thread managers; a
        // fetched copy is revalidated each time Favorites opens.
        let canManageThreads = (effectiveMessagePermissions(in: parent) ?? 0) & DiscordPermissionBits.manageThreads != 0
        guard !thread.isPrivate || canManageThreads || thread.notificationSettings != nil else { return nil }
        return FavoriteConversation(entry: entry, channel: threadNavigationChannel(thread), thread: thread)
    }

    func openFavorites() {
        guard showsFavoritesRailItem else { return }
        leaveGuildJoinRequestPage()
        setFavoritesPresented(true)
        loadFavoriteThreads()
        let conversations = favoriteConversations()
        openFavorite(conversations.first { $0.id == favorites.lastChannelID } ?? conversations.first)
    }

    /// Like the official client, fetch favourited threads that no loaded list
    /// carries; a thread that can't be read stays stored but unlisted.
    private func loadFavoriteThreads() {
        // A fetched private thread is withheld until Discord confirms the
        // membership again, so revoked access never shows stale content.
        for (id, thread) in favorites.threads where thread.isPrivate {
            favorites.threads[id] = nil
            favorites.requestedThreadIDs.remove(id)
        }
        let threadTypes: Set<Int> = [10, 11, 12]
        let missing = (favorites.settings?.entries ?? []).filter {
            $0.channelType.map(threadTypes.contains) == true && knownRootChannel($0.id) == nil
                && sidebarThread($0.id) == nil && favorites.requestedThreadIDs.insert($0.id).inserted
        }
        guard !missing.isEmpty else { return }
        startAccountChildTask(account: accountSession()) { model, account in
            for entry in missing {
                // A private thread (type 12) always asks Discord, whose answer
                // states the current membership; others may come from cache.
                let post = try? await (entry.channelType == 12
                    ? account.provider.resolveThreadAccess(threadID: entry.id)
                    : account.provider.forumPost(threadID: entry.id))
                guard model.isCurrentAccountSession(account) else { return }
                // A failed read is retried the next time Favorites opens.
                guard let post else {
                    model.favorites.requestedThreadIDs.remove(entry.id)
                    continue
                }
                model.favorites.threads[entry.id] = post.thread
            }
        }
    }

    func selectFavorite(_ conversation: FavoriteConversation) {
        setFavoritesPresented(true)
        favorites.lastChannelID = conversation.id
        if let thread = conversation.thread {
            // Full width, as the server channel list opens a thread.
            openSidebarThread(thread)
        } else {
            navigate(to: conversation.channel.guildID, linkedChannelID: conversation.id)
        }
    }

    func setFavoritesPresented(_ isPresented: Bool) {
        guard favorites.isPresented != isPresented else { return }
        favorites.isPresented = isPresented
        refreshServerRailSelection()
    }

    /// Following a link out of Favorites opens the conversation where it lives.
    func leaveFavoritesUnlessFavorite(_ channelID: ChannelID) {
        if !isFavorite(channelID) { setFavoritesPresented(false) }
    }

    func isFavorite(_ channelID: ChannelID) -> Bool {
        favorites.settings?.contains(channelID) ?? false
    }

    /// Adds or removes a channel, DM or thread. Like Discord, an addition over
    /// the account's limit shows the notice and sends nothing.
    func toggleFavorite(_ channelID: ChannelID, channelType: Int?) {
        guard let settings = favorites.settings else { return }
        if settings.contains(channelID) {
            updateFavorites(.remove(channelID))
        } else if let limit = settings.limitBlockingAddition(premiumType: currentUser?.premiumType ?? 0) {
            favorites.limitReached = limit
        } else {
            updateFavorites(.add(channelID, channelType: channelType, categoryID: nil))
        }
    }

    func createFavoriteCategory(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, (favorites.settings?.entries.count ?? .max) < FavoritesSettings.maximumEntries else { return }
        // Discord names a new category with a snowflake for the current time.
        let milliseconds = UInt64(Date.now.timeIntervalSince1970 * 1_000) - 1_420_070_400_000
        updateFavorites(.createCategory(ChannelID(rawValue: milliseconds << 22), name: name))
    }

    func setFavoritesEnabled(_ isEnabled: Bool) {
        updateFavorites(.setVisible(isEnabled))
        // Hiding it here leaves it, as Discord's settings toggle does.
        if !isEnabled, favorites.isPresented { selectGuild(nil) }
    }

    func updateFavorites(_ edit: FavoritesSettings.Edit) {
        guard var settings = favorites.settings else { return }
        settings.apply(edit)
        presentFavorites(settings)
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                try await account.provider.updateFavorites(edit)
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.errorMessage = error.localizedDescription
                model.presentFavorites(await account.provider.favoritesSettings())
            }
        }
    }

    /// A thread's mute lives in its member settings, not channel overrides.
    func isFavoriteMuted(_ favorite: FavoriteConversation) -> Bool {
        favorite.thread.map { SidebarThreadPolicy.isMuted($0, now: .now) } ?? isChannelMuted(favorite.channel)
    }

    /// Whether the rail's Favorites tile shows the unread pill and how many
    /// mentions its badge counts, across every shown favourite.
    var favoritesUnread: (isUnread: Bool, mentions: Int) {
        favoriteConversations().reduce(into: (false, 0)) { result, favorite in
            result.mentions += readState.mentions(channelID: favorite.id)
            if !result.isUnread, !isFavoriteMuted(favorite), readState.unread(channelID: favorite.id) {
                result.isUnread = true
            }
        }
    }
}

extension Channel {
    /// The Discord channel type a new favourite records when the provider
    /// has not cached the server's own value.
    var favoriteChannelType: Int {
        switch kind {
        case .directMessage: 1
        case .groupDirectMessage: 3
        case .voice: 2
        case .announcement: 5
        case .forum: 15
        case .text, .unknown: 0
        }
    }
}
