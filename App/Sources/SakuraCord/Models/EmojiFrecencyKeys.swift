import Foundation
import MessageRendering
import SakuraCordModels

/// Discord's unique names include skin tones; picker presentation folds tones
/// back to the base emoji only after ranking and the 42-candidate cutoff.
enum EmojiFrecencyKeys {
    /// Discord's frequently used cutoff, applied to resolved keys before folding.
    static let frequentlyUsedCandidateLimit = 42

    private struct Catalog: Decodable { var entries: [String: [String]] }
    private static let entries: [String: [String]] = {
        guard let url = Bundle.module.url(forResource: "emoji-frecency-keys", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
        else { return [:] }
        return catalog.entries
    }()
    private static let keysByValue = Dictionary(
        entries.compactMap { key, entry -> (String, String)? in
            guard let value = entry.first else { return nil }
            return (normalized(value), key)
        }, uniquingKeysWith: { first, _ in first }
    )
    private static let customExpression = RegularExpressionFactory.make("<a?:[A-Za-z0-9_]+:([0-9]+)>")

    static func baseKey(_ key: String) -> String { entries[key]?.last ?? key }
    static func value(for key: String) -> String? { entries[key]?.first }

    static func reactionKey(_ token: String) -> String? {
        if let last = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .split(separator: ":").last, token.contains(":"), last.allSatisfy(\.isNumber) {
            return String(last)
        }
        return keysByValue[normalized(token)] ?? (entries[token] == nil ? nil : token)
    }

    static func messageKeys(in content: String, customEmojis: [DiscordEmoji]) -> [String] {
        let text = DiscordMarkdown.emojiUsageText(in: content)
        let customIDs = Set(customEmojis.map(\.id))
        let matches = customExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result: [String] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), let idRange = Range(match.range(at: 1), in: text) else { continue }
            result.append(contentsOf: unicodeKeys(in: text[cursor ..< range.lowerBound]))
            let id = String(text[idRange])
            if customIDs.contains(id) { result.append(id) }
            cursor = range.upperBound
        }
        result.append(contentsOf: unicodeKeys(in: text[cursor...]))
        return result
    }

    private static func unicodeKeys(in text: Substring) -> [String] {
        text.compactMap { keysByValue[normalized(String($0))] }
    }

    /// Emoji identity ignores the U+FE0F variation selector.
    static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{FE0F}", with: "")
    }
}
