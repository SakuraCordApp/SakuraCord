import Foundation

/// Discord's affinity rankings, most affine first: channels by score and DM
/// partners by the probability of messaging them.
public struct ConversationAffinities: Equatable, Sendable {
    public var channelIDs: [ChannelID]
    public var userIDs: [UserID]

    public init(channelIDs: [ChannelID] = [], userIDs: [UserID] = []) {
        self.channelIDs = channelIDs
        self.userIDs = userIDs
    }
}

/// Discord's Favorites server: the account's favourited channels and DMs,
/// their categories, and whether the server is shown. Entries keep the stored
/// map order; new entries are appended, as the first-party client writes them.
public struct FavoritesSettings: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable, Codable {
        public var id: ChannelID
        public var isCategory: Bool
        /// The favourite's name override, or the category name. Empty when unset.
        public var nickname: String
        public var position: UInt32
        public var parentID: ChannelID?
        /// The Discord channel type recorded with the favourite.
        public var channelType: Int?
        /// Marks a shown Unlimited favorites entry kept only on this device,
        /// past Discord's limit; such entries are never sent to Discord.
        public var isLocal = false

        public init(
            id: ChannelID,
            isCategory: Bool = false,
            nickname: String = "",
            position: UInt32,
            parentID: ChannelID? = nil,
            channelType: Int? = nil
        ) {
            self.id = id
            self.isCategory = isCategory
            self.nickname = nickname
            self.position = position
            self.parentID = parentID
            self.channelType = channelType
        }

        /// Voice and stage favourites follow the others in each section, and
        /// local favourites follow the synced ones.
        var sortKey: UInt64 {
            UInt64(position) + (channelType == 2 || channelType == 13 ? 10_000 : 0) + (isLocal ? 1 << 32 : 0)
        }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        /// nil for the uncategorised rows above every category.
        public var category: Entry?
        public var entries: [Entry]
        public var id: ChannelID? { category?.id }
    }

    /// Thread Settings: whether joined threads are added automatically and
    /// when read ones are removed, stored as Discord stores them.
    public struct ThreadSettings: Equatable, Sendable {
        public var autoAddsJoinedThreads = false
        /// Auto-added threads go to a category named after their server
        /// instead of Auto-Added Threads.
        public var autoAddsPerServer = false
        /// nil when never chosen, which Discord treats as on.
        public var removesReadThreads: Bool?
        /// 0 removes threads when archived; otherwise also after this many
        /// days without activity.
        public var removalDays: UInt32 = 0
        /// Removal applies to every favourited thread, not only auto-add categories.
        public var removesFromAllThreads = false

        public init(
            autoAddsJoinedThreads: Bool = false,
            autoAddsPerServer: Bool = false,
            removesReadThreads: Bool? = nil,
            removalDays: UInt32 = 0,
            removesFromAllThreads: Bool = false
        ) {
            self.autoAddsJoinedThreads = autoAddsJoinedThreads
            self.autoAddsPerServer = autoAddsPerServer
            self.removesReadThreads = removesReadThreads
            self.removalDays = removalDays
            self.removesFromAllThreads = removesFromAllThreads
        }
    }

    /// Every entry, categories included, may not exceed this.
    public static let maximumEntries = 200
    /// Auto-added threads' category when they don't go per server.
    public static let autoAddedThreadsCategoryName = "Auto-Added Threads"

    public var entries: [Entry]
    /// The stored `guild_visible` choice, nil when the account never made one.
    public var storedVisibility: Bool?
    /// Discord's `muted`, kept for the write and cleared by a reset.
    public var isMuted = false
    public var threadSettings = ThreadSettings()

    public init(
        entries: [Entry] = [],
        storedVisibility: Bool? = nil,
        isMuted: Bool = false,
        threadSettings: ThreadSettings = ThreadSettings()
    ) {
        self.entries = entries
        self.storedVisibility = storedVisibility
        self.isMuted = isMuted
        self.threadSettings = threadSettings
    }

    /// Without an explicit choice the server shows once anything is favourited.
    public var isEnabled: Bool { storedVisibility ?? !entries.isEmpty }

    public func contains(_ id: ChannelID) -> Bool {
        entries.contains { $0.id == id && !$0.isCategory }
    }

    public var categories: [Entry] {
        entries.enumerated()
            .filter(\.element.isCategory)
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element)
    }

    /// The limit an addition would exceed, if any. Full Nitro raises the
    /// channel limit from 3 to 200; categories don't count.
    public func limitBlockingAddition(premiumType: Int) -> Int? {
        if entries.count >= Self.maximumEntries { return Self.maximumEntries }
        let limit = premiumType == 2 ? Self.maximumEntries : 3
        return entries.count(where: { !$0.isCategory }) >= limit ? limit : nil
    }

    /// Uncategorised favourites, then each category by position. A favourite
    /// whose category no longer exists is uncategorised.
    public var sections: [Section] {
        let categories = categories
        let categoryIDs = Set(categories.map(\.id))
        let rows = entries.enumerated()
            .filter { !$0.element.isCategory }
            .sorted { ($0.element.sortKey, $0.offset) < ($1.element.sortKey, $1.offset) }
            .map(\.element)
        let grouped = Dictionary(grouping: rows) { $0.parentID.flatMap { categoryIDs.contains($0) ? $0 : nil } }
        return [Section(category: nil, entries: grouped[nil] ?? [])]
            + categories.map { Section(category: $0, entries: grouped[$0.id] ?? []) }
    }

    private var nextPosition: UInt32 { (entries.map(\.position).max() ?? 0) + 1 }

    /// The category Discord files an addition under by name: the first whose
    /// trimmed name matches regardless of case.
    public func category(named name: String) -> Entry? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first { $0.isCategory && $0.nickname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name }
    }

    public enum Edit: Equatable, Sendable {
        case setVisible(Bool)
        case add(ChannelID, channelType: Int, categoryID: ChannelID? = nil)
        case remove(ChannelID)
        case rename(ChannelID, nickname: String)
        case createCategory(ChannelID, name: String)
        case move(ChannelID, categoryID: ChannelID?)
        case setThreadSettings(ThreadSettings)
        /// Reset Favorites: every favourite, category and setting back to its default.
        case reset
    }

    /// Applies an edit the way the first-party favourites actions do.
    public mutating func apply(_ edit: Edit) {
        switch edit {
        case .setVisible(let isVisible):
            storedVisibility = isVisible
        case .add(let id, let channelType, let categoryID):
            guard !contains(id) else { return }
            // The first favourite reveals a hidden Favorites server.
            if !isEnabled { storedVisibility = true }
            let parentID = categoryID.flatMap { id in categories.contains { $0.id == id } ? id : nil }
            entries.append(Entry(id: id, position: nextPosition, parentID: parentID, channelType: channelType))
        case .remove(let id):
            guard let removed = entries.first(where: { $0.id == id }) else { return }
            entries.removeAll { $0.id == id }
            if removed.isCategory {
                for index in entries.indices where entries[index].parentID == id { entries[index].parentID = nil }
            }
        case .rename(let id, let nickname):
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].nickname = nickname
        case .createCategory(let id, let name):
            entries.append(Entry(id: id, isCategory: true, nickname: name, position: nextPosition))
        case .move(let id, let categoryID):
            move(id, to: categoryID)
        case .setThreadSettings(let settings):
            threadSettings = settings
        case .reset:
            self = FavoritesSettings()
        }
    }

    /// The moved favourite ends its new section, then every favourite is
    /// renumbered in display order; categories keep their positions.
    private mutating func move(_ id: ChannelID, to categoryID: ChannelID?) {
        guard let index = entries.firstIndex(where: { $0.id == id && !$0.isCategory }),
              categoryID.map({ category in categories.contains { $0.id == category } }) ?? true
        else { return }
        entries[index].parentID = categoryID
        entries[index].position = .max
        for (position, entryID) in sections.flatMap({ $0.entries.map(\.id) }).enumerated() {
            if let entryIndex = entries.firstIndex(where: { $0.id == entryID }) {
                entries[entryIndex].position = UInt32(position)
            }
        }
    }
}
