import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func removeGuild(_ guildID: GuildID) {
        resetMemberListSubscriptionWork(guildID: guildID)
        var channelIDs = Set(
            (cachedChannels[guildID] ?? []).map(\.id)
                + (cachedGuildChannelDTOs[guildID]?.keys.compactMap(ChannelID.init) ?? [])
        )
        channelIDs.formUnion(
            cachedForumPosts.values.flatMap(\.values).compactMap {
                $0.thread.guildID == guildID ? $0.id : nil
            }
        )
        cachedGuilds[guildID] = nil
        cachedGuildOnboarding[guildID] = nil
        cachedJoinedThreads = cachedJoinedThreads.filter {
            $0.value.guildID != guildID
        }
        cachedJoinedThreadOrder.removeAll {
            cachedJoinedThreads[$0] == nil
        }
        cachedForumThreadOrder.removeAll { channelIDs.contains($0) }
        cachedChannels[guildID] = nil
        cachedGuildChannelDTOs[guildID] = nil
        cachedGuildRoles[guildID] = nil
        cachedMembers[guildID] = nil
        for threadID in threadMemberSubscriptions.removeValue(forKey: guildID) ?? [] {
            cachedThreadMemberIDs[threadID] = nil
            continuation?.yield(.threadMembersChanged(guildID: guildID, threadID: threadID, members: nil))
        }
        cachedMemberListItems[guildID] = nil
        selectedMemberListID[guildID] = nil
        memberListState.memberListSubscriptions[guildID] = nil
        memberListState.memberListSubscriptionOrder[guildID] = nil
        memberListState.memberListViewportRequests[guildID] = nil
        memberListState.memberListsNeedingRefresh[guildID] = nil
        cachedMemberListGroups[guildID] = nil
        requestedHistoryMemberIDs[guildID] = nil
        resolvingHistoryMemberIDs[guildID] = nil
        cachedEmojis[guildID] = nil
        guildChannelTasks.removeValue(forKey: guildID)?.cancel()
        guildRoleTasks.removeValue(forKey: guildID)?.cancel()
        emojiTasks.removeValue(forKey: guildID)?.cancel()
        gatewayGuildIDs.removeAll { $0 == guildID }
        removeGuildFromRail(guildID)

        let forumParentIDs = cachedForumPosts.compactMap { parentID, posts in
            if channelIDs.contains(parentID)
                || posts.values.contains(where: { $0.thread.guildID == guildID })
            {
                return parentID
            }
            return nil
        }
        for parentID in forumParentIDs {
            cachedForumPosts[parentID] = nil
            forumReadStates[parentID] = nil
        }
        for channelID in channelIDs {
            forumReadStates[channelID] = nil
        }
        cachedMessages.removeAll { channelIDs.contains($0.channelID) }
        cancelPendingMemberRequests(guildID: guildID, error: CancellationError())
        publishGuildLayout()
    }

    func clearCurrentUserPermissionSnapshot(_ guildID: GuildID) {
        guard var guild = cachedGuilds[guildID], guild.currentUserPermissions != nil else {
            return
        }
        guild.currentUserPermissions = nil
        cachedGuilds[guildID] = guild
        continuation?.yield(.guildChanged(guild))
    }

    func cancelPendingMemberRequests(guildID: GuildID, error: any Error) {
        let roleRequestIDs = pendingRoleMemberRequests.compactMap {
            $0.value.guildID == guildID ? $0.key : nil
        }
        for requestID in roleRequestIDs {
            failRoleMemberRequest(requestID: requestID, error: error)
        }
        let searchRequestIDs = pendingMemberSearchRequests.compactMap {
            $0.value.guildID == guildID ? $0.key : nil
        }
        for requestID in searchRequestIDs {
            failMemberSearchRequest(requestID: requestID, error: error)
        }
    }

    func failGatewayRequests(rateLimited rateLimit: GatewayRateLimitedDTO) {
        switch rateLimit.opcode {
        case 8:
            let error = ChatProviderError.invalidRequest(
                "Discord rate limited the Gateway member request."
            )
            if let guildID = rateLimit.metadata?.guildID.flatMap(GuildID.init) {
                cancelPendingMemberRequests(guildID: guildID, error: error)
            } else {
                cancelPendingMemberRequests(error: error)
            }
        case 37:
            // A socket send completing does not mean Discord accepted its
            // subscription. The opcode cooldown is shared; without guild
            // metadata any retained selected subscription may have been refused.
            let guildIDs = rateLimit.metadata?.guildID.flatMap(GuildID.init)
                .map { [$0] } ?? Array(Set(memberListState.memberListSubscriptions.keys)
                    .union(memberListState.memberListViewportRequests.keys).union(memberListInFlightRequests.keys))
            for guildID in guildIDs {
                var memberListIDs = Set(memberListState.memberListSubscriptions[guildID].map { Array($0.keys) } ?? [])
                if let viewport = memberListState.memberListViewportRequests[guildID] {
                    memberListIDs.insert(viewport.memberListID)
                }
                if let inFlight = memberListInFlightRequests[guildID] {
                    memberListIDs.insert(inFlight.memberListID)
                }
                for memberListID in memberListIDs where !memberListSubscriptionsForRefresh(
                    guildID: guildID, memberListID: memberListID
                ).isEmpty {
                    markMemberListForRefresh(
                        guildID: guildID, memberListID: memberListID, resetRetryBudget: false
                    )
                }
                scheduleMemberListRefreshRetry(guildID: guildID)
            }
        case 18, 20:
            cancelApplicationStreamNegotiations(
                error: ChatProviderError.invalidRequest(
                    "Discord temporarily rate limited the screen-share request."
                )
            )
        case 31:
            let error = ChatProviderError.invalidRequest(
                "Discord rate limited the Gateway soundboard request."
            )
            for requestID in Array(pendingSoundboardRequests.keys) {
                failSoundboardRequest(requestID, error: error)
            }
        default:
            break
        }
    }

    func applyUserUpdate(dto: UserDTO, user: User) {
        var user = user
        if dto.nsfwAllowed == nil { user.allowsAdultContent = currentUser?.allowsAdultContent }
        cacheGatewayUser(dto)
        currentUser = user

        if var channels = cachedChannels[nil] {
            var changed = false
            for channelIndex in channels.indices {
                for recipientIndex in channels[channelIndex].recipients.indices
                where channels[channelIndex].recipients[recipientIndex].id == user.id {
                    channels[channelIndex].recipients[recipientIndex] = user
                    changed = true
                }
            }
            if changed {
                cachedChannels[nil] = channels
                continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
            }
        }

        for guildID in cachedMembers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var members = cachedMembers[guildID],
                  let index = members.firstIndex(where: { $0.id == user.id })
            else { continue }
            members[index].applyGlobalProfileUser(user)
            cachedMembers[guildID] = members
            publishMembers(
                guildID: guildID,
                members: members,
                groups: selectedMemberListGroups(guildID: guildID)
            )
        }

        if var privateMember = cachedPrivateMembersByID[user.id] {
            privateMember.user = user
            cachedPrivateMembersByID[user.id] = privateMember
            continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
        }

        let affectedMessageIDs = cachedMessages.values.compactMap {
            $0.author.id == user.id
                || $0.mentionedUsers.contains(where: { $0.id == user.id })
                ? $0.id : nil
        }
        for messageID in affectedMessageIDs {
            guard var message = cachedMessages[messageID] else { continue }
            message.applyIdentityUpdate(user)
            cachedMessages[messageID] = message
        }
        // Retained forum previews have a lifetime independent of the message
        // working set, just like the app's visible conversations.
        for (parentID, posts) in cachedForumPosts {
            for (channelID, var post) in posts {
                post.firstMessage?.applyIdentityUpdate(user)
                post.mostRecentMessage?.applyIdentityUpdate(user)
                cachedForumPosts[parentID]?[channelID] = post
            }
        }
        continuation?.yield(.currentUserChanged(user))
    }
}
