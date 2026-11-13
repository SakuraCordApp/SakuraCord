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

    /// A suggestion added past the limit with Unlimited favorites is filed
    /// under Channels like a synced one, also when the limit notice's
    /// Turn On Unlimited Favorites re-adds it.
    @Test func `a suggestion kept past the limit lands in Channels`() throws {
        for turnsOnFromNotice in [false, true] {
            let model = AppModel(launchMode: .offlineTesting)
            let synced = (1 ... 3).map {
                FavoritesSettings.Entry(id: ChannelID(rawValue: $0), position: UInt32($0), channelType: 11)
            }
            _ = model.consumeFavoritesEvent(.favoritesChanged(FavoritesSettings(entries: synced), isConfirmed: true))
            model.featuresSettings.unlimitedFavorites = !turnsOnFromNotice

            let suggestion = FavoriteAddition(id: ChannelID(rawValue: 4), channelType: 11)
            model.addFavorites([suggestion], categoryName: AppModel.favoriteSuggestionsCategoryName)
            if turnsOnFromNotice {
                #expect(model.favorites.settings?.category(named: AppModel.favoriteSuggestionsCategoryName) == nil)
                model.addFavoriteBeyondLimit(try #require(model.favorites.limitReached))
            }

            let sections = try #require(model.displayedFavorites?.sections)
            #expect(sections.first?.entries.map(\.id.rawValue) == [1, 2, 3])
            #expect(sections.last?.category?.nickname == AppModel.favoriteSuggestionsCategoryName)
            #expect(sections.last?.entries.map(\.id.rawValue) == [4])
            #expect(model.favorites.localEntries.map(\.id.rawValue) == [4])
        }
    }

    /// Guards the account: near Discord's 200-entry cap a suggestion never
    /// sends more than 200 entries, and Unlimited favorites keeps it locally,
    /// in Channels only when the list has room for the category.
    @Test func `a suggestion near the entry cap never sends Discord more than it allows`() throws {
        func model(threads: Int, unseen: Int, categories: Int) -> AppModel {
            let model = AppModel(launchMode: .offlineTesting)
            var entries = (0 ..< categories).map {
                FavoritesSettings.Entry(id: ChannelID(rawValue: UInt64(1_000 + $0)), isCategory: true, nickname: "C\($0)", position: UInt32($0))
            }
            entries += (0 ..< threads).map { FavoritesSettings.Entry(id: ChannelID(rawValue: UInt64(10 + $0)), position: 1, channelType: 11) }
            entries += (0 ..< unseen).map { FavoritesSettings.Entry(id: ChannelID(rawValue: UInt64(20 + $0)), position: 1, channelType: 0) }
            _ = model.consumeFavoritesEvent(.favoritesChanged(FavoritesSettings(entries: entries), isConfirmed: true))
            model.featuresSettings.unlimitedFavorites = true
            return model
        }
        let suggestion = FavoriteAddition(id: ChannelID(rawValue: 99), channelType: 11)
        let channels = AppModel.favoriteSuggestionsCategoryName

        // 199 entries: the category fits, the favourite doesn't, so it stays local in Channels.
        let almostFull = model(threads: 2, unseen: 0, categories: 197)
        almostFull.addFavorites([suggestion], categoryName: channels)
        let saved = try #require(almostFull.favorites.settings)
        #expect(saved.entries.count == 200)
        #expect(almostFull.favorites.localEntries.first?.parentID == saved.category(named: channels)?.id)

        // 200 entries over the free limit with unseen ones: nothing synced changes, kept locally uncategorised.
        let full = model(threads: 3, unseen: 2, categories: 195)
        full.addFavorites([suggestion], categoryName: channels)
        #expect(full.favorites.settings?.entries.count == 200)
        #expect(full.favorites.settings?.category(named: channels) == nil)
        #expect(full.favorites.localEntries.map(\.id) == [suggestion.id])
        #expect(full.favorites.localEntries.first?.parentID == nil)

        // 200 entries under the free limit: unseen ones make room for the category and the favourite.
        let pruned = model(threads: 1, unseen: 2, categories: 197)
        pruned.addFavorites([suggestion], categoryName: channels)
        let synced = try #require(pruned.favorites.settings)
        #expect(synced.entries.count == 200)
        #expect(synced.entries.first { $0.id == suggestion.id }?.parentID == synced.category(named: channels)?.id)
    }

    /// Guards the account: an addition never sends Discord more favourites
    /// than the limit, even when an unseen (deleted) favourite is stored.
    @Test func `an addition at the limit drops unseen favourites instead of exceeding it`() {
        let model = AppModel(launchMode: .offlineTesting)
        let stored = [
            FavoritesSettings.Entry(id: ChannelID(rawValue: 1), position: 1, channelType: 11),
            FavoritesSettings.Entry(id: ChannelID(rawValue: 2), position: 2, channelType: 11),
            FavoritesSettings.Entry(id: ChannelID(rawValue: 3), position: 3, channelType: 0),
        ]
        _ = model.consumeFavoritesEvent(.favoritesChanged(FavoritesSettings(entries: stored), isConfirmed: true))

        model.toggleFavorite(ChannelID(rawValue: 4), channelType: 11)
        #expect(model.favorites.settings?.entries.map(\.id.rawValue) == [1, 2, 4])
    }
}
