import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayMemberEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        switch name {
        case "GUILD_MEMBER_LIST_UPDATE":
            await handleGuildMemberListUpdateDispatch(name: name, body: body)
        case "GUILD_MEMBERS_CHUNK":
            await handleGuildMembersChunkDispatch(name: name, body: body)
        case "GUILD_MEMBER_ADD", "GUILD_MEMBER_UPDATE":
            await handleGuildMemberAddDispatch(name: name, body: body)
        case "GUILD_MEMBER_REMOVE":
            await handleGuildMemberRemoveDispatch(name: name, body: body)
        case "USER_UPDATE":
            await handleUserUpdateDispatch(name: name, body: body)
        case "PRESENCE_UPDATE":
            await handlePresenceUpdateDispatch(name: name, body: body)
        default:
            return false
        }
        return true
    }

    func handleGuildMemberListUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(GuildMemberListUpdateDTO.self, from: body),
              let guildID = GuildID(update.guildID)
        else {
            gatewayLogger.error("Member-list update could not be decoded")
            return
        }
        let syncItemCount = update.ops.reduce(0) { $0 + ($1.items?.count ?? 0) }
        if syncItemCount > 0 {
            gatewayLogger.info("Member-list range synchronized; items=\(syncItemCount)")
        }
        // Discord's UserSearchManager deliberately does not subscribe to
        // GUILD_MEMBER_LIST_UPDATE. These members remain available to the
        // visible member list and nickname store, but must not leak into
        // the account-wide Forward user-search index.
        applyMemberListOperations(
            update.ops, guildID: guildID, memberListID: update.id
        )
        if let groups = update.groups {
            cachedMemberListGroups[guildID, default: [:]][update.id] = groups.map {
                GuildMemberListGroup(id: $0.id, count: $0.count)
            }
        }
        let changedUserIDs = Self.memberListChangedUserIDs(in: update.ops)
        let members = decodedMemberListMembers(
            guildID: guildID,
            memberListID: update.id,
            restrictingTo: changedUserIDs
        )
        cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
            existing: cachedMembers[guildID] ?? [], updates: members
        )
        publishUserSearchAliases()
        if guildID == pendingMemberGuildID,
           update.id == selectedMemberListID[guildID]
        {
            publishMembers(
                guildID: guildID,
                members: orderedMemberListMembers(guildID: guildID) ?? members,
                groups: cachedMemberListGroups[guildID]?[update.id] ?? []
            )
        }
    }

    func handleGuildMembersChunkDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let chunk = try? JSONValueDecoder().decode(GatewayGuildMembersChunkDTO.self, from: body),
            let guildID = GuildID(chunk.guildID)
        else { return }
        let guildRoles = cachedGuildRoles[guildID] ?? []
        let guildRoleCatalog = GuildMemberRoleCatalog(guildRoles)
        let decodedMembers = chunk.members.compactMap {
            try? $0.domain(
                currentUserID: currentUser?.id,
                currentStatus: presenceStatus,
                guildRoles: guildRoles,
                guildRoleCatalog: guildRoleCatalog,
                guildID: guildID
            )
        }
        let responseUserIDs = Set(decodedMembers.map(\.id)).union(
            (chunk.notFound ?? []).compactMap(UserID.init)
        )
        let roleMemberRequestID = pendingRoleMemberRequestID(
            guildID: guildID,
            responseUserIDs: responseUserIDs
        )
        if roleMemberRequestID == nil {
            // Discord's SearchContextManager handles unsolicited and
            // search-driven GUILD_MEMBERS_CHUNK_BATCH users. SakuraCord
            // also issues private member-resolution requests solely to
            // hydrate timeline presentation; those extra requests must
            // not expand message-search UserStore beyond Discord's live
            // source set.
            cacheLiveSearchUsers(chunk.members.map(\.user))
        } else {
            for member in chunk.members {
                cacheGatewayUser(member.user, messageSearchEligible: false)
            }
        }
        let joinedUserIDs = Set<UserID>(chunk.members.compactMap { member -> UserID? in
            guard member.joinedAt != nil, member.pending != true else { return nil }
            return UserID(member.user.id)
        })
        mergeResolvedMembers(
            decodedMembers, guildID: guildID, joinedUserIDs: joinedUserIDs
        )
        // The first-party SearchContext worker records membership from
        // every GUILD_MEMBERS_CHUNK_BATCH result. Keep this index separate
        // from the bounded visible-member cache so @ searches can filter
        // a newly resolved user immediately within this live connection.
        quickSwitcherGuildMemberUserIDsByGuildID[guildID, default: []]
            .formUnion(decodedMembers.map(\.id))
        publishUserSearchAliases()
        if let requestID = roleMemberRequestID,
           var request = pendingRoleMemberRequests[requestID]
        {
            request.members.append(contentsOf: decodedMembers)
            request.receivedChunks.insert(chunk.chunkIndex)
            if request.receivedChunks.count >= max(1, chunk.chunkCount) {
                pendingRoleMemberRequests[requestID] = nil
                request.timeoutTask.cancel()
                request.continuation.resume(returning: request.members)
            } else {
                pendingRoleMemberRequests[requestID] = request
            }
            return
        }

        guard let requestID = pendingMemberSearchRequestByGuild[guildID],
              var search = pendingMemberSearchRequests[requestID]
        else {
            return
        }
        search.members.append(contentsOf: decodedMembers)
        search.receivedChunks.insert(chunk.chunkIndex)
        if search.receivedChunks.count >= max(1, chunk.chunkCount) {
            _ = removeMemberSearchRequest(requestID: requestID)
            search.timeoutTask.cancel()
            let responseMembers = Array(search.members.prefix(search.maximumResults))
            mergeResolvedMembers(responseMembers, guildID: guildID)
            let members = DiscordMemberStoreOrdering.searchResults(
                in: cachedMembers[guildID] ?? [],
                matching: responseMembers,
                limit: search.maximumResults
            )
            search.continuation.resume(returning: members)
        } else {
            pendingMemberSearchRequests[requestID] = search
        }
    }

    func handleGuildMemberAddDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let update = try? JSONValueDecoder().decode(
                GatewayGuildMemberEventDTO.self, from: body
            ), let guildID = GuildID(update.guildID),
            var member = try? update.member.domain(
                currentUserID: currentUser?.id,
                currentStatus: presenceStatus,
                guildRoles: cachedGuildRoles[guildID] ?? [],
                guildID: guildID
            )
        else { return }
        let previousMember = cachedMembers[guildID]?.first { $0.id == member.id }
        // An omitted timeout leaves the prior value intact; explicit null ends it.
        if name == "GUILD_MEMBER_UPDATE", case let .object(fields) = body,
           fields["communication_disabled_until"] == nil {
            member.communicationDisabledUntil = previousMember?.communicationDisabledUntil
        }
        let membershipAdded = quickSwitcherGuildMemberUserIDsByGuildID[guildID, default: []].insert(member.id).inserted
        let wasJoined = quickSwitcherJoinedMemberIDsByGuildID[guildID]?.contains(member.id) == true
        if update.member.joinedAt != nil, member.isPending != true {
            quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                .insert(member.id)
        } else {
            quickSwitcherJoinedMemberIDsByGuildID[guildID]?.remove(member.id)
        }
        cacheLiveSearchUsers([update.member.user])
        publishMemberChange(member, guildID: guildID)
        if name == "GUILD_MEMBER_UPDATE" { invalidateGatewayProfile(for: member.id) }
        let isJoined = quickSwitcherJoinedMemberIDsByGuildID[guildID]?.contains(member.id) == true
        // A global profile edit fans out to every guild. Avatar-only updates
        // do not change the account-wide membership or nickname indexes.
        if previousMember == nil || membershipAdded || wasJoined != isJoined
            || forwardSearchNickname(from: previousMember) != forwardSearchNickname(from: member) {
            publishUserSearchAliases()
            scheduleForwardSearchPeopleCachePersistence()
        }
    }

    func handleGuildMemberRemoveDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let deletion = try? JSONValueDecoder().decode(
                GatewayGuildMemberRemoveDTO.self, from: body
            ), let guildID = GuildID(deletion.guildID),
            let userID = UserID(deletion.user.id)
        else { return }
        quickSwitcherGuildMemberUserIDsByGuildID[guildID]?.remove(userID)
        quickSwitcherJoinedMemberIDsByGuildID[guildID]?.remove(userID)
        removeMember(userID: userID, guildID: guildID)
        publishUserSearchAliases()
        scheduleForwardSearchPeopleCachePersistence()
    }

    func handleUserUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let dto = try? JSONValueDecoder().decode(UserDTO.self, from: body),
              let user = try? dto.domain()
        else { return }
        if user.id == currentUser?.id,
           let details = try? JSONValueDecoder().decode(DiscordAccountDetailsDTO.self, from: body) {
            currentAccountDetails = details.domain(merging: currentAccountDetails)
        }
        applyUserUpdate(dto: dto, user: user)
        invalidateGatewayProfile(for: user.id)
    }

    func handlePresenceUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(PresenceUpdateDTO.self, from: body)
        else { return }
        if update.guildID == nil {
            cachePrivatePresence(update)
            continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
            if let userID = UserID(update.user.id) {
                publishRelationshipPresences(complete: false, userIDs: [userID])
            }
            return
        }
        guard let guildID = update.guildID.flatMap(GuildID.init),
              let userID = UserID(update.user.id),
              let status = PresenceStatus(rawValue: update.status),
              var members = cachedMembers[guildID],
              let index = members.firstIndex(where: { $0.id == userID })
        else { return }
        members[index].status = status
        if let clientStatus = update.clientStatus {
            members[index].isMobileOnly = clientStatus.isMobileOnly
        }
        if let activities = update.activities {
            let primaryActivity = activities.memberListActivity
            members[index].customStatus = activities.first(where: { $0.type == 4 })?.displayText
            members[index].activityText =
                primaryActivity?.displayText
                    ?? members[index].customStatus
            members[index].isListeningToMusic = primaryActivity?.type == 2
        }
        cachedMembers[guildID] = members
        if guildID == pendingMemberGuildID {
            publishMembers(
                guildID: guildID,
                members: orderedMemberListMembers(guildID: guildID) ?? members,
                groups: selectedMemberListGroups(guildID: guildID)
            )
        }
    }
}
