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

    private struct RankedChannel {
        let channel: Channel
        let score: Double
        let sidebarPosition: Int
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
                return resolvedByID[message.author.id]
                    ?? Member(user: message.author, roleName: "Member", status: .offline)
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
                target: .unresolved,
                action: .chooseGame
            ))
        }
        if "time".hasPrefix(normalizedQuery) {
            results.append(MentionAutocompleteSuggestion(
                id: "special:time",
                title: "@time",
                detail: "Refer to a time dynamically in the viewer’s time zone",
                value: "@time",
                target: .unresolved,
                action: .chooseTimeFormat
            ))
        }
        return results
    }

    static func channelSuggestions(
        query: String,
        channels: [Channel],
        guilds: [GuildID: Guild],
        guildAndChannelUsageScores: [String: Int] = [:],
        currentUserID: UserID? = nil,
        currentMember: Member? = nil,
        roles: [GuildRole] = []
    ) -> [MentionAutocompleteSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalized(trimmedQuery)
        let queryTerms = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        var bestMatches: [RankedChannel] = []
        bestMatches.reserveCapacity(25)
        for channel in channels {
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
            guard isTextChannel else { continue }
            var score = channelMatchScore(
                channel: channel,
                guild: channel.guildID.flatMap { guilds[$0] },
                query: normalizedQuery,
                terms: queryTerms
            )
            if guildAndChannelUsageScores[channel.id.description, default: 0] > 0 {
                // Preserve the current client's observable precedence behavior:
                // its missing parentheses make any positive frecency value a
                // full three-point boost before the 10/7 cap is applied.
                score = min(score + 3, score >= 7 ? 10 : 7)
            }
            guard normalizedQuery.isEmpty || score > 0 else { continue }
            let candidate = RankedChannel(
                channel: channel,
                score: score,
                sidebarPosition: channel.categoryPosition * 100_000 + channel.position
            )
            let insertionIndex = bestMatches.firstIndex { isPreferred(candidate, over: $0) }
            if let insertionIndex {
                bestMatches.insert(candidate, at: insertionIndex)
                if bestMatches.count > 25 { bestMatches.removeLast() }
            } else if bestMatches.count < 25 {
                bestMatches.append(candidate)
            }
        }
        return bestMatches.map { match in
            let channel = match.channel
            return MentionAutocompleteSuggestion(
                id: "channel:\(channel.id)",
                title: channel.name,
                detail: channel.category
                    ?? channel.guildID.flatMap { guilds[$0]?.name }
                    ?? "Channel",
                value: "<#\(channel.id)>",
                target: .channel(channel.id),
                systemImage: ChannelIconPresentation.systemImage(
                    for: channel.kind,
                    isHidden: false
                )
            )
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

    private static func isPreferred(_ lhs: RankedChannel, over rhs: RankedChannel) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.sidebarPosition != rhs.sidebarPosition {
            return lhs.sidebarPosition < rhs.sidebarPosition
        }
        return lhs.channel.id < rhs.channel.id
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

    private static func channelMatchScore(
        channel: Channel,
        guild: Guild?,
        query: String,
        terms: [String]
    ) -> Double {
        guard !query.isEmpty else { return 7 }
        let name = normalized(channel.name)
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

        // Discord lets remaining terms match category or guild context, at
        // half weight, while keeping a contextual result below a direct prefix.
        if terms.count > 1 {
            let context = normalized([channel.category, guild?.name].compactMap { $0 }.joined(separator: " "))
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
