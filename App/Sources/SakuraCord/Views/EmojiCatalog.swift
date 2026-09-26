import AppKit
import SwiftUI

enum NativeEmojiCategory: String, CaseIterable, Identifiable {
    case smileys, people, nature, food, activities, travel, objects, symbols, flags

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .smileys: "Smileys & Emotion"
        case .people: "People & Body"
        case .nature: "Animals & Nature"
        case .food: "Food & Drink"
        case .activities: "Activities"
        case .travel: "Travel & Places"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }

    var symbol: String {
        switch self {
        case .smileys: "😀"
        case .people: "👋"
        case .nature: "🐻"
        case .food: "🍕"
        case .activities: "⚽️"
        case .travel: "🚗"
        case .objects: "💡"
        case .symbols: "❤️"
        case .flags: "🏳️"
        }
    }
}

struct NativeEmoji: Identifiable {
    private static let discordKeySeparatorExpression = RegularExpressionFactory.make("[^a-z0-9]+")

    let value: String
    let name: String
    let aliases: String
    let category: NativeEmojiCategory
    let skinToneVariants: [NativeEmojiSkinTone: String]
    let shortcodes: [String]
    let searchText: String
    let discordKey: String
    let discordKeys: Set<String>

    init(
        value: String,
        name: String,
        aliases: String,
        category: NativeEmojiCategory,
        skinToneVariants: [NativeEmojiSkinTone: String] = [:],
        shortcodes: [String] = []
    ) {
        self.value = value
        self.name = name
        self.aliases = aliases
        self.category = category
        self.skinToneVariants = skinToneVariants
        self.shortcodes = shortcodes

        let normalizedName = name.lowercased().replacingOccurrences(of: "&", with: "and")
        let discordKey = shortcodes.first
            ?? Self.discordKeySeparatorExpression.stringByReplacingMatches(
                in: normalizedName,
                range: NSRange(location: 0, length: normalizedName.utf16.count),
                withTemplate: "_"
            ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        self.discordKey = discordKey
        searchText = (
            [name, aliases] + shortcodes
                + shortcodes.map { $0.replacingOccurrences(of: "_", with: " ") }
        ).joined(separator: " ").lowercased()
        var discordKeys = Set(aliases.split(separator: " ").map(String.init))
        discordKeys.formUnion(shortcodes)
        discordKeys.insert(discordKey)
        discordKeys.insert(value)
        self.discordKeys = discordKeys
    }

    var id: String {
        value
    }

    func value(for skinTone: NativeEmojiSkinTone) -> String {
        skinToneVariants[skinTone] ?? value
    }
}

private enum NativeEmojiCatalog {
    private struct CatalogFile: Decodable {
        let formatVersion: Int
        let unicodeVersion: String
        let sourceEntryCount: Int
        let items: [CatalogItem]
    }

    private struct CatalogItem: Decodable {
        let value: String
        let name: String
        let aliases: String
        let category: String
        let skinToneVariants: [String: String]
        let shortcodes: [String]
    }

    private struct LoadedCatalog {
        let items: [NativeEmoji]
        let sourceEntryCount: Int
    }

    private static let loadedCatalog = loadCatalog()
    static let items: [NativeEmoji] =
        loadedCatalog.items.isEmpty ? fallbackItems : loadedCatalog.items
    static let sourceEntryCount = loadedCatalog.sourceEntryCount

    private static func loadCatalog() -> LoadedCatalog {
        guard let url = Bundle.module.url(forResource: "emoji-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CatalogFile.self, from: data),
              decoded.formatVersion == 1,
              decoded.unicodeVersion == "17.0"
        else {
            return LoadedCatalog(items: [], sourceEntryCount: 0)
        }
        return LoadedCatalog(
            items: decoded.items.compactMap {
                guard let category = NativeEmojiCategory(rawValue: $0.category) else { return nil }
                return NativeEmoji(
                    value: $0.value,
                    name: $0.name,
                    aliases: $0.aliases,
                    category: category,
                    skinToneVariants: Dictionary(
                        uniqueKeysWithValues: $0.skinToneVariants.compactMap { key, value in
                            NativeEmojiSkinTone(rawValue: key).map { ($0, value) }
                        }
                    ),
                    shortcodes: $0.shortcodes
                )
            },
            sourceEntryCount: decoded.sourceEntryCount
        )
    }

    private static let fallbackItems: [NativeEmoji] = [
        .init(value: "😀", name: "grinning face", aliases: "smile happy", category: .smileys),
        .init(
            value: "😃", name: "grinning face with big eyes", aliases: "happy joy", category: .smileys
        ),
        .init(value: "😄", name: "grinning squinting face", aliases: "laugh happy", category: .smileys),
        .init(value: "😁", name: "beaming face", aliases: "grin", category: .smileys),
        .init(value: "😆", name: "laughing face", aliases: "satisfied xd", category: .smileys),
        .init(
            value: "😅", name: "grinning face with sweat", aliases: "nervous relief", category: .smileys
        ),
        .init(value: "😂", name: "face with tears of joy", aliases: "lol laugh cry", category: .smileys),
        .init(value: "🤣", name: "rolling on the floor laughing", aliases: "rofl", category: .smileys),
        .init(value: "😊", name: "smiling face with smiling eyes", aliases: "blush", category: .smileys),
        .init(value: "🙂", name: "slightly smiling face", aliases: "smile", category: .smileys),
        .init(value: "🙃", name: "upside down face", aliases: "sarcasm", category: .smileys),
        .init(value: "😉", name: "winking face", aliases: "wink", category: .smileys),
        .init(
            value: "😍", name: "smiling face with heart eyes", aliases: "love crush", category: .smileys
        ),
        .init(
            value: "🥰", name: "smiling face with hearts", aliases: "love affection", category: .smileys
        ),
        .init(value: "😘", name: "face blowing a kiss", aliases: "kiss", category: .smileys),
        .init(value: "😋", name: "face savoring food", aliases: "yum delicious", category: .smileys),
        .init(value: "😎", name: "smiling face with sunglasses", aliases: "cool", category: .smileys),
        .init(value: "🤩", name: "star struck", aliases: "excited wow", category: .smileys),
        .init(value: "🥳", name: "partying face", aliases: "celebrate birthday", category: .smileys),
        .init(value: "😏", name: "smirking face", aliases: "smirk", category: .smileys),
        .init(value: "😒", name: "unamused face", aliases: "annoyed", category: .smileys),
        .init(value: "😔", name: "pensive face", aliases: "sad", category: .smileys),
        .init(value: "😢", name: "crying face", aliases: "sad tear", category: .smileys),
        .init(value: "😭", name: "loudly crying face", aliases: "sob cry", category: .smileys),
        .init(
            value: "😤", name: "face with steam from nose", aliases: "triumph angry", category: .smileys
        ),
        .init(value: "😡", name: "enraged face", aliases: "rage angry", category: .smileys),
        .init(
            value: "🤬", name: "face with symbols on mouth", aliases: "swearing curse", category: .smileys
        ),
        .init(value: "🤯", name: "exploding head", aliases: "mind blown shocked", category: .smileys),
        .init(value: "😳", name: "flushed face", aliases: "embarrassed", category: .smileys),
        .init(value: "🥺", name: "pleading face", aliases: "puppy eyes", category: .smileys),
        .init(value: "🤔", name: "thinking face", aliases: "think hmm", category: .smileys),
        .init(value: "🫡", name: "saluting face", aliases: "salute respect", category: .smileys),
        .init(value: "🤗", name: "hugging face", aliases: "hug", category: .smileys),
        .init(value: "🫠", name: "melting face", aliases: "melt", category: .smileys),
        .init(value: "👀", name: "eyes", aliases: "look watch", category: .people),
        .init(value: "👋", name: "waving hand", aliases: "wave hello goodbye", category: .people),
        .init(value: "🤚", name: "raised back of hand", aliases: "hand", category: .people),
        .init(value: "🖐️", name: "hand with fingers splayed", aliases: "five", category: .people),
        .init(value: "✋", name: "raised hand", aliases: "stop high five", category: .people),
        .init(value: "👌", name: "ok hand", aliases: "okay", category: .people),
        .init(value: "🤌", name: "pinched fingers", aliases: "italian gesture", category: .people),
        .init(value: "🤏", name: "pinching hand", aliases: "small tiny", category: .people),
        .init(value: "✌️", name: "victory hand", aliases: "peace", category: .people),
        .init(value: "🤞", name: "crossed fingers", aliases: "luck hope", category: .people),
        .init(value: "🤟", name: "love you gesture", aliases: "ily", category: .people),
        .init(value: "🤘", name: "sign of the horns", aliases: "rock metal", category: .people),
        .init(
            value: "👉", name: "backhand index pointing right", aliases: "point right", category: .people
        ),
        .init(
            value: "👈", name: "backhand index pointing left", aliases: "point left", category: .people
        ),
        .init(value: "👆", name: "backhand index pointing up", aliases: "point up", category: .people),
        .init(
            value: "👇", name: "backhand index pointing down", aliases: "point down", category: .people
        ),
        .init(value: "👍", name: "thumbs up", aliases: "+1 yes like", category: .people),
        .init(value: "👎", name: "thumbs down", aliases: "-1 no dislike", category: .people),
        .init(value: "👏", name: "clapping hands", aliases: "clap applause", category: .people),
        .init(value: "🙌", name: "raising hands", aliases: "hooray celebrate", category: .people),
        .init(value: "🫶", name: "heart hands", aliases: "love", category: .people),
        .init(value: "🙏", name: "folded hands", aliases: "pray thanks please", category: .people),
        .init(value: "💪", name: "flexed biceps", aliases: "strong muscle", category: .people),
        .init(value: "🧠", name: "brain", aliases: "smart mind", category: .people),
        .init(value: "🐶", name: "dog face", aliases: "puppy pet", category: .nature),
        .init(value: "🐱", name: "cat face", aliases: "kitty pet", category: .nature),
        .init(value: "🐭", name: "mouse face", aliases: "rodent", category: .nature),
        .init(value: "🐹", name: "hamster", aliases: "pet", category: .nature),
        .init(value: "🐰", name: "rabbit face", aliases: "bunny", category: .nature),
        .init(value: "🦊", name: "fox", aliases: "animal", category: .nature),
        .init(value: "🐻", name: "bear", aliases: "animal", category: .nature),
        .init(value: "🐼", name: "panda", aliases: "animal", category: .nature),
        .init(value: "🐨", name: "koala", aliases: "animal", category: .nature),
        .init(value: "🐯", name: "tiger face", aliases: "animal", category: .nature),
        .init(value: "🦁", name: "lion", aliases: "animal", category: .nature),
        .init(value: "🐸", name: "frog", aliases: "toad", category: .nature),
        .init(value: "🐵", name: "monkey face", aliases: "animal", category: .nature),
        .init(value: "🐔", name: "chicken", aliases: "bird", category: .nature),
        .init(value: "🐧", name: "penguin", aliases: "bird", category: .nature),
        .init(value: "🐦", name: "bird", aliases: "animal", category: .nature),
        .init(value: "🦄", name: "unicorn", aliases: "magic", category: .nature),
        .init(value: "🐝", name: "honeybee", aliases: "bee insect", category: .nature),
        .init(value: "🦋", name: "butterfly", aliases: "insect", category: .nature),
        .init(value: "🐌", name: "snail", aliases: "slow", category: .nature),
        .init(value: "🐙", name: "octopus", aliases: "sea", category: .nature),
        .init(value: "🦈", name: "shark", aliases: "blahaj sea", category: .nature),
        .init(value: "🌱", name: "seedling", aliases: "plant grow", category: .nature),
        .init(value: "🌸", name: "cherry blossom", aliases: "flower", category: .nature),
        .init(value: "🌈", name: "rainbow", aliases: "weather pride", category: .nature),
        .init(value: "☀️", name: "sun", aliases: "sunny weather", category: .nature),
        .init(value: "⭐️", name: "star", aliases: "favorite", category: .nature),
        .init(value: "🔥", name: "fire", aliases: "lit hot flame", category: .nature),
        .init(value: "🍏", name: "green apple", aliases: "fruit", category: .food),
        .init(value: "🍎", name: "red apple", aliases: "fruit", category: .food),
        .init(value: "🍓", name: "strawberry", aliases: "fruit", category: .food),
        .init(value: "🍕", name: "pizza", aliases: "food", category: .food),
        .init(value: "🍔", name: "hamburger", aliases: "burger food", category: .food),
        .init(value: "🍟", name: "french fries", aliases: "chips food", category: .food),
        .init(value: "🌮", name: "taco", aliases: "food", category: .food),
        .init(value: "🍿", name: "popcorn", aliases: "movie food", category: .food),
        .init(value: "🍪", name: "cookie", aliases: "biscuit", category: .food),
        .init(value: "🎂", name: "birthday cake", aliases: "cake party", category: .food),
        .init(value: "☕️", name: "hot beverage", aliases: "coffee tea", category: .food),
        .init(value: "🍺", name: "beer mug", aliases: "drink", category: .food),
        .init(value: "🍷", name: "wine glass", aliases: "drink", category: .food),
        .init(value: "⚽️", name: "soccer ball", aliases: "football sport", category: .activities),
        .init(value: "🏀", name: "basketball", aliases: "sport", category: .activities),
        .init(value: "🏈", name: "american football", aliases: "sport", category: .activities),
        .init(value: "🎾", name: "tennis", aliases: "sport", category: .activities),
        .init(value: "🎮", name: "video game", aliases: "controller gaming", category: .activities),
        .init(value: "🎲", name: "game die", aliases: "dice", category: .activities),
        .init(value: "🎯", name: "bullseye", aliases: "target dart", category: .activities),
        .init(value: "🎨", name: "artist palette", aliases: "art paint", category: .activities),
        .init(value: "🎸", name: "guitar", aliases: "music", category: .activities),
        .init(value: "🎉", name: "party popper", aliases: "celebrate tada", category: .activities),
        .init(value: "🏆", name: "trophy", aliases: "winner award", category: .activities),
        .init(value: "🚗", name: "automobile", aliases: "car vehicle", category: .travel),
        .init(value: "🚌", name: "bus", aliases: "vehicle", category: .travel),
        .init(value: "🚲", name: "bicycle", aliases: "bike", category: .travel),
        .init(value: "✈️", name: "airplane", aliases: "flight travel", category: .travel),
        .init(value: "🚀", name: "rocket", aliases: "space launch", category: .travel),
        .init(
            value: "🌍", name: "globe showing Europe Africa", aliases: "earth world", category: .travel
        ),
        .init(value: "🏠", name: "house", aliases: "home", category: .travel),
        .init(value: "🏙️", name: "cityscape", aliases: "city", category: .travel),
        .init(value: "🌅", name: "sunrise", aliases: "morning", category: .travel),
        .init(value: "⌚️", name: "watch", aliases: "time", category: .objects),
        .init(value: "📱", name: "mobile phone", aliases: "iphone smartphone", category: .objects),
        .init(value: "💻", name: "laptop", aliases: "computer mac coding", category: .objects),
        .init(value: "⌨️", name: "keyboard", aliases: "computer typing", category: .objects),
        .init(value: "🖥️", name: "desktop computer", aliases: "monitor", category: .objects),
        .init(value: "📷", name: "camera", aliases: "photo", category: .objects),
        .init(value: "🎧", name: "headphone", aliases: "music audio", category: .objects),
        .init(value: "🔋", name: "battery", aliases: "power", category: .objects),
        .init(value: "💡", name: "light bulb", aliases: "idea", category: .objects),
        .init(value: "🔒", name: "locked", aliases: "secure lock", category: .objects),
        .init(value: "🔑", name: "key", aliases: "password", category: .objects),
        .init(value: "🛠️", name: "hammer and wrench", aliases: "tools build", category: .objects),
        .init(value: "🧪", name: "test tube", aliases: "science test", category: .objects),
        .init(value: "📌", name: "pushpin", aliases: "pin", category: .objects),
        .init(value: "❤️", name: "red heart", aliases: "love", category: .symbols),
        .init(value: "🧡", name: "orange heart", aliases: "love", category: .symbols),
        .init(value: "💛", name: "yellow heart", aliases: "love", category: .symbols),
        .init(value: "💚", name: "green heart", aliases: "love", category: .symbols),
        .init(value: "💙", name: "blue heart", aliases: "love", category: .symbols),
        .init(value: "💜", name: "purple heart", aliases: "love", category: .symbols),
        .init(value: "🖤", name: "black heart", aliases: "love", category: .symbols),
        .init(value: "💔", name: "broken heart", aliases: "sad heartbreak", category: .symbols),
        .init(value: "💕", name: "two hearts", aliases: "love", category: .symbols),
        .init(value: "💯", name: "hundred points", aliases: "100 perfect", category: .symbols),
        .init(value: "💢", name: "anger symbol", aliases: "mad", category: .symbols),
        .init(value: "💥", name: "collision", aliases: "boom explosion", category: .symbols),
        .init(value: "💫", name: "dizzy", aliases: "star", category: .symbols),
        .init(value: "✨", name: "sparkles", aliases: "shiny magic", category: .symbols),
        .init(value: "✅", name: "check mark button", aliases: "done yes", category: .symbols),
        .init(value: "❌", name: "cross mark", aliases: "no error", category: .symbols),
        .init(value: "⚠️", name: "warning", aliases: "alert", category: .symbols),
        .init(value: "❓", name: "question mark", aliases: "help", category: .symbols),
        .init(value: "‼️", name: "double exclamation mark", aliases: "important", category: .symbols),
        .init(value: "🏳️", name: "white flag", aliases: "surrender", category: .flags),
        .init(value: "🏴", name: "black flag", aliases: "flag", category: .flags),
        .init(value: "🏳️‍🌈", name: "rainbow flag", aliases: "pride lgbt", category: .flags),
        .init(value: "🏳️‍⚧️", name: "transgender flag", aliases: "trans pride", category: .flags),
        .init(value: "🇺🇦", name: "flag Ukraine", aliases: "ukraine ua", category: .flags),
        .init(value: "🇺🇸", name: "flag United States", aliases: "usa america", category: .flags),
        .init(value: "🇬🇧", name: "flag United Kingdom", aliases: "uk britain", category: .flags),
        .init(value: "🇪🇺", name: "flag European Union", aliases: "eu europe", category: .flags),
        .init(value: "🇯🇵", name: "flag Japan", aliases: "japan jp", category: .flags),
        .init(value: "🇨🇦", name: "flag Canada", aliases: "canada ca", category: .flags)
    ]
}

enum NativeEmojiPickerIndex {
    static let allItems = NativeEmojiCatalog.items.map(EmojiPickerItem.native)
    static let itemsByCategory = Dictionary(grouping: allItems) { item in
        guard case let .native(emoji) = item else { return NativeEmojiCategory.smileys }
        return emoji.category
    }
}

enum NativeEmojiCatalogDiagnostics {
    static var sourceEntryCount: Int {
        NativeEmojiCatalog.sourceEntryCount
    }

    static var itemCount: Int {
        NativeEmojiCatalog.items.count
    }

    static var skinToneCapableItemCount: Int {
        NativeEmojiCatalog.items.count(where: { !$0.skinToneVariants.isEmpty })
    }

    static var wavingHandValues: [String] {
        guard let wave = NativeEmojiCatalog.items.first(where: { $0.value == "👋" }) else { return [] }
        return NativeEmojiSkinTone.allCases.map { wave.value(for: $0) }
    }

    static var mediumToneVariationSelectorValues: [String] {
        ["✌️", "☝️", "✍️"].compactMap { base in
            NativeEmojiCatalog.items.first(where: { $0.value == base })?.value(for: .medium)
        }
    }

    static var baseItemsContainingSkinToneModifier: Int {
        NativeEmojiCatalog.items.count { emoji in
            emoji.value.unicodeScalars.contains {
                NativeEmojiSkinTone(modifierCodePoint: $0.value) != nil
            }
        }
    }

    static var categoryItemCounts: [String: Int] {
        Dictionary(grouping: NativeEmojiCatalog.items, by: { $0.category.rawValue })
            .mapValues(\.count)
    }

    static func shortcode(for value: String) -> String? {
        NativeEmojiCatalogMetadata.shortcode(for: value)
    }

    static func shortcodes(for value: String) -> [String] {
        NativeEmojiCatalog.items.first(where: { $0.value == value })?.shortcodes ?? []
    }

    static func searchMatches(value: String, query: String) -> Bool {
        guard let emoji = NativeEmojiCatalog.items.first(where: { $0.value == value }) else {
            return false
        }
        return EmojiSearchMatcher.matches(emoji.searchText, query: query)
    }

    static var emojiCountWithDiscordShortcodes: Int {
        NativeEmojiCatalog.items.count { !$0.shortcodes.isEmpty }
    }

    static var discordShortcodeAliasCount: Int {
        NativeEmojiCatalog.items.reduce(0) { $0 + $1.shortcodes.count }
    }
}

enum NativeEmojiCatalogMetadata {
    private static let valuesByShortcode = Dictionary(
        NativeEmojiCatalog.items.flatMap { emoji in emoji.shortcodes.map { ($0, emoji.value) } },
        uniquingKeysWith: { first, _ in first }
    )

    static func value(forShortcode shortcode: String) -> String? { valuesByShortcode[shortcode] }
    static func shortcode(for value: String) -> String? {
        NativeEmojiCatalog.items.first(where: {
            $0.value == value || $0.skinToneVariants.values.contains(value)
        }).map { ":\($0.discordKey):" }
    }
}

/// Locale-specific related names loaded by Discord's public emoji search
/// module. The composer uses these for matching only; display and ranking keep
/// the primary Discord shortcode.
enum DiscordEmojiSearchAliases {
    static let english: [String: [String]] = {
        guard let url = Bundle.module.url(
            forResource: "emoji-search-aliases-en-US",
            withExtension: "json"
        ), let data = try? Data(contentsOf: url),
            let aliases = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return aliases
    }()
}

struct NativeEmojiAutocompleteResult: Identifiable, Equatable {
    let value: String
    let name: String
    let shortcode: String
    let rankingName: String
    let completionNames: [String]
    let catalogIndex: Int
    var id: String {
        "native:\(value)"
    }
}

enum NativeEmojiAutocompleteCatalog {
    private struct SearchEntry {
        let emoji: NativeEmoji
        let normalizedKeys: [String]
        let completionNames: [String]
        let rankingName: String
        let catalogIndex: Int
    }

    /// Emoji metadata is immutable for the lifetime of the process. Building
    /// these sets, normalized strings, and sorted aliases for every keystroke
    /// made autocomplete spend most of its time recreating the same values.
    private static let searchEntries: [SearchEntry] = NativeEmojiCatalog.items.enumerated().map { index, emoji in
        let completionNames = Array(emoji.autocompleteKeys).sorted()
        return SearchEntry(
            emoji: emoji,
            normalizedKeys: completionNames.map(EmojiSearchMatcher.autocompleteNormalized),
            completionNames: completionNames,
            rankingName: emoji.discordAutocompleteName,
            catalogIndex: index
        )
    }

    static func search(_ query: String) -> [NativeEmojiAutocompleteResult] {
        let normalized = EmojiSearchMatcher.autocompleteNormalized(query)
        let tone =
            NativeEmojiSkinTone(rawValue: UserDefaults.standard.string(forKey: "emojiSkinTone") ?? "")
                ?? .standard
        var results: [NativeEmojiAutocompleteResult] = []
        results.reserveCapacity(normalized.isEmpty ? searchEntries.count : 64)
        for entry in searchEntries
            where normalized.isEmpty || entry.normalizedKeys.contains(where: { $0.contains(normalized) })
        {
            results.append(
                NativeEmojiAutocompleteResult(
                    value: entry.emoji.value(for: tone),
                    name: entry.emoji.name,
                    shortcode: entry.emoji.discordKey,
                    rankingName: entry.rankingName,
                    completionNames: entry.completionNames,
                    catalogIndex: entry.catalogIndex
                )
            )
        }
        return results
    }
}

private extension NativeEmoji {
    var discordAutocompleteName: String {
        guard category == .flags, name.hasPrefix("flag: ") else { return discordKey }
        return name
            .dropFirst("flag: ".count)
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    var autocompleteKeys: Set<String> {
        Set(shortcodes)
            .union([discordKey, discordAutocompleteName])
            .union(DiscordEmojiSearchAliases.english[discordKey] ?? [])
    }
}

enum EmojiSearchMatcher {
    nonisolated static func normalized(_ query: String) -> String {
        query.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))
        )
        .lowercased()
    }

    nonisolated static func autocompleteNormalized(_ query: String) -> String {
        normalized(query)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    nonisolated static func matches(_ searchText: String, query: String) -> Bool {
        let query = normalized(query)
        return !query.isEmpty && searchText.localizedCaseInsensitiveContains(query)
    }
}

enum EmojiPickerPerformanceDiagnostics {
    static let itemsPerRecycledRow = 9
    static var nativeItemCount: Int {
        NativeEmojiCatalog.items.count
    }

    static var nativeDocumentRowCount: Int {
        NativeEmojiCategory.allCases.reduce(0) { total, category in
            let count = NativeEmojiPickerIndex.itemsByCategory[category]?.count ?? 0
            return total + 1 + max(1, Int(ceil(Double(count) / Double(itemsPerRecycledRow))))
        }
    }

    static var nativeSectionIDs: [String] {
        NativeEmojiCategory.allCases.map { EmojiDocumentSection.native($0).id }
    }

    static func nativeSidebarIsVisible(bounds: CGRect?, viewportHeight: CGFloat) -> Bool {
        bounds.map { $0.maxY > 0 && $0.minY < viewportHeight } ?? false
    }
}
