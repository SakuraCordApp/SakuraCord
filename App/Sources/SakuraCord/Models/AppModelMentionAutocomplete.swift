import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// The people, roles, channels and threads an `@` or `#` typed in the
    /// selected channel's editors can mention. Only member queries read
    /// `recentMessages`.
    func mentionAutocompleteSuggestions(
        for context: MentionAutocompleteContext,
        recentMessages: @autoclosure () -> [Message]
    ) -> [MentionAutocompleteSuggestion] {
        let currentMember = (currentUser?.id).flatMap { membersByID[$0] }
        switch context.kind {
        case .member:
            return MentionAutocompleteSuggestionFactory.memberSuggestions(
                query: context.query,
                recentMessages: recentMessages(),
                localMembers: mentionAutocompleteMembers.filter { !isUserIgnored($0.id) },
                remoteMembers: mentionMemberResults.filter { !isUserIgnored($0.id) },
                roles: guildRoles,
                isGuildChannel: selectedChannel?.guildID != nil,
                canMentionNonMentionableRoles: MentionAutocompleteSuggestionFactory.canMentionNonMentionableRoles(
                    in: selectedChannel,
                    guild: selectedGuildID.flatMap { serverRailGuildsByID[$0] },
                    currentUserID: currentUser?.id,
                    currentMember: currentMember,
                    roles: guildRoles
                )
            )
        case .channel:
            return MentionAutocompleteSuggestionFactory.channelSuggestions(
                query: context.query,
                channels: visibleChannels.filter { !hiddenChannelIDs.contains($0.id) },
                threads: mentionAutocompleteThreads,
                guilds: serverRailGuildsByID,
                guildAndChannelUsageScores: discordGuildAndChannelUsageScores,
                currentUserID: currentUser?.id,
                currentMember: currentMember,
                roles: guildRoles
            )
        }
    }

    func requestMentionMemberSearch(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guildID = selectedGuildID, !normalized.isEmpty else {
            mentionMemberSearchTask?.cancel()
            mentionMemberSearchTask = nil
            mentionMemberSearchQuery = nil
            mentionMemberResults = []
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = mentionMemberSearchCache[key],
           Date().timeIntervalSince(cached.storedAt) < 60
        {
            mentionMemberSearchTask?.cancel()
            mentionMemberSearchTask = nil
            mentionMemberSearchQuery = nil
            mentionMemberResults = cached.members
            return
        }
        mentionMemberSearchCache[key] = nil
        guard mentionMemberSearchQuery != key else { return }
        mentionMemberSearchTask?.cancel()
        mentionMemberSearchQuery = key
        mentionMemberResults = []
        let session = accountSession()
        mentionMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                let results = try await session.provider.searchMembers(
                    in: guildID, query: key.query, limit: 10
                )
                let roles = try? await session.provider.roles(in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      mentionMemberSearchQuery == key,
                      selectedGuildID == guildID
                else { return }
                if let roles { applyGuildRoles(roles, to: guildID) }
                mentionMemberSearchCache[key] = MentionMemberSearchCacheEntry(
                    members: results,
                    storedAt: Date()
                )
                mentionMemberResults = results
                mergeMentionAutocompleteMembers(results)
                for member in results { knownMentionMembers[member.id] = member }
                mentionMemberSearchQuery = nil
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAccountSession(session),
                      mentionMemberSearchQuery == key
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                mentionMemberSearchQuery = nil
                mentionMemberResults = []
            }
        }
    }

    func rememberMentionMember(_ member: Member) {
        knownMentionMembers[member.id] = member
    }

    func mergeMentionAutocompleteMembers(_ updates: [Member]) {
        guard !updates.isEmpty else { return }
        mentionAutocompleteMembers = MentionAutocompleteSuggestionFactory.mergingMemberStore(
            mentionAutocompleteMembers, updates: updates
        )
    }

    func showMembers(withRole roleID: RoleID, in guildID: GuildID?) {
        roleMemberTask?.cancel()
        roleMemberResult = nil
        roleMemberErrorMessage = nil
        isLoadingRoleMembers = false
        guard let guildID else {
            roleMemberErrorMessage = "Role members are only available inside a server."
            return
        }
        isLoadingRoleMembers = true
        let session = accountSession()
        roleMemberTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.provider.members(withRole: roleID, in: guildID)
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                roleMemberResult = result
                for member in result.members {
                    membersByGuildID[guildID, default: [:]][member.id] = member
                    if selectedGuildID == guildID { knownMentionMembers[member.id] = member }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session)
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                roleMemberErrorMessage = error.localizedDescription
            }
            if isCurrentAccountSession(session) {
                isLoadingRoleMembers = false
            }
        }
    }
}
