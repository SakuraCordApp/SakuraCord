import OSLog
import SakuraCordModels
import SwiftUI

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
        let excludedUserIDs: Set<UserID>
        let guilds: [GuildID: Guild]
        let searchableChannelIDs: Set<ChannelID>?
    }

    private struct RankedMergeEntry {
        let destination: RankedDestination
        let stableOrder: Int
    }

    private struct RankedUser {
        let user: User
        let score: Double
        let sourceOrder: Int
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
        excludedUserIDs: Set<UserID> = [],
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
            excludedUserIDs: excludedUserIDs,
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

}

nonisolated extension ForwardDestinationSearchPolicy {
    private static func makeDestinations(
        source: DestinationSource
    ) -> [ForwardDestination] {
        let channels = source.channels
        let channelsByID = Dictionary(
            channels.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let userDestinations = makeUserDestinations(source: source)
        let channelDestinations = makeChannelDestinations(source: source)
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
        let threadDestinations = makeThreadDestinations(
            source: source,
            channelsByID: channelsByID
        )
        let orderedThreadDestinations = orderThreadDestinations(
            threadDestinations,
            channelStoreOrder: source.channelStoreOrder
        )
        let channelAndThreadDestinations = nonGroupChannelDestinations
            + orderedThreadDestinations
        return userDestinations
            + groupDirectMessageDestinations
            + channelAndThreadDestinations
    }

    private static func makeUserDestinations(
        source: DestinationSource
    ) -> [ForwardDestination] {
        let directMessagesByUserID = Dictionary(
            source.channels.compactMap { channel -> (UserID, Channel)? in
                guard channel.kind == .directMessage,
                      let user = channel.recipients.first
                else { return nil }
                return (user.id, channel)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        var seenUserIDs = Set<UserID>()
        let channelRecipients = source.includesChannelRecipientsAsUsers
            ? source.channels.flatMap(\.recipients)
            : []
        return (source.users + channelRecipients).compactMap { user in
            guard user.id != source.currentUserID,
                  !source.excludedUserIDs.contains(user.id),
                  seenUserIDs.insert(user.id).inserted
            else { return nil }
            return ForwardDestination(
                kind: .user(user, directMessage: directMessagesByUserID[user.id]),
                guild: nil,
                titleOverride: source.relationshipNicknamesByUserID[user.id]
            )
        }
    }

    private static func makeChannelDestinations(
        source: DestinationSource
    ) -> [ForwardDestination] {
        source.channels.compactMap { channel in
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
    }

    private static func makeThreadDestinations(
        source: DestinationSource,
        channelsByID: [ChannelID: Channel]
    ) -> [ForwardDestination] {
        source.threads.compactMap { thread in
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
    }

    private static func orderThreadDestinations(
        _ threadDestinations: [ForwardDestination],
        channelStoreOrder: [ChannelID]
    ) -> [ForwardDestination] {
        let parentSourceOrder = Dictionary(
            channelStoreOrder.enumerated().map { ($0.element, $0.offset) },
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
        return orderedThreadDestinations
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
                    let match = userMatch(
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
        records.compactMap { record -> RankedUser? in
            guard record.category == .user,
                  case .user(let user, _) = record.destination.kind,
                  case .user(_, let booster) = record.values
            else { return nil }
            return RankedUser(
                user: user,
                score: 10_000 * booster,
                sourceOrder: record.sourceOrder
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.sourceOrder < rhs.sourceOrder
        }.prefix(limit).map(\.user)
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
