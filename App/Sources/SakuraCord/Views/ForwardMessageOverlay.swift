import OSLog
import SakuraCordModels
import SwiftUI

// The forwarding presentation and its shared ranking policy intentionally live
// together so the native overlay and testable search policy cannot drift.
// swiftlint:disable file_length

struct PickerSearchField: View {
    @Binding var text: String
    let placeholder: String
    var accessibilityIdentifier = "picker-search"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .tint(SakuraCordAccentColor.color)
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
        .accessibilityIdentifier(accessibilityIdentifier)
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

nonisolated enum ForwardPickerLayoutMetrics {
    static let width: CGFloat = 480
    static let height: CGFloat = 679
    static let outerInset: CGFloat = 24
    static let cornerRadius: CGFloat = 16
    static let rowHeight: CGFloat = 48
    static let selectionDiameter: CGFloat = 20
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

    static func mergingPinnedDestinations(
        _ pins: [ForwardDestinationID],
        into destinations: [ForwardDestination],
        fallbacks: [ForwardDestination],
        limit: Int = 15
    ) -> [ForwardDestination] {
        guard !pins.isEmpty else { return Array(destinations.prefix(limit)) }
        let destinationsByID = Dictionary(
            (destinations + fallbacks).map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var seen = Set<ForwardDestinationID>()
        return (pins + destinations.map(\.id)).compactMap { destinationID in
            guard seen.insert(destinationID).inserted else { return nil }
            return destinationsByID[destinationID]
        }.prefix(limit).map { $0 }
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

// swiftlint:disable:next type_body_length
nonisolated enum ForwardDestinationSearchPolicy {
    enum ResultCategory: Sendable {
        case user, groupDirectMessage, selectableChannel, voiceChannel
    }

    struct ScoredResult: Sendable {
        let destination: ForwardDestination
        let category: ResultCategory
        let score: Double
        let comparator: String?
        let stableOrder: Int
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

    private struct DestinationSource {
        let channels: [Channel]
        let threads: [MessageThreadSummary]
        let includesUnjoinedThreads: Bool
        let channelStoreOrder: [ChannelID]
        let users: [User]
        let includesChannelRecipientsAsUsers: Bool
        let relationshipNicknamesByUserID: [UserID: String]
        let currentUserID: UserID?
        let guilds: [GuildID: Guild]
        let searchableChannelIDs: Set<ChannelID>?
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

    fileprivate final class SearchRecord: Sendable {
        let destination: ForwardDestination
        let category: ResultCategory
        let sourceOrder: Int
        let isEligible: Bool
        let values: SearchValues

        init(
            destination: ForwardDestination,
            category: ResultCategory,
            sourceOrder: Int,
            isEligible: Bool,
            values: SearchValues
        ) {
            self.destination = destination
            self.category = category
            self.sourceOrder = sourceOrder
            self.isEligible = isEligible
            self.values = values
        }
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

    private struct UserMatch {
        let score: Int
        let isFuzzy: Bool
    }

    private struct SearchScore {
        let value: Double
        let comparator: String?
        let isFuzzyUserMatch: Bool
        let isMatch: Bool
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
        let channelsByID = channelsByID(channels)
        var seenChannelIDs = Set<ChannelID>()
        return storeOrder.compactMap {
            guard seenChannelIDs.insert($0).inserted else { return nil }
            return channelsByID[$0]
        } + channels.filter { seenChannelIDs.insert($0.id).inserted }
    }

    struct Index: Sendable {
        let destinations: [ForwardDestination]
        fileprivate let searchRecords: [SearchRecord]
        fileprivate let usageScores: [String: Int]
        fileprivate let usageOrder: [String]
        fileprivate let eligibleChannelIDs: Set<ChannelID>?
        fileprivate let friendUserIDs: Set<UserID>
        fileprivate let relationshipNicknamesByUserID: [UserID: String]
        fileprivate let userBoosters: [UserID: Double]
        let maximumResolvableUsageScore: Int

        func quickSwitcherUserIndex(
            userSearchAliasesByUserID: [UserID: [String]]
        ) -> Index {
            let users = destinations.filter { destination in
                if case .user = destination.kind { return true }
                return false
            }
            return Index(
                destinations: users,
                searchRecords: ForwardDestinationSearchPolicy.makeSearchRecords(
                    users,
                    usageScores: usageScores,
                    maximumUsageScore: Double(maximumResolvableUsageScore),
                    friendUserIDs: friendUserIDs,
                    userBoosters: userBoosters,
                    relationshipNicknamesByUserID: relationshipNicknamesByUserID,
                    userSearchAliasesByUserID: userSearchAliasesByUserID,
                    eligibleChannelIDs: nil
                ),
                usageScores: usageScores,
                usageOrder: usageOrder,
                eligibleChannelIDs: nil,
                friendUserIDs: friendUserIDs,
                relationshipNicknamesByUserID: relationshipNicknamesByUserID,
                userBoosters: userBoosters,
                maximumResolvableUsageScore: maximumResolvableUsageScore
            )
        }

        func results(
            query: String,
            recentChannelIDs: [ChannelID] = [],
            pinnedDestinationIDs: [ForwardDestinationID] = [],
            originChannelID: ChannelID? = nil,
            categories: Set<ResultCategory>? = nil,
            limitPerCategory: Int = ForwardDestinationSearchPolicy.resultLimitPerCategory
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
                query: normalizedQuery,
                categories: categories,
                limitPerCategory: limitPerCategory
            ).map(\.destination)
        }

        func scoredResults(
            query: String,
            categories: Set<ResultCategory>,
            limitPerCategory: Int,
            requiresDestinationEligibility: Bool = true,
            allowedUserIDs: Set<UserID>? = nil,
            preservesSourceOrderForEqualScores: Bool = false,
            allowsEmptyQuery: Bool = false,
            groupsBeforeUsersForEqualScores: Bool = false
        ) -> [ScoredResult] {
            let normalizedQuery = ForwardDestinationSearchPolicy.normalize(query)
            guard allowsEmptyQuery || !normalizedQuery.isEmpty else { return [] }
            return ForwardDestinationSearchPolicy.searchedResults(
                searchRecords,
                query: normalizedQuery,
                categories: categories,
                limitPerCategory: limitPerCategory,
                requiresDestinationEligibility: requiresDestinationEligibility,
                allowedUserIDs: allowedUserIDs,
                preservesSourceOrderForEqualScores: preservesSourceOrderForEqualScores,
                groupsBeforeUsersForEqualScores: groupsBeforeUsersForEqualScores
            )
        }

        func unqueriedTextChannelResults(
            currentGuildID: GuildID?,
            limit: Int
        ) -> [ScoredResult] {
            ForwardDestinationSearchPolicy.unqueriedTextChannelResults(
                searchRecords,
                currentGuildID: currentGuildID,
                limit: limit
            )
        }

        func messageSearchUnqueriedChannelResults(
            currentGuildID: GuildID?,
            currentChannelID: ChannelID?,
            limit: Int
        ) -> [ScoredResult] {
            ForwardDestinationSearchPolicy.messageSearchUnqueriedChannelResults(
                searchRecords,
                currentGuildID: currentGuildID,
                currentChannelID: currentChannelID,
                limit: limit
            )
        }

        func messageSearchUnqueriedDirectMessageResults(
            currentChannelID: ChannelID?,
            limit: Int
        ) -> [ScoredResult] {
            ForwardDestinationSearchPolicy.messageSearchUnqueriedDirectMessageResults(
                searchRecords,
                currentChannelID: currentChannelID,
                limit: limit
            )
        }

        func messageSearchDirectMessageResults(
            query: String,
            limit: Int
        ) -> [ScoredResult] {
            ForwardDestinationSearchPolicy.messageSearchDirectMessageResults(
                searchRecords,
                query: ForwardDestinationSearchPolicy.normalize(query),
                relationshipNicknamesByUserID: relationshipNicknamesByUserID,
                limit: limit
            )
        }

        func messageSearchUnqueriedUserResults(limit: Int) -> [User] {
            ForwardDestinationSearchPolicy.messageSearchUnqueriedUserResults(
                searchRecords,
                limit: limit
            )
        }

    }

    static func makeIndex(
        channels: [Channel],
        threads: [MessageThreadSummary] = [],
        includesUnjoinedThreads: Bool = false,
        channelStoreOrder: [ChannelID] = [],
        users: [User] = [],
        userBoosterChannels: [Channel]? = nil,
        includesChannelRecipientsAsUsers: Bool = true,
        friendUserIDs: Set<UserID> = [],
        relationshipNicknamesByUserID: [UserID: String] = [:],
        userSearchAliasesByUserID: [UserID: [String]] = [:],
        currentUserID: UserID? = nil,
        guilds: [GuildID: Guild],
        usageScores: [String: Int],
        maximumUsageScore: Int? = nil,
        usageOrder: [String] = [],
        searchableChannelIDs: Set<ChannelID>? = nil,
        eligibleChannelIDs: Set<ChannelID>? = nil
    ) -> Index {
        let destinations = makeDestinations(source: DestinationSource(
            channels: channels,
            threads: threads,
            includesUnjoinedThreads: includesUnjoinedThreads,
            channelStoreOrder: channelStoreOrder,
            users: users,
            includesChannelRecipientsAsUsers: includesChannelRecipientsAsUsers,
            relationshipNicknamesByUserID: relationshipNicknamesByUserID,
            currentUserID: currentUserID,
            guilds: guilds,
            searchableChannelIDs: searchableChannelIDs
        ))
        let resolvableUsageKeys = Set(
            channels.map { $0.id.description }
                + threads.map { $0.id.description }
                + guilds.keys.map(\.description)
        )
        let maximumUsageScore = max(
            1,
            maximumUsageScore
                ?? resolvableUsageKeys.compactMap { usageScores[$0] }.max()
                ?? 1
        )
        let userBoosters = messageSearchUserBoosters(
            channels: userBoosterChannels ?? channels,
            usageScores: usageScores,
            maximumUsageScore: Double(maximumUsageScore),
            friendUserIDs: friendUserIDs
        )
        return Index(
            destinations: destinations,
            searchRecords: makeSearchRecords(
                destinations,
                usageScores: usageScores,
                maximumUsageScore: Double(maximumUsageScore),
                friendUserIDs: friendUserIDs,
                userBoosters: userBoosters,
                relationshipNicknamesByUserID: relationshipNicknamesByUserID,
                userSearchAliasesByUserID: userSearchAliasesByUserID,
                eligibleChannelIDs: eligibleChannelIDs
            ),
            usageScores: usageScores,
            usageOrder: usageOrder,
            eligibleChannelIDs: eligibleChannelIDs,
            friendUserIDs: friendUserIDs,
            relationshipNicknamesByUserID: relationshipNicknamesByUserID,
            userBoosters: userBoosters,
            maximumResolvableUsageScore: maximumUsageScore
        )
    }

    static func results(
        query: String,
        channels: [Channel],
        threads: [MessageThreadSummary] = [],
        includesUnjoinedThreads: Bool = false,
        channelStoreOrder: [ChannelID] = [],
        users: [User] = [],
        userBoosterChannels: [Channel]? = nil,
        friendUserIDs: Set<UserID> = [],
        relationshipNicknamesByUserID: [UserID: String] = [:],
        userSearchAliasesByUserID: [UserID: [String]] = [:],
        currentUserID: UserID? = nil,
        guilds: [GuildID: Guild],
        usageScores: [String: Int],
        maximumUsageScore: Int? = nil,
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
            includesUnjoinedThreads: includesUnjoinedThreads,
            channelStoreOrder: channelStoreOrder,
            users: users,
            userBoosterChannels: userBoosterChannels,
            friendUserIDs: friendUserIDs,
            relationshipNicknamesByUserID: relationshipNicknamesByUserID,
            userSearchAliasesByUserID: userSearchAliasesByUserID,
            currentUserID: currentUserID,
            guilds: guilds,
            usageScores: usageScores,
            maximumUsageScore: maximumUsageScore,
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

    // swiftlint:disable:next function_body_length
    private static func makeDestinations(
        source: DestinationSource
    ) -> [ForwardDestination] {
        let channels = source.channels
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
        let channelRecipients = source.includesChannelRecipientsAsUsers
            ? channels.flatMap(\.recipients)
            : []
        let orderedUsers = (source.users + channelRecipients).filter { user in
            user.id != source.currentUserID && seenUserIDs.insert(user.id).inserted
        }
        let userDestinations = orderedUsers.map { user in
            ForwardDestination(
                kind: .user(user, directMessage: directMessagesByUserID[user.id]),
                guild: nil,
                titleOverride: source.relationshipNicknamesByUserID[user.id]
            )
        }
        let channelDestinations = channels.compactMap { channel -> ForwardDestination? in
            guard channel.kind != .directMessage else { return nil }
            if channel.kind != .groupDirectMessage {
                guard supportsSearchCandidate(channel.kind),
                      source.searchableChannelIDs?.contains(channel.id) != false
                else { return nil }
            }
            return ForwardDestination(
                kind: .channel(channel),
                guild: channel.guildID.flatMap { source.guilds[$0] },
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
        let threadDestinations = source.threads.compactMap { thread -> ForwardDestination? in
            guard source.includesUnjoinedThreads || !thread.isArchived,
                  source.includesUnjoinedThreads || thread.notificationSettings != nil,
                  source.searchableChannelIDs?.contains(thread.id) != false
            else { return nil }
            return ForwardDestination(
                kind: .thread(
                    thread,
                    parent: thread.parentID.flatMap { channelsByID[$0] }
                ),
                guild: thread.guildID.flatMap { source.guilds[$0] }
            )
        }
        let parentSourceOrder = Dictionary(
            source.channelStoreOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { earlier, _ in earlier }
        )
        // ThreadStore returns a guild's threads grouped by parent-channel
        // store position, with snowflake order inside each parent. Ordinary
        // channels still precede the complete thread projection.
        func parentChannelID(of destination: ForwardDestination) -> ChannelID? {
            guard case .thread(_, let parent) = destination.kind else { return nil }
            return parent?.id
        }
        let activeJoinedThreadDestinations = threadDestinations.filter { destination in
            guard case .thread(let thread, _) = destination.kind else { return false }
            return !thread.isArchived && thread.notificationSettings != nil
        }.sorted { lhs, rhs in
            guard let lhsID = lhs.resolvedChannelID,
                  let rhsID = rhs.resolvedChannelID
            else { return lhs.resolvedChannelID != nil }
            return lhsID < rhsID
        }
        let activeJoinedThreadIDs = Set(
            activeJoinedThreadDestinations.compactMap(\.resolvedChannelID)
        )
        let remainingThreadDestinations = threadDestinations.filter {
            $0.resolvedChannelID.map(activeJoinedThreadIDs.contains) != true
        }.sorted { lhs, rhs in
            let lhsParentOrder = parentChannelID(of: lhs).flatMap { parentSourceOrder[$0] }
                ?? Int.max
            let rhsParentOrder = parentChannelID(of: rhs).flatMap { parentSourceOrder[$0] }
                ?? Int.max
            if lhsParentOrder != rhsParentOrder { return lhsParentOrder < rhsParentOrder }
            if let lhsID = lhs.resolvedChannelID,
               let rhsID = rhs.resolvedChannelID,
               lhsID != rhsID
            {
                return lhsID < rhsID
            }
            return false
        }
        let orderedThreadDestinations = activeJoinedThreadDestinations
            + remainingThreadDestinations
        let channelAndThreadDestinations = nonGroupChannelDestinations
            + orderedThreadDestinations
        return userDestinations
            + groupDirectMessageDestinations
            + channelAndThreadDestinations
    }

    private static func supportsSearchCandidate(_ kind: ChannelKindValue) -> Bool {
        switch kind {
        case .text, .announcement, .forum, .voice, .groupDirectMessage: true
        case .directMessage, .unknown: false
        }
    }

    private static func channelsByID(_ channels: [Channel]) -> [ChannelID: Channel] {
        Dictionary(
            channels.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
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

    private static func makeSearchRecords(
        _ destinations: [ForwardDestination],
        usageScores: [String: Int],
        maximumUsageScore: Double,
        friendUserIDs: Set<UserID>,
        userBoosters: [UserID: Double]? = nil,
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
                // Preserve the current first-party client's expression
                // exactly. Its null-coalescing/division precedence means a
                // present positive score is clamped directly to one here;
                // it is not normalized by the frecency engine's 1,000-point
                // maximum. Consequently every used channel receives the
                // complete internal three-point channel boost.
                internalChannel: usage > 0 ? 1 : 0
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
                        booster: userBoosters?[user.id]
                            ?? 1 + boosters.normalized
                                + (friendUserIDs.contains(user.id) ? 0.2 : 0)
                                + (directMessage == nil ? 0 : 0.1)
                    )
                )]
            case .channel(let channel) where channel.kind == .groupDirectMessage:
                return [record(
                    category: .groupDirectMessage,
                    values: .groupDirectMessage(
                        name: discordConfusableSkeleton(normalize(destination.title)),
                        recipientValues: channel.recipients.flatMap {
                            [
                                $0.displayName,
                                $0.username,
                                relationshipNicknamesByUserID[$0.id],
                            ].compactMap { $0 }.map {
                                discordConfusableSkeleton(normalize($0))
                            }
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
                        // Discord's channel frecency projection excludes
                        // ThreadStore rows. Reusing a historical thread ID's
                        // channel score changes equal-match ordering.
                        boosters: UsageBoosters(normalized: 0, internalChannel: 0),
                        basePenalty: (thread.isArchived ? 3 : 0)
                            + (thread.notificationSettings == nil ? 5 : 0),
                        minimumAfterPenalty: 0
                    )
                )]
            }
        }
    }

    /// Reproduces Discord's `FrecencyUser` map. User frecency is derived from
    /// private-channel usage. The current worker prefilters the frequent
    /// entities to one-to-one DMs, making its group-DM switch branch
    /// unreachable. Friend and DM membership bonuses are added afterward.
    private static func messageSearchUserBoosters(
        channels: [Channel],
        usageScores: [String: Int],
        maximumUsageScore: Double,
        friendUserIDs: Set<UserID>
    ) -> [UserID: Double] {
        var result: [UserID: Double] = [:]
        for channel in channels {
            let usage = Double(usageScores[channel.id.description, default: 0])
            guard usage > 0 else { continue }
            let normalized = min(max(usage / maximumUsageScore, 0), 1)
            switch channel.kind {
            case .directMessage:
                if let recipient = channel.recipients.first {
                    result[recipient.id] = 1 + normalized
                }
            case .groupDirectMessage:
                continue
            default:
                continue
            }
        }
        for userID in friendUserIDs {
            result[userID] = (result[userID] ?? 1) + 0.2
        }
        for channel in channels where channel.kind == .directMessage {
            guard let recipient = channel.recipients.first else { continue }
            result[recipient.id] = (result[recipient.id] ?? 1) + 0.1
        }
        return result
    }

    private static func searchedResults(
        _ records: [SearchRecord],
        query: String,
        categories: Set<ResultCategory>? = nil,
        limitPerCategory: Int = resultLimitPerCategory,
        requiresDestinationEligibility: Bool = true,
        allowedUserIDs: Set<UserID>? = nil,
        preservesSourceOrderForEqualScores: Bool = false,
        groupsBeforeUsersForEqualScores: Bool = false
    ) -> [ScoredResult] {
        let preparedQuery = PreparedQuery(query)
        var users: [RankedDestination] = []
        var groups: [RankedDestination] = []
        var textChannels: [RankedDestination] = []
        var voiceChannels: [RankedDestination] = []
        users.reserveCapacity(limitPerCategory)
        groups.reserveCapacity(limitPerCategory)
        textChannels.reserveCapacity(limitPerCategory)
        voiceChannels.reserveCapacity(limitPerCategory)
        var fuzzyUserCount = 0
        for (offset, record) in records.enumerated() {
            if offset & 63 == 0, Task.isCancelled { return [] }
            guard categories?.contains(record.category) != false else { continue }
            if record.category == .user,
               let allowedUserIDs,
               record.destination.userID.map(allowedUserIDs.contains) != true
            {
                continue
            }
            let match = searchScore(
                record.values,
                query: preparedQuery
            )
            guard match.isMatch else { continue }
            if match.isFuzzyUserMatch {
                guard fuzzyUserCount < 50 else { continue }
                fuzzyUserCount += 1
            }
            let ranked = RankedDestination(
                destination: record.destination,
                category: record.category,
                score: match.value,
                comparator: match.comparator,
                sourceOrder: record.sourceOrder,
                isEligible: record.isEligible
            )
            switch record.category {
            case .user: users.append(ranked)
            case .groupDirectMessage: groups.append(ranked)
            case .selectableChannel: textChannels.append(ranked)
            case .voiceChannel: voiceChannels.append(ranked)
            }
        }
        users = sortedPrefix(
            users,
            limit: limitPerCategory,
            preservesSourceOrderForEqualScores: preservesSourceOrderForEqualScores
        )
        groups = sortedPrefix(
            groups,
            limit: limitPerCategory,
            preservesSourceOrderForEqualScores: preservesSourceOrderForEqualScores
        )
        textChannels = sortedPrefix(
            textChannels,
            limit: limitPerCategory,
            preservesSourceOrderForEqualScores: preservesSourceOrderForEqualScores
        )
        voiceChannels = sortedPrefix(
            voiceChannels,
            limit: limitPerCategory,
            preservesSourceOrderForEqualScores: preservesSourceOrderForEqualScores
        )
        let rankedCategories = groupsBeforeUsersForEqualScores
            ? [groups, users, textChannels, voiceChannels]
            : [users, groups, textChannels, voiceChannels]
        return mergedRankedDestinations(
            rankedCategories,
            limitPerCategory: limitPerCategory,
            requiresDestinationEligibility: requiresDestinationEligibility,
            preservesSourceOrderForEqualScores: preservesSourceOrderForEqualScores
        )
    }

    private static func sortedPrefix(
        _ results: [RankedDestination],
        limit: Int,
        preservesSourceOrderForEqualScores: Bool
    ) -> [RankedDestination] {
        Array(results.sorted { lhs, rhs in
            if preservesSourceOrderForEqualScores, lhs.score == rhs.score {
                return lhs.sourceOrder < rhs.sourceOrder
            }
            return ranksBefore(lhs, rhs)
        }.prefix(limit))
    }

    private static func ranksBefore(
        _ lhs: RankedDestination,
        _ rhs: RankedDestination
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if let left = lhs.comparator,
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
        _ rankedCategories: [[RankedDestination]],
        limitPerCategory: Int,
        requiresDestinationEligibility: Bool,
        preservesSourceOrderForEqualScores: Bool
    ) -> [ScoredResult] {
        let limited = rankedCategories.enumerated().flatMap { item -> [RankedMergeEntry] in
            let (categoryOrder, ranked) = item
            return ranked
                .enumerated()
                .map {
                    RankedMergeEntry(
                        destination: $0.element,
                        stableOrder: categoryOrder * limitPerCategory + $0.offset
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
            if !preservesSourceOrderForEqualScores,
               let left = lhs.destination.comparator,
               let right = rhs.destination.comparator,
               left != right
            {
                return left.utf16.lexicographicallyPrecedes(right.utf16)
            }
            return lhs.stableOrder < rhs.stableOrder
        }.compactMap { entry in
            guard !requiresDestinationEligibility || entry.destination.isEligible else {
                return nil
            }
            return ScoredResult(
                destination: entry.destination.destination,
                category: entry.destination.category,
                score: entry.destination.score,
                comparator: entry.destination.comparator,
                stableOrder: entry.stableOrder
            )
        }
    }

    private static func unqueriedTextChannelResults(
        _ records: [SearchRecord],
        currentGuildID: GuildID?,
        limit: Int
    ) -> [ScoredResult] {
        let ranked = records.compactMap { record -> RankedDestination? in
            guard record.category == .selectableChannel,
                  record.destination.guild?.id == currentGuildID,
                  !isVoiceDestination(record.destination),
                  case .text(
                      _, _, let boosters, let basePenalty, let minimumAfterPenalty
                  ) = record.values
            else { return nil }
            let score = boostedTextDestinationScore(
                base: 7,
                // Empty channel-mode search does not receive SearchContext's
                // outer frecency map. Positive local use still applies the
                // worker's complete internal boost, leaving equally used
                // channels in ChannelStore insertion order.
                boosters: UsageBoosters(
                    normalized: 0,
                    internalChannel: boosters.internalChannel
                ),
                basePenalty: basePenalty,
                minimumAfterPenalty: minimumAfterPenalty
            )
            return RankedDestination(
                destination: record.destination,
                category: record.category,
                score: score,
                comparator: nil,
                sourceOrder: record.sourceOrder,
                isEligible: record.isEligible
            )
        }
        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            switch (lhs.destination.kind, rhs.destination.kind) {
            case (.channel(let left), .channel(let right)):
                if left.position != right.position { return left.position < right.position }
            case (.channel, .thread):
                return true
            case (.thread, .channel):
                return false
            case (
                .thread(let left, let leftParent),
                .thread(let right, let rightParent)
            ):
                let leftPosition = leftParent?.position ?? Int.max
                let rightPosition = rightParent?.position ?? Int.max
                if leftPosition != rightPosition { return leftPosition < rightPosition }
                if left.id != right.id { return left.id < right.id }
            case (.user, _), (_, .user):
                break
            }
            return lhs.sourceOrder < rhs.sourceOrder
        }.prefix(limit).map {
            ScoredResult(
                destination: $0.destination,
                category: $0.category,
                score: $0.score,
                comparator: nil,
                stableOrder: $0.sourceOrder
            )
        }
    }

    private static func messageSearchUnqueriedChannelResults(
        _ records: [SearchRecord],
        currentGuildID: GuildID?,
        currentChannelID: ChannelID?,
        limit: Int
    ) -> [ScoredResult] {
        let ranked = records.compactMap { record -> RankedDestination? in
            guard record.category == .selectableChannel,
                  record.destination.guild?.id == currentGuildID,
                  case .text(
                      let title,
                      _,
                      let boosters,
                      let basePenalty,
                      let minimumAfterPenalty
                  ) = record.values
            else { return nil }
            return RankedDestination(
                destination: record.destination,
                category: record.category,
                score: boostedTextDestinationScore(
                    base: 7,
                    boosters: boosters,
                    basePenalty: basePenalty,
                    minimumAfterPenalty: minimumAfterPenalty
                ),
                comparator: title,
                sourceOrder: record.sourceOrder,
                isEligible: record.isEligible
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.sourceOrder < rhs.sourceOrder
        }
        var current: RankedDestination?
        var remaining: [RankedDestination] = []
        for row in ranked {
            if row.destination.resolvedChannelID == currentChannelID {
                current = row
            } else {
                remaining.append(row)
            }
        }
        return ([current].compactMap { $0 } + remaining).prefix(limit).map {
            ScoredResult(
                destination: $0.destination,
                category: $0.category,
                score: $0.score,
                comparator: $0.comparator,
                stableOrder: $0.sourceOrder
            )
        }
    }

    private static func messageSearchUnqueriedDirectMessageResults(
        _ records: [SearchRecord],
        currentChannelID: ChannelID?,
        limit: Int
    ) -> [ScoredResult] {
        let ranked = records.compactMap { record -> RankedDestination? in
            let score: Double
            switch (record.category, record.values) {
            case (.user, .user(_, let booster)):
                guard record.destination.resolvedChannelID != nil else { return nil }
                score = 10_000 * booster
            case (.groupDirectMessage, .groupDirectMessage(_, _, let usage)):
                score = 10_000 * (1 + usage)
            default:
                return nil
            }
            return RankedDestination(
                destination: record.destination,
                category: record.category,
                score: score,
                comparator: nil,
                sourceOrder: record.sourceOrder,
                isEligible: true
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.sourceOrder < rhs.sourceOrder
        }
        var current: RankedDestination?
        var remaining: [RankedDestination] = []
        for row in ranked {
            if row.destination.resolvedChannelID == currentChannelID {
                current = row
            } else {
                remaining.append(row)
            }
        }
        return ([current].compactMap { $0 } + remaining).prefix(limit).map {
            ScoredResult(
                destination: $0.destination,
                category: $0.category,
                score: $0.score,
                comparator: nil,
                stableOrder: $0.sourceOrder
            )
        }
    }

    private static func messageSearchDirectMessageResults(
        _ records: [SearchRecord],
        query: String,
        relationshipNicknamesByUserID: [UserID: String],
        limit: Int
    ) -> [ScoredResult] {
        let preparedQuery = PreparedMatch(query)
        var exactUsers: [RankedDestination] = []
        var fuzzyUsers: [RankedDestination] = []
        var groups: [RankedDestination] = []
        var fuzzyUserCount = 0
        for record in records {
            switch (record.category, record.destination.kind, record.values) {
            case (.user, .user(let user, let directMessage), .user(_, let booster)):
                guard directMessage != nil else { continue }
                let identities = [
                    user.username,
                    relationshipNicknamesByUserID[user.id],
                    user.displayName,
                ].compactMap { $0 }.map(PreparedUserIdentity.init)
                var bestScore = 0
                var isFuzzy = false
                for identity in identities {
                    let match = legacyDirectMessageUserMatch(
                        identity,
                        query: preparedQuery
                    )
                    if match.score > bestScore
                        || match.score == bestScore && isFuzzy && !match.isFuzzy
                    {
                        bestScore = match.score
                        isFuzzy = match.isFuzzy
                    }
                }
                guard bestScore > 0 else { continue }
                if isFuzzy {
                    guard fuzzyUserCount < 50 else { continue }
                    fuzzyUserCount += 1
                }
                let ranked = RankedDestination(
                    destination: record.destination,
                    category: .user,
                    score: 1_000 * Double(bestScore) * booster,
                    comparator: nil,
                    sourceOrder: record.sourceOrder,
                    isEligible: true
                )
                if isFuzzy { fuzzyUsers.append(ranked) } else { exactUsers.append(ranked) }
            case (.groupDirectMessage, _, _):
                let match = searchScore(record.values, query: PreparedQuery(query))
                guard match.isMatch else { continue }
                groups.append(RankedDestination(
                    destination: record.destination,
                    category: .groupDirectMessage,
                    score: match.value,
                    comparator: nil,
                    sourceOrder: record.sourceOrder,
                    isEligible: true
                ))
            default:
                continue
            }
        }
        exactUsers = sortedPrefix(
            exactUsers,
            limit: limit,
            preservesSourceOrderForEqualScores: true
        )
        fuzzyUsers = sortedPrefix(
            fuzzyUsers,
            limit: limit,
            preservesSourceOrderForEqualScores: true
        )
        var users = Array(exactUsers.prefix(limit))
        if users.count < limit {
            users += fuzzyUsers.prefix(limit - users.count)
        }
        groups = sortedPrefix(
            groups,
            limit: limit,
            preservesSourceOrderForEqualScores: true
        )
        return mergedRankedDestinations(
            [users, groups],
            limitPerCategory: limit,
            requiresDestinationEligibility: false,
            preservesSourceOrderForEqualScores: true
        ).prefix(limit).map { $0 }
    }

    private static func messageSearchUnqueriedUserResults(
        _ records: [SearchRecord],
        limit: Int
    ) -> [User] {
        // swiftlint:disable:next large_tuple
        records.compactMap { record -> (User, Double, Int)? in
            guard record.category == .user,
                  case .user(let user, _) = record.destination.kind,
                  case .user(_, let booster) = record.values
            else { return nil }
            return (user, 10_000 * booster, record.sourceOrder)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.2 < rhs.2
        }.prefix(limit).map(\.0)
    }

    private static func isVoiceDestination(
        _ destination: ForwardDestination
    ) -> Bool {
        switch destination.kind {
        case .channel(let channel): channel.kind == .voice
        case .thread, .user: false
        }
    }

    static func guildSearchScore(
        name: String,
        query: String,
        usageScore: Int,
        maximumUsageScore: Int
    ) -> Double {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return 0 }
        let preparedQuery = PreparedQuery(normalizedQuery)
        let baseScore = matchScore(
            normalize(name),
            query: preparedQuery.match,
            fuzzy: true
        )
        guard baseScore > 0 else { return 0 }
        let usage = Double(usageScore)
        let maximum = Double(max(1, maximumUsageScore))
        let usageBooster = 1 + min(max(usage / maximum, 0), 1)
        return 1_000 * Double(baseScore) * usageBooster
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
    ) -> SearchScore {
        switch values {
        case .user(let values, let booster):
            var bestScore = 0
            var comparator: String?
            var isFuzzy = false
            for value in values {
                let match = userMatch(value, query: query.match)
                if match.score > bestScore {
                    bestScore = match.score
                    comparator = value.comparator
                    isFuzzy = match.isFuzzy
                }
            }
            return SearchScore(
                value: 1_000 * Double(bestScore) * booster,
                comparator: comparator,
                isFuzzyUserMatch: isFuzzy,
                isMatch: bestScore > 0
            )
        case .groupDirectMessage(let name, let recipientValues, let usage):
            // Group-DM search is the one channel category that Discord runs
            // through its confusable-character normalizer before applying the
            // ordinary fuzzy matcher. In particular, ASCII `m` becomes `rn`;
            // omitting this made queries such as `len` miss a recipient whose
            // display name ended in `me` even though the official client
            // returned that group.
            let groupQuery = PreparedMatch(
                discordConfusableSkeleton(query.match.value)
            )
            let ownNameScore = matchScore(name, query: groupQuery, fuzzy: true)
            var recipientScore = 0
            for value in recipientValues {
                recipientScore = max(
                    recipientScore,
                    min(5, matchScore(value, query: groupQuery, fuzzy: true))
                )
            }
            return SearchScore(
                value: 1_000 * Double(max(ownNameScore, recipientScore)) * (1 + usage),
                comparator: nil,
                isFuzzyUserMatch: false,
                isMatch: max(ownNameScore, recipientScore) > 0
            )
        case .text(
            let title,
            let metadata,
            let boosters,
            let basePenalty,
            let minimumAfterPenalty
        ):
            let score = textDestinationSearchScore(
                    title: title,
                    metadata: metadata,
                    query: query,
                    boosters: boosters,
                    basePenalty: basePenalty,
                    minimumAfterPenalty: minimumAfterPenalty
                )
            return SearchScore(
                value: score.value,
                comparator: nil,
                isFuzzyUserMatch: false,
                isMatch: score.isMatch
            )
        }
    }

    private static func userMatch(
        _ identity: PreparedUserIdentity,
        query: PreparedMatch
    ) -> UserMatch {
        if identity.searchValue.hasPrefix(query.value) {
            return UserMatch(score: 10, isFuzzy: false)
        }
        if identity.confusableSkeleton.hasPrefix(query.confusableSkeleton) {
            return UserMatch(score: 1, isFuzzy: false)
        }
        let matchesFuzzy = isOrderedSubsequence(query.value, of: identity.searchValue)
            || isOrderedSubsequence(
                query.confusableSkeleton,
                of: identity.confusableSkeleton
            )
        return UserMatch(score: matchesFuzzy ? 1 : 0, isFuzzy: matchesFuzzy)
    }

    private static func legacyDirectMessageUserMatch(
        _ identity: PreparedUserIdentity,
        query: PreparedMatch
    ) -> UserMatch {
        if identity.searchValue.hasPrefix(query.value) {
            return UserMatch(score: 10, isFuzzy: false)
        }
        if identity.confusableSkeleton.hasPrefix(query.confusableSkeleton) {
            return UserMatch(score: 1, isFuzzy: false)
        }
        let matchesFuzzy = isOrderedSubsequence(query.value, of: identity.searchValue)
            || isOrderedSubsequence(
                query.confusableSkeleton,
                of: identity.confusableSkeleton
            )
        return UserMatch(score: matchesFuzzy ? 1 : 0, isFuzzy: matchesFuzzy)
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
    ) -> (value: Double, isMatch: Bool) {
        if query.hasSingleDescriptor {
            let base = matchScore(title, query: query.match, fuzzy: true)
            return (
                boostedTextDestinationScore(
                base: Double(base),
                boosters: boosters,
                basePenalty: basePenalty,
                minimumAfterPenalty: minimumAfterPenalty
                ),
                base > 0
            )
        }
        var descriptors = query.descriptors
        var base = consumeBestMatch(
            in: title,
            descriptors: &descriptors,
            fuzzy: true
        )
        guard base > 0 else { return (0, false) }
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
        else { return (0, false) }
        return (
            boostedTextDestinationScore(
                base: base,
                boosters: boosters,
                basePenalty: basePenalty,
                minimumAfterPenalty: minimumAfterPenalty
            ),
            true
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
        // Channel and guild search lowercases literally. Discord applies
        // accent folding only inside its user/GDM identity path; folding here
        // makes e.g. `music` match `música` and changes the complete channel
        // result set.
        value.lowercased(with: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class ForwardDestinationSearchIndexCache {
    static let shared = ForwardDestinationSearchIndexCache()

    private struct Key: Equatable {
        let modelID: ObjectIdentifier
        let userID: UserID?
        let revision: UInt64
    }

    private struct PrewarmKey: Equatable {
        let modelID: ObjectIdentifier
        let userID: UserID?
    }

    private nonisolated struct Input {
        let channels: [Channel]
        let threads: [MessageThreadSummary]
        let channelStoreOrder: [ChannelID]
        let users: [User]
        let friendUserIDs: Set<UserID>
        let relationshipNicknamesByUserID: [UserID: String]
        let userSearchAliasesByUserID: [UserID: [String]]
        let currentUserID: UserID?
        let guilds: [GuildID: Guild]
        let usageScores: [String: Int]
        let usageOrder: [String]
        let searchableChannelIDs: Set<ChannelID>
        let eligibleChannelIDs: Set<ChannelID>

        func makeIndex() -> ForwardDestinationSearchPolicy.Index {
            ForwardDestinationSearchPolicy.makeIndex(
                channels: channels,
                threads: threads,
                channelStoreOrder: channelStoreOrder,
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
            )
        }
    }

    /// A value-semantic snapshot of the stores needed to build the search
    /// corpus. Capturing these copy-on-write values on the main actor is cheap;
    /// ordering, dictionary construction, permission resolution, filtering,
    /// and index construction all happen after the snapshot leaves it.
    private nonisolated struct Source: Sendable {
        let snapshot: BootstrapSnapshot?
        let serverRailGuildsByID: [GuildID: Guild]
        let selectedGuildID: GuildID?
        let membersByID: [UserID: Member]
        let membersByGuildID: [GuildID: [UserID: Member]]
        let guildRoles: [GuildRole]
        let guildRolesByGuildID: [GuildID: [GuildRole]]
        let currentUserRoleIDsByGuild: [GuildID: Set<RoleID>]
        let usageScores: [String: Int]
        let usageOrder: [String]

        func makeInput(currentUserID: UserID?) -> Input {
            let channels = ForwardDestinationSearchPolicy.channelsInStoreOrder(
                snapshot?.channels ?? [],
                storeOrder: snapshot?.forwardChannelStoreOrder ?? []
            )
            let channelsByID = Dictionary(
                channels.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let threads = snapshot?.activeJoinedThreads ?? []
            var permissionBasisByGuildID: [GuildID: ConversationPermissionBasis] = [:]
            var unresolvedGuildIDs: Set<GuildID> = []
            var permissionsByChannelID: [ChannelID: UInt64] = [:]
            permissionBasisByGuildID.reserveCapacity(serverRailGuildsByID.count)
            permissionsByChannelID.reserveCapacity(channels.count)
            for channel in channels {
                guard let guildID = channel.guildID else { continue }
                let permissionBasis: ConversationPermissionBasis?
                if let cached = permissionBasisByGuildID[guildID] {
                    permissionBasis = cached
                } else if unresolvedGuildIDs.contains(guildID) {
                    permissionBasis = nil
                } else if let resolved = makePermissionBasis(
                    for: guildID,
                    currentUserID: currentUserID
                ) {
                    permissionBasisByGuildID[guildID] = resolved
                    permissionBasis = resolved
                } else {
                    unresolvedGuildIDs.insert(guildID)
                    permissionBasis = nil
                }
                permissionsByChannelID[channel.id] = permissionBasis.map {
                    ConversationPermissionResolver.effectivePermissions(
                        guild: $0.guild,
                        channel: channel,
                        resolvedBasePermissions: $0.resolvedBasePermissions,
                        overwritePrincipals: $0.overwritePrincipals,
                        hasCurrentRoleIdentity: $0.hasCurrentRoleIdentity
                    )
                } ?? nil
            }
            let searchableChannelIDs = Set(
                channels.lazy.filter { channel in
                    ForwardDestinationPermissionPolicy.canSearchChannel(
                        channel,
                        permissions: permissionsByChannelID[channel.id]
                    )
                }.map(\.id)
            ).union(threads.compactMap { thread in
                guard !thread.isArchived,
                      let parentID = thread.parentID,
                      let parent = channelsByID[parentID],
                      ForwardDestinationPermissionPolicy.canSearchThread(
                          parent: parent,
                          permissions: permissionsByChannelID[parent.id]
                      )
                else { return nil }
                return thread.id
            })
            let eligibleChannelIDs = Set(
                channels.lazy.filter { channel in
                    ForwardDestinationPermissionPolicy.canUseChannel(
                        channel,
                        permissions: permissionsByChannelID[channel.id]
                    )
                }.map(\.id)
            ).union(threads.compactMap { thread in
                guard !thread.isArchived,
                      let parentID = thread.parentID,
                      let parent = channelsByID[parentID],
                      ForwardDestinationPermissionPolicy.canUseThread(
                          parent: parent,
                          permissions: permissionsByChannelID[parent.id]
                      )
                else { return nil }
                return thread.id
            })
            let snapshotGuilds = Dictionary(
                uniqueKeysWithValues: (snapshot?.guilds ?? []).map { ($0.id, $0) }
            )
            let guilds = snapshotGuilds.merging(serverRailGuildsByID) { _, railGuild in
                railGuild
            }
            return Input(
                channels: channels,
                threads: threads,
                channelStoreOrder: snapshot?.forwardChannelStoreOrder ?? [],
                users: snapshot?.knownUsers ?? [],
                friendUserIDs: snapshot?.friendUserIDs ?? [],
                relationshipNicknamesByUserID:
                    snapshot?.relationshipNicknamesByUserID ?? [:],
                userSearchAliasesByUserID:
                    snapshot?.userSearchAliasesByUserID ?? [:],
                currentUserID: currentUserID,
                guilds: guilds,
                usageScores: usageScores,
                usageOrder: usageOrder,
                searchableChannelIDs: searchableChannelIDs,
                eligibleChannelIDs: eligibleChannelIDs
            )
        }

        private func makePermissionBasis(
            for guildID: GuildID,
            currentUserID: UserID?
        ) -> ConversationPermissionBasis? {
            guard let guild = serverRailGuildsByID[guildID],
                  let currentUserID
            else { return nil }
            let member = membersByGuildID[guildID]?[currentUserID]
                ?? (guildID == selectedGuildID ? membersByID[currentUserID] : nil)
            let roles = guildRolesByGuildID[guildID]
                ?? (guildID == selectedGuildID ? guildRoles : [])
            let storedRoleIDs = currentUserRoleIDsByGuild[guildID]
            let roleIDs = storedRoleIDs ?? Set(member?.roles.map(\.id) ?? [])
            return ConversationPermissionBasis(
                guild: guild,
                resolvedBasePermissions: guild.currentUserPermissions
                    ?? ConversationPermissionResolver.basePermissions(
                        guildID: guildID,
                        roleIDs: roleIDs,
                        roles: roles
                    ),
                overwritePrincipals: PermissionOverwritePrincipals(
                    guildID: guildID,
                    currentUserID: currentUserID,
                    roleIDs: roleIDs
                ),
                hasCurrentRoleIdentity: storedRoleIDs != nil || member != nil,
                currentUserIsPending: member?.isPending == true
            )
        }
    }

    private var modelID: ObjectIdentifier?
    private var userID: UserID?
    private var revision: UInt64?
    private var index: ForwardDestinationSearchPolicy.Index?
    private var preparationKey: Key?
    private var preparationTask: Task<ForwardDestinationSearchPolicy.Index, Never>?
    private var prewarmKey: PrewarmKey?
    private var prewarmTask: Task<Void, Never>?

    func value(
        for model: AppModel,
        userID: UserID?,
        revision: UInt64
    ) -> ForwardDestinationSearchPolicy.Index? {
        guard modelID == ObjectIdentifier(model),
              self.userID == userID,
              self.revision == revision
        else { return nil }
        return index
    }

    /// Returns the most recently completed index for this account even while a
    /// newer source revision is being prepared. An open search surface can use
    /// this immutable snapshot immediately and adopt the refresh next time it
    /// is presented instead of blocking interaction on background work.
    func latestValue(
        for model: AppModel,
        userID: UserID?
    ) -> ForwardDestinationSearchPolicy.Index? {
        guard modelID == ObjectIdentifier(model),
              self.userID == userID
        else { return nil }
        return index
    }

    func invalidate(for model: AppModel) {
        guard modelID == ObjectIdentifier(model) else { return }
        revision = nil
    }

    func store(
        _ index: ForwardDestinationSearchPolicy.Index,
        for model: AppModel,
        userID: UserID?,
        revision: UInt64
    ) {
        modelID = ObjectIdentifier(model)
        self.userID = userID
        self.revision = revision
        self.index = index
    }

    /// Starts one cache-owned background prewarm for an account. View tasks
    /// are revision-bound and are cancelled repeatedly during READY and guild
    /// activation; owning the debounce here guarantees one build while still
    /// coalescing every source revision that arrives before it begins.
    func schedulePrewarm(for model: AppModel) {
        let userID = model.snapshot?.currentUser.id
        let key = PrewarmKey(
            modelID: ObjectIdentifier(model),
            userID: userID
        )
        if let prewarmKey, prewarmKey != key {
            prewarmTask?.cancel()
            prewarmTask = nil
            self.prewarmKey = nil
        }
        guard latestValue(for: model, userID: userID) == nil,
              prewarmTask == nil
        else { return }
        prewarmKey = key
        AppPerformanceSignposts.signposter.emitEvent(
            "ForwardDestinationIndexPrewarmScheduled"
        )
        prewarmTask = Task { @MainActor [weak self, weak model] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                guard let self, self.prewarmKey == key else { return }
                self.prewarmKey = nil
                self.prewarmTask = nil
                return
            }
            guard let self, self.prewarmKey == key else { return }
            self.prewarmKey = nil
            self.prewarmTask = nil
            guard let model,
                  ObjectIdentifier(model) == key.modelID,
                  model.snapshot?.currentUser.id == key.userID,
                  self.latestValue(for: model, userID: key.userID) == nil
            else { return }
            _ = await self.prepare(for: model, priority: .utility)
        }
    }

    func prepare(
        for model: AppModel,
        priority: TaskPriority
    ) async -> ForwardDestinationSearchPolicy.Index? {
        let currentUserID = model.snapshot?.currentUser.id
        let sourceRevision = model.forwardSearchSourceRevision
        if let cached = value(
            for: model,
            userID: currentUserID,
            revision: sourceRevision
        ) {
            return cached
        }

        let key = Key(
            modelID: ObjectIdentifier(model),
            userID: currentUserID,
            revision: sourceRevision
        )
        if let preparationTask,
           let preparationKey,
           preparationKey != key
        {
            // Index construction is synchronous CPU work. Cancelling its Task
            // does not interrupt that work, so starting the next revision here
            // used to leave overlapping rebuilds competing with typing and
            // presentation. Cache the in-flight snapshot, then coalesce callers
            // onto one rebuild for the newest revision.
            let prepared = await preparationTask.value
            if self.preparationKey == preparationKey {
                modelID = preparationKey.modelID
                userID = preparationKey.userID
                revision = preparationKey.revision
                index = prepared
                self.preparationKey = nil
                self.preparationTask = nil
            }
            guard !Task.isCancelled else { return nil }
            return await prepare(for: model, priority: priority)
        }

        let task: Task<ForwardDestinationSearchPolicy.Index, Never>
        if preparationKey == key, let preparationTask {
            task = preparationTask
        } else {
            let source = AppPerformanceSignposts.measureSync(
                "ForwardDestinationIndexSourceSnapshot"
            ) {
                makeSource(for: model)
            }
            let newTask = Task.detached(priority: priority) {
                let signposter = OSSignposter(
                    subsystem: "dev.sakuracord.SakuraCord",
                    category: "PointsOfInterest"
                )
                let preparation = signposter.beginInterval(
                    "ForwardDestinationIndexPreparation"
                )
                defer {
                    signposter.endInterval(
                        "ForwardDestinationIndexPreparation",
                        preparation
                    )
                }
                let inputInterval = signposter.beginInterval(
                    "ForwardDestinationIndexInputPreparation"
                )
                let input = source.makeInput(currentUserID: currentUserID)
                signposter.endInterval(
                    "ForwardDestinationIndexInputPreparation",
                    inputInterval
                )
                let construction = signposter.beginInterval(
                    "ForwardDestinationIndexConstruction"
                )
                let index = input.makeIndex()
                signposter.endInterval(
                    "ForwardDestinationIndexConstruction",
                    construction
                )
                return index
            }
            preparationKey = key
            preparationTask = newTask
            task = newTask
        }

        let prepared = await task.value
        if preparationKey == key {
            store(
                prepared,
                for: model,
                userID: currentUserID,
                revision: sourceRevision
            )
            preparationKey = nil
            preparationTask = nil
        }
        guard !Task.isCancelled else { return nil }
        return prepared
    }

    private func makeSource(for model: AppModel) -> Source {
        Source(
            snapshot: model.snapshot,
            serverRailGuildsByID: model.serverRailGuildsByID,
            selectedGuildID: model.selectedGuildID,
            membersByID: model.membersByID,
            membersByGuildID: model.membersByGuildID,
            guildRoles: model.guildRoles,
            guildRolesByGuildID: model.guildRolesByGuildID,
            currentUserRoleIDsByGuild: model.currentUserRoleIDsByGuild,
            usageScores: model.discordGuildAndChannelUsageScores,
            usageOrder: model.discordGuildAndChannelUsageOrder
        )
    }
}

struct ForwardMessageOverlay: View {
    let model: AppModel
    let message: Message
    let animationState: WindowModalAnimationState
    let dismiss: () -> Void
    @State private var query = ""
    @State private var context = ""
    @State private var selectedDestinationIDs: [ForwardDestinationID] = []
    @State private var searchPinnedDestinationIDs: [ForwardDestinationID] = []
    @State private var searchIndex: ForwardDestinationSearchPolicy.Index?
    @State private var searchIndexRevision = 0
    @State private var displayedDestinations: [ForwardDestination] = []
    @State private var unqueriedDestinations: [ForwardDestination] = []
    @State private var destinationScrollPosition: ForwardDestinationID?
    @FocusState private var isContextFocused: Bool

    private struct SearchRequest: Hashable {
        let query: String
        let pinnedDestinationIDs: [ForwardDestinationID]
        let indexRevision: Int
    }

    private var isVisible: Bool {
        animationState.isVisible
    }

    private func rebuildSearchIndex() async {
        // Frecency settings improve ranking, but destination discovery itself
        // is entirely local. Never hold the first picker population behind the
        // authenticated enrichment request; its revision will rebuild this
        // index when it settles.
        if !model.hasLoadedDiscordEmojiSettings {
            Task { @MainActor in
                await model.loadDiscordEmojiSettings()
            }
        }
        guard !Task.isCancelled else { return }
        guard let index = await ForwardDestinationSearchIndexCache.shared.prepare(
            for: model,
            priority: .userInitiated
        ), !Task.isCancelled
        else { return }
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
        let indexRevision = searchIndexRevision
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
        guard self.query == query,
              searchPinnedDestinationIDs == pins,
              searchIndexRevision == indexRevision
        else { return }

        var validatedResults = validateContentPermissions(in: results)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validatedResults = ForwardDestinationSelectionPolicy.mergingPinnedDestinations(
                pins,
                into: validatedResults,
                fallbacks: displayedDestinations + unqueriedDestinations
            )
            unqueriedDestinations = validatedResults
        }
        displayedDestinations = validatedResults
    }

    private func validateContentPermissions(
        in results: [ForwardDestination]
    ) -> [ForwardDestination] {
        let needsContentPermissionValidation = !message.attachments.isEmpty
            || !message.embeds.isEmpty
            || !message.stickers.isEmpty
            || message.flags.contains(.voiceMessage)
        guard needsContentPermissionValidation else {
            return results
        }
        return results.map { destination in
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
                Color.black.opacity(
                    WindowModalVisualStyle.menuBackgroundDimmingOpacity
                )
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
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
                        in: ConcentricRectangle(
                            cornerRadius: ForwardPickerLayoutMetrics.cornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        ConcentricRectangle(
                            cornerRadius: ForwardPickerLayoutMetrics.cornerRadius,
                            style: .continuous
                        )
                        .stroke(.separator, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
                    .scaleEffect(isVisible ? 1 : 0.965)
                    .frame(
                        width: min(
                            ForwardPickerLayoutMetrics.width,
                            max(
                                0,
                                geometry.size.width
                                    - ForwardPickerLayoutMetrics.outerInset * 2
                            )
                        ),
                        height: min(
                            ForwardPickerLayoutMetrics.height,
                            max(
                                0,
                                geometry.size.height
                                    - ForwardPickerLayoutMetrics.outerInset * 2
                            )
                        )
                    )
                    .padding(ForwardPickerLayoutMetrics.outerInset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        // Keep a modal-level SwiftUI responder in the chain after Search gives
        // up focus. AppKit routes Escape through `cancelOperation(_:)`, while
        // SwiftUI's exit command reaches this focusable ancestor for controls
        // that install their own internal responder.
        .focusable()
        .focusEffectDisabled()
        .accessibilityAddTraits(.isModal)
        .animation(
            .easeOut(duration: WindowModalAnimationTiming.openingSeconds),
            value: isVisible
        )
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
        .onExitCommand(perform: dismiss)
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
                HoverCloseButton(
                    help: "Close",
                    accessibilityIdentifier: "forward-close",
                    action: dismiss
                )
            }
            PickerSearchField(
                text: $query,
                placeholder: "Search",
                accessibilityIdentifier: "forward-search"
            )
        }
        .padding(24)
    }

    private var destinationList: some View {
        ScrollView {
            // Discord caps each result category at 20, so the picker has at most
            // 80 rows. Keeping that bounded list eager avoids SwiftUI's lazy
            // collection invalidation trap when accessibility scroll actions
            // race a live search-index update.
            VStack(spacing: 0) {
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
            .scrollTargetLayout()
        }
        .scrollPosition(id: $destinationScrollPosition, anchor: .top)
        .overlay {
            if searchIndex == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading conversations")
            } else if displayedDestinations.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.forwardingErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
            ForwardedMessagePreview(model: model, message: message)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Add an optional message…", text: $context, axis: .vertical)
                    .tint(SakuraCordAccentColor.color)
                    .textFieldStyle(.plain)
                    .focused($isContextFocused)
                    .lineLimit(1 ... 3)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 40)
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
                    .frame(height: 40)
                    .contentShape(ConcentricRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .contentShape(ConcentricRectangle(cornerRadius: 12, style: .continuous))
                .glassEffect(
                    .regular.tint(SakuraCordAccentColor.color).interactive(),
                    in: ConcentricRectangle(cornerRadius: 12, style: .continuous)
                )
                .disabled(selectedDestinationIDs.isEmpty || model.isForwardingMessages)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
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
            displayedDestinations = ForwardDestinationSelectionPolicy
                .mergingPinnedDestinations(
                updatedPins,
                into: unqueriedDestinations,
                fallbacks: displayedDestinations
            )
            unqueriedDestinations = displayedDestinations
            searchPinnedDestinationIDs = updatedPins
            query = ""
            destinationScrollPosition = destinationID
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
