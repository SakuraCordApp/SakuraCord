import SakuraCordModels
import SwiftUI

struct PickerSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .contentShape(ConcentricRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { isFocused = true }
        .glassEffect(
            .regular.interactive(),
            in: ConcentricRectangle(cornerRadius: 12, style: .continuous)
        )
        .task { isFocused = true }
    }
}

nonisolated enum ForwardDestinationID: Hashable {
    case channel(ChannelID)
    case user(UserID)

    var accessibilityIdentifier: String {
        switch self {
        case .channel(let channelID): "forward-destination-channel-\(channelID)"
        case .user(let userID): "forward-destination-user-\(userID)"
        }
    }
}

nonisolated enum ForwardDestinationSelectionPolicy {
    static func searchPins(
        afterSelecting destinationID: ForwardDestinationID,
        query: String,
        selectedDestinationIDs: [ForwardDestinationID],
        existing: [ForwardDestinationID]
    ) -> [ForwardDestinationID] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return existing
        }
        let newlyPinned = [destinationID]
            + selectedDestinationIDs.filter { $0 != destinationID }
        let newlyPinnedSet = Set(newlyPinned)
        return newlyPinned + existing.filter { !newlyPinnedSet.contains($0) }
    }
}

nonisolated struct ForwardDestination: Identifiable, Equatable {
    enum Kind: Equatable {
        case channel(Channel)
        case thread(MessageThreadSummary, parent: Channel?)
        case user(User, directMessage: Channel?)
    }

    let kind: Kind
    let guild: Guild?
    var titleOverride: String?
    var detailOverride: String?
    var unavailableReason: String?

    var id: ForwardDestinationID {
        switch kind {
        case .channel(let channel): .channel(channel.id)
        case .thread(let thread, _): .channel(thread.id)
        case .user(let user, _): .user(user.id)
        }
    }

    var resolvedChannelID: ChannelID? {
        switch kind {
        case .channel(let channel): channel.id
        case .thread(let thread, _): thread.id
        case .user(_, let directMessage): directMessage?.id
        }
    }

    var userID: UserID? {
        guard case .user(let user, _) = kind else { return nil }
        return user.id
    }

    var title: String {
        if let titleOverride { return titleOverride }
        return switch kind {
        case .channel(let channel): channel.name
        case .thread(let thread, _): thread.name
        case .user(let user, _): user.displayName
        }
    }

    var detail: String {
        if let detailOverride { return detailOverride }
        return switch kind {
        case .channel(let channel):
            channel.kind == .groupDirectMessage ? "" : guild?.name ?? "Channel"
        case .thread(_, let parent): parent?.name ?? guild?.name ?? "Thread"
        case .user(let user, _): user.tag
        }
    }

    var avatarURL: URL? {
        switch kind {
        case .channel(let channel):
            channel.kind == .groupDirectMessage ? channel.iconURL : guild?.iconURL
        case .thread: guild?.iconURL
        case .user(let user, _): user.avatarURL
        }
    }
}

nonisolated enum ForwardDestinationSearchPolicy {
    fileprivate enum ResultCategory {
        case user, groupDirectMessage, selectableChannel, voiceChannel
    }

    private struct RankedDestination {
        let destination: ForwardDestination
        let category: ResultCategory
        let score: Double
        let comparator: String?
        let sourceOrder: Int
        let isEligible: Bool
    }

    private struct IndexedGroupDestination {
        let offset: Int
        let destination: ForwardDestination
        let position: Int
    }

    private struct RankedMergeEntry {
        let destination: RankedDestination
        let stableOrder: Int
    }

    fileprivate enum SearchValues: Sendable {
        case user(
            values: [PreparedUserIdentity],
            booster: Double
        )
        case groupDirectMessage(
            name: String,
            recipientValues: [String],
            usage: Double
        )
        case text(
            title: String,
            metadata: [String],
            boosters: UsageBoosters,
            basePenalty: Double,
            minimumAfterPenalty: Double
        )
    }

    fileprivate struct SearchRecord: Sendable {
        let destination: ForwardDestination
        let category: ResultCategory
        let sourceOrder: Int
        let isEligible: Bool
        let values: SearchValues
    }

    private struct PreparedMatch {
        let value: String
        let fuzzyBytes: [UInt8]?
        let separatedTerms: [String]
        let confusableSkeleton: String

        init(_ value: String) {
            self.value = value
            fuzzyBytes = value.unicodeScalars.allSatisfy(\.isASCII)
                ? Array(value.utf8)
                : nil
            separatedTerms = value.contains(where: { $0 == " " || $0 == "," })
                ? value.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                : []
            confusableSkeleton = ForwardDestinationSearchPolicy.discordConfusableSkeleton(value)
        }
    }

    fileprivate struct PreparedUserIdentity: Sendable {
        let searchValue: String
        let confusableSkeleton: String
        let comparator: String

        init(_ value: String) {
            searchValue = ForwardDestinationSearchPolicy.userIdentitySearchValue(value)
            confusableSkeleton = ForwardDestinationSearchPolicy.discordConfusableSkeleton(
                searchValue
            )
            comparator = ForwardDestinationSearchPolicy.userIdentityComparator(value)
        }
    }

    private struct QueryDescriptor {
        let match: PreparedMatch
        let isFullMatch: Bool
    }

    private struct PreparedQuery {
        let match: PreparedMatch
        let descriptors: [QueryDescriptor]
        let hasSingleDescriptor: Bool

        init(_ value: String) {
            let match = PreparedMatch(value)
            self.match = match
            var descriptors = value.split(whereSeparator: \.isWhitespace).map {
                QueryDescriptor(match: PreparedMatch(String($0)), isFullMatch: false)
            }
            if value.contains(" ") {
                descriptors.insert(QueryDescriptor(match: match, isFullMatch: true), at: 0)
            }
            self.descriptors = descriptors.isEmpty
                ? [QueryDescriptor(match: match, isFullMatch: false)]
                : descriptors
            hasSingleDescriptor = self.descriptors.count == 1
                && !self.descriptors[0].isFullMatch
        }
    }

    fileprivate struct UsageBoosters: Sendable {
        let normalized: Double
        let internalChannel: Double
    }

    static let maximumSelections = 5
    static let resultLimitPerCategory = 20

    static func channelsInStoreOrder(
        _ channels: [Channel],
        storeOrder: [ChannelID]
    ) -> [Channel] {
        let channelsByID = Dictionary(
            channels.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var seenChannelIDs = Set<ChannelID>()
        return storeOrder.compactMap {
            guard seenChannelIDs.insert($0).inserted else { return nil }
            return channelsByID[$0]
        } + channels.filter { seenChannelIDs.insert($0.id).inserted }
    }

    struct Index: Sendable {
        fileprivate let destinations: [ForwardDestination]
        fileprivate let searchRecords: [SearchRecord]
        fileprivate let usageScores: [String: Int]
        fileprivate let usageOrder: [String]
        fileprivate let eligibleChannelIDs: Set<ChannelID>?

        func results(
            query: String,
            recentChannelIDs: [ChannelID] = [],
            pinnedDestinationIDs: [ForwardDestinationID] = [],
            originChannelID: ChannelID? = nil
        ) -> [ForwardDestination] {
            let normalizedQuery = ForwardDestinationSearchPolicy.normalize(query)
            guard !normalizedQuery.isEmpty else {
                return ForwardDestinationSearchPolicy.unqueriedResults(
                    destinations: destinations,
                    usageScores: usageScores,
                    usageOrder: usageOrder,
                    recentChannelIDs: recentChannelIDs,
                    pinnedDestinationIDs: pinnedDestinationIDs,
                    eligibleChannelIDs: eligibleChannelIDs,
                    originChannelID: originChannelID
                )
            }
            return ForwardDestinationSearchPolicy.searchedResults(
                searchRecords,
                query: normalizedQuery
            )
        }
    }

    static func makeIndex(
        channels: [Channel],
        threads: [MessageThreadSummary] = [],
        users: [User] = [],
        friendUserIDs: Set<UserID> = [],
        relationshipNicknamesByUserID: [UserID: String] = [:],
        userSearchAliasesByUserID: [UserID: [String]] = [:],
        currentUserID: UserID? = nil,
        guilds: [GuildID: Guild],
        usageScores: [String: Int],
        usageOrder: [String] = [],
        searchableChannelIDs: Set<ChannelID>? = nil,
        eligibleChannelIDs: Set<ChannelID>? = nil
    ) -> Index {
        let destinations = makeDestinations(
            channels: channels,
            threads: threads,
            users: users,
            relationshipNicknamesByUserID: relationshipNicknamesByUserID,
            currentUserID: currentUserID,
            guilds: guilds,
            searchableChannelIDs: searchableChannelIDs
        )
        let maximumUsageScore = maximumUsageScore(
            channels: channels,
            threads: threads,
            guilds: guilds,
            usageScores: usageScores
        )
        return Index(
            destinations: destinations,
            searchRecords: makeSearchRecords(
                destinations,
                usageScores: usageScores,
                maximumUsageScore: maximumUsageScore,
                friendUserIDs: friendUserIDs,
                relationshipNicknamesByUserID: relationshipNicknamesByUserID,
                userSearchAliasesByUserID: userSearchAliasesByUserID,
                eligibleChannelIDs: eligibleChannelIDs
            ),
            usageScores: usageScores,
            usageOrder: usageOrder,
            eligibleChannelIDs: eligibleChannelIDs
        )
    }

    static func results(
        query: String,
        channels: [Channel],
        threads: [MessageThreadSummary] = [],
        users: [User] = [],
        friendUserIDs: Set<UserID> = [],
        relationshipNicknamesByUserID: [UserID: String] = [:],
        userSearchAliasesByUserID: [UserID: [String]] = [:],
        currentUserID: UserID? = nil,
        guilds: [GuildID: Guild],
        usageScores: [String: Int],
        usageOrder: [String] = [],
        recentChannelIDs: [ChannelID] = [],
        pinnedDestinationIDs: [ForwardDestinationID] = [],
        searchableChannelIDs: Set<ChannelID>? = nil,
        eligibleChannelIDs: Set<ChannelID>? = nil,
        originChannelID: ChannelID? = nil
    ) -> [ForwardDestination] {
        makeIndex(
            channels: channels,
            threads: threads,
            users: users,
            friendUserIDs: friendUserIDs,
            relationshipNicknamesByUserID: relationshipNicknamesByUserID,
            userSearchAliasesByUserID: userSearchAliasesByUserID,
            currentUserID: currentUserID,
            guilds: guilds,
            usageScores: usageScores,
            usageOrder: usageOrder,
            searchableChannelIDs: searchableChannelIDs,
            eligibleChannelIDs: eligibleChannelIDs
        ).results(
            query: query,
            recentChannelIDs: recentChannelIDs,
            pinnedDestinationIDs: pinnedDestinationIDs,
            originChannelID: originChannelID
        )
    }

    private static func makeDestinations(
        channels: [Channel],
        threads: [MessageThreadSummary],
        users: [User],
        relationshipNicknamesByUserID: [UserID: String],
        currentUserID: UserID?,
        guilds: [GuildID: Guild],
        searchableChannelIDs: Set<ChannelID>?
    ) -> [ForwardDestination] {
        let channelsByID = Dictionary(
            channels.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let directMessagesByUserID = Dictionary(
            channels.compactMap { channel -> (UserID, Channel)? in
                guard channel.kind == .directMessage,
                      let user = channel.recipients.first
                else { return nil }
                return (user.id, channel)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        var seenUserIDs = Set<UserID>()
        let orderedUsers = (users + channels.flatMap(\.recipients)).filter { user in
            user.id != currentUserID && seenUserIDs.insert(user.id).inserted
        }
        let userDestinations = orderedUsers.map { user in
            ForwardDestination(
                kind: .user(user, directMessage: directMessagesByUserID[user.id]),
                guild: nil,
                titleOverride: relationshipNicknamesByUserID[user.id]
            )
        }
        let channelDestinations = channels.compactMap { channel -> ForwardDestination? in
            guard channel.kind != .directMessage else { return nil }
            if channel.kind != .groupDirectMessage {
                guard supportsSearchCandidate(channel.kind),
                      searchableChannelIDs?.contains(channel.id) != false
                else { return nil }
            }
            return ForwardDestination(
                kind: .channel(channel),
                guild: channel.guildID.flatMap { guilds[$0] },
                detailOverride: groupDirectMessageDetail(channel)
            )
        }
        let indexedChannelDestinations = channelDestinations.enumerated()
        let groupDirectMessageDestinations = indexedChannelDestinations.compactMap { item -> IndexedGroupDestination? in
            let (offset, destination) = item
            guard case .channel(let channel) = destination.kind,
                  channel.kind == .groupDirectMessage
            else { return nil }
            return IndexedGroupDestination(
                offset: offset,
                destination: destination,
                position: channel.position
            )
        }.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.offset < rhs.offset
        }.map(\.destination)
        let nonGroupChannelDestinations = indexedChannelDestinations.compactMap { item -> ForwardDestination? in
            let (_, destination) = item
            guard case .channel(let channel) = destination.kind,
                  channel.kind == .groupDirectMessage
            else { return destination }
            return nil
        }
        let threadDestinations = threads.compactMap { thread -> ForwardDestination? in
            guard !thread.isArchived,
                  thread.notificationSettings != nil,
                  searchableChannelIDs?.contains(thread.id) != false
            else { return nil }
            return ForwardDestination(
                kind: .thread(
                    thread,
                    parent: thread.parentID.flatMap { channelsByID[$0] }
                ),
                guild: thread.guildID.flatMap { guilds[$0] }
            )
        }
        return userDestinations
            + groupDirectMessageDestinations
            + nonGroupChannelDestinations
            + threadDestinations
    }

    private static func supportsSearchCandidate(_ kind: ChannelKindValue) -> Bool {
        switch kind {
        case .text, .announcement, .forum, .voice, .groupDirectMessage: true
        case .directMessage, .unknown: false
        }
    }

    private static func groupDirectMessageDetail(_ channel: Channel) -> String? {
        guard channel.kind == .groupDirectMessage else { return nil }
        // Discord's row-label helper omits the detail entirely when the raw
        // Group DM name is empty. Returning nil preserves that distinction
        // instead of manufacturing an empty subtitle value.
        guard channel.hasExplicitName else { return nil }
        let names = channel.recipients.map(\.displayName)
        let visible = names.prefix(3).joined(separator: ", ")
        let remaining = names.count - min(names.count, 3)
        return remaining > 0 ? "\(visible) and \(remaining) others" : visible
    }

    private static func maximumUsageScore(
        channels: [Channel],
        threads: [MessageThreadSummary],
        guilds: [GuildID: Guild],
        usageScores: [String: Int]
    ) -> Double {
        let resolvableUsageKeys = Set(channels.map { $0.id.description })
            .union(threads.map { $0.id.description })
            .union(guilds.keys.map(\.description))
        return Double(max(
            1,
            usageScores.lazy
                .filter { resolvableUsageKeys.contains($0.key) }
                .map { $0.value }
                .max() ?? 1
        ))
    }

    private static func makeSearchRecords(
        _ destinations: [ForwardDestination],
        usageScores: [String: Int],
        maximumUsageScore: Double,
        friendUserIDs: Set<UserID>,
        relationshipNicknamesByUserID: [UserID: String],
        userSearchAliasesByUserID: [UserID: [String]],
        eligibleChannelIDs: Set<ChannelID>?
    ) -> [SearchRecord] {
        destinations.enumerated().flatMap { offset, destination -> [SearchRecord] in
            let usage = Double(destination.resolvedChannelID.map {
                usageScores[$0.description, default: 0]
            } ?? 0)
            let boosters = UsageBoosters(
                normalized: min(max(usage / maximumUsageScore, 0), 1),
                internalChannel: min(max(usage / 100, 0), 1)
            )
            let eligible = isEligible(
                destination,
                eligibleChannelIDs: eligibleChannelIDs
            )
            func record(
                category: ResultCategory,
                values: SearchValues
            ) -> SearchRecord {
                SearchRecord(
                    destination: destination,
                    category: category,
                    sourceOrder: offset,
                    isEligible: eligible,
                    values: values
                )
            }
            switch destination.kind {
            case .user(let user, let directMessage):
                return [record(
                    category: .user,
                    values: .user(
                        values: (
                            [
                                user.tag,
                                relationshipNicknamesByUserID[user.id],
                                user.displayName,
                            ].compactMap { $0 }
                                + (userSearchAliasesByUserID[user.id] ?? [])
                        ).map(PreparedUserIdentity.init),
                        booster: 1 + boosters.normalized
                            + (friendUserIDs.contains(user.id) ? 0.2 : 0)
                            + (directMessage == nil ? 0 : 0.1)
                    )
                )]
            case .channel(let channel) where channel.kind == .groupDirectMessage:
                return [record(
                    category: .groupDirectMessage,
                    values: .groupDirectMessage(
                        name: normalize(destination.title),
                        recipientValues: channel.recipients.flatMap {
                            [
                                $0.displayName,
                                $0.username,
                                relationshipNicknamesByUserID[$0.id],
                            ].compactMap { $0 }.map(normalize)
                        },
                        usage: boosters.normalized
                    )
                )]
            case .channel(let channel):
                let metadata = [destination.guild?.name, channel.category]
                    .compactMap { $0 }.map(normalize)
                let selectable = record(
                    category: .selectableChannel,
                    values: .text(
                        title: normalize(destination.title),
                        metadata: metadata,
                        boosters: boosters,
                        basePenalty: channel.kind == .voice ? 1 : 0,
                        minimumAfterPenalty: channel.kind == .voice ? 0.5 : 0
                    )
                )
                guard channel.kind == .voice else { return [selectable] }
                // Discord's default result types overlap: SELECTABLE searches
                // vocal channels with the one-point penalty, then VOCAL
                // searches them again without it. SearchContextManager keeps
                // the first duplicate before its final score sort.
                return [selectable, record(
                    category: .voiceChannel,
                    values: .text(
                        title: normalize(destination.title),
                        metadata: metadata,
                        boosters: boosters,
                        basePenalty: 0,
                        minimumAfterPenalty: 0
                    )
                )]
            case .thread(let thread, let parent):
                return [record(
                    category: .selectableChannel,
                    values: .text(
                        title: normalize(thread.name),
                        metadata: [destination.guild?.name, parent?.name]
                            .compactMap { $0 }.map(normalize),
                        boosters: boosters,
                        basePenalty: thread.isArchived ? 3 : 0,
                        minimumAfterPenalty: 0
                    )
                )]
            }
        }
    }

    private static func searchedResults(
        _ records: [SearchRecord],
        query: String
    ) -> [ForwardDestination] {
        let preparedQuery = PreparedQuery(query)
        var users: [RankedDestination] = []
        var groups: [RankedDestination] = []
        var textChannels: [RankedDestination] = []
        var voiceChannels: [RankedDestination] = []
        users.reserveCapacity(resultLimitPerCategory)
        groups.reserveCapacity(resultLimitPerCategory)
        textChannels.reserveCapacity(resultLimitPerCategory)
        voiceChannels.reserveCapacity(resultLimitPerCategory)
        for record in records {
            guard !Task.isCancelled else { return [] }
            let (score, comparator) = searchScore(record.values, query: preparedQuery)
            guard score > 0 else { continue }
            let ranked = RankedDestination(
                destination: record.destination,
                category: record.category,
                score: score,
                comparator: comparator,
                sourceOrder: record.sourceOrder,
                isEligible: record.isEligible
            )
            switch record.category {
            case .user: insertBounded(ranked, into: &users)
            case .groupDirectMessage: insertBounded(ranked, into: &groups)
            case .selectableChannel: insertBounded(ranked, into: &textChannels)
            case .voiceChannel: insertBounded(ranked, into: &voiceChannels)
            }
        }
        return mergedRankedDestinations([users, groups, textChannels, voiceChannels])
    }

    private static func insertBounded(
        _ candidate: RankedDestination,
        into results: inout [RankedDestination]
    ) {
        guard let last = results.last else {
            results.append(candidate)
            return
        }
        guard ranksBefore(candidate, last) else {
            if results.count < resultLimitPerCategory {
                results.append(candidate)
            }
            return
        }
        let insertionIndex = results.firstIndex {
            ranksBefore(candidate, $0)
        } ?? results.endIndex
        guard insertionIndex < resultLimitPerCategory
            || results.count < resultLimitPerCategory
        else { return }
        results.insert(candidate, at: insertionIndex)
        if results.count > resultLimitPerCategory {
            results.removeLast()
        }
    }

    private static func ranksBefore(
        _ lhs: RankedDestination,
        _ rhs: RankedDestination
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.category == .user,
           let left = lhs.comparator,
           let right = rhs.comparator,
           left != right
        {
            // JavaScript's `<` compares UTF-16 code units. Swift's default
            // String ordering is locale-aware at the Character layer, so use
            // the same code-unit ordering as Discord's worker comparator.
            return left.utf16.lexicographicallyPrecedes(right.utf16)
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    private static func isEligible(
        _ destination: ForwardDestination,
        eligibleChannelIDs: Set<ChannelID>?
    ) -> Bool {
        switch destination.kind {
        case .user:
            true
        case .channel(let channel) where channel.kind == .groupDirectMessage:
            true
        case .channel(let channel):
            eligibleChannelIDs?.contains(channel.id) != false
        case .thread(let thread, _):
            eligibleChannelIDs?.contains(thread.id) != false
        }
    }

    private static func mergedRankedDestinations(
        _ rankedCategories: [[RankedDestination]]
    ) -> [ForwardDestination] {
        let limited = rankedCategories.enumerated().flatMap { item -> [RankedMergeEntry] in
            let (categoryOrder, ranked) = item
            return ranked
                .enumerated()
                .map {
                    RankedMergeEntry(
                        destination: $0.element,
                        stableOrder: categoryOrder * resultLimitPerCategory + $0.offset
                    )
                }
        }
        // SearchContextManager concatenates category results, removes the
        // first duplicate type/id, then globally sorts. The forwarding filter
        // runs afterward, so an ineligible row still consumes its raw category
        // slot and is not replaced by a lower-ranked candidate.
        var seen: Set<ForwardDestinationID> = []
        let unique = limited.filter {
            seen.insert($0.destination.destination.id).inserted
        }
        return unique.sorted { lhs, rhs in
            if lhs.destination.score != rhs.destination.score {
                return lhs.destination.score > rhs.destination.score
            }
            return lhs.stableOrder < rhs.stableOrder
        }.compactMap { entry in
            entry.destination.isEligible ? entry.destination.destination : nil
        }
    }

    private static func unqueriedResults(
        destinations: [ForwardDestination],
        usageScores: [String: Int],
        usageOrder: [String],
        recentChannelIDs: [ChannelID],
        pinnedDestinationIDs: [ForwardDestinationID],
        eligibleChannelIDs: Set<ChannelID>?,
        originChannelID: ChannelID?
    ) -> [ForwardDestination] {
        let destinations = destinations.filter {
            isEligible($0, eligibleChannelIDs: eligibleChannelIDs)
        }
        let destinationsByID = Dictionary(
            uniqueKeysWithValues: destinations.map { ($0.id, $0) }
        )
        let destinationsByChannelID = Dictionary(
            destinations.compactMap { destination in
                destination.resolvedChannelID.map { ($0, destination) }
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let usageSourceOrder = Dictionary(
            uniqueKeysWithValues: usageOrder.enumerated().map { ($0.element, $0.offset) }
        )
        let frequentDestinationIDs = destinations.enumerated().filter { _, destination in
            guard let channelID = destination.resolvedChannelID else { return false }
            return usageScores[channelID.description, default: 0] > 0
        }.sorted { lhs, rhs in
            let leftKey = lhs.element.resolvedChannelID?.description ?? ""
            let rightKey = rhs.element.resolvedChannelID?.description ?? ""
            let left = usageScores[leftKey, default: 0]
            let right = usageScores[rightKey, default: 0]
            if left != right { return left > right }
            let leftOrder = usageSourceOrder[leftKey] ?? Int.max
            let rightOrder = usageSourceOrder[rightKey] ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return lhs.offset < rhs.offset
        }.map(\.element.id)
        let recentDestinationIDs = recentChannelIDs.compactMap {
            destinationsByChannelID[$0]?.id
        }
        let pinned = Set(pinnedDestinationIDs)
        var seen: Set<ForwardDestinationID> = []
        return (pinnedDestinationIDs + recentDestinationIDs + frequentDestinationIDs)
            .compactMap { destinationID in
            guard seen.insert(destinationID).inserted,
                  let destination = destinationsByID[destinationID],
                  destination.resolvedChannelID != originChannelID || pinned.contains(destinationID)
            else { return nil }
            return destination
        }.prefix(15).map { $0 }
    }

    private static func searchScore(
        _ values: SearchValues,
        query: PreparedQuery
    ) -> (Double, String?) {
        switch values {
        case .user(let values, let booster):
            var bestScore = 0
            var comparator: String?
            for value in values {
                let score = userMatchScore(value, query: query.match)
                // Discord's worker keeps the first identity with the highest
                // score: username, relationship nickname, global name, then
                // guild nicknames in store order.
                if score > bestScore {
                    bestScore = score
                    comparator = value.comparator
                }
            }
            return (1_000 * Double(bestScore) * booster, comparator)
        case .groupDirectMessage(let name, let recipientValues, let usage):
            let ownNameScore = matchScore(name, query: query.match, fuzzy: true)
            var recipientScore = 0
            for value in recipientValues {
                recipientScore = max(
                    recipientScore,
                    min(5, matchScore(value, query: query.match, fuzzy: true))
                )
            }
            return (
                1_000 * Double(max(ownNameScore, recipientScore)) * (1 + usage),
                nil
            )
        case .text(
            let title,
            let metadata,
            let boosters,
            let basePenalty,
            let minimumAfterPenalty
        ):
            return (
                textDestinationSearchScore(
                    title: title,
                    metadata: metadata,
                    query: query,
                    boosters: boosters,
                    basePenalty: basePenalty,
                    minimumAfterPenalty: minimumAfterPenalty
                ),
                nil
            )
        }
    }

    private static func userMatchScore(
        _ identity: PreparedUserIdentity,
        query: PreparedMatch
    ) -> Int {
        if identity.searchValue.hasPrefix(query.value) { return 10 }
        if identity.searchValue.contains(query.value) { return 5 }
        if isOrderedSubsequence(query.value, of: identity.searchValue) { return 1 }
        return isOrderedSubsequence(
            query.confusableSkeleton,
            of: identity.confusableSkeleton
        ) ? 1 : 0
    }

    private static func userIdentitySearchValue(_ value: String) -> String {
        value.lowercased(with: .current)
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    private static func userIdentityComparator(_ value: String) -> String {
        value.lowercased(with: .current)
    }

    private static func discordConfusableSkeleton(_ value: String) -> String {
        // Discord's current user-search worker applies its Unicode-confusable
        // table after ordinary accent folding. Compatibility decomposition
        // covers its styled/full-width Latin mappings; these remaining ASCII
        // mappings are the table's non-identity entries.
        let compatible = value.decomposedStringWithCompatibilityMapping
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased(with: .current)
        var result = ""
        result.reserveCapacity(compatible.utf8.count)
        for character in compatible {
            switch character {
            case "0": result.append("o")
            case "1", "I": result.append("l")
            case "m": result.append("rn")
            default: result.append(character)
            }
        }
        return result
    }

    private static func isOrderedSubsequence(
        _ query: String,
        of candidate: String
    ) -> Bool {
        guard !query.isEmpty else { return false }
        var queryIndex = query.startIndex
        for character in candidate where character == query[queryIndex] {
            query.formIndex(after: &queryIndex)
            if queryIndex == query.endIndex { return true }
        }
        return false
    }

    private static func textDestinationSearchScore(
        title: String,
        metadata: [String],
        query: PreparedQuery,
        boosters: UsageBoosters,
        basePenalty: Double,
        minimumAfterPenalty: Double = 0
    ) -> Double {
        if query.hasSingleDescriptor {
            let base = matchScore(title, query: query.match, fuzzy: true)
            return boostedTextDestinationScore(
                base: Double(base),
                boosters: boosters,
                basePenalty: basePenalty,
                minimumAfterPenalty: minimumAfterPenalty
            )
        }
        var descriptors = query.descriptors
        var base = consumeBestMatch(
            in: title,
            descriptors: &descriptors,
            fuzzy: true
        )
        guard base > 0 else { return 0 }
        if !descriptors.isEmpty {
            for value in metadata {
                let score = consumeBestMatch(
                    in: value, descriptors: &descriptors, fuzzy: false
                )
                if score > 0 { base += 0.5 * score }
            }
            base = min(6, base)
        }
        guard descriptors.count <= 1,
              descriptors.first?.isFullMatch != false
        else { return 0 }
        return boostedTextDestinationScore(
            base: base,
            boosters: boosters,
            basePenalty: basePenalty,
            minimumAfterPenalty: minimumAfterPenalty
        )
    }

    private static func boostedTextDestinationScore(
        base: Double,
        boosters: UsageBoosters,
        basePenalty: Double,
        minimumAfterPenalty: Double
    ) -> Double {
        // Discord rejects a channel whose name/guild/parent score is zero
        // before applying the SELECTABLE voice-channel penalty. Applying the
        // 0.5 floor first would turn every unmatched voice channel into a
        // result for every query.
        guard base > 0 else { return 0 }
        let adjustedBase = max(minimumAfterPenalty, base - basePenalty)
        guard adjustedBase > 0 else { return 0 }
        let cap = adjustedBase >= 7 ? 10.0 : 7.0
        let internallyBoosted = min(
            adjustedBase + 3 * boosters.internalChannel,
            cap
        )
        return 1_000 * internallyBoosted * (1 + boosters.normalized)
    }

    private static func consumeBestMatch(
        in value: String,
        descriptors: inout [QueryDescriptor],
        fuzzy: Bool
    ) -> Double {
        var bestIndex: Int?
        var bestScore = 0
        for (index, descriptor) in descriptors.enumerated() {
            let score = matchScore(
                value,
                query: descriptor.match,
                fuzzy: fuzzy,
                treatsHyphenAsSpace: descriptor.isFullMatch
            )
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        if let bestIndex, !descriptors[bestIndex].isFullMatch {
            descriptors.remove(at: bestIndex)
        }
        return Double(bestScore)
    }

    private static func matchScore(
        _ value: String,
        query: PreparedMatch,
        fuzzy: Bool,
        treatsHyphenAsSpace: Bool = false
    ) -> Int {
        guard !query.value.isEmpty else { return 0 }
        let candidate = treatsHyphenAsSpace
            ? value.replacingOccurrences(of: "-", with: " ")
            : value
        if candidate == query.value { return 10 }
        if candidate.hasPrefix(query.value) { return 7 }
        if candidate.contains(query.value) { return 5 }
        if !query.separatedTerms.isEmpty,
           query.separatedTerms.allSatisfy(candidate.contains)
        {
            return 3
        }
        guard fuzzy else { return 0 }
        return fuzzyMatch(value, query: query) ? 1 : 0
    }

    private static func fuzzyMatch(_ value: String, query: PreparedMatch) -> Bool {
        if let queryBytes = query.fuzzyBytes {
            var queryIndex = 0
            for byte in value.utf8 where byte == queryBytes[queryIndex] {
                queryIndex += 1
                if queryIndex == queryBytes.count { return true }
            }
            return false
        }
        var index = value.startIndex
        for character in query.value {
            guard let found = value[index...].firstIndex(of: character) else { return false }
            index = value.index(after: found)
        }
        return true
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ForwardMessageOverlay: View {
    let model: AppModel
    let message: Message
    @State private var query = ""
    @State private var context = ""
    @State private var selectedDestinationIDs: [ForwardDestinationID] = []
    @State private var searchPinnedDestinationIDs: [ForwardDestinationID] = []
    @State private var searchIndex: ForwardDestinationSearchPolicy.Index?
    @State private var searchIndexRevision = 0
    @State private var displayedDestinations: [ForwardDestination] = []
    @FocusState private var isContextFocused: Bool

    private struct SearchRequest: Hashable {
        let query: String
        let pinnedDestinationIDs: [ForwardDestinationID]
        let indexRevision: Int
    }

    private var guilds: [GuildID: Guild] {
        let snapshotGuilds = Dictionary(
            uniqueKeysWithValues: (model.snapshot?.guilds ?? []).map { ($0.id, $0) }
        )
        return snapshotGuilds.merging(model.serverRailGuildsByID) { _, railGuild in
            railGuild
        }
    }

    private func rebuildSearchIndex() async {
        await model.loadDiscordEmojiSettings()
        guard model.hasLoadedDiscordEmojiSettings else {
            searchIndex = nil
            displayedDestinations = []
            return
        }
        let snapshotChannels = model.snapshot?.channels ?? []
        let channels = ForwardDestinationSearchPolicy.channelsInStoreOrder(
            snapshotChannels,
            storeOrder: model.snapshot?.forwardChannelStoreOrder ?? []
        )
        let friendUserIDs = model.snapshot?.friendUserIDs ?? []
        // Discord searches its singular account-wide UserStore, which is fed by
        // READY, relationships, READY_SUPPLEMENTAL, and subsequently observed
        // users. The provider projects that store here. Do not merge AppModel
        // member dictionaries again: doing so admits guild-only records and
        // changes source order and category-cutoff membership.
        let knownUsers = model.snapshot?.knownUsers ?? []
        let channelsByID = Dictionary(
            channels.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let threads = model.snapshot?.activeJoinedThreads ?? []
        let searchableChannelIDs = Set(
            channels.lazy.filter(model.canSearchForwardDestination).map(\.id)
        ).union(threads.compactMap { thread in
            guard !thread.isArchived,
                  let parentID = thread.parentID,
                  let parent = channelsByID[parentID],
                  model.canSearchForwardThreadDestination(parent: parent)
            else { return nil }
            return thread.id
        })
        let eligibleChannelIDs = Set(
            channels.lazy.filter(model.canUseForwardDestination).map(\.id)
        ).union(threads.compactMap { thread in
            guard !thread.isArchived,
                  let parentID = thread.parentID,
                  let parent = channelsByID[parentID],
                  model.canUseForwardThreadDestination(parent: parent)
            else { return nil }
            return thread.id
        })
        let relationshipNicknamesByUserID =
            model.snapshot?.relationshipNicknamesByUserID ?? [:]
        let userSearchAliasesByUserID =
            model.snapshot?.userSearchAliasesByUserID ?? [:]
        let currentUserID = model.snapshot?.currentUser.id
        let guildSnapshot = guilds
        let usageScores = model.discordGuildAndChannelUsageScores
        let usageOrder = model.discordGuildAndChannelUsageOrder
        let userSnapshot = knownUsers
        let indexTask = Task.detached(priority: .userInitiated) {
            ForwardDestinationSearchPolicy.makeIndex(
                channels: channels,
                threads: threads,
                users: userSnapshot,
                friendUserIDs: friendUserIDs,
                relationshipNicknamesByUserID: relationshipNicknamesByUserID,
                userSearchAliasesByUserID: userSearchAliasesByUserID,
                currentUserID: currentUserID,
                guilds: guildSnapshot,
                usageScores: usageScores,
                usageOrder: usageOrder,
                searchableChannelIDs: searchableChannelIDs,
                eligibleChannelIDs: eligibleChannelIDs
            )
        }
        let index = await withTaskCancellationHandler {
            await indexTask.value
        } onCancel: {
            indexTask.cancel()
        }
        guard !Task.isCancelled else { return }
        searchIndex = index
        searchIndexRevision &+= 1
    }

    private func refreshDisplayedDestinations() async {
        guard let searchIndex else {
            displayedDestinations = []
            return
        }
        let query = query
        let pins = searchPinnedDestinationIDs
        let history = model.forwardDestinationHistory
        let originChannelID = message.channelID
        let searchTask = Task.detached(priority: .userInitiated) {
            searchIndex.results(
                query: query,
                recentChannelIDs: history,
                pinnedDestinationIDs: pins,
                originChannelID: originChannelID
            )
        }
        let results = await withTaskCancellationHandler {
            await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
        guard !Task.isCancelled else { return }

        let needsContentPermissionValidation = !message.attachments.isEmpty
            || !message.embeds.isEmpty
            || !message.stickers.isEmpty
            || message.flags.contains(.voiceMessage)
        guard needsContentPermissionValidation else {
            displayedDestinations = results
            return
        }
        displayedDestinations = results.map { destination in
            var destination = destination
            let permissionChannel: Channel? = switch destination.kind {
            case .channel(let channel): channel
            case .thread(_, let parent): parent
            case .user: nil
            }
            if let permissionChannel {
                destination.unavailableReason = model.forwardUnavailableReason(
                    for: message,
                    destination: permissionChannel
                )
            }
            return destination
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissForwarding() }
                GlassEffectContainer(spacing: 0) {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        destinationList
                        Divider()
                        footer
                    }
                    .background(
                        Color(nsColor: .windowBackgroundColor),
                        in: ConcentricRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay {
                        ConcentricRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
                    .frame(
                        width: min(468, max(0, geometry.size.width - 48)),
                        height: min(679, max(0, geometry.size.height - 48))
                    )
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .zIndex(1_100)
        .accessibilityAddTraits(.isModal)
        // Discord's UserSearchContextManager stays subscribed to UserStore,
        // GuildMemberStore, ChannelStore, and supplemental READY updates while
        // the modal is open. Rebuild only when those source stores advance;
        // typing changes the lightweight result task below and never rebuilds
        // the index.
        .task(id: model.forwardSearchSourceRevision) {
            await rebuildSearchIndex()
        }
        .task(id: SearchRequest(
            query: query,
            pinnedDestinationIDs: searchPinnedDestinationIDs,
            indexRevision: searchIndexRevision
        )) {
            await refreshDisplayedDestinations()
        }
        .onExitCommand { model.dismissForwarding() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Forward To")
                        .font(.title2.weight(.semibold))
                    Text(selectedDestinationIDs.count >= ForwardDestinationSearchPolicy.maximumSelections
                        ? "Maximum 5 places at once."
                        : "Select where you want to share this message.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.dismissForwarding() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            PickerSearchField(text: $query, placeholder: "Search")
        }
        .padding(24)
    }

    private var destinationList: some View {
        ScrollView {
            // Discord caps each result category at 20, so the picker has at most
            // 80 rows. Keeping that bounded list eager avoids SwiftUI's lazy
            // collection invalidation trap when accessibility scroll actions
            // race a live search-index update.
            VStack(spacing: 2) {
                ForEach(displayedDestinations) { destination in
                    ForwardDestinationRow(
                        destination: destination,
                        isSelected: selectedDestinationIDs.contains(destination.id)
                    ) {
                        toggle(destination.id)
                    }
                }
            }
            .padding(8)
        }
        .overlay {
            if !model.hasLoadedDiscordEmojiSettings {
                ProgressView("Loading conversations…")
            } else if displayedDestinations.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.forwardingErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForwardedMessagePreview(message: message)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add an optional message...", text: $context, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isContextFocused)
                    .lineLimit(1 ... 3)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 38)
                    .contentShape(ConcentricRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { isContextFocused = true }
                    .glassEffect(
                        .regular.interactive(),
                        in: ConcentricRectangle(cornerRadius: 12, style: .continuous)
                    )
                Button {
                    let destinations = selectedDestinationIDs
                    Task { await model.forward(message, to: destinations, context: context) }
                } label: {
                    Group {
                        if model.isForwardingMessages {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(selectedDestinationIDs.count > 1
                                ? "Send (\(selectedDestinationIDs.count))"
                                : "Send")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(minWidth: 66)
                    .frame(height: 38)
                    .contentShape(ConcentricRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .contentShape(ConcentricRectangle(cornerRadius: 12, style: .continuous))
                .glassEffect(
                    .regular.tint(.accentColor).interactive(),
                    in: ConcentricRectangle(cornerRadius: 12, style: .continuous)
                )
                .disabled(selectedDestinationIDs.isEmpty || model.isForwardingMessages)
            }
        }
        .padding(24)
    }

    private func toggle(_ destinationID: ForwardDestinationID) {
        let selectedFromSearch = !query.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        let updatedPins = ForwardDestinationSelectionPolicy.searchPins(
            afterSelecting: destinationID,
            query: query,
            selectedDestinationIDs: selectedDestinationIDs,
            existing: searchPinnedDestinationIDs
        )
        if selectedFromSearch {
            searchPinnedDestinationIDs = updatedPins
            query = ""
        }
        if let index = selectedDestinationIDs.firstIndex(of: destinationID) {
            selectedDestinationIDs.remove(at: index)
            return
        }
        guard selectedDestinationIDs.count < ForwardDestinationSearchPolicy.maximumSelections else {
            NSSound.beep()
            return
        }
        selectedDestinationIDs.insert(destinationID, at: 0)
    }
}

private struct ForwardDestinationRow: View {
    let destination: ForwardDestination
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ForwardDestinationAvatar(destination: destination)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    let detail = destination.unavailableReason ?? destination.detail
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(destination.unavailableReason == nil
                                ? Color.secondary : Color.red)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackground)
            }
        }
        .buttonStyle(.plain)
        .disabled(destination.unavailableReason != nil)
        .opacity(destination.unavailableReason == nil ? 1 : 0.62)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(destination.id.accessibilityIdentifier)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        .primary.opacity(isSelected || isHovered ? 0.075 : 0.001)
    }

    private var accessibilityLabel: String {
        let detail = destination.unavailableReason ?? destination.detail
        return detail.isEmpty ? destination.title : "\(destination.title), \(detail)"
    }
}

private struct ForwardDestinationAvatar: View {
    let destination: ForwardDestination

    var body: some View {
        switch destination.kind {
        case .channel(let channel) where channel.guildID != nil:
            guildIcon(channelKind: channel.kind)
        case .thread:
            guildIcon(channelKind: .text)
        case .channel, .user:
            AvatarView(
                name: destination.title,
                url: destination.avatarURL,
                size: 28
            )
        }
    }

    private func guildIcon(channelKind: ChannelKindValue) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if destination.guild?.iconURL != nil {
                GuildIconView(
                    name: destination.guild?.name ?? destination.title,
                    iconURL: destination.guild?.iconURL,
                    size: 28,
                    cornerRadius: 9,
                    animates: false
                )
            } else {
                ConcentricRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Text(guildInitials)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
            }
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: channelKind == .voice ? "speaker.wave.2.fill" : "number")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    Circle().stroke(.black.opacity(0.12), lineWidth: 0.5)
                }
                .offset(x: 4, y: 4)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var guildInitials: String {
        let name = destination.guild?.name ?? destination.title
        let initials = name.split(whereSeparator: { $0.isWhitespace }).compactMap(\.first)
        if initials.count > 1 {
            return String(initials.prefix(3)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

private struct ForwardedMessagePreview: View {
    let message: Message

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.secondary.opacity(0.48))
                .frame(width: 3, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(previewText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let attachmentSummary {
                    Label(attachmentSummary, systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let mediaURL {
                AsyncImage(url: mediaURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.12)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Message being forwarded: \(previewText)")
    }

    private var attachmentSummary: String? {
        let imageCount = message.attachments.count(where: {
            $0.mediaKind == .image || $0.mediaKind == .animatedImage
        })
        guard imageCount > 0 else { return nil }
        return imageCount == 1 ? "1 image" : "\(imageCount) images"
    }

    private var mediaURL: URL? {
        message.stickers.first?.assetURL
            ?? message.attachments.first(where: {
                $0.mediaKind == .image || $0.mediaKind == .animatedImage
            })?.proxyURL
            ?? message.attachments.first(where: {
                $0.mediaKind == .image || $0.mediaKind == .animatedImage
            })?.url
            ?? message.embeds.lazy.compactMap { $0.thumbnail?.url ?? $0.image?.url }.first
    }

    private var previewText: String {
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MessageReplySummary.text(content: message.content)
        }
        if let sticker = message.stickers.first {
            return "Sticker: \(sticker.name)"
        }
        if let attachment = message.attachments.first {
            return nonEmpty(attachment.description)
                ?? nonEmpty(attachment.title)
                ?? attachment.filename
        }
        if let embed = message.embeds.first {
            return nonEmpty(embed.title)
                ?? nonEmpty(embed.description)
                ?? "Embed"
        }
        if message.hasPoll { return "Poll" }
        return "Message"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}
