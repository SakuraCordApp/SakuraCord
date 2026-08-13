import SakuraCordModels

nonisolated enum QuickSwitcherQueryMode: Character, CaseIterable, Sendable {
    case user = "@"
    case textChannel = "#"
    case voiceChannel = "!"
    case guild = "*"

    var heading: String {
        switch self {
        case .user: "Direct Messages"
        case .textChannel: "Text Channels"
        case .voiceChannel: "Voice Channels"
        case .guild: "Servers"
        }
    }
}

nonisolated struct QuickSwitcherParsedQuery: Equatable, Sendable {
    let rawValue: String
    let searchValue: String
    let mode: QuickSwitcherQueryMode?

    init(_ value: String) {
        rawValue = value
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first,
           let mode = QuickSwitcherQueryMode(rawValue: first)
        {
            self.mode = mode
            searchValue = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            mode = nil
            searchValue = trimmed
        }
    }
}

nonisolated enum QuickSwitcherResultID: Hashable, Sendable {
    case heading(String)
    case destination(ForwardDestinationID)
    case guild(GuildID)
    case navigation(String)
}

nonisolated enum QuickSwitcherSelectionPolicy {
    static func synchronized(
        current: QuickSwitcherResultID?,
        selectableIDs: [QuickSwitcherResultID],
        preservesCurrent: Bool
    ) -> QuickSwitcherResultID? {
        guard preservesCurrent,
              let current,
              selectableIDs.contains(current)
        else { return selectableIDs.first }
        return current
    }

    static func moved(
        current: QuickSwitcherResultID?,
        selectableIDs: [QuickSwitcherResultID],
        delta: Int
    ) -> QuickSwitcherResultID? {
        guard !selectableIDs.isEmpty else { return nil }
        let currentIndex = current.flatMap { selectableIDs.firstIndex(of: $0) } ?? -1
        let next = (currentIndex + delta + selectableIDs.count) % selectableIDs.count
        return selectableIDs[next]
    }
}

nonisolated struct QuickSwitcherNavigationDestination: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let searchAliases: [String]

    static let discordDefaults = [
        QuickSwitcherNavigationDestination(
            id: "SETTINGS", title: "Settings",
            searchAliases: ["Settings"]
        ),
    ]
}

nonisolated enum QuickSwitcherResult: Identifiable, Equatable, Sendable {
    case heading(id: String, title: String)
    case destination(ForwardDestination)
    case guild(Guild)
    case navigation(QuickSwitcherNavigationDestination)

    var id: QuickSwitcherResultID {
        switch self {
        case .heading(let id, _): .heading(id)
        case .destination(let destination): .destination(destination.id)
        case .guild(let guild): .guild(guild.id)
        case .navigation(let navigation): .navigation(navigation.id)
        }
    }

    var isSelectable: Bool {
        if case .heading = self { return false }
        return true
    }
}

nonisolated struct QuickSwitcherSearchContext: Sendable {
    let index: ForwardDestinationSearchPolicy.Index
    let userIndex: ForwardDestinationSearchPolicy.Index
    let guilds: [Guild]
    let usageScores: [String: Int]
    let history: [ChannelID]
    let currentChannelID: ChannelID?
    let currentGuildID: GuildID?
    let currentUserID: UserID?
    let searchableUserIDs: Set<UserID>?
    let friendUserIDs: Set<UserID>
    let currentGuildMemberIDs: Set<UserID>
    let currentGuildLiveMemberIDs: Set<UserID>
    let unreadChannelIDs: Set<ChannelID>
    let mutedChannelIDs: Set<ChannelID>
    let mentionedChannelIDs: [ChannelID]
    let draftChannelIDs: [ChannelID]
    let recentlyTalkedUserIDs: [UserID]
}

nonisolated enum QuickSwitcherSearchPolicy {
    private struct RankedResult {
        let result: QuickSwitcherResult
        let score: Double
        let comparator: String?
        let stableOrder: Int
    }

    private struct RankedGuild {
        let guild: Guild
        let score: Double
        let sourceOrder: Int
    }

    static func results(
        query: String,
        context: QuickSwitcherSearchContext
    ) -> [QuickSwitcherResult] {
        let parsed = QuickSwitcherParsedQuery(query)
        if parsed.searchValue.isEmpty {
            return emptyResults(mode: parsed.mode, context: context)
        }

        let limit = parsed.mode == nil ? 5 : 100
        switch parsed.mode {
        case .user:
            let allowed = context.friendUserIDs.union(context.currentGuildMemberIDs)
                .intersection(
                    context.searchableUserIDs
                        ?? context.friendUserIDs.union(context.currentGuildMemberIDs)
                )
            let rows = context.userIndex.scoredResults(
                query: parsed.searchValue,
                categories: [.user],
                limitPerCategory: 100,
                requiresDestinationEligibility: false,
                allowedUserIDs: allowed
            ).filter { row in
                guard case .user(let user, _) = row.destination.kind else { return false }
                return user.id != context.currentUserID
            }.prefix(limit).map { QuickSwitcherResult.destination($0.destination) }
            return modeSection(
                mode: .user,
                title: context.guilds.first(where: { $0.id == context.currentGuildID })?.name,
                rows: Array(rows)
            )
        case .textChannel:
            let rows = channelResults(
                index: context.index,
                query: parsed.searchValue,
                categories: [.selectableChannel],
                limit: limit,
                includesVoice: true,
                onlyVoice: false
            )
            return modeSection(mode: .textChannel, rows: rows)
        case .voiceChannel:
            let rows = channelResults(
                index: context.index,
                query: parsed.searchValue,
                categories: [.voiceChannel],
                limit: limit,
                includesVoice: true,
                onlyVoice: true
            )
            return modeSection(mode: .voiceChannel, rows: rows)
        case .guild:
            return modeSection(
                mode: .guild,
                rows: rankedGuilds(
                    context.guilds,
                    query: parsed.searchValue,
                    usageScores: context.usageScores,
                    maximumUsageScore: context.index.maximumResolvableUsageScore,
                    excluding: context.currentGuildID,
                    limit: limit
                ).map(QuickSwitcherResult.guild)
            )
        case nil:
            return generalResults(query: parsed.searchValue, context: context, limit: limit)
        }
    }

    private static func generalResults(
        query: String,
        context: QuickSwitcherSearchContext,
        limit: Int
    ) -> [QuickSwitcherResult] {
        let maximumUsage = context.index.maximumResolvableUsageScore
        func destinationRows(
            categories: Set<ForwardDestinationSearchPolicy.ResultCategory>,
            limit: Int
        ) -> [(ForwardDestinationSearchPolicy.ScoredResult, RankedResult)] {
            let nonUserCategories = categories.subtracting([.user])
            let nonUsers = nonUserCategories.isEmpty ? [] : context.index.scoredResults(
                query: query,
                categories: nonUserCategories,
                limitPerCategory: limit,
                requiresDestinationEligibility: false,
                allowedUserIDs: context.searchableUserIDs
            )
            let users = categories.contains(.user) ? context.userIndex.scoredResults(
                query: query,
                categories: [.user],
                limitPerCategory: limit,
                requiresDestinationEligibility: false,
                allowedUserIDs: context.searchableUserIDs
            ) : []
            return (nonUsers + users).compactMap { row in
                guard row.destination.userID != context.currentUserID else { return nil }
                return (row, RankedResult(
                    result: .destination(row.destination),
                    score: row.score,
                    comparator: row.comparator,
                    stableOrder: row.stableOrder
                ))
            }
        }
        func guildRows(limit: Int) -> [RankedResult] {
            context.guilds.enumerated().compactMap { offset, guild -> RankedResult? in
                guard guild.id != context.currentGuildID else { return nil }
                let score = ForwardDestinationSearchPolicy.guildSearchScore(
                    name: guild.name,
                    query: query,
                    usageScore: context.usageScores[guild.id.description, default: 0],
                    maximumUsageScore: maximumUsage
                )
                guard score > 0 else { return nil }
                return RankedResult(
                    result: .guild(guild),
                    score: score,
                    comparator: nil,
                    stableOrder: 3 * limit + offset
                )
            }.sorted(by: ranksBefore).prefix(limit).map { $0 }
        }

        let initialCategories: Set<ForwardDestinationSearchPolicy.ResultCategory> = [
            .user, .groupDirectMessage, .selectableChannel,
        ]
        var destinations = destinationRows(categories: initialCategories, limit: limit)
        var guilds = guildRows(limit: limit)
        var navigation: [RankedResult] = []
        for (offset, item) in QuickSwitcherNavigationDestination.discordDefaults.enumerated() {
            let score = item.searchAliases.map {
                ForwardDestinationSearchPolicy.guildSearchScore(
                    name: $0,
                    query: query,
                    usageScore: 0,
                    maximumUsageScore: maximumUsage
                )
            }.max() ?? 0
            guard score > 0 else { continue }
            navigation.append(RankedResult(
                result: .navigation(item),
                score: score,
                comparator: nil,
                stableOrder: 7 * limit + offset
            ))
        }

        let populatedDestinationCategories = Set(destinations.map { $0.0.category })
        let populatedCategoryCount = populatedDestinationCategories.count
            + (guilds.isEmpty ? 0 : 1)
            + (navigation.isEmpty ? 0 : 1)
        if populatedCategoryCount == 1 {
            if let category = populatedDestinationCategories.first {
                destinations = destinationRows(categories: [category], limit: 100)
            } else if !guilds.isEmpty {
                guilds = guildRows(limit: 100)
            }
        }

        let ranked = destinations.map(\.1) + guilds + navigation
        return ranked.sorted(by: ranksBefore).map(\.result)
    }

    private static func channelResults(
        index: ForwardDestinationSearchPolicy.Index,
        query: String,
        categories: Set<ForwardDestinationSearchPolicy.ResultCategory>,
        limit: Int,
        includesVoice: Bool,
        onlyVoice: Bool
    ) -> [QuickSwitcherResult] {
        return index.scoredResults(
            query: query,
            categories: categories,
            limitPerCategory: limit,
            requiresDestinationEligibility: false
        ).lazy.filter { row in
            (includesVoice || !isVoice(row.destination))
                && (!onlyVoice || isVoice(row.destination))
        }.prefix(limit).map { .destination($0.destination) }
    }

    private static func emptyResults(
        mode: QuickSwitcherQueryMode?,
        context: QuickSwitcherSearchContext
    ) -> [QuickSwitcherResult] {
        if let mode {
            switch mode {
            case .user:
                let destinationsByUser = Dictionary(
                    context.index.destinations.compactMap { destination in
                        destination.userID.map { ($0, destination) }
                    },
                    uniquingKeysWith: { existing, _ in existing }
                )
                let rows = context.recentlyTalkedUserIDs.compactMap {
                    destinationsByUser[$0]
                }.filter {
                    guard case .user(let user, _) = $0.kind else { return false }
                    return user.id != context.currentUserID
                        && (context.currentGuildID == nil
                            || context.currentGuildLiveMemberIDs.contains(user.id))
                }
                return modeSection(
                    mode: mode,
                    title: context.guilds.first(where: { $0.id == context.currentGuildID })?.name,
                    rows: rows.map(QuickSwitcherResult.destination)
                )
            case .textChannel, .voiceChannel:
                let onlyVoice = mode == .voiceChannel
                let rows: [QuickSwitcherResult]
                if onlyVoice {
                    rows = context.index.destinations.filter { destination in
                        destination.guild?.id == context.currentGuildID
                            && isVoice(destination)
                    }.map(QuickSwitcherResult.destination)
                } else {
                    rows = context.index.unqueriedTextChannelResults(
                        currentGuildID: context.currentGuildID,
                        limit: 100
                    ).map { .destination($0.destination) }
                }
                return modeSection(mode: mode, rows: rows)
            case .guild:
                return modeSection(
                    mode: mode,
                    rows: rankedGuilds(
                        context.guilds,
                        query: "",
                        usageScores: context.usageScores,
                        maximumUsageScore: context.index.maximumResolvableUsageScore,
                        limit: 100
                    ).map(QuickSwitcherResult.guild)
                )
            }
        }

        let destinationsByChannel = Dictionary(
            context.index.destinations.compactMap { destination in
                destination.resolvedChannelID.map { ($0, destination) }
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let historyRows = context.history.compactMap { destinationsByChannel[$0] }
            .filter { $0.resolvedChannelID != context.currentChannelID }
        let protectedHistoryIDs = Set(historyRows.prefix(3).compactMap(\.resolvedChannelID))
        var seen = protectedHistoryIDs
        if let currentChannelID = context.currentChannelID { seen.insert(currentChannelID) }

        func sectionRows(_ ids: [ChannelID]) -> [ForwardDestination] {
            ids.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                return destinationsByChannel[id]
            }
        }

        let drafts = sectionRows(context.draftChannelIDs)
        let mentions = sectionRows(Array(context.mentionedChannelIDs.reversed()))
        let unread = sectionRows(context.index.destinations.compactMap { destination in
            guard destination.guild?.id == context.currentGuildID,
                  let id = destination.resolvedChannelID,
                  context.unreadChannelIDs.contains(id),
                  !context.mutedChannelIDs.contains(id)
            else { return nil }
            return id
        })
        let hasOtherSections = !drafts.isEmpty || !mentions.isEmpty || !unread.isEmpty
        var output = section(
            id: "previous",
            title: "Previous Channels",
            rows: Array(historyRows.prefix(hasOtherSections ? 3 : 7)).map(
                QuickSwitcherResult.destination
            )
        )
        output += section(id: "drafts", title: "Drafts", rows: drafts.map(QuickSwitcherResult.destination))
        output += section(id: "mentions", title: "Mentions", rows: mentions.map(QuickSwitcherResult.destination))
        output += section(id: "unread", title: "Unread Channels", rows: unread.map(QuickSwitcherResult.destination))
        return output
    }

    private static func rankedGuilds(
        _ guilds: [Guild],
        query: String,
        usageScores: [String: Int],
        maximumUsageScore: Int,
        excluding excludedGuildID: GuildID? = nil,
        limit: Int
    ) -> [Guild] {
        if query.isEmpty {
            return Array(guilds.lazy.filter {
                $0.id != excludedGuildID
            }.prefix(limit))
        }
        return guilds.enumerated().compactMap { offset, guild -> RankedGuild? in
            guard guild.id != excludedGuildID else { return nil }
            let usage = usageScores[guild.id.description, default: 0]
            let score = ForwardDestinationSearchPolicy.guildSearchScore(
                name: guild.name,
                query: query,
                usageScore: usage,
                maximumUsageScore: maximumUsageScore
            )
            guard score > 0 else { return nil }
            return RankedGuild(
                guild: guild,
                score: score,
                sourceOrder: offset
            )
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.sourceOrder < $1.sourceOrder
        }.prefix(limit).map(\.guild)
    }

    private static func modeSection(
        mode: QuickSwitcherQueryMode,
        title: String? = nil,
        rows: [QuickSwitcherResult]
    ) -> [QuickSwitcherResult] {
        [.heading(id: "mode-\(mode.rawValue)", title: title ?? mode.heading)] + rows
    }

    private static func section(
        id: String,
        title: String,
        rows: [QuickSwitcherResult]
    ) -> [QuickSwitcherResult] {
        rows.isEmpty ? [] : [.heading(id: id, title: title)] + rows
    }

    private static func isVoice(_ destination: ForwardDestination) -> Bool {
        guard case .channel(let channel) = destination.kind else { return false }
        return channel.kind == .voice
    }

    private static func ranksBefore(
        _ lhs: RankedResult,
        _ rhs: RankedResult
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if let left = lhs.comparator,
           let right = rhs.comparator,
           left != right
        {
            return left.utf16.lexicographicallyPrecedes(right.utf16)
        }
        return lhs.stableOrder < rhs.stableOrder
    }

}
