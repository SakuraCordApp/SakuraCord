import Foundation
import SakuraCordModels

struct GatewayFeatureMapping {
    var kind: GatewayFeatureEvent.Kind
    var operation: GatewayFeatureEvent.Operation
}

extension DiscordRESTProvider {
    static let gatewayFeatureMappings: [String: GatewayFeatureMapping] = [
        "GUILD_SOUNDBOARD_SOUND_CREATE": .init(kind: .soundboard, operation: .create),
        "GUILD_SOUNDBOARDS_SOUND_CREATE": .init(kind: .soundboard, operation: .create),
        "GUILD_SOUNDBOARD_SOUND_UPDATE": .init(kind: .soundboard, operation: .update),
        "GUILD_SOUNDBOARDS_SOUND_UPDATE": .init(kind: .soundboard, operation: .update),
        "GUILD_SOUNDBOARD_SOUND_DELETE": .init(kind: .soundboard, operation: .delete),
        "GUILD_SOUNDBOARDS_SOUND_DELETE": .init(kind: .soundboard, operation: .delete),
        "GUILD_SOUNDBOARD_SOUNDS_UPDATE": .init(kind: .soundboard, operation: .replace),
        "SOUNDBOARD_SOUNDS": .init(kind: .soundboard, operation: .replace),
        "GUILD_SCHEDULED_EVENT_CREATE": .init(kind: .scheduledEvent, operation: .create),
        "GUILD_SCHEDULED_EVENT_UPDATE": .init(kind: .scheduledEvent, operation: .update),
        "GUILD_SCHEDULED_EVENT_DELETE": .init(kind: .scheduledEvent, operation: .delete),
        "GUILD_SCHEDULED_EVENT_USER_ADD": .init(kind: .scheduledEvent, operation: .add),
        "GUILD_SCHEDULED_EVENT_USER_REMOVE": .init(kind: .scheduledEvent, operation: .remove),
        "GUILD_SCHEDULED_EVENT_EXCEPTION_CREATE": .init(kind: .scheduledEvent, operation: .create),
        "GUILD_SCHEDULED_EVENT_EXCEPTION_UPDATE": .init(kind: .scheduledEvent, operation: .update),
        "GUILD_SCHEDULED_EVENT_EXCEPTION_DELETE": .init(kind: .scheduledEvent, operation: .delete),
        "GUILD_SCHEDULED_EVENT_EXCEPTIONS_DELETE": .init(kind: .scheduledEvent, operation: .delete),
        "STAGE_INSTANCE_CREATE": .init(kind: .stageInstance, operation: .create),
        "STAGE_INSTANCE_UPDATE": .init(kind: .stageInstance, operation: .update),
        "STAGE_INSTANCE_DELETE": .init(kind: .stageInstance, operation: .delete),
        "MESSAGE_POLL_VOTE_ADD": .init(kind: .pollVote, operation: .add),
        "MESSAGE_POLL_VOTE_REMOVE": .init(kind: .pollVote, operation: .remove),
        "INTEGRATION_CREATE": .init(kind: .integration, operation: .create),
        "INTEGRATION_UPDATE": .init(kind: .integration, operation: .update),
        "INTEGRATION_DELETE": .init(kind: .integration, operation: .delete),
        "GUILD_INTEGRATIONS_UPDATE": .init(kind: .integration, operation: .replace),
        "WEBHOOKS_UPDATE": .init(kind: .webhook, operation: .update),
        "AUTO_MODERATION_RULE_CREATE": .init(kind: .autoModeration, operation: .create),
        "AUTO_MODERATION_RULE_UPDATE": .init(kind: .autoModeration, operation: .update),
        "AUTO_MODERATION_RULE_DELETE": .init(kind: .autoModeration, operation: .delete),
        "AUTO_MODERATION_ACTION_EXECUTION": .init(kind: .autoModeration, operation: .execute),
        "AUTO_MODERATION_MENTION_RAID_DETECTION": .init(kind: .autoModeration, operation: .execute),
        "ENTITLEMENT_CREATE": .init(kind: .entitlement, operation: .create),
        "ENTITLEMENT_UPDATE": .init(kind: .entitlement, operation: .update),
        "ENTITLEMENT_DELETE": .init(kind: .entitlement, operation: .delete),
        "SUBSCRIPTION_CREATE": .init(kind: .subscription, operation: .create),
        "SUBSCRIPTION_UPDATE": .init(kind: .subscription, operation: .update),
        "SUBSCRIPTION_DELETE": .init(kind: .subscription, operation: .delete),
    ]

    static func gatewayFeatureMapping(for eventName: String) -> GatewayFeatureMapping? {
        gatewayFeatureMappings[eventName]
    }

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
        cachedChannels[guildID] = nil
        cachedGuildChannelDTOs[guildID] = nil
        cachedGuildRoles[guildID] = nil
        cachedGuildStickers[guildID] = nil
        cachedMembers[guildID] = nil
        cachedMemberListItems[guildID] = nil
        cachedMemberListGroups[guildID] = nil
        requestedHistoryMemberIDs[guildID] = nil
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
        guard rateLimit.opcode == 8 else { return }
        let error = ChatProviderError.invalidRequest(
            "Discord rate limited the Gateway member request."
        )
        if let guildID = rateLimit.metadata?.guildID.flatMap(GuildID.init) {
            cancelPendingMemberRequests(guildID: guildID, error: error)
        } else {
            cancelPendingMemberRequests(error: error)
        }
    }

    func applyUserUpdate(dto: UserDTO, user: User) {
        cachedGatewayUsersByID[dto.id] = dto
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
                    groups: cachedMemberListGroups[guildID] ?? []
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
