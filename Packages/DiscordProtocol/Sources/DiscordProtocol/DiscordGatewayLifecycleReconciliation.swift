import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func removeGuild(_ guildID: GuildID) {
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
        cachedMemberListItems[guildID] = nil
        selectedMemberListID[guildID] = nil
        memberListSubscriptions[guildID] = nil
        memberListSubscriptionOrder[guildID] = nil
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
        cachedMessages = cachedMessages.filter { !channelIDs.contains($0.value.channelID) }
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
        case 18, 20:
            cancelApplicationStreamNegotiations(
                error: ChatProviderError.invalidRequest(
                    "Discord temporarily rate limited the screen-share request."
                )
            )
        default:
            break
        }
    }

    func applyUserUpdate(dto: UserDTO, user: User) {
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
            let oldGlobalName = members[index].globalDisplayName
            let oldDisplayName = members[index].user.displayName
            var memberUser = user
            if let oldGlobalName, oldDisplayName != oldGlobalName {
                memberUser.displayName = oldDisplayName
            }
            if let guildAvatarURL = members[index].guildAvatarURL {
                memberUser.avatarURL = guildAvatarURL
            }
            members[index].user = memberUser
            members[index].globalDisplayName = user.displayName
            cachedMembers[guildID] = members
            continuation?.yield(
                .membersChanged(
                    guildID: guildID,
                    members: members,
                    groups: selectedMemberListGroups(guildID: guildID)
                )
            )
        }

        if var privateMember = cachedPrivateMembersByID[user.id] {
            privateMember.user = user
            cachedPrivateMembersByID[user.id] = privateMember
            continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
        }

        let affectedMessageIDs = cachedMessages.compactMap {
            $0.value.author.id == user.id
                || $0.value.mentionedUsers.contains(where: { $0.id == user.id })
                ? $0.key : nil
        }
        for messageID in affectedMessageIDs {
            guard var message = cachedMessages[messageID] else { continue }
            if message.author.id == user.id { message.author = user }
            for index in message.mentionedUsers.indices
            where message.mentionedUsers[index].id == user.id {
                message.mentionedUsers[index] = user
            }
            cachedMessages[messageID] = message
            continuation?.yield(.messageUpdated(message))
        }
        continuation?.yield(.currentUserChanged(user))
    }
}
