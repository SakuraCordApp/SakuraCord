import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayMessageEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        switch name {
        case "MESSAGE_POLL_VOTE_ADD", "MESSAGE_POLL_VOTE_REMOVE", "MESSAGE_POLL_VOTE_ADD_MANY":
            handlePollVoteDispatch(name: name, body: body)
        case "TYPING_START":
            await handleTypingStartDispatch(name: name, body: body)
        case "MESSAGE_REACTION_ADD":
            await handleMessageReactionAddDispatch(name: name, body: body)
        case "MESSAGE_CREATE":
            await handleMessageCreateDispatch(name: name, body: body)
        case "MESSAGE_ACK":
            await handleMessageAckDispatch(name: name, body: body)
        case "RECENT_MENTION_DELETE":
            if case let .object(values) = body,
               case let .string(rawID) = values["message_id"],
               let id = MessageID(rawID) {
                continuation?.yield(.inboxMentionDismissed(id))
            }
        case "MESSAGE_REACTION_REMOVE":
            await handleMessageReactionRemoveDispatch(name: name, body: body)
        case "MESSAGE_REACTION_REMOVE_ALL":
            await handleMessageReactionRemoveAllDispatch(name: name, body: body)
        case "MESSAGE_REACTION_REMOVE_EMOJI":
            await handleMessageReactionRemoveEmojiDispatch(name: name, body: body)
        case "MESSAGE_UPDATE":
            await handleMessageUpdateDispatch(name: name, body: body)
        case "MESSAGE_DELETE":
            await handleMessageDeleteDispatch(name: name, body: body)
        case "MESSAGE_DELETE_BULK":
            await handleMessageDeleteBulkDispatch(name: name, body: body)
        default:
            return false
        }
        return true
    }

    func handleTypingStartDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let typing = try? JSONValueDecoder().decode(TypingStartDTO.self, from: body),
              let channelID = ChannelID(typing.channelID),
              let userID = UserID(typing.userID),
              var user = DiscordTypingEventResolver.resolve(.init(
                  typing: typing,
                  userID: userID,
                  currentUser: currentUser,
                  currentStatus: presenceStatus,
                  cachedMembers: cachedMembers,
                  cachedChannels: cachedChannels.values.flatMap(\.self),
                  cachedAuthor: cachedGatewayUsersByID[typing.userID].flatMap { try? $0.domain() }
                      ?? cachedForwardSearchUsersByID[userID],
                  cachedGuildRoles: cachedGuildRoles
              ))
        else {
            gatewayLogger.debug("Ignored an unresolved or malformed typing event")
            return
        }
        if typing.guildID == nil, let nickname = cachedRelationshipNicknamesByUserID[userID] {
            user.displayName = nickname
        }
        continuation?.yield(.typing(channelID: channelID, user: user))
    }

    func handleMessageReactionAddDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let value = try? JSONValueDecoder().decode(
                GatewayMessageReactionUserDTO.self,
                from: body
            ),
            let update = value.domainUpdate(isAddition: true)
        else { return }
        applyGatewayReactionUpdate(update)
    }

    func handleMessageCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        if let dto = try? JSONValueDecoder().decode(MessageDTO.self, from: body),
           var message = try? dto.domain()
        {
            // A newly created poll starts empty; historical omitted results remain unknown.
            if message.poll != nil, message.poll?.results == nil { message.poll?.results = PollResults() }
            // Ephemeral interaction responses can omit guild_id; their channel
            // still identifies the guild that later component actions need.
            if message.guildID == nil {
                message.guildID = cachedJoinedThreads[message.channelID]?.guildID
                    ?? cachedChannels.values.lazy.flatMap(\.self)
                    .first { $0.id == message.channelID }?.guildID
            }
            attachKnownThread(to: &message)
            attachKnownStarterPreview(to: &message)
            cacheMessageSearchUsers(dto.searchIndexUsers)
            cacheForwardSearchMessageAliases([message])
            cachedMessages[message.id] = message
            continuation?.yield(.messageCreated(message))
            promotePrivateChannel(
                channelID: message.channelID,
                lastMessageID: message.id
            )
            updateForumPostForMessage(message, marksUnread: true)
        }
    }

    func handleMessageAckDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let ack = try? JSONValueDecoder().decode(GatewayMessageAckDTO.self, from: body),
              let channelID = ChannelID(ack.channelID)
        else { return }
        forumReadStates[channelID] = ForumReadState(
            lastReadMessageID: ack.messageID.flatMap(MessageID.init),
            mentionCount: ack.mentionCount ?? 0
        )
        continuation?.yield(
            .readStateChanged(
                ChannelReadState(
                    channelID: channelID,
                    lastAcknowledgedMessageID: ack.messageID.flatMap(MessageID.init),
                    mentionCount: ack.mentionCount ?? 0,
                    isManual: ack.manual ?? false,
                    flags: ack.flags,
                    lastViewed: ack.lastViewed,
                    version: ack.version
                )
            )
        )
        for (parentID, posts) in cachedForumPosts where posts[channelID] != nil {
            if let lastMessageID = posts[channelID]?.thread.lastMessageID {
                cachedForumPosts[parentID]?[channelID]?.isUnread =
                    (ack.mentionCount ?? 0) > 0
                    || (ack.messageID.flatMap(MessageID.init).map {
                        lastMessageID > $0
                    } ?? true)
            } else {
                cachedForumPosts[parentID]?[channelID]?.isUnread =
                    (ack.mentionCount ?? 0) > 0
            }
            publishForumPosts(parentID: parentID)
            break
        }
    }

    func handleMessageReactionRemoveDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let value = try? JSONValueDecoder().decode(
                GatewayMessageReactionUserDTO.self,
                from: body
            ),
            let update = value.domainUpdate(isAddition: false)
        else { return }
        applyGatewayReactionUpdate(update)
    }

    func handleMessageReactionRemoveAllDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let value = try? JSONValueDecoder().decode(
                GatewayMessageReactionRemoveAllDTO.self,
                from: body
            ),
            let update = value.domainUpdate
        else { return }
        applyGatewayReactionUpdate(update)
    }

    func handleMessageReactionRemoveEmojiDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let value = try? JSONValueDecoder().decode(
                GatewayMessageReactionRemoveEmojiDTO.self,
                from: body
            ),
            let update = value.domainUpdate
        else { return }
        applyGatewayReactionUpdate(update)
    }

    func handleMessageUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let dto = try? JSONValueDecoder().decode(MessageUpdateDTO.self, from: body),
              let messageID = MessageID(dto.id), let channelID = ChannelID(dto.channelID)
        else { return }
        if let mentions = dto.mentions?.elements { cacheMessageSearchUsers(mentions.map(\.searchIndexUser)) }
        let guildID = cachedMessages[messageID]?.guildID
            ?? cachedJoinedThreads[channelID]?.guildID
            ?? cachedForumPosts.values.lazy.compactMap { $0[channelID]?.thread.guildID }.first
            ?? cachedChannels.values.lazy.flatMap(\.self).first { $0.id == channelID }?.guildID
        guard var update = dto.domain(guildID: guildID) else { return }
        attachKnownStartedThread(to: &update)
        if var message = cachedMessages[messageID] {
            update.apply(to: &message)
            cachedMessages[messageID] = message
            continuation?.yield(.messageUpdated(message))
            updateForumPostForMessage(message)
        } else {
            continuation?.yield(.messagePatched(update))
            if let post = cachedForumPosts.values.lazy.compactMap({ $0[channelID] }).first,
               var message = [post.firstMessage, post.mostRecentMessage].compactMap({ $0 }).first(where: { $0.id == messageID }) {
                update.apply(to: &message)
                updateForumPostForMessage(message)
            }
        }
    }

    /// Preview caches outlive the message working set. Remove deleted content
    /// there too so a later catalogue publication cannot resurrect it.
    func removeDeletedForumPreview(channelID: ChannelID, messageID: MessageID) {
        for (parentID, posts) in cachedForumPosts {
            guard var post = posts[channelID] else { continue }
            var changed = false
            // A forum starter shares its post's ID.
            if messageID.rawValue == channelID.rawValue || post.firstMessage?.id == messageID {
                post.firstMessage = nil
                post.isFirstMessageLoaded = true
                changed = true
            }
            if post.mostRecentMessage?.id == messageID { post.mostRecentMessage = nil; changed = true }
            guard changed else { continue }
            cachedForumPosts[parentID]?[channelID] = post
            publishForumPosts(parentID: parentID)
        }
    }

    func handleMessageDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        if let value = try? JSONValueDecoder().decode(MessageDeleteDTO.self, from: body),
           let channelID = ChannelID(value.channelID), let messageID = MessageID(value.id)
        {
            cachedMessages[messageID] = nil
            removeDeletedForumPreview(channelID: channelID, messageID: messageID)
            continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
        }
    }

    func handleMessageDeleteBulkDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let deletion = try? JSONValueDecoder().decode(
                GatewayMessageDeleteBulkDTO.self, from: body
            ), let channelID = ChannelID(deletion.channelID)
        else { return }
        for messageID in deletion.ids.compactMap(MessageID.init) {
            cachedMessages[messageID] = nil
            removeDeletedForumPreview(channelID: channelID, messageID: messageID)
            continuation?.yield(
                .messageDeleted(channelID: channelID, messageID: messageID)
            )
        }
    }
}
