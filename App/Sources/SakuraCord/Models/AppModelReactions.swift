import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    struct ReactionMutationTiming: Sendable {
        var debounce: Duration = .milliseconds(160)
        var sleepForRateLimit: @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    }

    func edit(_ message: Message, content: String) async {
        guard !message.hasPoll, !message.flags.contains(.voiceMessage),
              guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil
        else { return }
        let session = accountSession()
        do {
            let updated = try await session.provider.edit(message, content: content)
            guard isCurrentAccountSession(session) else { return }
            invalidateMessageTranslation(updated.id, content: updated.content)
            let reconciled = reconcileVisibleOrCached(updated, updatesOnly: true)
            recordAuthoritativeMessageUpsert(reconciled)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ message: Message) async {
        let session = accountSession()
        do {
            try await session.provider.delete(
                messageID: message.id,
                channelID: message.channelID
            )
            guard isCurrentAccountSession(session) else { return }
            consumeMessageDeleted(
                channelID: message.channelID,
                messageID: message.id
            )
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func dismissEphemeralMessage(_ message: Message) {
        guard message.flags.contains(.ephemeral) else { return }
        invalidateMessageTranslation(message.id)
        if message.channelID == selectedChannelID {
            mutateSelectedMessages {
                $0.removeAll { $0.id == message.id }
            }
        }
        messageCache[message.channelID]?.removeAll { $0.id == message.id }
    }

    func toggleReaction(_ emoji: String, on message: Message) async {
        guard canUpdateReactions(on: message) else { return }
        let guildID = message.guildID ?? selectedGuildID
        let currentGuildEmojis = guildID.flatMap { emojisByGuild[$0] } ?? []
        guard
            DiscordEmojiPermissionPolicy.canToggleReaction(
                emoji,
                existingReactions: message.reactions,
                currentGuildEmojis: currentGuildEmojis,
                premiumType: snapshot?.currentUser.premiumType ?? 0
            )
        else {
            errorMessage = "Nitro is required for animated and other-server emoji reactions."
            return
        }
        guard snapshot?.currentUser.id != nil else {
            errorMessage = ChatProviderError.unauthenticated.localizedDescription
            return
        }

        let key = ReactionMutationKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: Reaction(emoji: emoji, count: 0).id
        )
        let latestMessage = reactionMessage(for: key) ?? message
        let latestReacted =
            latestMessage.reactions.first(where: { $0.id == key.reactionID })?
                .didCurrentUserReact ?? false
        var state =
            reactionMutations[key]
            ?? ReactionMutationState(
                emoji: emoji,
                confirmedReacted: latestReacted,
                desiredReacted: latestReacted,
                generation: 0,
                isSending: false
            )
        state.emoji = emoji
        state.desiredReacted.toggle()
        if state.desiredReacted { recordReactionEmojiUsage(emoji) }
        state.generation &+= 1
        reactionMutations[key] = state
        applyCurrentUserReactionState(state.desiredReacted, for: key, emoji: emoji)

        if !state.isSending {
            scheduleReactionMutation(for: key)
        }
    }

    func scheduleReactionMutation(for key: ReactionMutationKey) {
        guard let state = reactionMutations[key], !state.isSending else { return }
        let generation = state.generation
        let debounce = reactionMutationTiming.debounce
        reactionMutationTasks[key]?.cancel()
        reactionMutationTasks[key] = Task { @MainActor [weak self] in
            if debounce > .zero {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.sendReactionMutation(for: key, generation: generation)
        }
    }

    func sendReactionMutation(
        for key: ReactionMutationKey,
        generation: UInt64
    ) async {
        let session = accountSession()
        guard var state = reactionMutations[key],
              state.generation == generation,
              !state.isSending
        else { return }
        reactionMutationTasks[key] = nil
        guard state.desiredReacted != state.confirmedReacted else {
            reactionMutations[key] = nil
            return
        }

        guard guildTimeoutUntil(in: key.channelID) == nil else {
            applyCurrentUserReactionState(state.confirmedReacted, for: key, emoji: state.emoji)
            reactionMutations[key] = nil
            return
        }
        let sentState = state.desiredReacted
        state.isSending = true
        reactionMutations[key] = state
        do {
            try await session.provider.setReaction(
                state.emoji,
                reacted: sentState,
                messageID: key.messageID,
                channelID: key.channelID
            )
        } catch {
            guard isCurrentAccountSession(session) else { return }
            guard var latest = reactionMutations[key] else { return }
            if case let ChatProviderError.rateLimited(retryAfter, _) = error,
               !latest.hasRetriedRateLimit
            {
                latest.hasRetriedRateLimit = true
                reactionMutations[key] = latest
                let sleep = reactionMutationTiming.sleepForRateLimit
                // Keep this key in flight while waiting so clicks update only
                // the desired state, without restarting or bypassing cooldown.
                reactionMutationTasks[key] = Task { @MainActor [weak self] in
                    do {
                        try await sleep(.seconds(retryAfter))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          let self,
                          self.isCurrentAccountSession(session),
                          var pending = self.reactionMutations[key]
                    else { return }
                    pending.isSending = false
                    self.reactionMutations[key] = pending
                    await self.sendReactionMutation(for: key, generation: pending.generation)
                }
                return
            }
            applyCurrentUserReactionState(
                latest.confirmedReacted,
                for: key,
                emoji: latest.emoji
            )
            reactionMutations[key] = nil
            reactionMutationTasks[key] = nil
            errorMessage = error.localizedDescription
            return
        }

        guard isCurrentAccountSession(session) else { return }
        guard var latest = reactionMutations[key] else { return }
        latest.confirmedReacted = sentState
        latest.isSending = false
        latest.hasRetriedRateLimit = false
        applyCurrentUserReactionState(
            latest.desiredReacted,
            for: key,
            emoji: latest.emoji
        )
        if latest.desiredReacted == latest.confirmedReacted {
            reactionMutations[key] = nil
            reactionMutationTasks[key] = nil
            if let message = reactionMessage(for: key) {
                recordAuthoritativeMessageUpsert(message)
            }
        } else {
            reactionMutations[key] = latest
            if let message = reactionMessage(for: key) {
                recordAuthoritativeMessageUpsert(message)
            }
            scheduleReactionMutation(for: key)
        }
    }

    func reactionMessage(for key: ReactionMutationKey) -> Message? {
        messageInWorkspace(channelID: key.channelID, messageID: key.messageID)
            ?? presentedGuideResource?.messages.first { $0.id == key.messageID && $0.channelID == key.channelID }
            ?? inbox.retainedMessages.first { $0.id == key.messageID }
    }

    func knownReactionReactor(for userID: UserID) -> ReactionReactor? {
        if let member = membersByID[userID] {
            return ReactionReactor(
                id: userID,
                displayName: member.user.displayName,
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL
            )
        }
        guard currentUser?.id == userID, let user = currentUser else {
            return nil
        }
        return ReactionReactor(user: user)
    }

    func applyCurrentUserReactionState(
        _ reacted: Bool,
        for key: ReactionMutationKey,
        emoji: String
    ) {
        guard let currentUserID = snapshot?.currentUser.id else { return }
        let update: MessageReactionUpdate =
            reacted
            ? .add(
                channelID: key.channelID,
                messageID: key.messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
            : .remove(
                channelID: key.channelID,
                messageID: key.messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
        applyReactionUpdate(update, persistsResult: false)
    }

    func loadReactionReactors(_ requestedReaction: Reaction, on message: Message) async {
        guard requestedReaction.count > 0, await waitForTimelineScrollingToEnd() else { return }
        let reaction: Reaction
        if let current = retainedMessage(channelID: message.channelID, messageID: message.id) {
            guard let latest = current.reactions.first(where: { $0.id == requestedReaction.id }) else { return }
            reaction = latest
        } else {
            reaction = requestedReaction
        }
        guard reaction.count > 0,
              Set(reaction.reactors.map(\.id)).count < min(reaction.count, 5)
        else { return }
        let session = accountSession()
        let key = ReactionReactorLoadKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: reaction.id
        )
        if let task = reactionReactorLoadTasks[key] {
            await task.value
            guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
            await loadReactionReactors(reaction, on: message)
            return
        }
        // History replacements can discard the identities while preserving
        // the count. Restore the saved preview instead of fetching it again.
        if let cached = loadedReactionReactorPreviews[key], cached.count == reaction.count {
            applyReactionReactors(cached.reactors, for: key)
            return
        }
        if let failedAt = failedReactionReactorLoads[key],
           Date.now.timeIntervalSince(failedAt) < 30
        {
            return
        }
        let loadID = UUID()
        reactionReactorLoadIDs[key] = loadID
        let task = Task { @MainActor [self] in
            defer {
                if isCurrentAccountSession(session), reactionReactorLoadIDs[key] == loadID {
                    reactionReactorLoadTasks[key] = nil
                    reactionReactorLoadIDs[key] = nil
                }
            }
            do {
                let reactors = try await reactionReactorLoadLimiter.withPermit {
                    try await session.provider.reactionReactors(
                        for: reaction.emoji,
                        messageID: message.id,
                        channelID: message.channelID,
                        reactionCount: reaction.count
                    )
                }
                guard await waitForTimelineScrollingToEnd(),
                      !Task.isCancelled,
                      isCurrentAccountSession(session),
                      reactionReactorLoadIDs[key] == loadID
                else { return }
                if let current = retainedMessage(channelID: message.channelID, messageID: message.id),
                   current.reactions.first(where: { $0.id == reaction.id })?.count != reaction.count {
                    return
                }
                failedReactionReactorLoads[key] = nil
                storeReactionReactorPreview(reactors, count: reaction.count, for: key)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isCurrentAccountSession(session),
                      reactionReactorLoadIDs[key] == loadID
                else { return }
                if failedReactionReactorLoads.count >= 256,
                   let oldest = failedReactionReactorLoads.min(by: { $0.value < $1.value })?.key
                {
                    failedReactionReactorLoads[oldest] = nil
                }
                failedReactionReactorLoads[key] = .now
            }
        }
        reactionReactorLoadTasks[key] = task
        await task.value
    }

    private func storeReactionReactorPreview(_ reactors: [ReactionReactor], count: Int, for key: ReactionReactorLoadKey) {
        if loadedReactionReactorPreviews[key] == nil, loadedReactionReactorPreviews.count >= 256,
           let evictedKey = loadedReactionReactorPreviews.keys.first {
            loadedReactionReactorPreviews[evictedKey] = nil
        }
        var seen: Set<UserID> = []
        let previews = Array(reactors.filter { seen.insert($0.id).inserted }.prefix(5))
        loadedReactionReactorPreviews[key] = (count, previews)
        applyReactionReactors(previews, for: key)
    }

    /// Returns only identities already held locally; never starts a load.
    func retainedReactionReactors(for reaction: Reaction, on message: Message) -> [ReactionReactor] {
        let key = ReactionReactorLoadKey(
            channelID: message.channelID, messageID: message.id, reactionID: reaction.id
        )
        let cached = loadedReactionReactorPreviews[key]
        let saved = cached?.count == reaction.count ? cached?.reactors ?? [] : []
        var seen: Set<UserID> = []
        return Array((reaction.reactors + saved)
            .filter { seen.insert($0.id).inserted }
            .prefix(min(5, max(0, reaction.count))))
    }

    func applyReactionReactors(
        _ reactors: [ReactionReactor],
        for key: ReactionReactorLoadKey
    ) {
        var seen: Set<UserID> = []
        let normalized = reactors.filter { seen.insert($0.id).inserted }.prefix(5)

        func updating(_ values: [Message]) -> [Message] {
            guard let messageIndex = values.firstIndex(where: { $0.id == key.messageID }) else {
                return values
            }
            var result = values
            result[messageIndex] = updating(result[messageIndex])
            return result
        }

        func updating(_ message: Message) -> Message {
            guard
                let reactionIndex = message.reactions.firstIndex(where: {
                    $0.id == key.reactionID && $0.count > 0
                })
            else { return message }
            var result = message
            var seen = Set<UserID>()
            let merged =
                normalized + result.reactions[reactionIndex].reactors
            result.reactions[reactionIndex].reactors = Array(
                merged
                    .filter { seen.insert($0.id).inserted }
                    .prefix(min(5, max(0, result.reactions[reactionIndex].count)))
            )
            return result
        }

        if key.channelID == selectedChannelID {
            let updated = updating(messages)
            if updated != messages { replaceSelectedMessages(with: updated) }
        } else if var cached = messageCache[key.channelID] {
            cached = updating(cached)
            messageCache[key.channelID] = cached
        }
        if key.channelID == openThread?.id {
            threadMessages = updating(threadMessages)
        }
        if let resource = presentedGuideResource, resource.channelID == key.channelID,
           let message = resource.messages.first(where: { $0.id == key.messageID }) {
            receiveGuideResourceEvent(.messageUpdated(updating(message)))
        }
        if let message = inbox.retainedMessages.first(where: { $0.id == key.messageID }) {
            reconcileInboxMessage(updating(message))
        }
    }

    func resetReactionReactorLoads() {
        for task in reactionReactorLoadTasks.values { task.cancel() }
        reactionReactorLoadTasks = [:]
        reactionReactorLoadIDs = [:]
        loadedReactionReactorPreviews = [:]
        failedReactionReactorLoads = [:]
    }

    func clearReactionReactorLoadState(
        channelID: ChannelID,
        messageID: MessageID
    ) {
        invalidateReactionReactorPreviews(channelID: channelID, messageID: messageID)
    }

    private func invalidateReactionReactorPreviews(channelID: ChannelID, messageID: MessageID, reactionID: String? = nil) {
        func matches(_ key: ReactionReactorLoadKey) -> Bool {
            key.channelID == channelID && key.messageID == messageID
                && (reactionID == nil || key.reactionID == reactionID)
        }
        for key in reactionReactorLoadTasks.keys
        where matches(key) {
            reactionReactorLoadTasks[key]?.cancel()
        }
        loadedReactionReactorPreviews = loadedReactionReactorPreviews.filter { !matches($0.key) }
        failedReactionReactorLoads = failedReactionReactorLoads.filter { !matches($0.key) }
    }

    func clearReactionMutationState(
        channelID: ChannelID? = nil,
        messageID: MessageID? = nil
    ) {
        let keys = reactionMutations.keys.filter { key in
            (channelID == nil || key.channelID == channelID)
                && (messageID == nil || key.messageID == messageID)
        }
        for key in keys {
            reactionMutationTasks[key]?.cancel()
            reactionMutationTasks[key] = nil
            reactionMutations[key] = nil
        }
    }

    private func applyInboxReactionUpdate(_ update: MessageReactionUpdate, currentUserID: UserID?, reactor: ReactionReactor?) {
        if let message = inbox.retainedMessages.first(where: { $0.id == update.messageID }) {
            var updated = message
            if updated.applyReactionUpdate(update, currentUserID: currentUserID, reactor: reactor) {
                reconcileInboxMessage(updated)
            }
        }

    }

    func applyReactionUpdate(
        _ update: MessageReactionUpdate,
        persistsResult: Bool = true
    ) {
        // A count can return to an earlier value after removals and additions.
        // Its previous short response no longer describes the current users.
        invalidateReactionReactorPreviews(
            channelID: update.channelID, messageID: update.messageID, reactionID: update.reactionID
        )
        let currentUserID = snapshot?.currentUser.id
        let reactor: ReactionReactor? =
            switch update {
            case .add(_, _, let userID, _, _):
                knownReactionReactor(for: userID)
            case .remove, .removeAll, .removeEmoji:
                nil
            }
        var messageToPersist: Message?

        func applying(to values: inout [Message]) {
            guard
                let index = values.firstIndex(where: {
                    $0.id == update.messageID && $0.channelID == update.channelID
                })
            else {
                return
            }
            var message = values[index]
            if message.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: reactor
            ) {
                values[index] = message
            }
            messageToPersist = message
        }

        if update.channelID == selectedChannelID {
            var updated = messages
            applying(to: &updated)
            if updated != messages {
                replaceSelectedMessages(with: updated)
            }
        }
        if var cached = messageCache[update.channelID] {
            applying(to: &cached)
            messageCache[update.channelID] = cached
        }
        if update.channelID == openThread?.id {
            applying(to: &threadMessages)
        }

        applyInboxReactionUpdate(update, currentUserID: currentUserID, reactor: reactor)

        if var resourceMessages = presentedGuideResource?.messages {
            applying(to: &resourceMessages)
            if let message = resourceMessages.first(where: { $0.id == update.messageID && $0.channelID == update.channelID }) {
                receiveGuideResourceEvent(.messageUpdated(message))
            }
        }

        if let forumIndex = forumCatalogueIndexByID[update.channelID] {
            var post = forumCataloguePosts[forumIndex]
            if var firstMessage = post.firstMessage, firstMessage.id == update.messageID {
                _ = firstMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                )
                post.firstMessage = firstMessage
                messageToPersist = firstMessage
            }
            if var mostRecentMessage = post.mostRecentMessage,
               mostRecentMessage.id == update.messageID
            {
                _ = mostRecentMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                )
                post.mostRecentMessage = mostRecentMessage
                messageToPersist = mostRecentMessage
            }
            if post != forumCataloguePosts[forumIndex] {
                forumCataloguePosts[forumIndex] = post
                updateForumPresentation(with: post)
            }
        }

        if persistsResult {
            for (key, mutation) in reactionMutations
            where key.channelID == update.channelID && key.messageID == update.messageID {
                applyCurrentUserReactionState(
                    mutation.desiredReacted,
                    for: key,
                    emoji: mutation.emoji
                )
            }
            let lookupKey = ReactionMutationKey(
                channelID: update.channelID,
                messageID: update.messageID,
                reactionID: ""
            )
            messageToPersist = reactionMessage(for: lookupKey) ?? messageToPersist
        }

        if persistsResult, let messageToPersist {
            recordAuthoritativeMessageUpsert(messageToPersist)
        }
        NotificationCenter.default.post(name: .sakuracordMessageReactionDidChange, object: self, userInfo: ["update": update])
    }

}
