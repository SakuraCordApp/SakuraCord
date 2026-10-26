import Foundation
import SakuraCordModels

/// What a person last chose in each forum, so returning to it shows the
/// same board. Sort, layout and tag matching persist across launches; the
/// scroll position lasts for the session. Search and tag filters do not
/// carry over: a forum opens unfiltered.
@MainActor
final class ForumViewMemory {
    struct Preferences: Codable, Equatable {
        var sortOrder: ForumSortOrder
        var layout: ForumLayout
        var tagMatch: ForumTagMatch
        var updatedAt: Date
    }

    /// The first visible post and how far its top sits below the board's top.
    struct ScrollPosition: Equatable {
        let postID: ChannelID
        let offset: Double
    }

    private static let key = "forum.viewPreferences"
    /// Enough for every forum someone visits; the least recently changed go.
    private static let limit = 256
    private let defaults: (any PreferenceStoring)?
    private var preferences: [String: Preferences]
    private var scrollPositions: [ChannelID: ScrollPosition] = [:]
    /// The position to restore on the current visit, once its posts arrive.
    private var pendingRestore: (channelID: ChannelID, position: ScrollPosition)?

    /// `defaults` nil keeps everything in memory (offline and test sessions).
    init(defaults: (any PreferenceStoring)?) {
        self.defaults = defaults
        preferences = defaults?.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Preferences].self, from: $0) } ?? [:]
    }

    private static func key(_ channelID: ChannelID) -> String {
        String(channelID.rawValue)
    }

    func preferences(for channelID: ChannelID) -> Preferences? {
        preferences[Self.key(channelID)]
    }

    func remember(sortOrder: ForumSortOrder, layout: ForumLayout, tagMatch: ForumTagMatch, for channelID: ChannelID) {
        preferences[Self.key(channelID)] = Preferences(
            sortOrder: sortOrder,
            layout: layout,
            tagMatch: tagMatch,
            updatedAt: .now
        )
        if preferences.count > Self.limit,
           let oldest = preferences.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key
        {
            preferences[oldest] = nil
        }
        save()
    }

    /// Back to the forum's own defaults.
    func forget(_ channelID: ChannelID) {
        preferences[Self.key(channelID)] = nil
        scrollPositions[channelID] = nil
        cancelPendingRestore()
        save()
    }

    func rememberScrollPosition(_ position: ScrollPosition?, for channelID: ChannelID) {
        scrollPositions[channelID] = position
    }

    /// Opening a forum arms one restore of where it was left; a board
    /// rebuilt later in the same visit finds nothing to restore.
    func beginVisit(_ channelID: ChannelID) {
        pendingRestore = scrollPositions[channelID].map { (channelID, $0) }
    }

    /// A new query starts at its first post, so it drops a pending restore.
    func cancelPendingRestore() {
        pendingRestore = nil
    }

    func hasPendingRestore(for channelID: ChannelID) -> Bool {
        pendingRestore?.channelID == channelID
    }

    func takePendingRestore(for channelID: ChannelID) -> ScrollPosition? {
        guard let pendingRestore, pendingRestore.channelID == channelID else { return nil }
        self.pendingRestore = nil
        return pendingRestore.position
    }

    private func save() {
        guard let defaults else { return }
        if preferences.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
