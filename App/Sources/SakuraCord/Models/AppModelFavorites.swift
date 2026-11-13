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
    /// The addition Discord's limit just blocked, shown as its upsell notice.
    var limitReached: FavoritesLimitNotice?
    var nameEditor: FavoritesNameEditor?
    /// nil until the account's settings load.
    var suggestionsDismissed: Bool?
    /// Suggested Channels, most suggested first.
    var suggestions: [ForwardDestination] = []
    @ObservationIgnored var suggestionPool = FavoriteSuggestionPool()
    @ObservationIgnored var suggestionsTask: Task<Void, Never>?
    @ObservationIgnored var suggestionsNeedRefresh = false
    var isPickerPresented = false
    var isEditingThreadSettings = false
    /// Discord prunes read threads at most once a day per account.
    @ObservationIgnored var lastThreadPrune: (scope: String?, date: Date)?
    @ObservationIgnored var lastChannelID: ChannelID?
    /// Favourited threads the session's active-thread lists don't carry, such
    /// as archived ones, fetched when Favorites opens.
    var threads: [ChannelID: MessageThreadSummary] = [:]
    @ObservationIgnored var requestedThreadIDs: Set<ChannelID> = []
    /// Unlimited favorites' entries past Discord's limit, for `localScope`'s account.
    var localEntries: [FavoritesSettings.Entry] = []
    @ObservationIgnored var localScope: String?
    /// Whether `settings` is Discord's answer rather than an edit awaiting it.
    @ObservationIgnored var settingsAreConfirmed = false

    func reset() {
        settings = nil
        isPresented = false
        limitReached = nil
        nameEditor = nil
        suggestionsDismissed = nil
        suggestions = []
        suggestionPool = FavoriteSuggestionPool()
        suggestionsTask?.cancel()
        suggestionsTask = nil
        suggestionsNeedRefresh = false
        isPickerPresented = false
        isEditingThreadSettings = false
        lastThreadPrune = nil
        lastChannelID = nil
        threads = [:]
        requestedThreadIDs = []
        localEntries = []
        localScope = nil
        settingsAreConfirmed = false
    }
}

/// A conversation to favourite, with the Discord channel type it records.
struct FavoriteAddition: Equatable {
    let id: ChannelID
    let channelType: Int
}

/// A favourite Discord's limit kept from being added, with where it was going.
struct FavoritesLimitNotice: Identifiable, Equatable {
    let limit: Int
    let addition: FavoriteAddition
    var parentID: ChannelID?
    var categoryName: String?
    var id: ChannelID { addition.id }
}

/// The open Favorites name dialog.
enum FavoritesNameEditor: Identifiable, Equatable {
    case createCategory
    /// A category's name or a favourite's nickname.
    case rename(FavoritesSettings.Entry)

    var id: String {
        switch self {
        case .createCategory: "create"
        case .rename(let entry): "rename-\(entry.id)"
        }
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
        case let .favoritesChanged(settings, isConfirmed): presentFavorites(settings, isConfirmed: isConfirmed)
        case .favoritesSaveFailed(let reason): errorMessage = "Discord did not save your Favorites. \(reason)"
        case .favoritesSuggestionsDismissed(let isDismissed):
            favorites.suggestionsDismissed = isDismissed
            refreshFavoriteSuggestions()
        case let .currentUserThreadMembershipChanged(threadID, isJoined): followThreadMembership(threadID, isJoined: isJoined)
        default: return false
        }
        return true
    }

    private func presentFavorites(_ settings: FavoritesSettings?, isConfirmed: Bool) {
        changeFavorites {
            favorites.settings = settings
            favorites.settingsAreConfirmed = isConfirmed
            dropSyncedLocalFavorites()
        }
        refreshFavoriteSuggestions()
    }

    /// Hidden elsewhere, an open Favorites server stays until it is left, as
    /// in Discord. Removing the open favourite opens the one above it.
    func changeFavorites(_ change: () -> Void) {
        guard favorites.isPresented, let current = presentedFavoriteChannelID else { return change() }
        let previous = favoriteConversations()
        change()
        guard let displayed = displayedFavorites, !displayed.contains(current),
              let index = previous.firstIndex(where: { $0.id == current })
        else { return }
        let remaining = favoriteConversations()
        let above = previous[..<index].last { displayed.contains($0.id) }
        openFavorite(remaining.first { $0.id == above?.id } ?? remaining.first)
    }

    /// Opens a favourite, or leaves no conversation open when none is listed.
    private func openFavorite(_ conversation: FavoriteConversation?) {
        if let conversation {
            selectFavorite(conversation)
        } else {
            cancelConversationNavigation()
            onboarding.presentedGuildID = nil
            setFavoritesPresented(true)
            closeThread()
            selectedChannelID = nil
        }
    }

    /// Without an explicit choice, shown local favourites keep the server visible too.
    var favoritesAreEnabled: Bool { displayedFavorites?.isEnabled ?? false }

    var showsFavoritesRailItem: Bool { favoritesAreEnabled || favorites.isPresented }

    /// The conversation the Favorites list shows as selected.
    var presentedFavoriteChannelID: ChannelID? {
        isThreadFullWidth ? openThread?.id ?? selectedChannelID : selectedChannelID
    }

    func favoriteConversations() -> [FavoriteConversation] {
        displayedFavorites?.sections.flatMap(\.entries).compactMap(favoriteConversation) ?? []
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
        loadFavoriteThreads()
        openRememberedFavorite()
    }

    private func openRememberedFavorite() {
        let conversations = favoriteConversations()
        openFavorite(conversations.first { $0.id == favorites.lastChannelID } ?? conversations.first)
    }

    /// Like the official client, fetch favourited threads that no loaded list
    /// carries; a thread that can't be read stays stored but unlisted.
    func loadFavoriteThreads() {
        // A fetched private thread asks Discord again each time, since only
        // its answer states the current membership.
        for (id, thread) in favorites.threads where thread.isPrivate { favorites.requestedThreadIDs.remove(id) }
        let missing = (displayedFavorites?.entries ?? []).filter {
            (10 ... 12).contains($0.channelType ?? 0) && knownRootChannel($0.id) == nil
                && sidebarThread($0.id) == nil && favorites.requestedThreadIDs.insert($0.id).inserted
        }
        // Discord loads favourited threads before its daily prune of read ones.
        guard !missing.isEmpty else { return pruneReadFavoriteThreads() }
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
                    // A private thread Discord no longer confirms stops listing,
                    // and an open one is withheld until Discord confirms it again.
                    if entry.channelType == 12 {
                        model.favorites.threads[entry.id] = nil
                        if model.openThread?.id == entry.id { model.beginOpenThreadResolution() }
                    }
                    continue
                }
                model.favorites.threads[entry.id] = post.thread
            }
            model.pruneReadFavoriteThreads()
            // Threads that load after Favorites opened empty open like any favourite.
            if model.favorites.isPresented, model.presentedFavoriteChannelID == nil,
               !model.favoriteConversations().isEmpty {
                model.openRememberedFavorite()
            }
        }
    }

    /// Favorites opens with its conversation, as a server opens with its channel.
    func selectFavorite(_ conversation: FavoriteConversation) {
        favorites.lastChannelID = conversation.id
        if let thread = conversation.thread {
            // Full width, as the server channel list opens a thread.
            openSidebarThread(thread, presentsFavorites: true)
        } else {
            navigate(to: conversation.channel.guildID, linkedChannelID: conversation.id, presentsFavorites: true)
        }
    }

    func setFavoritesPresented(_ isPresented: Bool) {
        guard favorites.isPresented != isPresented else { return }
        favorites.isPresented = isPresented
        refreshServerRailSelection()
        refreshFavoriteSuggestions()
    }

    func isFavorite(_ channelID: ChannelID) -> Bool {
        displayedFavorites?.contains(channelID) ?? false
    }

    /// Whether Discord would keep this conversation as a favourite: it drops
    /// channels the account doesn't know or lacks View Channel for on every
    /// save. Permissions still loading count as viewable.
    func canAddFavorite(_ channelID: ChannelID) -> Bool {
        guard let channel = knownRootChannel(channelID) else { return sidebarThread(channelID) != nil }
        return effectiveMessagePermissions(in: channel).map { $0 & DiscordPermissionBits.viewChannel != 0 } ?? true
    }

    /// Adds or removes a channel, DM or thread.
    func toggleFavorite(_ channelID: ChannelID, channelType: Int) {
        if isFavorite(channelID) {
            updateFavorites(.remove(channelID))
        } else {
            addFavorites([FavoriteAddition(id: channelID, channelType: channelType)])
        }
    }

    /// Adds conversations in one save as Discord's add action does: each in
    /// turn until one meets the account's limit, under `parentID` or under a
    /// category found, or else created, by name. The limit shows the notice
    /// unless the addition is silent, and a blocked first addition sends
    /// nothing; Unlimited favorites keeps it on this device instead.
    func addFavorites(
        _ additions: [FavoriteAddition], parentID: ChannelID? = nil, categoryName: String? = nil, isSilent: Bool = false
    ) {
        guard var settings = favorites.settings else { return }
        let premiumType = currentUser?.premiumType ?? 0
        var edits: [FavoritesSettings.Edit] = []
        var parentID = parentID
        var resolvesCategory = categoryName != nil
        func apply(_ edit: FavoritesSettings.Edit) {
            settings.apply(edit)
            edits.append(edit)
        }
        for addition in additions where !isFavorite(addition.id) && !settings.contains(addition.id) {
            // Discord prunes favourites the account can no longer see before it
            // counts, so a deleted or hidden channel never blocks an addition.
            var counted = settings
            counted.entries.removeAll { !$0.isCategory && !canAddFavorite($0.id) && !(10 ... 12).contains($0.channelType ?? 0) }
            let category = resolvesCategory ? categoryName.flatMap(settings.category(named:)) : nil
            let newCategoryName = resolvesCategory && category == nil ? categoryName : nil
            // Discord's list takes the favourite only with room for it and any new category.
            let limit = counted.limitBlockingAddition(premiumType: premiumType)
                ?? (newCategoryName != nil && counted.entries.count + 2 > FavoritesSettings.maximumEntries
                    ? FavoritesSettings.maximumEntries : nil)
            if let limit, !featuresSettings.unlimitedFavorites {
                if !isSilent {
                    favorites.limitReached = FavoritesLimitNotice(
                        limit: limit, addition: addition, parentID: parentID, categoryName: resolvesCategory ? categoryName : nil
                    )
                }
                break
            }
            if resolvesCategory {
                resolvesCategory = false
                if let category {
                    parentID = category.id
                } else if let newCategoryName, limit == nil || settings.entries.count < FavoritesSettings.maximumEntries {
                    // A favourite kept on this device past the limit is filed where a
                    // synced one would be, while Discord's list has room for the category.
                    // Discord names a new category with a snowflake for the current time.
                    let id = ChannelID(timestamp: .now)
                    apply(.createCategory(id, name: newCategoryName))
                    parentID = id
                }
            }
            if limit != nil {
                addLocalFavorite(addition.id, channelType: addition.channelType, parentID: parentID)
                continue
            }
            // Unseen favourites stay stored until keeping them would push the
            // save past Discord's limit; then they go in the same save, as
            // Discord prunes them, so Discord never receives more.
            if settings.limitBlockingAddition(premiumType: premiumType) != nil {
                for entry in settings.entries where !entry.isCategory && !counted.entries.contains(entry) {
                    apply(.remove(entry.id))
                }
            }
            apply(.add(addition.id, channelType: addition.channelType, categoryID: parentID))
        }
        if !edits.isEmpty { updateFavorites(edits) }
    }

    /// Turns on Unlimited favorites, then adds the favourite the limit blocked.
    func addFavoriteBeyondLimit(_ notice: FavoritesLimitNotice) {
        var settings = featuresSettings
        settings.unlimitedFavorites = true
        applyFeaturesSettings(settings)
        favorites.limitReached = nil
        addFavorites([notice.addition], parentID: notice.parentID, categoryName: notice.categoryName)
    }

    func createFavoriteCategory(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, (favorites.settings?.entries.count ?? .max) < FavoritesSettings.maximumEntries else { return }
        // Discord names a new category with a snowflake for the current time.
        updateFavorites(.createCategory(ChannelID(timestamp: .now), name: name))
    }

    func setFavoritesEnabled(_ isEnabled: Bool) {
        updateFavorites(.setVisible(isEnabled))
        // Hiding it here leaves it, as Discord's settings toggle does.
        if !isEnabled, favorites.isPresented { openFriends() }
    }

    func updateFavorites(_ edit: FavoritesSettings.Edit) {
        updateFavorites([edit])
    }

    /// Edits Discord owns reach the provider in one call, so they share a save.
    func updateFavorites(_ edits: [FavoritesSettings.Edit]) {
        let synced = edits.filter { !applyLocalFavoriteEdit($0) }
        guard !synced.isEmpty, var settings = favorites.settings else { return }
        synced.forEach { settings.apply($0) }
        presentFavorites(settings, isConfirmed: false)
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                try await account.provider.updateFavorites(synced)
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.errorMessage = error.localizedDescription
                model.presentFavorites(await account.provider.favoritesSettings(), isConfirmed: false)
            }
        }
    }

    /// Like a server category's Mark as Read, each favourite in the category
    /// gets its own channel ACK at its newest message.
    func markFavoriteCategoryRead(_ categoryID: ChannelID) {
        for favorite in favoriteConversations() where favorite.entry.parentID == categoryID {
            markConversationRead(channelID: favorite.id)
        }
    }

    func isFavoriteCategoryUnread(_ categoryID: ChannelID) -> Bool {
        favoriteConversations().contains { $0.entry.parentID == categoryID && canMarkConversationRead(channelID: $0.id) }
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
