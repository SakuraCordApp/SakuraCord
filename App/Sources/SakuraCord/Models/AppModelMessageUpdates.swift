import SakuraCordModels

extension AppModel {
    func invalidateChangedSystemMessageRecipients(replacing previous: BootstrapSnapshot?) {
        func recipients(in snapshot: BootstrapSnapshot?) -> [ChannelID: User] {
            var result: [ChannelID: User] = [:]
            for channel in snapshot?.channels ?? [] where channel.kind == .directMessage {
                result[channel.id] = channel.recipients.first { $0.id != snapshot?.currentUser.id }
            }
            return result
        }

        let oldRecipients = recipients(in: previous)
        let newRecipients = recipients(in: snapshot)
        let changedChannels = Set(oldRecipients.keys).union(newRecipients.keys).filter {
            oldRecipients[$0]?.id != newRecipients[$0]?.id
                || oldRecipients[$0]?.displayName != newRecipients[$0]?.displayName
        }
        guard !changedChannels.isEmpty,
              retainedMessages.contains(where: {
                  $0.type == .friendRequestAccepted && changedChannels.contains($0.channelID)
              }) else { return }
        // Include retained off-screen layouts and supplementary message surfaces.
        invalidateTimelinePresentation()
    }

    func applyingMessageUpdate(_ update: MessageUpdate) -> Message? {
        guard var message = retainedMessage(channelID: update.channelID, messageID: update.messageID) else { return nil }
        update.apply(to: &message)
        return message
    }

    /// The workspace copy, or one retained by a supplementary message surface.
    func retainedMessage(channelID: ChannelID, messageID: MessageID) -> Message? {
        if let message = messageInWorkspace(channelID: channelID, messageID: messageID) { return message }
        if let resource = presentedGuideResource, resource.channelID == channelID,
           let message = resource.messages.first(where: { $0.id == messageID }) { return message }
        if let pinned = pinnedMessages.items.first(where: { $0.id == messageID })?.message { return pinned }
        if let search = messageSearch.page?.results.lazy.flatMap(\.messages).first(where: { $0.id == messageID && $0.channelID == channelID }) {
            return search
        }
        return inbox.retainedMessages.first { $0.id == messageID }
    }

    /// Snapshot the retained surfaces for events that must find affected messages.
    var retainedMessages: [Message] {
        messages + threadMessages + messageCache.values.flatMap { $0 }
            + pinnedMessages.items.map(\.message)
            + (presentedGuideResource?.messages ?? [])
            + Array(inbox.retainedMessages)
            + (messageSearch.page?.results.flatMap(\.messages) ?? [])
            + forumCataloguePosts.flatMap { [$0.firstMessage, $0.mostRecentMessage].compactMap { $0 } }
    }

    func reconcileRetainedMessageIdentities(_ user: User) {
        // Pages still being prepared have no retained message IDs yet. Keep
        // identity changes at conversation scope until their refresh commits.
        inbox.refreshJournal?.recordIdentityUpdate(user)
        for channelID in conversationRefreshJournals.keys {
            conversationRefreshJournals[channelID]?.recordIdentityUpdate(user)
        }
        for guildID in onboarding.guides.keys where onboarding.guides[guildID]?.resource?.refreshJournal != nil {
            onboarding.guides[guildID]?.resource?.refreshJournal?.recordIdentityUpdate(user)
        }
        var seen = Set<MessageID>()
        for message in retainedMessages where seen.insert(message.id).inserted {
            guard message.author.id == user.id || message.mentionedUsers.contains(where: { $0.id == user.id }) else { continue }
            var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
            update.updatedUsers[user.id] = user
            consumeImmediately(.messagePatched(update))
        }
    }

    func messageInWorkspace(channelID: ChannelID, messageID: MessageID) -> Message? {
        if channelID == selectedChannelID,
           let index = selectedMessageIndex(for: messageID),
           messages.indices.contains(index)
        {
            return messages[index]
        }
        if channelID == openThread?.id,
           let message = threadMessages.first(where: { $0.id == messageID })
        {
            return message
        }
        if let message = messageCache[channelID]?.first(where: { $0.id == messageID }) {
            return message
        }
        if let forumIndex = forumCatalogueIndexByID[channelID] {
            let post = forumCataloguePosts[forumIndex]
            if post.firstMessage?.id == messageID {
                return post.firstMessage
            }
            if post.mostRecentMessage?.id == messageID {
                return post.mostRecentMessage
            }
        }
        return nil
    }
}
