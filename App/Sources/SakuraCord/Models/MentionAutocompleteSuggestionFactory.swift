import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

enum MentionAutocompleteSuggestionFactory {
    private static let resultLimit = 10

    private enum MemberMatchRank: Int {
        case none = 0
        case fuzzy = 1
        case strong = 2
    }

    private struct RankedMember {
        let storeIndex: Int
        let rank: MemberMatchRank
        let member: Member
    }

    private struct RankedCandidate {
        let suggestion: MentionAutocompleteSuggestion
        let score: Double
        let position: Int
        let id: ChannelID
        /// The parent channel of a thread or post; nil for a channel.
        let parentID: ChannelID?
    }

    private struct MemberSearchSignature: Equatable {
        let username: String
        let displayName: String
        let globalDisplayName: String?
    }

    private struct MemberSearchCacheEntry {
        let signature: MemberSearchSignature
        let candidates: [String]
    }

    private static var memberSearchCache: [UserID: MemberSearchCacheEntry] = [:]
    private static let memberSearchCacheLimit = 50_000

    static func memberHeading(query: String) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "OPTIONS" : "OPTIONS MATCHING @\(normalized.uppercased())"
    }

    static func channelHeading(query: String) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "TEXT CHANNELS" : "TEXT CHANNELS MATCHING #\(normalized.uppercased())"
    }

    static func memberSuggestions(
        query: String,
        recentMessages: [Message],
        localMembers: [Member],
        remoteMembers: [Member],
        roles: [GuildRole],
        isGuildChannel: Bool = false,
        canMentionNonMentionableRoles: Bool = false
    ) -> [MentionAutocompleteSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalized(trimmedQuery)
        // A completed opcode-8 query is the official client's narrowed result
        // set. Keep its order and do not re-introduce fuzzy local members that
        // Discord omitted. Before it arrives, the local GuildMemberStore still
        // makes the menu responsive immediately.
        let memberStore = normalizedQuery.isEmpty || remoteMembers.isEmpty
            ? mergingMemberStore(localMembers, updates: remoteMembers)
            : remoteMembers

        let orderedMembers: [Member]
        if normalizedQuery.isEmpty {
            let resolvedByID = Dictionary(
                memberStore.map { ($0.id, $0) },
                uniquingKeysWith: { _, rhs in rhs }
            )
            var seen = Set<UserID>()
            let recent = recentMessages.reversed().compactMap { message -> Member? in
                guard seen.insert(message.author.id).inserted else { return nil }
                if let member = resolvedByID[message.author.id] { return member }
                // Webhook deliveries (webhooks and app replies) only name a
                // mentionable author when that author resolved as a member:
                // webhook identities and user-installed apps never do.
                guard message.webhookID == nil || message.guildMember != nil else { return nil }
                return Member(user: message.author, roleName: "Member", status: .offline)
            }
            // Discord prefers recent channel authors for a bare @. When the
            // channel has no messages cached, its guild-member store order is
            // the fallback.
            orderedMembers = recent.isEmpty ? memberStore : recent
        } else {
            var bestMatches: [RankedMember] = []
            bestMatches.reserveCapacity(resultLimit)
            for (index, member) in memberStore.enumerated() {
                let rank = memberMatchRank(member, normalizedQuery: normalizedQuery)
                guard rank != .none else { continue }
                let candidate = RankedMember(storeIndex: index, rank: rank, member: member)
                let insertionIndex = bestMatches.firstIndex {
                    isPreferred(candidate, over: $0)
                }
                if let insertionIndex {
                    bestMatches.insert(candidate, at: insertionIndex)
                    if bestMatches.count > resultLimit {
                        bestMatches.removeLast()
                    }
                } else if bestMatches.count < resultLimit {
                    bestMatches.append(candidate)
                }
            }
            orderedMembers = bestMatches.map(\.member)
        }

        let specialSuggestions = specialSuggestions(
            normalizedQuery: normalizedQuery,
            isGuildChannel: isGuildChannel
        )
        let memberSuggestions = orderedMembers.prefix(resultLimit - specialSuggestions.count).map { member in
            let topColor = MessageAuthorPresentation.topRoleColor(in: member.roles)
            return MentionAutocompleteSuggestion(
                id: "user:\(member.id)",
                title: member.user.displayName,
                detail: "@\(member.user.username)",
                value: "<@\(member.id)>",
                target: .user(member.id),
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
                colorHex: topColor,
                member: member
            )
        }
        // Keep the first matching member as the default selection for a bare
        // @, while placing broadcasts within the visible portion of the menu.
        var values: [MentionAutocompleteSuggestion] = []
        values.append(contentsOf: memberSuggestions.prefix(1))
        values.append(contentsOf: specialSuggestions)
        values.append(contentsOf: memberSuggestions.dropFirst())

        let matchingRoles = roles.compactMap { role -> (GuildRole, Int)? in
            role.name.caseInsensitiveCompare("@everyone") != .orderedSame
                && (role.isMentionable || canMentionNonMentionableRoles)
                ? (role, roleMatchRank(name: role.name, query: trimmedQuery))
                : nil
        }.filter { _, rank in
            normalizedQuery.isEmpty || rank > 0
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let comparison = lhs.0.name.localizedCompare(rhs.0.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.0.id < rhs.0.id
        }
        let remaining = max(0, resultLimit - values.count)
        values.append(contentsOf: matchingRoles.prefix(remaining).map { role, _ in
            MentionAutocompleteSuggestion(
                id: "role:\(role.id)",
                title: "@\(role.name)",
                detail: "",
                value: "<@&\(role.id)>",
                target: .role(role.id),
                colorHex: role.colorHex
            )
        })
        return values
    }

    private static func specialSuggestions(
        normalizedQuery: String,
        isGuildChannel: Bool
    ) -> [MentionAutocompleteSuggestion] {
        let matchingBroadcasts = isGuildChannel
            ? ["everyone", "here"].filter { $0.hasPrefix(normalizedQuery) }
            : []
        var results = matchingBroadcasts.map { name in
            MentionAutocompleteSuggestion(
                id: "broadcast:\(name)",
                title: "@\(name)",
                detail: "",
                value: "@\(name)",
                target: .unresolved
            )
        }
        if "game".hasPrefix(normalizedQuery) {
            results.append(MentionAutocompleteSuggestion(
                id: "special:game",
                title: "@game",
                detail: "Mention a game",
                value: "@game",
                target: .unresolved
            ))
        }
        if "time".hasPrefix(normalizedQuery) {
            results.append(MentionAutocompleteSuggestion(
                id: "special:time",
                title: "@time",
                detail: "Refer to a time dynamically in the viewer’s time zone",
                value: "@time",
                target: .unresolved
            ))
        }
        return results
    }

    static func channelSuggestions(
        query: String,
        channels: [Channel],
        threads: [MessageThreadSummary] = [],
        guilds: [GuildID: Guild],
        guildAndChannelUsageScores: [String: Int] = [:],
        currentUserID: UserID? = nil,
        currentMember: Member? = nil,
        roles: [GuildRole] = []
    ) -> [MentionAutocompleteSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.lowercased()
        let queryTerms = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let channelsByID = threads.isEmpty ? [:] : Dictionary(
            channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var bestMatches: [RankedCandidate] = []
        bestMatches.reserveCapacity(channelSuggestionLimit)
        for channel in channels {
            let usage = guildAndChannelUsageScores[channel.id.description, default: 0]
            if let candidate = rankedChannelCandidate(
                channel: channel, guilds: guilds, usageScore: usage,
                query: normalizedQuery, terms: queryTerms
            ) {
                insertCandidate(candidate, into: &bestMatches)
            }
        }
        for thread in threads {
            let parent = thread.parentID.flatMap { channelsByID[$0] }
            let usage = guildAndChannelUsageScores[thread.id.description, default: 0]
            if let candidate = rankedThreadCandidate(
                thread: thread, parent: parent, guilds: guilds, usageScore: usage,
                query: normalizedQuery, terms: queryTerms
            ) {
                insertCandidate(candidate, into: &bestMatches)
            }
        }
        return bestMatches.map(\.suggestion)
    }

    private static func rankedChannelCandidate(
        channel: Channel,
        guilds: [GuildID: Guild],
        usageScore: Int,
        query: String,
        terms: [String]
    ) -> RankedCandidate? {
        let isTextChannel = switch channel.kind {
        case .text, .announcement, .forum: true
        case .voice, .directMessage, .groupDirectMessage, .unknown: false
        }
        // The supplied channel list is the same already-discovered store
        // used by the sidebar. Re-evaluating permissions here can hide a
        // channel that Discord supplied when the current-member snapshot
        // is still partial (and makes the picker disagree with the
        // sidebar). The comparison client's autocomplete searches that
        // channel store directly, including entries exposed by its active
        // channel-store patches.
        guard isTextChannel else { return nil }
        let guild = channel.guildID.flatMap { guilds[$0] }
        let context = [channel.category, guild?.name].compactMap { $0 }.joined(separator: " ")
        guard let score = boostedScore(
            name: channel.name, context: context, usageScore: usageScore, query: query, terms: terms
        ) else { return nil }
        return RankedCandidate(
            suggestion: MentionAutocompleteSuggestion(
                id: "channel:\(channel.id)",
                title: channel.name,
                detail: channel.category ?? guild?.name ?? "Channel",
                value: "<#\(channel.id)>",
                target: .channel(channel.id),
                systemImage: ChannelIconPresentation.systemImage(
                    for: channel.kind,
                    isHidden: false
                )
            ),
            score: score,
            position: channel.position,
            id: channel.id,
            parentID: nil
        )
    }

    private static func rankedThreadCandidate(
        thread: MessageThreadSummary,
        parent: Channel?,
        guilds: [GuildID: Guild],
        usageScore: Int,
        query: String,
        terms: [String]
    ) -> RankedCandidate? {
        let guild = (thread.guildID ?? parent?.guildID).flatMap { guilds[$0] }
        let context = [parent?.name, parent?.category, guild?.name].compactMap { $0 }.joined(separator: " ")
        guard let score = boostedScore(
            name: thread.name, context: context, usageScore: usageScore, query: query, terms: terms
        ) else { return nil }
        let isForum = parent?.kind == .forum
        let detail = parent?.name ?? guild?.name ?? "Thread"
        return RankedCandidate(
            suggestion: MentionAutocompleteSuggestion(
                id: "thread:\(thread.id)",
                title: thread.name,
                detail: detail,
                value: "<#\(thread.id)>",
                target: .channel(thread.id),
                systemImage: ChannelIconPresentation.systemImage(forThreadInForum: isForum)
            ),
            score: score,
            position: 0,
            id: thread.id,
            parentID: thread.parentID ?? thread.id
        )
    }

    /// The most rows Discord's `#` list shows, channels and threads together.
    private static let channelSuggestionLimit = 10

    /// Discord drops a non-matching channel before its frecency boost, and its
    /// missing parentheses make any positive frecency value a full three-point
    /// boost before the 10/7 cap.
    private static func boostedScore(
        name: String, context: String, usageScore: Int, query: String, terms: [String]
    ) -> Double? {
        let score = matchScore(name: name, context: context, query: query, terms: terms)
        guard query.isEmpty || score > 0 else { return nil }
        return usageScore > 0 ? min(score + 3, score >= 7 ? 10 : 7) : score
    }

    private static func insertCandidate(_ candidate: RankedCandidate, into matches: inout [RankedCandidate]) {
        if let insertionIndex = matches.firstIndex(where: { isPreferred(candidate, over: $0) }) {
            matches.insert(candidate, at: insertionIndex)
            if matches.count > channelSuggestionLimit { matches.removeLast() }
        } else if matches.count < channelSuggestionLimit {
            matches.append(candidate)
        }
    }

    private static func mergingMemberStore(_ members: [Member], updates: [Member]) -> [Member] {
        guard !updates.isEmpty else { return members }
        var result = members
        var positions = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element.id, $0.offset) })
        for update in updates {
            if let index = positions[update.id] {
                result[index] = update
            } else {
                positions[update.id] = result.count
                result.append(update)
            }
        }
        return result
    }

    private static func isPreferred(_ lhs: RankedMember, over rhs: RankedMember) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank.rawValue > rhs.rank.rawValue }
        // Discord's user comparator is stable for equal scores, so
        // GuildMemberStore insertion order is the exact tie-break.
        return lhs.storeIndex < rhs.storeIndex
    }

    private static func isPreferred(_ lhs: RankedCandidate, over rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        // On equal scores Discord lists channels before threads and posts;
        // channels by their own position (not their category's), then oldest
        // first; threads by parent channel, then oldest first.
        if (lhs.parentID == nil) != (rhs.parentID == nil) { return lhs.parentID == nil }
        if let lhsParent = lhs.parentID, let rhsParent = rhs.parentID {
            if lhsParent != rhsParent { return lhsParent < rhsParent }
        } else if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        return lhs.id < rhs.id
    }

    private static func memberMatchRank(
        _ member: Member,
        normalizedQuery: String
    ) -> MemberMatchRank {
        guard !normalizedQuery.isEmpty else { return .strong }
        if member.id.description == normalizedQuery { return .strong }
        var hasFuzzyMatch = false
        for candidate in normalizedCandidates(for: member) {
            if candidate.hasPrefix(normalizedQuery) { return .strong }
            if isOrderedSubsequence(normalizedQuery, of: candidate) {
                hasFuzzyMatch = true
            }
        }
        return hasFuzzyMatch ? .fuzzy : .none
    }

    private static func normalizedCandidates(for member: Member) -> [String] {
        let signature = MemberSearchSignature(
            username: member.user.username,
            displayName: member.user.displayName,
            globalDisplayName: member.globalDisplayName
        )
        if let cached = memberSearchCache[member.id], cached.signature == signature {
            return cached.candidates
        }

        var candidates: [String] = []
        candidates.reserveCapacity(6)
        for value in [signature.username, signature.displayName] + [signature.globalDisplayName].compactMap({ $0 }) {
            let lowered = value.lowercased()
            candidates.append(lowered)
            guard !lowered.utf8.allSatisfy({ $0 < 0x80 }) else { continue }
            let folded = normalized(value)
            if folded != lowered {
                candidates.append(folded)
            }
        }
        if memberSearchCache.count >= memberSearchCacheLimit,
           memberSearchCache[member.id] == nil
        {
            memberSearchCache.removeAll(keepingCapacity: true)
        }
        memberSearchCache[member.id] = MemberSearchCacheEntry(
            signature: signature,
            candidates: candidates
        )
        return candidates
    }

    /// Match-sorter's ranking ladder used by Discord for role autocomplete.
    private static func roleMatchRank(name: String, query: String) -> Int {
        guard !query.isEmpty else { return 1 }
        if name == query { return 7 }
        let name = normalized(name)
        let query = normalized(query)
        if name == query { return 6 }
        if name.hasPrefix(query) { return 5 }
        if name.contains(" \(query)") { return 4 }
        if name.contains(query) { return 3 }
        if query.count > 1, acronym(for: name).contains(query) { return 2 }
        return isOrderedSubsequence(query, of: name) ? 1 : 0
    }

    private static func acronym(for value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "-" })
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }

    private static func matchScore(
        name: String,
        context: String,
        query: String,
        terms: [String]
    ) -> Double {
        guard !query.isEmpty else { return 7 }
        // Discord folds case only: `cafe` reaches `café-lounge` as a letter
        // subsequence, `café` as a substring, and `cafè` matches nothing.
        let name = name.lowercased()
        var score: Double
        if name == query {
            score = 10
        } else if name.hasPrefix(query) {
            score = 7
        } else if name.contains(query) {
            score = 5
        } else if !terms.isEmpty, terms.allSatisfy({ name.contains($0) }) {
            score = 3
        } else if isOrderedSubsequence(query, of: name) {
            score = 1
        } else {
            score = 0
        }

        // Discord lets remaining terms match category, parent channel or guild context, at
        // half weight, while keeping a contextual result below a direct prefix.
        if terms.count > 1 {
            let context = context.lowercased()
            let unmatched = terms.filter { !name.contains($0) }
            if !unmatched.isEmpty, unmatched.allSatisfy({ context.contains($0) }) {
                score = min(score, 6) + 0.5 * Double(unmatched.count)
            }
        }
        return score
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func isOrderedSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var remaining = needle[...]
        for character in haystack where !remaining.isEmpty {
            if character == remaining.first { remaining.removeFirst() }
        }
        return remaining.isEmpty
    }

    private static func canView(
        _ channel: Channel,
        guild: Guild?,
        currentUserID: UserID?,
        currentMember: Member?,
        roles: [GuildRole]
    ) -> Bool {
        let viewChannel: UInt64 = 1 << 10
        guard let permissions = resolvedPermissions(
            in: channel,
            guild: guild,
            currentUserID: currentUserID,
            currentMember: currentMember,
            roles: roles
        ) else { return true }
        return permissions & viewChannel != 0
    }

    static func canMentionNonMentionableRoles(
        in channel: Channel?,
        guild: Guild? = nil,
        currentUserID: UserID?,
        currentMember: Member?,
        roles: [GuildRole]
    ) -> Bool {
        guard let channel,
              let permissions = resolvedPermissions(
                  in: channel,
                  guild: guild,
                  currentUserID: currentUserID,
                  currentMember: currentMember,
                  roles: roles
              )
        else { return false }
        let mentionEveryone: UInt64 = 1 << 17
        return permissions & mentionEveryone != 0
    }

    private static func resolvedPermissions(
        in channel: Channel,
        guild: Guild?,
        currentUserID: UserID?,
        currentMember: Member?,
        roles: [GuildRole]
    ) -> UInt64? {
        if guild?.isOwnedByCurrentUser == true { return .max }
        guard let guildID = channel.guildID,
              let currentUserID
        else { return nil }

        let memberRoleIDs: Set<String>
        if let currentMember, currentMember.id == currentUserID {
            memberRoleIDs = Set(currentMember.roles.map { $0.id.description })
        } else {
            memberRoleIDs = []
        }

        var permissions: UInt64
        if let knownPermissions = guild?.currentUserPermissions {
            // The guild list already supplies the current user's aggregate base
            // permissions, even while the member subscription is still warming.
            permissions = knownPermissions
        } else {
            guard let everyone = roles.first(where: {
                $0.id.description == guildID.description
            }), let everyonePermissions = everyone.permissions,
            currentMember?.id == currentUserID
            else { return nil }
            permissions = everyonePermissions
            for role in roles where memberRoleIDs.contains(role.id.description) {
                permissions |= role.permissions ?? 0
            }
        }
        let administrator: UInt64 = 1 << 3
        if permissions & administrator != 0 { return .max }

        let overwrites = channel.permissionOverwrites ?? []
        if let overwrite = overwrites.first(where: {
            $0.type == 0 && $0.id == guildID.description
        }) {
            permissions &= ~overwrite.deny
            permissions |= overwrite.allow
        }

        var roleAllow: UInt64 = 0
        var roleDeny: UInt64 = 0
        for overwrite in overwrites
            where overwrite.type == 0 && memberRoleIDs.contains(overwrite.id) {
            roleAllow |= overwrite.allow
            roleDeny |= overwrite.deny
        }
        permissions &= ~roleDeny
        permissions |= roleAllow

        if let overwrite = overwrites.first(where: {
            $0.type == 1 && $0.id == currentUserID.description
        }) {
            permissions &= ~overwrite.deny
            permissions |= overwrite.allow
        }
        return permissions
    }
}
