import DiscordProtocol
import Foundation
import SakuraCordModels

public extension MockChatProvider {
    func refreshAttachmentURL(_ url: URL) async throws -> URL? {
        attachmentURLRefreshRequests.append(url)
        return url
    }

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        try await messages(
            in: channelID,
            anchoredAt: before.map(MessageHistoryAnchor.before) ?? .newest,
            limit: limit
        )
    }

    func messages(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage {
        guard
            snapshot.channels.contains(where: { $0.id == channelID })
            || messagesByChannel[channelID] != nil
        else {
            throw ChatProviderError.channelNotFound
        }
        let messages = messagesByChannel[channelID] ?? []
        let boundedLimit = min(max(1, limit), 100)

        func lowerBound(for messageID: MessageID) -> Int {
            var lowerBound = messages.startIndex
            var upperBound = messages.endIndex
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                if messages[middle].id < messageID {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            return lowerBound
        }

        let pageStart: Int
        let pageEnd: Int
        switch anchor {
        case .newest:
            pageEnd = messages.endIndex
            pageStart = max(messages.startIndex, pageEnd - boundedLimit)
        case .before(let messageID):
            pageEnd = lowerBound(for: messageID)
            pageStart = max(messages.startIndex, pageEnd - boundedLimit)
        case .after(let messageID):
            let boundary = lowerBound(for: messageID)
            pageStart = messages.indices.contains(boundary)
                && messages[boundary].id == messageID
                ? boundary + 1
                : boundary
            pageEnd = min(messages.endIndex, pageStart + boundedLimit)
        case .around(let messageID):
            let target = min(lowerBound(for: messageID), messages.endIndex)
            let proposedStart = max(
                messages.startIndex,
                target - boundedLimit / 2
            )
            pageEnd = min(messages.endIndex, proposedStart + boundedLimit)
            pageStart = max(messages.startIndex, pageEnd - boundedLimit)
        }
        let page = Array(messages[pageStart ..< pageEnd])
        return MessagePage(
            messages: page,
            hasMoreBefore: pageStart > messages.startIndex,
            hasMoreAfter: pageEnd < messages.endIndex
        )
    }

    func sendTyping(in channelID: ChannelID) async throws {
        guard let channel = snapshot.channels.first(where: { $0.id == channelID }) else {
            throw ChatProviderError.channelNotFound
        }
        guard channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown else {
            throw ChatProviderError.invalidRequest("Typing is unavailable in this demo channel.")
        }
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        guard draft.attachmentURLs.count <= SendMessageDraft.maximumAttachmentCount else {
            throw ChatProviderError.invalidRequest(
                "A message can include at most \(SendMessageDraft.maximumAttachmentCount) attachments."
            )
        }
        guard
            !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachmentURLs.isEmpty || !draft.stickerIDs.isEmpty || draft.poll != nil
        else {
            throw ChatProviderError.invalidRequest("A message needs text or an attachment.")
        }
        nextMessageID += 1
        let attachments = try draft.attachments.enumerated().map { index, attachment in
            var staged = try MockChatMediaFixtures.stageAttachment(
                attachment.url,
                messageID: nextMessageID,
                index: index
            )
            let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            staged.filename =
                attachment.isSpoiler && !filename.hasPrefix(UploadFilename.spoilerPrefix)
                    ? UploadFilename.spoilerPrefix + filename : filename
            staged.description = attachment.description
            if let voiceMessage = draft.voiceMessage {
                staged.filename = VoiceMessageMetadata.filename
                staged.mediaType = "audio/ogg"
                staged.durationSeconds = voiceMessage.durationSeconds
                staged.waveform = voiceMessage.waveform
            }
            return staged
        }
        let replyPreview = draft.replyTo.flatMap { messageID in
            messagesByChannel[draft.channelID]?.first(where: { $0.id == messageID }).map {
                MessageReplyPreview(message: $0)
            }
        }
        var message = Message(
            id: MessageID(rawValue: nextMessageID), channelID: draft.channelID, author: currentUser,
            content: draft.content, replyTo: draft.replyTo, replyPreview: replyPreview,
            attachments: attachments,
            nonce: draft.nonce,
            stickers: draft.stickerIDs.map {
                MessageSticker(id: $0, name: "Demo sticker", format: .png)
            },
            mentionedUsers: draft.mentionsRepliedUser
                ? replyPreview.map { [$0.author] } ?? []
                : [],
            poll: draft.poll?.preview()
        )
        message.flags.formUnion(draft.messageFlags)
        messagesByChannel[draft.channelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        return message
    }

    func forward(_ draft: ForwardMessageDraft) async throws -> Message {
        guard snapshot.channels.contains(where: { $0.id == draft.destinationChannelID }) else {
            throw ChatProviderError.channelNotFound
        }
        guard let source = messagesByChannel[draft.sourceChannelID]?.first(where: {
            $0.id == draft.sourceMessageID
        }) else {
            throw ChatProviderError.messageNotFound
        }
        nextMessageID += 1
        let forwardedSnapshot = ForwardedMessageSnapshot(
            type: source.type,
            content: source.content,
            timestamp: source.timestamp,
            editedTimestamp: source.editedTimestamp,
            flags: source.flags,
            attachments: source.attachments,
            embeds: source.embeds,
            components: source.components,
            stickers: source.stickers,
            mentionedUsers: source.mentionedUsers,
            mentionedRoleIDs: source.mentionedRoleIDs
        )
        let message = Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: draft.destinationChannelID,
            author: currentUser,
            content: forwardedSnapshot.content,
            timestamp: .now,
            editedTimestamp: forwardedSnapshot.editedTimestamp,
            attachments: forwardedSnapshot.attachments,
            nonce: draft.nonce,
            type: forwardedSnapshot.type,
            // A silent source does not make its forward silent; only the request does.
            flags: forwardedSnapshot.flags.subtracting(.suppressNotifications)
                .union(draft.suppressesNotifications ? .suppressNotifications : []),
            guildID: snapshot.channels.first(where: {
                $0.id == draft.destinationChannelID
            })?.guildID,
            embeds: forwardedSnapshot.embeds,
            components: forwardedSnapshot.components,
            stickers: forwardedSnapshot.stickers,
            mentionedUsers: forwardedSnapshot.mentionedUsers,
            mentionedRoleIDs: forwardedSnapshot.mentionedRoleIDs,
            messageReference: DiscordMessageReference(
                type: .forward,
                messageID: draft.sourceMessageID,
                channelID: draft.sourceChannelID,
                guildID: draft.sourceGuildID
            ),
            forwardedSnapshot: forwardedSnapshot
        )
        messagesByChannel[draft.destinationChannelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        return message
    }

    func edit(_ message: Message, content: String) async throws -> Message {
        guard var messages = messagesByChannel[message.channelID],
              let index = messages.firstIndex(where: { $0.id == message.id })
        else {
            throw ChatProviderError.messageNotFound
        }
        messages[index].content = content
        messages[index].editedTimestamp = .now
        let updated = messages[index]
        messagesByChannel[message.channelID] = messages
        continuation?.yield(.messageUpdated(updated))
        return updated
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {
        guard var messages = messagesByChannel[channelID],
              let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            throw ChatProviderError.messageNotFound
        }
        messages.remove(at: index)
        messagesByChannel[channelID] = messages
        continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
    }

    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID)
        async throws
    {
        guard let message = messagesByChannel[channelID]?.first(where: { $0.id == messageID }) else {
            throw ChatProviderError.messageNotFound
        }
        let reactionID = Reaction(emoji: emoji, count: 0).id
        let reacted =
            message.reactions.first(where: { $0.id == reactionID })?.didCurrentUserReact ?? false
        try await setReaction(
            emoji,
            reacted: !reacted,
            messageID: messageID,
            channelID: channelID
        )
    }

    func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        guard var messages = messagesByChannel[channelID],
              let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            throw ChatProviderError.messageNotFound
        }
        var message = messages[index]
        let reactionID = Reaction(emoji: emoji, count: 0).id
        if let reactionIndex = message.reactions.firstIndex(where: { $0.id == reactionID }) {
            let active = message.reactions[reactionIndex].didCurrentUserReact
            guard active != reacted else { return }
            message.reactions[reactionIndex].didCurrentUserReact = reacted
            message.reactions[reactionIndex].count += reacted ? 1 : -1
            if !reacted {
                message.reactions[reactionIndex].reactors.removeAll {
                    $0.id == snapshot.currentUser.id
                }
            } else if !message.reactions[reactionIndex].reactors.contains(where: {
                $0.id == snapshot.currentUser.id
            }) {
                message.reactions[reactionIndex].reactors.append(
                    ReactionReactor(user: snapshot.currentUser)
                )
            }
            if message.reactions[reactionIndex].count == 0 {
                message.reactions.remove(at: reactionIndex)
            }
        } else if reacted {
            message.reactions.append(
                Reaction(
                    emoji: emoji,
                    count: 1,
                    didCurrentUserReact: true,
                    reactors: [ReactionReactor(user: snapshot.currentUser)]
                )
            )
        } else {
            return
        }
        messages[index] = message
        messagesByChannel[channelID] = messages
        continuation?.yield(.messageUpdated(message))
    }

    func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        guard let message = messagesByChannel[channelID]?.first(where: { $0.id == messageID }),
              let reaction = message.reactions.first(where: {
                  $0.id
                      == Reaction(
                          emoji: emoji,
                          count: reactionCount
                      ).id
              })
        else {
            throw ChatProviderError.messageNotFound
        }
        return Array(reaction.reactors.prefix(5))
    }

    func pinnedMessages(
        in channelID: ChannelID,
        before: Date?,
        limit: Int
    ) async throws -> PinnedMessagePage {
        guard snapshot.channels.contains(where: { $0.id == channelID })
                || messagesByChannel[channelID] != nil
        else { throw ChatProviderError.channelNotFound }
        let boundedLimit = min(max(limit, 1), 50)
        let values = (messagesByChannel[channelID] ?? []).compactMap { message -> PinnedMessage? in
            guard let pinnedAt = pinnedAtByMessageID[message.id],
                  before.map({ pinnedAt < $0 }) ?? true
            else { return nil }
            var pinned = message
            pinned.isPinned = true
            return PinnedMessage(pinnedAt: pinnedAt, message: pinned)
        }.sorted {
            if $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
            return $0.message.id > $1.message.id
        }
        return PinnedMessagePage(
            items: Array(values.prefix(boundedLimit)),
            hasMore: values.count > boundedLimit
        )
    }

    func setMessagePinned(
        _ isPinned: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        guard var messages = messagesByChannel[channelID],
              let index = messages.firstIndex(where: { $0.id == messageID })
        else { throw ChatProviderError.messageNotFound }
        pinMutationRequests.append(.init(
            channelID: channelID,
            messageID: messageID,
            isPinned: isPinned
        ))
        if let pinMutationFailureStatus {
            throw ChatProviderError.transport(
                status: pinMutationFailureStatus,
                requestID: nil
            )
        }
        messages[index].isPinned = isPinned
        messagesByChannel[channelID] = messages
        if isPinned {
            pinnedAtByMessageID[messageID] = .now
        } else {
            pinnedAtByMessageID[messageID] = nil
        }
        continuation?.yield(.messageUpdated(messages[index]))
    }

    func setPollAnswers(_ answerIDs: [Int], messageID: MessageID, channelID: ChannelID) async throws {
        guard let index = messagesByChannel[channelID]?.firstIndex(where: { $0.id == messageID }),
              var message = messagesByChannel[channelID]?[index], var poll = message.poll,
              !poll.isClosed(), poll.allowsMultipleAnswers || answerIDs.count <= 1,
              answerIDs.allSatisfy({ id in poll.answers.contains { $0.id == id } }) else {
            throw ChatProviderError.invalidRequest("This poll is unavailable.")
        }
        let selected = Set(answerIDs)
        for answer in poll.answers {
            let old = poll.selectedAnswerIDs.contains(answer.id)
            if old != selected.contains(answer.id) {
                poll.applyVote(answerID: answer.id, isAddition: !old, isCurrentUser: true)
            }
        }
        message.poll = poll
        messagesByChannel[channelID]?[index] = message
        continuation?.yield(.messageUpdated(message))
    }

    func reactionUsers(for emoji: String, messageID: MessageID, channelID: ChannelID, after: UserID?, limit: Int) async throws -> MessagePeoplePage {
        guard let message = messagesByChannel[channelID]?.first(where: { $0.id == messageID }),
              let reaction = message.reactions.first(where: { $0.id == Reaction(emoji: emoji, count: 0).id })
        else { throw ChatProviderError.messageNotFound }
        let users = (0 ..< max(0, reaction.count)).map { index -> User in
            if reaction.reactors.indices.contains(index) {
                let reactor = reaction.reactors[index]
                return User(id: reactor.id, username: "reactor\(index + 1)", displayName: reactor.displayName, avatarURL: reactor.avatarURL)
            }
            return User(id: UserID(rawValue: UInt64(100_000 + index)), username: "reactor\(index + 1)", displayName: "Reactor \(index + 1)")
        }.sorted { $0.id.rawValue < $1.id.rawValue }.filter { user in
            after.map { user.id.rawValue > $0.rawValue } ?? true
        }
        let limit = min(100, max(1, limit))
        return MessagePeoplePage(users: Array(users.prefix(limit)), hasMore: users.count > limit)
    }

    func pollVoters(messageID: MessageID, channelID: ChannelID, answerID: Int, after: UserID?, limit: Int) async throws -> MessagePeoplePage {
        let poll = messagesByChannel[channelID]?.first(where: { $0.id == messageID })?.poll
        return MessagePeoplePage(users: after == nil && poll?.selectedAnswerIDs.contains(answerID) == true ? [currentUser] : [], hasMore: false)
    }

    func endPoll(messageID: MessageID, channelID: ChannelID) async throws -> Message {
        guard let index = messagesByChannel[channelID]?.firstIndex(where: { $0.id == messageID }),
              var message = messagesByChannel[channelID]?[index], message.author.id == currentUser.id,
              message.poll?.isClosed() == false else { throw ChatProviderError.messageNotFound }
        message.poll?.expiry = .now
        message.poll?.results?.isFinalized = true
        messagesByChannel[channelID]?[index] = message
        continuation?.yield(.messageUpdated(message))
        return message
    }

    struct PinMutationRequest: Equatable, Sendable {
        public var channelID: ChannelID
        public var messageID: MessageID
        public var isPinned: Bool
    }
}
