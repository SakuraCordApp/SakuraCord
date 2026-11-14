import DiscordProtocol
import Foundation
import SakuraCordModels

/// The Thread Settings dialog's choices, as Discord's modal presents the
/// stored settings.
struct FavoritesThreadSettingsChoice: Equatable {
    enum AutoAdd: Hashable { case perServer, ownCategory, never }
    enum Scope: Hashable { case autoAddCategories, all }

    var autoAdd: AutoAdd
    /// Days without activity after which read threads go; 0 when archived,
    /// nil never.
    var removalDays: UInt32?
    var scope: Scope

    static let removalDayChoices: [UInt32] = [0, 7, 14]
}

/// Favorites' thread automation: joined threads added automatically and read
/// ones pruned, exactly as the official client performs them. See
/// docs/protocol/SETTINGS.md, Favorites server.
extension AppModel {
    /// Discord shows every thread setting as off while Favorites is hidden.
    var favoritesThreadSettingsChoice: FavoritesThreadSettingsChoice {
        let isEnabled = favoritesAreEnabled
        let thread = favorites.settings?.threadSettings ?? FavoritesSettings.ThreadSettings()
        let autoAdd: FavoritesThreadSettingsChoice.AutoAdd = !isEnabled || !thread.autoAddsJoinedThreads ? .never
            : thread.autoAddsPerServer ? .perServer : .ownCategory
        let removes = (thread.removesReadThreads ?? true) && isEnabled
        return FavoritesThreadSettingsChoice(
            autoAdd: autoAdd,
            removalDays: removes ? thread.removalDays : nil,
            scope: thread.removesFromAllThreads ? .all : .autoAddCategories
        )
    }

    /// Saves the dialog as Discord does: the auto-add choice (creating Auto-Added
    /// Threads for it when missing), then removal, whose days and scope are
    /// kept unchanged when it's turned off.
    func saveFavoritesThreadSettings(_ choice: FavoritesThreadSettingsChoice) {
        guard var thread = favorites.settings?.threadSettings, let settings = favorites.settings else { return }
        var edits: [FavoritesSettings.Edit] = []
        let autoAdds = choice.autoAdd != .never
        let perServer = choice.autoAdd == .perServer
        if choice.autoAdd == .ownCategory, settings.category(named: FavoritesSettings.autoAddedThreadsCategoryName) == nil {
            if settings.entries.count >= FavoritesSettings.maximumEntries {
                errorMessage = "Favorites are limited to \(FavoritesSettings.maximumEntries) channels and DMs."
            } else {
                edits.append(.createCategory(ChannelID(timestamp: .now), name: FavoritesSettings.autoAddedThreadsCategoryName))
                thread.autoAddsJoinedThreads = autoAdds
                thread.autoAddsPerServer = perServer
            }
        } else {
            thread.autoAddsJoinedThreads = autoAdds
            thread.autoAddsPerServer = perServer
        }
        thread.removesReadThreads = choice.removalDays != nil
        if let days = choice.removalDays {
            thread.removalDays = days
            thread.removesFromAllThreads = choice.scope == .all
        }
        edits.append(.setThreadSettings(thread))
        updateFavorites(edits)
    }

    /// Joining a thread adds it under its server's category or Auto-Added
    /// Threads; leaving one removes it from Favorites, whatever the settings.
    func followThreadMembership(_ threadID: ChannelID, isJoined: Bool) {
        guard isJoined else {
            if isFavorite(threadID) { updateFavorites(.remove(threadID)) }
            return
        }
        let choice = favoritesThreadSettingsChoice
        guard choice.autoAdd != .never, !isFavorite(threadID),
              let thread = favoriteThread(threadID),
              thread.isPrivate || thread.parentID.flatMap(knownRootChannel).map(canViewFavoriteThreadParent) == true
        else { return }
        let serverName = choice.autoAdd == .perServer
            ? thread.guildID.flatMap { serverRailGuildsByID[$0]?.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            : nil
        addFavorites(
            [FavoriteAddition(id: threadID, channelType: thread.favoriteChannelType)],
            categoryName: serverName.flatMap { $0.isEmpty ? nil : $0 } ?? FavoritesSettings.autoAddedThreadsCategoryName,
            isSilent: true
        )
    }

    private func canViewFavoriteThreadParent(_ parent: Channel) -> Bool {
        (effectiveMessagePermissions(in: parent) ?? 0) & DiscordPermissionBits.viewChannel != 0
    }

    /// The categories auto-add files into: Auto-Added Threads and, per
    /// server, every category named after one of the account's servers.
    private func favoriteAutoAddCategoryIDs(in settings: FavoritesSettings) -> [ChannelID] {
        var names = [FavoritesSettings.autoAddedThreadsCategoryName]
        if favoritesThreadSettingsChoice.autoAdd == .perServer { names += serverRailGuildsByID.values.map(\.name) }
        return Array(Set(names.compactMap { settings.category(named: $0)?.id }))
    }

    /// Discord's daily prune when Favorites opens: read favourited threads in
    /// scope go when archived or, with a day limit, after that long without
    /// activity. Threads with unread messages and the open one stay.
    func pruneReadFavoriteThreads() {
        let choice = favoritesThreadSettingsChoice
        // Unlimited favorites' local threads are pruned like synced ones.
        guard let days = choice.removalDays, let settings = displayedFavorites else { return }
        let scope = choice.scope == .all ? nil : favoriteAutoAddCategoryIDs(in: settings)
        let account = currentUser?.id.description
        if let last = favorites.lastThreadPrune, last.scope == account, Date.now.timeIntervalSince(last.date) < 24 * 60 * 60 { return }
        if scope?.isEmpty == true { return }
        favorites.lastThreadPrune = (account, .now)
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let removals = settings.entries.compactMap { entry -> (id: ChannelID, activity: Date)? in
            guard !entry.isCategory, scope.map({ entry.parentID.map($0.contains) ?? false }) ?? true,
                  entry.id != presentedFavoriteChannelID,
                  let thread = favoriteThread(entry.id),
                  let parent = thread.parentID.flatMap(knownRootChannel), canViewFavoriteThreadParent(parent),
                  !readState.unread(channelID: entry.id), readState.mentions(channelID: entry.id) == 0
            else { return nil }
            let activity = [
                (thread.lastMessageID?.createdAt ?? thread.createdAt), thread.lastNonMessageActivityAt, thread.archiveTimestamp,
            ].compactMap(\.self).max() ?? .distantFuture
            guard thread.isArchived || (days > 0 && activity < cutoff) else { return nil }
            return (entry.id, activity)
        }
        guard !removals.isEmpty else { return }
        updateFavorites(removals.sorted { $0.activity < $1.activity }.map { .remove($0.id) })
    }
}
