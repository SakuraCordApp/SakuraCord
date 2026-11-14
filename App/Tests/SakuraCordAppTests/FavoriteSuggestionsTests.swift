import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
struct FavoriteSuggestionsTests {
    /// Guards the window: removing the Suggested Channels section in the
    /// update that removes the Favorites list threw inside AppKit, and the
    /// window stopped drawing after leaving Favorites for another server.
    @Test func `leaving Favorites keeps Suggested Channels and dismissing clears them`() {
        let model = AppModel(launchMode: .offlineTesting)
        let channel = Channel(id: ChannelID(rawValue: 7), guildID: nil, name: "suggested")
        let suggestions = [ForwardDestination(kind: .channel(channel), guild: nil)]
        model.favorites.isPresented = true
        model.favorites.suggestionsDismissed = false
        model.favorites.suggestions = suggestions

        model.setFavoritesPresented(false)
        #expect(model.favorites.suggestions == suggestions)

        model.favorites.isPresented = true
        model.favorites.suggestionsDismissed = true
        model.refreshFavoriteSuggestions()
        #expect(model.favorites.suggestions.isEmpty)
    }
}
