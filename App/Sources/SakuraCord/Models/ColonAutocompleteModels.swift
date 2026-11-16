import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ColonAutocompleteSuggestion: Identifiable {
    let id: String
    let title: String
    let detail: String
    let rankingName: String
    let value: String
    let imageURL: URL?
    let source: String?
    let usageKey: String
    let discordUsageKeys: [String]
    let completionNames: [String]
    let customEmoji: DiscordEmoji?
    let stableOrder: Int

    func matchesCompletionName(_ name: String) -> Bool {
        completionNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

enum DiscordEmojiAutocompleteRanking {
    static func boundaryExpression(query: String) -> NSRegularExpression {
        let escapedQuery = NSRegularExpression.escapedPattern(for: query.lowercased())
        return RegularExpressionFactory.make("(^|_|[A-Z])\(escapedQuery)s?([A-Z]|_|$)")
    }

    /// Mirrors the public client's base name score. Favorites are composed ahead
    /// of the ordinary search results by the composer rather than changing this
    /// score in the current experiment assignment.
    static func relevance(
        name: String,
        query: String,
        boundaryExpression: NSRegularExpression
    ) -> Double {
        let originalName = name
        let name = name.lowercased()
        let query = query.lowercased()
        var score = 1.0
        if name == query { score += 4 }
        if name.hasPrefix(query) { score += 1 }
        if beginsAtWordOrCapitalBoundary(
            name: originalName,
            expression: boundaryExpression
        ) {
            score += 2
        }
        return score
    }

    private static func beginsAtWordOrCapitalBoundary(
        name: String,
        expression: NSRegularExpression
    ) -> Bool {
        func matches(_ value: String) -> Bool {
            expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex ..< value.endIndex, in: value)
            ) != nil
        }
        return matches(name) || matches(name.lowercased())
    }

    static func searchNormalized(_ value: String) -> String {
        EmojiSearchMatcher.autocompleteNormalized(value)
    }

}
