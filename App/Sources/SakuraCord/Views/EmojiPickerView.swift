import AppKit
import Foundation
import Observation
import SakuraCordModels
import SwiftUI

enum EmojiPickerSelection {
    case native(String)
    case custom(DiscordEmoji)

    var usageKey: String {
        switch self {
        case let .native(value): "unicode:\(value)"
        case let .custom(emoji): "custom:\(emoji.name):\(emoji.id)"
        }
    }
}

struct EmojiPickerActivation {
    let selection: EmojiPickerSelection
    let keepsPickerPresented: Bool
}

enum EmojiPickerActivationPolicy {
    nonisolated static func keepsPickerPresented(
        allowsPersistentSelection: Bool,
        shiftPressed: Bool
    ) -> Bool {
        allowsPersistentSelection && shiftPressed
    }
}

struct EmojiPickerHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

struct EmojiPickerButton: View {
    let cell: EmojiPickerCell
    let isFavorite: Bool
    let skinTone: NativeEmojiSkinTone
    let interaction: EmojiPickerInteractionModel
    let select: (Bool) -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        Button {
            select(NSEvent.modifierFlags.contains(.shift))
        } label: {
            cell.item.preview(skinTone: skinTone)
                .frame(width: EmojiPickerGridMetrics.cellSize, height: EmojiPickerGridMetrics.cellSize)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background {
            ConcentricRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    interaction.selectedCellID == cell.id
                        ? Color.primary.opacity(0.13)
                        : .clear
                )
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard hovering else { return }
            interaction.select(cell)
        }
        .help(cell.item.shortcode)
        .overlay {
            EmojiPickerContextMenuBridge(
                item: cell.item,
                skinTone: skinTone,
                isFavorite: isFavorite,
                toggleFavorite: toggleFavorite
            )
        }
    }
}

@MainActor
@Observable
final class EmojiPickerInteractionModel {
    private(set) var selectedCellID: String?
    private(set) var selectedRowID: String?
    private(set) var item = NativeEmojiPickerIndex.allItems[0]
    private var hasExplicitSelection = false

    func select(_ cell: EmojiPickerCell) {
        hasExplicitSelection = true
        updateSelection(to: cell)
    }

    private func updateSelection(to cell: EmojiPickerCell) {
        selectedCellID = cell.id
        selectedRowID = cell.rowID
        item = cell.item
    }

    func synchronize(with cells: [EmojiPickerCell]) {
        guard !cells.isEmpty else { return }
        guard hasExplicitSelection else {
            updateSelection(to: cells[0])
            return
        }
        if let selectedCellID, cells.contains(where: { $0.id == selectedCellID }) {
            return
        }
        updateSelection(to: cells.first(where: { $0.item.id == item.id }) ?? cells[0])
    }

    func resetSelection(with cells: [EmojiPickerCell]) {
        hasExplicitSelection = false
        synchronize(with: cells)
    }
}

enum EmojiPickerScrollPolicy {
    nonisolated static func shouldReveal(
        previousRowID: String?,
        destinationRowID: String
    ) -> Bool {
        previousRowID != destinationRowID
    }
}

enum EmojiPickerItem: Identifiable {
    case native(NativeEmoji)
    case custom(DiscordEmoji)

    var id: String {
        usageKey
    }

    var usageKey: String {
        selection.usageKey
    }

    var discordKey: String {
        switch self {
        case let .native(emoji): emoji.discordKey
        case let .custom(emoji): emoji.id
        }
    }

    var selection: EmojiPickerSelection {
        selection(skinTone: .standard)
    }

    func selection(skinTone: NativeEmojiSkinTone) -> EmojiPickerSelection {
        switch self {
        case let .native(emoji): .native(emoji.value(for: skinTone))
        case let .custom(emoji): .custom(emoji)
        }
    }

    var name: String {
        switch self {
        case let .native(emoji): emoji.name
        case let .custom(emoji): emoji.name
        }
    }

    var shortcode: String {
        switch self {
        case let .native(emoji): ":\(emoji.discordKey):"
        case let .custom(emoji): ":\(emoji.name):"
        }
    }

    func matches(normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return false }
        return switch self {
        case let .native(emoji):
            emoji.searchText.contains(normalizedQuery)
        case let .custom(emoji):
            emoji.name.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    @ViewBuilder func preview(
        skinTone: NativeEmojiSkinTone,
        dimension: CGFloat = 36,
        nativeFontSize: CGFloat = 31
    ) -> some View {
        switch self {
        case let .native(emoji):
            Text(emoji.value(for: skinTone))
                .font(.system(size: nativeFontSize))
                .fixedSize()
                .frame(width: dimension, height: dimension, alignment: .center)
                .offset(y: -1)
        case let .custom(emoji):
            if let url = emoji.imageURL {
                if emoji.isAnimated {
                    AnimatedRemoteImage(
                        url: url,
                        accessibilityCategory: .emoji
                    )
                        .frame(width: dimension - 2, height: dimension - 2)
                } else {
                    StaticEmojiImage(url: url)
                        .frame(width: dimension - 2, height: dimension - 2)
                }
            } else {
                Image(systemName: "face.dashed")
            }
        }
    }
}

enum EmojiPickerGridMetrics {
    static let columns = 9
    static let cellSize: CGFloat = 43
}

struct EmojiPickerCell: Identifiable {
    let id: String
    let rowID: String
    let item: EmojiPickerItem
}

enum EmojiPickerGridDirection {
    case left
    case right
    case up
    case down
}

enum EmojiPickerGridNavigation {
    nonisolated static func destinationID(
        rows: [[String]],
        currentID: String?,
        direction: EmojiPickerGridDirection
    ) -> String? {
        guard let firstID = rows.first?.first else { return nil }
        guard let currentID,
              let position = rows.enumerated().lazy.compactMap({ rowIndex, row -> (Int, Int)? in
                  row.firstIndex(of: currentID).map { (rowIndex, $0) }
              }).first
        else {
            return firstID
        }

        let rowIndex = position.0
        let columnIndex = position.1
        switch direction {
        case .left:
            if columnIndex > 0 {
                return rows[rowIndex][columnIndex - 1]
            }
            guard rowIndex > 0 else { return currentID }
            return rows[rowIndex - 1].last ?? currentID
        case .right:
            if columnIndex + 1 < rows[rowIndex].count {
                return rows[rowIndex][columnIndex + 1]
            }
            guard rowIndex + 1 < rows.count else { return currentID }
            return rows[rowIndex + 1].first ?? currentID
        case .up:
            guard rowIndex > 0 else { return currentID }
            return rows[rowIndex - 1][min(columnIndex, rows[rowIndex - 1].count - 1)]
        case .down:
            guard rowIndex + 1 < rows.count else { return currentID }
            return rows[rowIndex + 1][min(columnIndex, rows[rowIndex + 1].count - 1)]
        }
    }
}

private struct StaticEmojiImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
            if case let .success(image) = phase {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
    }
}

nonisolated enum NativeEmojiSkinTone: String, CaseIterable, Identifiable, Sendable {
    case standard
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .standard: "Default"
        case .light: "Light"
        case .mediumLight: "Medium light"
        case .medium: "Medium"
        case .mediumDark: "Medium dark"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "👋"
        case .light: "👋🏻"
        case .mediumLight: "👋🏼"
        case .medium: "👋🏽"
        case .mediumDark: "👋🏾"
        case .dark: "👋🏿"
        }
    }

    var modifierCodePoint: UInt32? {
        switch self {
        case .standard: nil
        case .light: 0x1F3FB
        case .mediumLight: 0x1F3FC
        case .medium: 0x1F3FD
        case .mediumDark: 0x1F3FE
        case .dark: 0x1F3FF
        }
    }

    init?(modifierCodePoint: UInt32) {
        switch modifierCodePoint {
        case 0x1F3FB: self = .light
        case 0x1F3FC: self = .mediumLight
        case 0x1F3FD: self = .medium
        case 0x1F3FE: self = .mediumDark
        case 0x1F3FF: self = .dark
        default: return nil
        }
    }
}

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

private enum NativeEmojiPickerIndex {
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

struct EmojiPickerView: View {
    let model: AppModel
    let useCase: DiscordEmojiUseCase
    let allowsPersistentSelection: Bool
    let dismiss: () -> Void
    let select: (EmojiPickerActivation) -> Void
    @State private var document = EmojiPickerDocumentStore()
    @State private var interaction = EmojiPickerInteractionModel()
    @State private var nativeCategoriesAreVisibleInSidebar = false
    @State private var searchIsFocused = false
    @State private var pendingVisibleGuilds: [GuildID] = []
    @State private var visibleGuildLoadTask: Task<Void, Never>?
    @FocusState private var keyboardNavigationIsFocused: Bool
    @AppStorage("emojiSkinTone") private var skinToneRawValue = NativeEmojiSkinTone.standard.rawValue

    init(
        model: AppModel,
        useCase: DiscordEmojiUseCase = .message,
        allowsPersistentSelection: Bool = false,
        dismiss: @escaping () -> Void,
        select: @escaping (EmojiPickerActivation) -> Void
    ) {
        self.model = model
        self.useCase = useCase
        self.allowsPersistentSelection = allowsPersistentSelection
        self.dismiss = dismiss
        self.select = select
    }

    var body: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    EmojiSearchField(
                        text: searchQuery,
                        isFocused: $searchIsFocused
                    )

                    Divider()

                    HStack(spacing: 0) {
                        EmojiDocumentSidebar(
                            guilds: document.guilds,
                            visibleSection: document.visibleSection,
                            nativeCategoriesAreVisible: $nativeCategoriesAreVisibleInSidebar,
                            showsNativeJumpButton: !nativeCategoriesAreVisibleInSidebar,
                            jump: {
                                jump(to: $0, proxy: proxy)
                                requestSearchFocus()
                            },
                            jumpToNative: {
                                jumpToNative(proxy: proxy)
                                requestSearchFocus()
                            }
                        )
                        Divider()
                        VStack(spacing: 0) {
                            EmojiPickerDocumentList(
                                document: document,
                                interaction: interaction,
                                skinTone: selectedSkinTone,
                                proxy: proxy,
                                choose: choose,
                                toggleFavorite: toggleFavorite,
                                retry: retry,
                                becameVisible: sectionBecameVisible
                            )
                            Divider()
                            EmojiHoverPreviewBar(
                                interaction: interaction,
                                skinTone: selectedSkinTone
                            )
                            .frame(height: 38)
                        }
                    }
                }
                .focusable()
                .focused($keyboardNavigationIsFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    handleKeyPress(press, proxy: proxy)
                }
                .task {
                    document.synchronize(with: model, useCase: useCase)
                    interaction.synchronize(with: document.selectableCells)
                    searchIsFocused = true
                    await Task.yield()
                    await model.loadDiscordEmojiSettings()
                    if let guildID = model.selectedGuildID {
                        await model.loadEmojis(for: guildID)
                    }
                    document.synchronize(with: model, useCase: useCase)
                    interaction.synchronize(with: document.selectableCells)
                    document.visibleSection = .favorites
                    await Task.yield()
                    proxy.scrollTo(EmojiDocumentRow.headerID(for: .favorites), anchor: .top)
                    await Task.yield()
                    searchIsFocused = true
                }
            }
        }
        .frame(width: ChatChromeMetrics.emojiPickerWidth, height: 420)
        .onExitCommand(perform: handleEscapeCommand)
        .onChange(of: skinToneRawValue) { _, _ in
            requestSearchFocus()
        }
        .onChange(of: model.discordFavoriteEmojiKeys) { _, _ in
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
        }
        .onDisappear {
            visibleGuildLoadTask?.cancel()
            visibleGuildLoadTask = nil
            pendingVisibleGuilds.removeAll()
        }
    }

    private var searchQuery: Binding<String> {
        Binding(
            get: { document.query },
            set: { query in
                let clearsSearch = !document.query.isEmpty && query.isEmpty
                document.setQuery(query)
                guard clearsSearch else { return }
                interaction.resetSelection(with: document.selectableCells)
            }
        )
    }

    private var selectedSkinTone: NativeEmojiSkinTone {
        NativeEmojiSkinTone(rawValue: skinToneRawValue) ?? .standard
    }

    private func handleEscapeCommand() {
        guard !document.query.isEmpty else {
            dismiss()
            return
        }
        searchQuery.wrappedValue = ""
        requestSearchFocus()
    }

    private func requestSearchFocus() {
        searchIsFocused = false
        Task { @MainActor in
            await Task.yield()
            searchIsFocused = true
        }
    }

    private func choose(_ cell: EmojiPickerCell, shiftPressed: Bool) {
        interaction.select(cell)
        activate(cell.item, shiftPressed: shiftPressed)
    }

    private func activate(_ item: EmojiPickerItem, shiftPressed: Bool) {
        let selection = item.selection(skinTone: selectedSkinTone)
        model.recordEmojiUse(selection.usageKey)
        let keepsPickerPresented = EmojiPickerActivationPolicy.keepsPickerPresented(
            allowsPersistentSelection: allowsPersistentSelection,
            shiftPressed: shiftPressed
        )
        select(
            EmojiPickerActivation(
            selection: selection,
            keepsPickerPresented: keepsPickerPresented
            )
        )
        guard keepsPickerPresented else { return }
        document.synchronize(with: model, useCase: useCase)
        interaction.synchronize(with: document.selectableCells)
        keyboardNavigationIsFocused = true
    }

    private func toggleFavorite(_ item: EmojiPickerItem) {
        let isFavorite = document.isFavorite(item)
        Task { @MainActor in
            guard await model.setEmojiFavorite(
                discordKey: item.discordKey,
                isFavorite: !isFavorite
            ) else { return }
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
        }
    }

    private func retry(_ guildID: GuildID) {
        Task { @MainActor in
            await model.retryEmojis(for: guildID)
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
        }
    }

    private func sectionBecameVisible(_ section: EmojiDocumentSection) {
        document.markVisible(section)
        guard case let .guild(guildID) = section,
              model.emojisByGuild[guildID] == nil,
              !model.loadingEmojiGuildIDs.contains(guildID),
              !pendingVisibleGuilds.contains(guildID)
        else { return }
        pendingVisibleGuilds.append(guildID)
        startVisibleGuildLoaderIfNeeded()
    }

    private func startVisibleGuildLoaderIfNeeded() {
        guard visibleGuildLoadTask == nil else { return }
        visibleGuildLoadTask = Task { @MainActor in
            while !Task.isCancelled, let guildID = pendingVisibleGuilds.first {
                pendingVisibleGuilds.removeFirst()
                await model.loadEmojis(for: guildID)
                guard !Task.isCancelled else { break }
                document.synchronize(with: model, useCase: useCase)
                interaction.synchronize(with: document.selectableCells)
            }
            visibleGuildLoadTask = nil
        }
    }

    private func jump(to section: EmojiDocumentSection, proxy: ScrollViewProxy) {
        document.setQuery("")
        interaction.synchronize(with: document.selectableCells)
        document.visibleSection = section
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(EmojiDocumentRow.headerID(for: section), anchor: .top)
            guard case let .guild(guildID) = section else { return }
            await model.loadEmojis(for: guildID)
            document.synchronize(with: model, useCase: useCase)
            interaction.synchronize(with: document.selectableCells)
            await Task.yield()
            proxy.scrollTo(EmojiDocumentRow.headerID(for: section), anchor: .top)
        }
    }

    private func jumpToNative(proxy: ScrollViewProxy) {
        let section = EmojiDocumentSection.native(.smileys)
        document.setQuery("")
        interaction.synchronize(with: document.selectableCells)
        document.visibleSection = section
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(EmojiDocumentRow.headerID(for: section), anchor: .top)
        }
    }

    private func handleKeyPress(
        _ press: KeyPress,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            return navigate(.left, proxy: proxy)
        case .rightArrow:
            return navigate(.right, proxy: proxy)
        case .upArrow:
            return navigate(.up, proxy: proxy)
        case .downArrow:
            return navigate(.down, proxy: proxy)
        case .return:
            activate(
                interaction.item,
                shiftPressed: press.modifiers.contains(.shift)
            )
            return .handled
        default:
            return .ignored
        }
    }

    private func navigate(
        _ direction: EmojiPickerGridDirection,
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        guard
            let cell = document.destinationCell(
            from: interaction.selectedCellID,
            direction: direction
            )
        else { return .ignored }
        let previousRowID = interaction.selectedRowID
        interaction.select(cell)
        if EmojiPickerScrollPolicy.shouldReveal(
            previousRowID: previousRowID,
            destinationRowID: cell.rowID
        ) {
            proxy.scrollTo(cell.rowID)
        }
        return .handled
    }
}

private struct EmojiPickerDocumentList: View {
    let document: EmojiPickerDocumentStore
    let interaction: EmojiPickerInteractionModel
    let skinTone: NativeEmojiSkinTone
    let proxy: ScrollViewProxy
    let choose: (EmojiPickerCell, Bool) -> Void
    let toggleFavorite: (EmojiPickerItem) -> Void
    let retry: (GuildID) -> Void
    let becameVisible: (EmojiDocumentSection) -> Void

    var body: some View {
        List(document.rows) { row in
            EmojiDocumentRowView(
                row: row,
                skinTone: skinTone,
                interaction: interaction,
                isFavorite: document.isFavorite,
                choose: choose,
                toggleFavorite: toggleFavorite,
                retry: retry,
                becameVisible: becameVisible
            )
            .id(row.id)
            .listRowInsets(row.listInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .onChange(of: document.query) { _, query in
            interaction.synchronize(with: document.selectableCells)
            guard !query.isEmpty else { return }
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo(EmojiDocumentRow.headerID(for: .search), anchor: .top)
            }
        }
    }
}

private struct EmojiSearchField: View {
    @Binding var text: String
    @Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: ChatChromeMetrics.pickerSearchHeaderSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(
                    size: ChatChromeMetrics.pickerSearchHeaderIconSize,
                    weight: .medium
                ))
                .foregroundStyle(.secondary)
            EmojiSearchTextField(text: $text, isFocused: $isFocused)
                .frame(maxWidth: .infinity)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, ChatChromeMetrics.pickerSearchHeaderInset)
        .frame(height: ChatChromeMetrics.pickerSearchHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .accessibilityIdentifier("picker-search")
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

private struct EmojiSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> EmojiSearchNSTextField {
        let textField = EmojiSearchNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = "Search emojis"
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: ChatChromeMetrics.pickerSearchHeaderFontSize)
        textField.textColor = .labelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.isAutomaticTextCompletionEnabled = false
        textField.contentType = NSTextContentType(rawValue: "dev.sakuracord.emoji-search")
        textField.allowsWritingTools = false
        textField.allowsWritingToolsAffordance = false
        textField.setAccessibilityLabel("Search emojis")
        return textField
    }

    func updateNSView(_ textField: EmojiSearchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        if textField.stringValue != text {
            textField.stringValue = text
        }

        if isFocused {
            textField.requestFirstResponderWhenReady()
            Self.disableCompletionFeatures(in: textField.currentEditor() as? NSTextView)
        } else if textField.window?.firstResponder === textField.currentEditor() {
            textField.window?.makeFirstResponder(nil)
        }
    }

    private static func disableCompletionFeatures(in editor: NSTextView?) {
        guard let editor else { return }
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
            Self.configureEditor(from: notification)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        private static func configureEditor(from notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let editor = textField.currentEditor() as? NSTextView
            EmojiSearchTextField.disableCompletionFeatures(in: editor)
            editor?.applySakuraCordTextSelectionAppearance()
        }
    }
}

private final class EmojiSearchNSTextField: NSTextField {
    private var focusRequestIsScheduled = false
    private var didAutofocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            didAutofocus = false
            focusRequestIsScheduled = false
            return
        }
        guard !didAutofocus else { return }
        requestFirstResponderWhenReady()
    }

    func requestFirstResponderWhenReady() {
        guard let window, !focusRequestIsScheduled else { return }
        if window.firstResponder === currentEditor() {
            didAutofocus = true
            return
        }
        focusRequestIsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [0, 80, 140, 220] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard let window = self.window else { break }
                window.makeKey()
                _ = window.makeFirstResponder(self)
                await Task.yield()
                if window.firstResponder === currentEditor() {
                    didAutofocus = true
                    break
                }
            }
            focusRequestIsScheduled = false
        }
    }
}

enum EmojiDocumentSection: Hashable, Identifiable {
    case favorites
    case frequent
    case native(NativeEmojiCategory)
    case guild(GuildID)
    case search

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .frequent: "frequent"
        case let .native(category): "native:\(category.rawValue)"
        case let .guild(id): "guild:\(id)"
        case .search: "search"
        }
    }

    var isNative: Bool {
        if case .native = self {
            return true
        }
        return false
    }
}

struct EmojiDocumentRow: Identifiable {
    enum Content {
        case header(title: String, count: Int)
        case emojis([EmojiPickerCell])
        case empty(String)
        case loading
        case failure(guildID: GuildID, details: String)
    }

    let id: String
    let section: EmojiDocumentSection
    let content: Content

    static func headerID(for section: EmojiDocumentSection) -> String {
        "header:\(section.id)"
    }

    var listInsets: EdgeInsets {
        if case .emojis = content {
            return EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        }
        return EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
    }
}

private struct EmojiDocumentSectionData {
    enum State {
        case ready
        case loading
        case failure(String)
    }

    let id: EmojiDocumentSection
    let title: String
    let items: [EmojiPickerItem]
    let emptyMessage: String
    var state: State = .ready
}

@MainActor
@Observable
final class EmojiPickerDocumentStore {
    static let itemsPerRow = EmojiPickerGridMetrics.columns

    private struct PreparedDocument {
        let rows: [EmojiDocumentRow]
        let selectableRows: [[EmojiPickerCell]]
        let navigationRows: [[String]]
        let selectableCells: [EmojiPickerCell]
        let cellsByID: [String: EmojiPickerCell]
    }

    private static let initialDocument: PreparedDocument = {
        let store = EmojiPickerDocumentStore(empty: ())
        store.rebuild()
        return PreparedDocument(
            rows: store.rows,
            selectableRows: store.selectableRows,
            navigationRows: store.navigationRows,
            selectableCells: store.selectableCells,
            cellsByID: store.cellsByID
        )
    }()

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild()
        }
    }

    private(set) var rows: [EmojiDocumentRow] = []
    private(set) var selectableCells: [EmojiPickerCell] = []
    private(set) var guilds: [Guild] = []
    var visibleSection: EmojiDocumentSection = .favorites

    private var emojisByGuild: [GuildID: [DiscordEmoji]] = [:]
    private var loadingGuilds: Set<GuildID> = []
    private var errorsByGuild: [GuildID: String] = [:]
    private var localUsage: [String: Int] = [:]
    private var localRecents: [String] = []
    private var discordFavorites: [String] = []
    private var discordFavoriteCandidates: Set<String> = []
    private var discordFrequentlyUsed: [String] = []
    private var discordUsage: [String: Int] = [:]
    private var selectableRows: [[EmojiPickerCell]] = []
    private var navigationRows: [[String]] = []
    private var cellsByID: [String: EmojiPickerCell] = [:]

    init() {
        let initialDocument = Self.initialDocument
        rows = initialDocument.rows
        selectableRows = initialDocument.selectableRows
        navigationRows = initialDocument.navigationRows
        selectableCells = initialDocument.selectableCells
        cellsByID = initialDocument.cellsByID
    }

    private init(empty: Void) {}

    func synchronize(with model: AppModel, useCase: DiscordEmojiUseCase) {
        let premiumType = model.snapshot?.currentUser.premiumType ?? 0
        let guilds = (model.snapshot?.guilds ?? []).filter {
            DiscordEmojiPermissionPolicy.canShowGuild(
                $0.id,
                for: useCase,
                premiumType: premiumType
            )
        }
        let visibleGuildIDs = Set(guilds.map(\.id))
        let emojisByGuild = model.emojisByGuild.reduce(into: [GuildID: [DiscordEmoji]]()) { result, entry in
            guard visibleGuildIDs.contains(entry.key) else { return }
            result[entry.key] = entry.value.filter {
                DiscordEmojiPermissionPolicy.canShow(
                    $0,
                    for: useCase,
                    premiumType: premiumType
                )
            }
        }
        let loadingGuilds = model.loadingEmojiGuildIDs.intersection(visibleGuildIDs)
        let errorsByGuild = model.emojiLoadErrorsByGuild.filter {
            visibleGuildIDs.contains($0.key)
        }
        let localUsage = model.emojiUsageCounts
        let localRecents = model.emojiRecentKeys
        let discordFavorites = model.discordFavoriteEmojiKeys
        let discordFrequentlyUsed = model.discordFrequentlyUsedEmojiKeys
        let discordUsage = model.discordEmojiUsageScores
        guard self.guilds != guilds
            || self.emojisByGuild != emojisByGuild
            || self.loadingGuilds != loadingGuilds
            || self.errorsByGuild != errorsByGuild
            || self.localUsage != localUsage
            || self.localRecents != localRecents
            || self.discordFavorites != discordFavorites
            || self.discordFrequentlyUsed != discordFrequentlyUsed
            || self.discordUsage != discordUsage
        else { return }

        self.guilds = guilds
        self.emojisByGuild = emojisByGuild
        self.loadingGuilds = loadingGuilds
        self.errorsByGuild = errorsByGuild
        self.localUsage = localUsage
        self.localRecents = localRecents
        self.discordFavorites = discordFavorites
        discordFavoriteCandidates = discordFavorites.reduce(into: []) { values, key in
            values.formUnion(settingsKeyCandidates(key))
        }
        self.discordFrequentlyUsed = discordFrequentlyUsed
        self.discordUsage = discordUsage
        rebuild()
    }

    func setQuery(_ value: String) {
        query = value
    }

    func destinationCell(
        from currentID: String?,
        direction: EmojiPickerGridDirection
    ) -> EmojiPickerCell? {
        let destinationID = EmojiPickerGridNavigation.destinationID(
            rows: navigationRows,
            currentID: currentID,
            direction: direction
        )
        return destinationID.flatMap { cellsByID[$0] }
    }

    func markVisible(_ section: EmojiDocumentSection) {
        guard section != .search else { return }
        visibleSection = section
    }

    func isFavorite(_ item: EmojiPickerItem) -> Bool {
        !item.discordKeys.isDisjoint(with: discordFavoriteCandidates)
    }

    private func rebuild() {
        rows = sections().flatMap(rows(for:))
        selectableRows = rows.compactMap { row in
            guard case let .emojis(cells) = row.content else { return nil }
            return cells
        }
        navigationRows = selectableRows.map { $0.map(\.id) }
        selectableCells = selectableRows.flatMap(\.self)
        cellsByID = Dictionary(uniqueKeysWithValues: selectableCells.map { ($0.id, $0) })
    }

    private func sections() -> [EmojiDocumentSectionData] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            let normalizedQuery = EmojiSearchMatcher.normalized(trimmedQuery)
            let matches = allItems().filter { $0.matches(normalizedQuery: normalizedQuery) }
            return [
                .init(
                id: .search,
                title: "Search Results",
                items: matches,
                emptyMessage: "No emojis match “\(trimmedQuery)”."
                )
            ]
        }

        let allItems = allItems()
        let favoriteItems = orderedItems(for: discordFavorites, in: allItems)
        let frequentItems: [EmojiPickerItem]
        if discordFrequentlyUsed.isEmpty {
            frequentItems = Array(
                orderedItems(for: localRecents, in: allItems).prefix(18)
            )
        } else {
            frequentItems = Array(
                orderedItems(for: discordFrequentlyUsed, in: allItems).prefix(18)
            )
        }
        var sections: [EmojiDocumentSectionData] = [
            .init(
                id: .favorites,
                title: "Favorites",
                items: favoriteItems,
                emptyMessage: "Your favorite emojis will appear here."
            ),
            .init(
                id: .frequent,
                title: "Frequently Used",
                items: frequentItems,
                emptyMessage: "Emojis you use will appear here."
            )
        ]

        sections.append(
            contentsOf: guilds.map { guild in
                let state: EmojiDocumentSectionData.State =
                    if loadingGuilds.contains(guild.id) {
                .loading
            } else if let error = errorsByGuild[guild.id] {
                .failure(error)
            } else {
                .ready
            }
            return EmojiDocumentSectionData(
                id: .guild(guild.id),
                title: guild.name,
                items: (emojisByGuild[guild.id] ?? [])
                    .filter(\.isAvailable)
                    .map(EmojiPickerItem.custom),
                emptyMessage: "This server has no custom emojis.",
                state: state
            )
            }
        )

        sections.append(
            contentsOf: NativeEmojiCategory.allCases.map { category in
            EmojiDocumentSectionData(
                id: .native(category),
                title: category.title,
                items: NativeEmojiPickerIndex.itemsByCategory[category] ?? [],
                emptyMessage: "No emojis are available in this category."
            )
            }
        )
        return sections
    }

    private func rows(for section: EmojiDocumentSectionData) -> [EmojiDocumentRow] {
        var result = [
            EmojiDocumentRow(
            id: EmojiDocumentRow.headerID(for: section.id),
            section: section.id,
            content: .header(title: section.title, count: section.items.count)
            )
        ]

        switch section.state {
        case .loading where section.items.isEmpty:
            result.append(
                .init(
                id: "loading:\(section.id.id)", section: section.id, content: .loading
                )
            )
            return result
        case let .failure(details) where section.items.isEmpty:
            if case let .guild(guildID) = section.id {
                result.append(
                    .init(
                    id: "failure:\(section.id.id)",
                    section: section.id,
                    content: .failure(guildID: guildID, details: details)
                    )
                )
            }
            return result
        default:
            break
        }

        guard !section.items.isEmpty else {
            result.append(
                .init(
                id: "empty:\(section.id.id)",
                section: section.id,
                content: .empty(section.emptyMessage)
                )
            )
            return result
        }

        for start in stride(from: 0, to: section.items.count, by: Self.itemsPerRow) {
            let end = min(start + Self.itemsPerRow, section.items.count)
            let items = Array(section.items[start ..< end])
            let rowID = "emojis:\(section.id.id):\(items[0].id)"
            let cells = items.map { item in
                EmojiPickerCell(
                    id: "\(rowID):\(item.id)",
                    rowID: rowID,
                    item: item
                )
            }
            result.append(
                .init(
                id: rowID,
                section: section.id,
                content: .emojis(cells)
                )
            )
        }
        return result
    }

    private func allItems() -> [EmojiPickerItem] {
        let loadedCustom = emojisByGuild.values
            .flatMap(\.self)
            .filter(\.isAvailable)
            .map(EmojiPickerItem.custom)
        let loadedIDs = Set(loadedCustom.map(\.discordKey))
        return NativeEmojiPickerIndex.allItems
            + loadedCustom
            + unresolvedSettingsCustomItems(excluding: loadedIDs)
    }

    private func orderedItems(
        for keys: [String],
        in items: [EmojiPickerItem]
    ) -> [EmojiPickerItem] {
        var itemsByDiscordKey: [String: EmojiPickerItem] = [:]
        for item in items {
            for key in item.discordKeys where itemsByDiscordKey[key] == nil {
                itemsByDiscordKey[key] = item
            }
        }
        var seen: Set<String> = []
        return keys.compactMap { key in
            let item = settingsKeyCandidates(key).lazy.compactMap { itemsByDiscordKey[$0] }.first
            guard let item, seen.insert(item.id).inserted else { return nil }
            return item
        }
    }

    private func settingsKeyCandidates(_ key: String) -> Set<String> {
        var candidates: Set<String> = [key]
        if let finalComponent = key.split(separator: ":").last,
           finalComponent.allSatisfy(\.isNumber)
        {
            candidates.insert(String(finalComponent))
        }
        if key.hasPrefix("custom:") {
            candidates.insert(String(key.dropFirst("custom:".count)))
        }
        return candidates
    }

    private func unresolvedSettingsCustomItems(excluding loadedIDs: Set<String>) -> [EmojiPickerItem] {
        var keys = Set(discordFavorites)
        keys.formUnion(discordFrequentlyUsed)
        keys.formUnion(discordUsage.keys)
        keys.formUnion(
            localUsage.keys.compactMap { key in
                key.hasPrefix("custom:") ? String(key.dropFirst("custom:".count)) : nil
            }
        )
        keys.formUnion(
            localRecents.compactMap { key in
                key.hasPrefix("custom:") ? String(key.dropFirst("custom:".count)) : nil
            }
        )

        return keys.compactMap { key in
            let candidate = key.split(separator: ":").last.map(String.init) ?? key
            guard !candidate.isEmpty,
                  candidate.allSatisfy(\.isNumber),
                  !loadedIDs.contains(candidate)
            else { return nil }
            let components = key.split(separator: ":")
            guard components.count >= 3 else { return nil }
            let name = String(components[components.count - 2]).trimmingCharacters(
                in: CharacterSet(charactersIn: "<>")
            )
            guard !name.isEmpty, name != "emoji", !name.allSatisfy(\.isNumber) else { return nil }
            return .custom(
                DiscordEmoji(
                    id: candidate,
                    name: name,
                    guildID: GuildID(rawValue: 0)
                )
            )
        }
    }
}
