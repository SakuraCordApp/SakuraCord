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
    }

    static func removeLocalFavorites(accountID: String) {
        UserDefaults.standard.removeObject(forKey: localFavoritesKey(accountID))
    }

    /// The list Favorites shows: the synced favourites, then the local ones
    /// while Unlimited favorites is on. Turned off, local ones stay stored.
    var displayedFavorites: FavoritesSettings? {
        guard var settings = favorites.settings else { return nil }
        if featuresSettings.unlimitedFavorites {
            settings.entries += favorites.localEntries.filter { !settings.contains($0.id) }
        }
        return settings
    }

    func addLocalFavorite(_ id: ChannelID, channelType: Int) {
        var entry = FavoritesSettings.Entry(
            id: id, position: (favorites.localEntries.map(\.position).max() ?? 0) + 1, channelType: channelType
        )
        entry.isLocal = true
        changeLocalFavorites { $0.append(entry) }
    }

    /// Applies a remove, rename or move of a shown local favourite; false
    /// for anything Discord owns.
    func applyLocalFavoriteEdit(_ edit: FavoritesSettings.Edit) -> Bool {
        let id: ChannelID
        switch edit {
        case .remove(let target), .rename(let target, _), .move(let target, _): id = target
        default: return false
        }
        guard featuresSettings.unlimitedFavorites,
              let index = favorites.localEntries.firstIndex(where: { $0.id == id })
        else { return false }
        changeLocalFavorites { entries in
            switch edit {
            case .rename(_, let nickname):
                entries[index].nickname = nickname
            case .move(_, let categoryID):
                entries[index].parentID = categoryID
                entries[index].position = (entries.map(\.position).max() ?? 0) + 1
            default:
                entries.remove(at: index)
            }
        }
        return true
    }

    func changeLocalFavorites(_ change: (inout [FavoritesSettings.Entry]) -> Void) {
        changeFavorites { change(&favorites.localEntries) }
        guard let scope = favorites.localScope else { return }
        let key = Self.localFavoritesKey(scope)
        if favorites.localEntries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(favorites.localEntries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
