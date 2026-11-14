import Foundation
import SakuraCordModels

/// FakeNitro's Unlimited favorites: favourites past Discord's limit stay on
/// this device, per account, after the synced ones. Discord only ever receives
/// the synced favourites; see docs/protocol/SETTINGS.md, Favorites server.
extension AppModel {
    private static func localFavoritesKey(_ accountID: String) -> String {
        "favorites.localEntries.v1.\(accountID)"
    }

    /// Loads the account's local favourites; signed out or offline, there are none.
    func configureLocalFavorites(accountID: String?) {
        favorites.localScope = launchMode == .normal ? accountID : nil
        favorites.localEntries = favorites.localScope
            .flatMap { UserDefaults.standard.data(forKey: Self.localFavoritesKey($0)) }
            .flatMap { try? JSONDecoder().decode([FavoritesSettings.Entry].self, from: $0) } ?? []
        dropSyncedLocalFavorites()
    }

    static func removeLocalFavorites(accountID: String) {
        UserDefaults.standard.removeObject(forKey: localFavoritesKey(accountID))
        UserDefaults.standard.removeObject(forKey: favoriteAffinitiesKey(accountID))
    }

    /// The list Favorites shows: the synced favourites, then the local ones
    /// while Unlimited favorites is on. Turned off, local ones stay stored.
    var displayedFavorites: FavoritesSettings? {
        guard var settings = favorites.settings else { return nil }
        if featuresSettings.unlimitedFavorites {
            settings.entries += favorites.localEntries.compactMap { entry in
                guard !settings.contains(entry.id) else { return nil }
                var local = entry
                local.isLocal = true
                return local
            }
        }
        return settings
    }

    /// Discord's list wins: a local favourite Discord has confirmed carrying is
    /// dropped, never on an edit still awaiting Discord's answer. While the
    /// option is off, local favourites are left untouched.
    func dropSyncedLocalFavorites() {
        guard featuresSettings.unlimitedFavorites, favorites.settingsAreConfirmed,
              let settings = favorites.settings
        else { return }
        let count = favorites.localEntries.count
        favorites.localEntries.removeAll { settings.contains($0.id) }
        if favorites.localEntries.count != count { saveLocalFavorites() }
    }

    func addLocalFavorite(_ id: ChannelID, channelType: Int, parentID: ChannelID? = nil) {
        // As with a synced addition, a favourite reveals a hidden Favorites server.
        if !favoritesAreEnabled { updateFavorites(.setVisible(true)) }
        let entry = FavoritesSettings.Entry(
            id: id, position: nextLocalFavoritePosition, parentID: parentID, channelType: channelType
        )
        changeLocalFavorites { $0.append(entry) }
    }

    func clearLocalFavorites() {
        changeLocalFavorites { $0.removeAll() }
    }

    /// Applies a remove, rename or move of a shown local favourite; false
    /// for anything Discord owns, which Discord's entry then receives.
    func applyLocalFavoriteEdit(_ edit: FavoritesSettings.Edit) -> Bool {
        switch edit {
        case .remove(let id) where favorites.settings?.contains(id) == true:
            // Removing Discord's favourite also removes a local copy it hides.
            if favorites.localEntries.contains(where: { $0.id == id }) {
                changeLocalFavorites { $0.removeAll { $0.id == id } }
            }
            return false
        case .remove(let id):
            return changeLocalFavorite(id) { entries, index in entries.remove(at: index) }
        case .rename(let id, let nickname):
            return changeLocalFavorite(id) { entries, index in entries[index].nickname = nickname }
        case .move(let id, let categoryID):
            return changeLocalFavorite(id) { [position = nextLocalFavoritePosition] entries, index in
                entries[index].parentID = categoryID
                entries[index].position = position
            }
        default:
            return false
        }
    }

    private var nextLocalFavoritePosition: UInt32 {
        (favorites.localEntries.map(\.position).max() ?? 0) + 1
    }

    private func changeLocalFavorite(
        _ id: ChannelID, _ change: (inout [FavoritesSettings.Entry], Int) -> Void
    ) -> Bool {
        guard featuresSettings.unlimitedFavorites, favorites.settings?.contains(id) != true,
              let index = favorites.localEntries.firstIndex(where: { $0.id == id })
        else { return false }
        changeLocalFavorites { change(&$0, index) }
        return true
    }

    private func changeLocalFavorites(_ change: (inout [FavoritesSettings.Entry]) -> Void) {
        changeFavorites { change(&favorites.localEntries) }
        saveLocalFavorites()
        refreshFavoriteSuggestions()
    }

    private func saveLocalFavorites() {
        guard let scope = favorites.localScope else { return }
        let key = Self.localFavoritesKey(scope)
        if favorites.localEntries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(favorites.localEntries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
