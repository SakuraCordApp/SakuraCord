import Foundation
import SakuraCordModels

/// Keeps the complete emoji lookup without eagerly parsing a CDN URL for every
/// emoji in every guild. Visible consumers resolve the same URL on lookup and
/// continue to share the existing image/data caches keyed by that URL.
nonisolated struct CustomEmojiImageURLs: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    private enum Source: Equatable, Sendable {
        case discord(animated: Bool)
        case custom(URL)
    }

    private var sources: [String: Source]

    init(minimumCapacity: Int = 0) {
        sources = Dictionary(minimumCapacity: minimumCapacity)
    }

    init(dictionaryLiteral elements: (String, URL)...) {
        sources = Dictionary(uniqueKeysWithValues: elements.map { ($0.0, .custom($0.1)) })
    }

    mutating func insert(_ emoji: DiscordEmoji) {
        sources[emoji.id] = emoji.assetURL.map(Source.custom) ?? .discord(animated: emoji.isAnimated)
    }

    subscript(id: String) -> URL? {
        switch sources[id] {
        case .discord(let animated): DiscordEmoji.imageURL(id: id, isAnimated: animated)
        case .custom(let url): url
        case nil: nil
        }
    }

    func differs(
        from other: Self,
        cancellationCheck: @Sendable () -> Bool
    ) -> Bool? {
        guard sources.count == other.sources.count else { return true }
        for (index, entry) in sources.enumerated() {
            if index.isMultiple(of: 128), cancellationCheck() { return nil }
            if other.sources[entry.key] != entry.value { return true }
        }
        return cancellationCheck() ? nil : false
    }
}

nonisolated extension EmojiReference {
    /// A custom emoji's image: the account's own link when it has one, else
    /// Discord's CDN.
    func imageURL(in customURLs: CustomEmojiImageURLs?) -> URL? {
        id.flatMap { customURLs?[$0] } ?? imageURL(size: 64)
    }
}
