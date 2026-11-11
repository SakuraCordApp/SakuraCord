import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct UnlimitedFavoritesTests {
    /// Guards the account: favourites past the limit never reach Discord's
    /// synced list, and Discord's own edits never lose or resurrect them.
    @Test func `favourites past the limit stay local and Discord's list stays authoritative`() {
        let model = AppModel(launchMode: .offlineTesting)
        let synced = (1 ... 3).map {
            FavoritesSettings.Entry(id: ChannelID(rawValue: $0), position: UInt32($0), channelType: 11)
        }
        _ = model.consumeFavoritesEvent(.favoritesChanged(FavoritesSettings(entries: synced), isConfirmed: true))
        model.featuresSettings.unlimitedFavorites = true

        model.toggleFavorite(ChannelID(rawValue: 4), channelType: 11)
        model.toggleFavorite(ChannelID(rawValue: 5), channelType: 11)
        #expect(model.favorites.settings?.entries.map(\.id.rawValue) == [1, 2, 3])
        #expect(model.favorites.limitReached == nil)
        #expect(model.displayedFavorites?.sections.first?.entries.map(\.id.rawValue) == [1, 2, 3, 4, 5])

        // Discord removes a synced favourite and starts carrying a local one.
        let remote = [synced[0], synced[1], FavoritesSettings.Entry(id: ChannelID(rawValue: 4), position: 9, channelType: 11)]
        _ = model.consumeFavoritesEvent(.favoritesChanged(FavoritesSettings(entries: remote), isConfirmed: true))
        #expect(model.favorites.localEntries.map(\.id.rawValue) == [5])
        #expect(model.displayedFavorites?.sections.first?.entries.map(\.id.rawValue) == [1, 2, 4, 5])

        // An edit still awaiting Discord's answer never deletes a local copy.
        let pending = remote + [FavoritesSettings.Entry(id: ChannelID(rawValue: 5), position: 10, channelType: 11)]
        _ = model.consumeFavoritesEvent(.favoritesChanged(FavoritesSettings(entries: pending), isConfirmed: false))
        _ = model.consumeFavoritesEvent(.favoritesChanged(FavoritesSettings(entries: remote), isConfirmed: true))
        #expect(model.favorites.localEntries.map(\.id.rawValue) == [5])

        model.featuresSettings.unlimitedFavorites = false
        #expect(model.displayedFavorites?.entries.map(\.id.rawValue) == [1, 2, 4])
        #expect(!model.isFavorite(ChannelID(rawValue: 5)))
        #expect(model.favorites.localEntries.map(\.id.rawValue) == [5])
    }
}
