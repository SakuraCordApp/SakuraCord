import CoreAudio
import DiscordProtocol
import Foundation
import MediaPipeline
import OSLog
import SakuraCordModels
import SakuraCordPersistence
import UniformTypeIdentifiers

enum ConversationRefreshMutation {
    case upsert(Message)
    case delete
}

struct ConversationRefreshJournal {
    let revision: UInt64
    var mutationsByMessageID: [MessageID: ConversationRefreshMutation] = [:]
}

extension AppModel {
    func beginConversationRefresh(in channelID: ChannelID) -> UInt64 {
        conversationRefreshJournalRevision &+= 1
        let revision = conversationRefreshJournalRevision
        conversationRefreshJournals[channelID] = ConversationRefreshJournal(
            revision: revision
        )
        return revision
    }

    func recordConversationRefreshMutation(
        _ mutation: ConversationRefreshMutation,
        messageID: MessageID,
        channelID: ChannelID
    ) {
        guard var journal = conversationRefreshJournals[channelID] else { return }
        journal.mutationsByMessageID[messageID] = mutation
        conversationRefreshJournals[channelID] = journal
    }

    func conversationRefreshMutations(
        in channelID: ChannelID,
        revision: UInt64
    ) -> [MessageID: ConversationRefreshMutation] {
        guard let journal = conversationRefreshJournals[channelID],
              journal.revision == revision
        else { return [:] }
        return journal.mutationsByMessageID
    }

    func endConversationRefresh(
        in channelID: ChannelID,
        revision: UInt64
    ) {
        guard conversationRefreshJournals[channelID]?.revision == revision else {
            return
        }
        conversationRefreshJournals[channelID] = nil
    }

    func cancelConversationRefresh(in channelID: ChannelID) {
        conversationRefreshJournals[channelID] = nil
    }

    @discardableResult
    func journalAuthoritativeMessageUpsert(_ message: Message) -> Message {
        let persistedMessage = reactionConfirmedSnapshot(message)
        recordConversationRefreshMutation(
            .upsert(persistedMessage),
            messageID: persistedMessage.id,
            channelID: persistedMessage.channelID
        )
        return persistedMessage
    }

    func recordAuthoritativeMessageUpsert(_ message: Message) {
        journalAuthoritativeMessageUpsert(message)
    }

    func edit(_ message: Message, content: String) async {
        guard !presentsCachedStartup else { return }
        let session = accountSession()
        do {
            let updated = try await session.provider.edit(
                messageID: message.id, channelID: message.channelID, content: content
            )
            guard isCurrentAccountSession(session) else { return }
            let reconciled = reconcileVisibleOrCached(updated)
            recordAuthoritativeMessageUpsert(reconciled)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ message: Message) async {
        guard !presentsCachedStartup else { return }
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
        if message.channelID == selectedChannelID {
            mutateSelectedMessages {
                $0.removeAll { $0.id == message.id }
            }
        }
        messageCache[message.channelID]?.removeAll { $0.id == message.id }
    }

    func toggleReaction(_ emoji: String, on message: Message) async {
        guard !presentsCachedStartup else { return }
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
        guard !presentsCachedStartup else { return }
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
            guard let latest = reactionMutations[key] else { return }
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
        if key.channelID == selectedChannelID,
           let index = selectedMessageIndex(for: key.messageID),
           messages.indices.contains(index)
        {
            return messages[index]
        }
        if key.channelID == openThread?.id,
           let message = threadMessages.first(where: { $0.id == key.messageID })
        {
            return message
        }
        if let message = messageCache[key.channelID]?.first(where: { $0.id == key.messageID }) {
            return message
        }
        if let forumIndex = forumCatalogueIndexByID[key.channelID] {
            let post = forumCataloguePosts[forumIndex]
            if post.firstMessage?.id == key.messageID {
                return post.firstMessage
            }
            if post.mostRecentMessage?.id == key.messageID {
                return post.mostRecentMessage
            }
        }
        return nil
    }

    func knownReactionReactor(for userID: UserID) -> ReactionReactor? {
        if let member = membersByID[userID] {
            return ReactionReactor(
                id: userID,
                displayName: member.user.displayName,
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL
            )
        }
        guard snapshot?.currentUser.id == userID, let user = snapshot?.currentUser else {
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

    func loadReactionReactors(_ reaction: Reaction, on message: Message) async {
        guard reaction.count > 0, reaction.reactors.isEmpty else { return }
        guard await waitForTimelineScrollingToEnd() else { return }
        let session = accountSession()
        let key = ReactionReactorLoadKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: reaction.id
        )
        if let failedAt = failedReactionReactorLoads[key],
           Date.now.timeIntervalSince(failedAt) < 30
        {
            return
        }
        guard loadingReactionReactors.insert(key).inserted else { return }
        defer {
            if isCurrentAccountSession(session) {
                loadingReactionReactors.remove(key)
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
                  isCurrentAccountSession(session)
            else { return }
            failedReactionReactorLoads[key] = nil
            applyReactionReactors(reactors, for: key)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccountSession(session) else { return }
            if failedReactionReactorLoads.count >= 256,
               let oldest = failedReactionReactorLoads.min(by: { $0.value < $1.value })?.key
            {
                failedReactionReactorLoads[oldest] = nil
            }
            failedReactionReactorLoads[key] = .now
        }
    }

    func reportTimelineLiveScrolling(
        _ isScrolling: Bool,
        conversationID: ChannelID
    ) {
        let wasScrolling = !liveScrollingConversationIDs.isEmpty
        if isScrolling {
            liveScrollingConversationIDs.insert(conversationID)
        } else {
            liveScrollingConversationIDs.remove(conversationID)
        }
        let isScrollingNow = !liveScrollingConversationIDs.isEmpty
        guard wasScrolling != isScrollingNow else { return }
        timelineScrollActivityRevision &+= 1
        let revision = timelineScrollActivityRevision
        Task {
            await SharedAnimatedImageDecodeScheduler.shared
                .setInteractiveScrolling(
                    isScrollingNow,
                    revision: revision
                )
        }
        if !isScrollingNow {
            flushUnreadPresentationRefresh()
        }
    }

    func waitForTimelineScrollingToEnd() async -> Bool {
        while !liveScrollingConversationIDs.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    func resetTimelineLiveScrolling() {
        liveScrollingConversationIDs.removeAll(keepingCapacity: true)
        timelineScrollActivityRevision &+= 1
        let revision = timelineScrollActivityRevision
        Task {
            await SharedAnimatedImageDecodeScheduler.shared
                .setInteractiveScrolling(
                    false,
                    revision: revision
                )
        }
        flushUnreadPresentationRefresh()
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
            replaceSelectedMessages(with: updating(messages))
        } else if var cached = messageCache[key.channelID] {
            cached = updating(cached)
            messageCache[key.channelID] = cached
        }
        if key.channelID == openThread?.id {
            threadMessages = updating(threadMessages)
        }

        guard let forumIndex = forumCatalogueIndexByID[key.channelID] else { return }
        var forumPost = forumCataloguePosts[forumIndex]
        if let firstMessage = forumPost.firstMessage {
            forumPost.firstMessage = updating(firstMessage)
        }
        if let mostRecentMessage = forumPost.mostRecentMessage {
            forumPost.mostRecentMessage = updating(mostRecentMessage)
        }
        guard forumPost != forumCataloguePosts[forumIndex] else { return }
        forumCataloguePosts[forumIndex] = forumPost
        updateForumPresentation(with: forumPost)
    }

    func clearReactionReactorLoadState(
        channelID: ChannelID,
        messageID: MessageID
    ) {
        loadingReactionReactors = Set(
            loadingReactionReactors.filter {
                $0.channelID != channelID || $0.messageID != messageID
            })
        failedReactionReactorLoads = failedReactionReactorLoads.filter {
            $0.key.channelID != channelID || $0.key.messageID != messageID
        }
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

    func applyReactionUpdate(
        _ update: MessageReactionUpdate,
        persistsResult: Bool = true
    ) {
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

        if let forumIndex = forumCatalogueIndexByID[update.channelID] {
            var post = forumCataloguePosts[forumIndex]
            if var firstMessage = post.firstMessage, firstMessage.id == update.messageID {
                if firstMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                ) {
                    post.firstMessage = firstMessage
                }
                messageToPersist = firstMessage
            }
            if var mostRecentMessage = post.mostRecentMessage,
               mostRecentMessage.id == update.messageID
            {
                if mostRecentMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                ) {
                    post.mostRecentMessage = mostRecentMessage
                }
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
    }

    func updateStatus(_ status: PresenceStatus) async {
        guard !presentsCachedStartup else { return }
        let session = accountSession()
        do {
            try await session.provider.updateStatus(status)
            guard isCurrentAccountSession(session) else { return }
            currentStatus = status
            members = members.map { member in
                guard member.user.id == snapshot?.currentUser.id else { return member }
                var updatedMember = member
                updatedMember.status = status
                return updatedMember
            }
        } catch {
            guard isCurrentAccountSession(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func joinVoice(_ channel: Channel) async {
        guard !presentsCachedStartup else { return }
        guard canJoinVoice(channel) else { return }
        if activeVoiceChannel?.id == channel.id,
           voiceSessionState == .connected || voiceSessionState == .connecting
        {
            return
        }
        let account = accountSession()
        await leaveVoice(account: account)
        guard isCurrentAccountSession(account) else { return }
        voiceMigrationGeneration &+= 1
        let voiceGeneration = voiceMigrationGeneration
        activeVoiceChannel = channel
        reconcilePrivateCallSounds()
        voiceSessionState = .connecting
        voiceErrorMessage = nil
        do {
            let info = try await account.provider.joinVoice(
                channelID: channel.id,
                guildID: channel.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened
            )
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            try await startVoiceSession(
                with: info,
                account: account,
                generation: voiceGeneration
            )
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            soundPlayer.play(.userJoin)
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            let failedSession = voiceSession
            voiceEventTask?.cancel()
            voiceEventTask = nil
            await failedSession?.disconnect()
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            voiceSessionState = .failed
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            try? await account.provider.updateVoiceState(
                channelID: nil,
                guildID: channel.guildID,
                selfMute: false,
                selfDeaf: false,
                selfVideo: false
            )
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            activeVoiceChannel = nil
            if voiceSession === failedSession {
                voiceSession = nil
            }
            reconcilePrivateCallSounds()
        }
    }

    func startPrivateCall(in channel: Channel, withVideo: Bool = false) async {
        guard !presentsCachedStartup else { return }
        guard channel.kind == .directMessage || channel.kind == .groupDirectMessage,
              !channel.isOfficialSystemDirectMessage
        else { return }

        await performPrivateCallAction(in: channel.id) { generation in
            await self.startPrivateCall(
                in: channel,
                withVideo: withVideo,
                generation: generation
            )
        }
    }

    func startPrivateCall(
        in channel: Channel,
        withVideo: Bool,
        generation: UInt64
    ) async {
        let session = accountSession()
        if privateCall(in: channel.id) != nil {
            await joinPrivateCall(
                in: channel,
                withVideo: withVideo,
                generation: generation
            )
            return
        }

        do {
            try await session.provider.subscribeToPrivateCall(channelID: channel.id)
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            let shouldRing: Bool
            if channel.kind == .groupDirectMessage {
                shouldRing = true
            } else {
                shouldRing = try await session.provider.privateCallIsRingable(
                    channelID: channel.id
                )
            }
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            await completePrivateCallStart(
                in: channel,
                withVideo: withVideo,
                shouldRing: shouldRing,
                generation: generation
            )
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: channel.id,
                      generation: generation
                  )
            else { return }
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func completePrivateCallStart(
        in channel: Channel,
        withVideo: Bool,
        shouldRing: Bool,
        generation: UInt64
    ) async {
        let session = accountSession()
        await joinVoice(channel)
        guard isCurrentPrivateCallAction(
            channelID: channel.id,
            generation: generation
        ),
              activeVoiceChannel?.id == channel.id,
              voiceSessionState == .connected,
              isCurrentAccountSession(session)
        else { return }
        if withVideo, !isCameraEnabled {
            await toggleCamera()
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
        }
        guard shouldRing else { return }
        beginLocalOutgoingPrivateCallRing(channelID: channel.id)
        do {
            try await session.provider.ringPrivateCall(
                channelID: channel.id,
                recipients: nil
            )
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: channel.id,
                      generation: generation
                  )
            else { return }
            endLocalOutgoingPrivateCallRing(channelID: channel.id)
            // Joining succeeded and is not replayed. Surface the bounded
            // ring failure without turning it into a second call action.
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func joinPrivateCall(in channel: Channel, withVideo: Bool = false) async {
        guard !presentsCachedStartup else { return }
        guard channel.kind == .directMessage || channel.kind == .groupDirectMessage,
              !channel.isOfficialSystemDirectMessage
        else { return }

        await performPrivateCallAction(in: channel.id) { generation in
            await self.joinPrivateCall(
                in: channel,
                withVideo: withVideo,
                generation: generation
            )
        }
    }

    func joinPrivateCall(
        in channel: Channel,
        withVideo: Bool,
        generation: UInt64
    ) async {
        let session = accountSession()
        do {
            try await session.provider.subscribeToPrivateCall(channelID: channel.id)
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            await joinVoice(channel)
            if isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ),
               isCurrentAccountSession(session),
               withVideo,
               activeVoiceChannel?.id == channel.id,
               voiceSessionState == .connected,
               !isCameraEnabled
            {
                await toggleCamera()
            }
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: channel.id,
                      generation: generation
                  )
            else { return }
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func acceptPrivateCall(_ call: PrivateCall) async {
        guard !presentsCachedStartup else { return }
        guard let channel = snapshot?.channels.first(where: { $0.id == call.channelID })
                ?? visibleChannels.first(where: { $0.id == call.channelID })
        else { return }

        await performPrivateCallAction(in: call.channelID) { generation in
            if self.selectedChannelID != channel.id {
                self.selectedGuildID = nil
                self.selectedChannelID = channel.id
            }
            await self.joinPrivateCall(
                in: channel,
                withVideo: false,
                generation: generation
            )
        }
    }

    func declinePrivateCall(_ call: PrivateCall) async {
        guard !presentsCachedStartup else { return }
        guard let currentUserID = snapshot?.currentUser.id else { return }
        await performPrivateCallAction(in: call.channelID) { generation in
            await self.declinePrivateCall(
                call,
                currentUserID: currentUserID,
                generation: generation
            )
        }
    }

    func declinePrivateCall(
        _ call: PrivateCall,
        currentUserID: UserID,
        generation: UInt64
    ) async {
        let session = accountSession()
        do {
            try await session.provider.stopRingingPrivateCall(
                channelID: call.channelID,
                recipients: [currentUserID]
            )
            guard isCurrentPrivateCallAction(
                channelID: call.channelID,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            if var updated = privateCallsByChannel[call.channelID] {
                updated.ongoingRings.removeAll { $0.recipientID == currentUserID }
                privateCallsByChannel[call.channelID] = updated
                reconcilePrivateCallSounds()
            }
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: call.channelID,
                      generation: generation
                  )
            else { return }
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func performPrivateCallAction(
        in channelID: ChannelID,
        operation: (UInt64) async -> Void
    ) async {
        guard privateCallActionChannelIDs.insert(channelID).inserted else {
            return
        }
        let generation = privateCallActionGeneration
        defer {
            if generation == privateCallActionGeneration {
                privateCallActionChannelIDs.remove(channelID)
            }
        }
        await operation(generation)
    }

    func isCurrentPrivateCallAction(
        channelID: ChannelID,
        generation: UInt64
    ) -> Bool {
        generation == privateCallActionGeneration
            && privateCallActionChannelIDs.contains(channelID)
    }

    func resetPrivateCallActions() {
        privateCallActionGeneration &+= 1
        privateCallActionChannelIDs = []
    }

    func isCurrentVoiceOperation(
        _ account: AppModelAccountSession,
        generation: Int,
        channelID: ChannelID
    ) -> Bool {
        isCurrentAccountSession(account)
            && generation == voiceMigrationGeneration
            && activeVoiceChannel?.id == channelID
    }

    func isCurrentVoiceOperation(
        _ account: AppModelAccountSession,
        generation: Int,
        voiceSession expectedSession: DiscordVoiceSession?
    ) -> Bool {
        guard isCurrentAccountSession(account),
              generation == voiceMigrationGeneration
        else { return false }
        if let expectedSession {
            return voiceSession === expectedSession
        }
        return voiceSession == nil
    }

    func reconcilePrivateCallVoiceState(_ state: VoiceParticipantState) {
        for (channelID, var call) in privateCallsByChannel {
            var states = call.voiceStates ?? []
            let originalStates = states
            states.removeAll { $0.userID == state.userID }
            if channelID == state.channelID {
                states.append(state)
            }
            guard states != originalStates else { continue }
            call.voiceStates = states
            privateCallsByChannel[channelID] = call
        }
    }

    func beginLocalOutgoingPrivateCallRing(channelID: ChannelID) {
        locallyStartedOutgoingPrivateCallRings.insert(channelID)
        outgoingPrivateCallRingTimeoutTasks[channelID]?.cancel()
        outgoingPrivateCallRingTimeoutTasks[channelID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(45))
            } catch {
                return
            }
            self?.endLocalOutgoingPrivateCallRing(channelID: channelID)
        }
        reconcilePrivateCallSounds()
    }

    func endLocalOutgoingPrivateCallRing(channelID: ChannelID) {
        locallyStartedOutgoingPrivateCallRings.remove(channelID)
        outgoingPrivateCallRingTimeoutTasks.removeValue(forKey: channelID)?.cancel()
        reconcilePrivateCallSounds()
    }

    func reconcilePrivateCallSounds() {
        let state = PrivateCallSoundState.make(
            calls: privateCallsByChannel.values,
            currentUserID: snapshot?.currentUser.id,
            activeChannelID: activeVoiceChannel?.id,
            locallyStartedOutgoingChannelIDs:
                locallyStartedOutgoingPrivateCallRings
        )
        soundPlayer.setLooping(.callRinging, active: state.ringsIncoming)
        soundPlayer.setLooping(.callCalling, active: state.ringsOutgoing)
    }

    func leaveVoice(
        account: AppModelAccountSession? = nil,
        expectedOperation: AppModelVoiceOperationIdentity? = nil
    ) async {
        let account = account ?? accountSession()
        guard isCurrentAccountSession(account) else { return }
        if let expectedOperation {
            guard isCurrentVoiceOperation(
                account,
                identity: expectedOperation
            ) else { return }
        }
        let channel = activeVoiceChannel
        let guildID = channel?.guildID
        let hadActiveVoice = channel != nil
        let departingSession = voiceSession
        if let channelID = channel?.id {
            endLocalOutgoingPrivateCallRing(channelID: channelID)
        }
        voiceMigrationGeneration &+= 1
        let voiceGeneration = voiceMigrationGeneration
        voiceMigrationTask?.cancel()
        voiceMigrationTask = nil
        voiceEventTask?.cancel()
        voiceEventTask = nil
        await departingSession?.disconnect()
        guard isCurrentAccountSession(account),
              voiceMigrationGeneration == voiceGeneration
        else { return }
        if voiceSession === departingSession {
            voiceSession = nil
        }
        if activeVoiceChannel?.id == channel?.id, channel != nil {
            try? await account.provider.updateVoiceState(
                channelID: nil,
                guildID: guildID,
                selfMute: false,
                selfDeaf: false,
                selfVideo: false
            )
        }
        guard isCurrentAccountSession(account),
              voiceMigrationGeneration == voiceGeneration,
              activeVoiceChannel?.id == channel?.id
        else { return }
        activeVoiceChannel = nil
        voiceParticipants = []
        isLocallySpeaking = false
        voiceVideoFrames = [:]
        if let ownUserID = snapshot?.currentUser.id {
            voiceStates[ownUserID] = nil
        }
        voiceEncryptionVersion = nil
        voiceLatencyMilliseconds = nil
        voiceSessionState = .idle
        isCameraEnabled = false
        reconcilePrivateCallSounds()
        if hadActiveVoice {
            soundPlayer.play(.disconnect)
        }
    }

    func toggleVoiceMute() async {
        guard !presentsCachedStartup else { return }
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        isVoiceMuted.toggle()
        let muted = isVoiceMuted
        UserDefaults.standard.set(isVoiceMuted, forKey: "voiceMuted")
        await session?.setMuted(muted)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        await publishVoiceState(account: account, generation: generation)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        if activeVoiceChannel != nil {
            soundPlayer.play(muted ? .mute : .unmute)
        }
    }

    func toggleVoiceDeafen() async {
        guard !presentsCachedStartup else { return }
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        isVoiceDeafened.toggle()
        let deafened = isVoiceDeafened
        UserDefaults.standard.set(isVoiceDeafened, forKey: "voiceDeafened")
        await session?.setDeafened(deafened)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        await publishVoiceState(account: account, generation: generation)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        if activeVoiceChannel != nil {
            soundPlayer.play(deafened ? .deafen : .undeafen)
        }
    }

    func toggleCamera() async {
        guard !presentsCachedStartup else { return }
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        let enabled = !isCameraEnabled
        if session == nil {
            isCameraEnabled = enabled
            await publishVoiceState(account: account, generation: generation)
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            if activeVoiceChannel != nil {
                soundPlayer.play(enabled ? .cameraOn : .cameraOff)
            }
            return
        }
        do {
            try await session?.setCameraEnabled(enabled)
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            isCameraEnabled = enabled
            if !enabled, let ownUserID = snapshot?.currentUser.id {
                voiceVideoFrames[String(ownUserID.rawValue)] = nil
            }
            let channel = activeVoiceChannel
            try await account.provider.updateVoiceState(
                channelID: channel?.id,
                guildID: channel?.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened,
                selfVideo: enabled
            )
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ), activeVoiceChannel?.id == channel?.id else { return }
            soundPlayer.play(enabled ? .cameraOn : .cameraOff)
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func selectCamera(_ camera: CameraDeviceInfo?) async {
        UserDefaults.standard.set(camera?.uniqueID, forKey: "voiceCameraUID")
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        do { try await session?.selectCamera(uniqueID: camera?.uniqueID) } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func updateInputVolume(_ value: Float) async {
        inputVolume = min(max(value, 0), 2)
        UserDefaults.standard.set(Double(inputVolume), forKey: "voiceInputVolume")
        await voiceSession?.setInputVolume(inputVolume)
    }

    func updateOutputVolume(_ value: Float) async {
        outputVolume = min(max(value, 0), 2)
        UserDefaults.standard.set(Double(outputVolume), forKey: "voiceOutputVolume")
        await voiceSession?.setOutputVolume(outputVolume)
    }

    func selectInputDevice(_ device: AudioDeviceInfo?) async {
        UserDefaults.standard.set(device?.uid, forKey: "voiceInputDeviceUID")
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        do { try await session?.selectInputDevice(device?.id) } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func selectOutputDevice(_ device: AudioDeviceInfo?) async {
        UserDefaults.standard.set(device?.uid, forKey: "voiceOutputDeviceUID")
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        do { try await session?.selectOutputDevice(device?.id) } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func updateParticipantVolume(_ value: Float, userID: String) async {
        await voiceSession?.setParticipantVolume(value, userID: userID)
    }

    func refreshMediaDevices() async {
        mediaDevices = await Task.detached(priority: .userInitiated) {
            MediaDeviceCatalog.snapshot()
        }.value
    }

    func publishVoiceState() async {
        await publishVoiceState(
            account: accountSession(),
            generation: voiceMigrationGeneration
        )
    }

    func publishVoiceState(
        account: AppModelAccountSession,
        generation: Int
    ) async {
        guard isCurrentAccountSession(account),
              generation == voiceMigrationGeneration,
              let activeVoiceChannel
        else { return }
        do {
            try await account.provider.updateVoiceState(
                channelID: activeVoiceChannel.id,
                guildID: activeVoiceChannel.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened,
                selfVideo: isCameraEnabled
            )
        } catch {
            guard isCurrentAccountSession(account),
                  generation == voiceMigrationGeneration
            else { return }
            voiceErrorMessage = error.localizedDescription
        }
    }

    func selectedAudioDeviceID(defaultsKey: String, devices: [AudioDeviceInfo])
        -> AudioDeviceID?
    {
        guard let uid = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return devices.first(where: { $0.uid == uid })?.id
    }

    func currentVoiceConfiguration() -> VoiceSessionConfiguration {
        let outputDeviceID = selectedAudioDeviceID(
            defaultsKey: "voiceOutputDeviceUID",
            devices: mediaDevices.audioOutputs
        )
        return VoiceSessionConfiguration(
            inputDeviceID: resolvedInputDeviceID(),
            outputDeviceID: outputDeviceID,
            inputVolume: inputVolume,
            outputVolume: outputVolume,
            isMuted: isVoiceMuted,
            isDeafened: isVoiceDeafened,
            cameraUniqueID: UserDefaults.standard.string(forKey: "voiceCameraUID")
        )
    }

    func resolvedInputDeviceID() -> AudioDeviceID? {
        if let storedUID = UserDefaults.standard.string(forKey: "voiceInputDeviceUID"),
           !storedUID.isEmpty
        {
            return mediaDevices.audioInputs.first(where: { $0.uid == storedUID })?.id
        }

        let defaultInput = mediaDevices.audioInputs.first(where: \.isDefault)
        // Automatic capture must not inherit a Bluetooth call route or a
        // silent virtual/aggregate device. Explicit selections remain honored.
        if defaultInput?.isBluetooth == true || defaultInput?.isVirtual == true,
           let builtIn = mediaDevices.audioInputs.first(where: \.isBuiltIn)
        {
            return builtIn.id
        }
        return nil
    }

    func startVoiceSession(
        with info: VoiceConnectionInfo,
        account: AppModelAccountSession,
        generation: Int
    ) async throws {
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            channelID: info.channelID
        ) else { throw CancellationError() }
        if info.endpoint == "mock.sakuracord.invalid" {
            voiceSessionState = .connected
            return
        }

        let session = DiscordVoiceSession(
            info: info,
            configuration: currentVoiceConfiguration(),
            gatewayDiagnostics: VoiceGatewayDiagnostics { direction, data in
                DiscordAPIDiagnosticStore.shared.recordWebSocketData(
                    transport: "voice_gateway",
                    direction: direction.rawValue,
                    data: data
                )
            }
        )
        voiceSession = session
        voiceEventTask?.cancel()
        voiceEventTask = Task { [weak self] in
            for await event in session.events {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentVoiceOperation(
                          account,
                          generation: generation,
                          voiceSession: session
                      )
                else { return }
                self.consumeVoiceEvent(event)
            }
        }
        do {
            try await session.connect()
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { throw CancellationError() }
            throw error
        }
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else {
            await session.disconnect()
            throw CancellationError()
        }
    }

    func scheduleVoiceServerMigration(to info: VoiceConnectionInfo?) {
        voiceMigrationGeneration &+= 1
        let generation = voiceMigrationGeneration
        voiceMigrationTask?.cancel()
        let account = accountSession()
        voiceMigrationTask = startAccountChildTask(account: account) { model, account in
            await model.migrateVoiceServer(
                to: info,
                generation: generation,
                account: account
            )
        }
    }

    func migrateVoiceServer(
        to info: VoiceConnectionInfo?,
        generation: Int,
        account: AppModelAccountSession
    ) async {
        guard !Task.isCancelled,
              isCurrentAccountSession(account),
              activeVoiceChannel != nil,
              generation == voiceMigrationGeneration
        else { return }
        let cameraWasEnabled = isCameraEnabled
        let previousSession = voiceSession

        voiceEventTask?.cancel()
        voiceEventTask = nil
        await previousSession?.disconnect()
        guard !Task.isCancelled,
              isCurrentAccountSession(account),
              generation == voiceMigrationGeneration
        else { return }

        if voiceSession === previousSession {
            voiceSession = nil
        }
        voiceParticipants = []
        voiceVideoFrames = [:]
        voiceEncryptionVersion = nil
        voiceLatencyMilliseconds = nil
        isCameraEnabled = false
        voiceSessionState = .reconnecting

        guard let info else { return }
        guard info.channelID == activeVoiceChannel?.id else { return }

        do {
            try await startVoiceSession(
                with: info,
                account: account,
                generation: generation
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(account),
                  generation == voiceMigrationGeneration
            else {
                await voiceSession?.disconnect()
                return
            }
            if cameraWasEnabled, voiceSession != nil {
                let migratedSession = voiceSession
                try await migratedSession?.setCameraEnabled(true)
                guard isCurrentVoiceOperation(
                    account,
                    generation: generation,
                    voiceSession: migratedSession
                ) else { return }
                isCameraEnabled = true
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccountSession(account),
                  generation == voiceMigrationGeneration
            else { return }
            voiceSessionState = .failed
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func consumeVoiceEvent(_ event: VoiceSessionEvent) {
        switch event {
        case .stateChanged(let state):
            voiceSessionState = state
        case .latencyUpdated(let milliseconds):
            voiceLatencyMilliseconds = milliseconds
        case .participantChanged(let participant):
            if let index = voiceParticipants.firstIndex(where: { $0.userID == participant.userID }) {
                voiceParticipants[index] = participant
            } else {
                voiceParticipants.append(participant)
            }
            voiceParticipants.sort { $0.userID < $1.userID }
            if let userID = UserID(participant.userID), var state = voiceStates[userID] {
                state.isVideoEnabled = participant.isCameraEnabled
                voiceStates[userID] = state
            }
        case .participantLeft(let userID):
            voiceParticipants.removeAll { $0.userID == userID }
            voiceVideoFrames[userID] = nil
        case .localSpeakingChanged(let speaking):
            isLocallySpeaking = speaking
        case .encryptionReady(let version):
            voiceEncryptionVersion = version
        case .videoFrame(let userID, let frame):
            voiceVideoFrames[userID] = frame
        case .videoStopped(let userID):
            voiceVideoFrames[userID] = nil
        case .error(let message):
            voiceErrorMessage = message
        }
    }

    func selectMember(_ member: Member) {
        if selectedMember?.id == member.id, isInspectorProfilePresented {
            dismissInspectorProfile()
            return
        }
        isInspectorProfilePresented = true
        if selectedMember?.id == member.id {
            return
        }
        presentProfile(for: member, destination: .inspector)
    }

    @discardableResult
    func showProfile(for user: User) -> UUID {
        let member =
            membersByID[user.id]
                ?? Member(user: user, roleName: "Member", status: .offline)
        return presentProfile(for: member, destination: .contextual)
    }

    func showInspectorProfile(for user: User) {
        isInspectorProfilePresented = true
        let member =
            membersByID[user.id]
                ?? Member(
                    user: user,
                    roleName: "Direct Message",
                    status: .offline
                )
        presentProfile(for: member, destination: .inspector)
    }

    func authorPresentation(for message: Message) -> MessageAuthorPresentation {
        MessageAuthorPresentation.resolve(
            message: message,
            member: membersByID[message.author.id],
            roles: guildRoles
        )
    }

    func authorPresentation(
        for replyPreview: MessageReplyPreview
    ) -> MessageAuthorPresentation {
        MessageAuthorPresentation.resolve(
            replyPreview: replyPreview,
            member: membersByID[replyPreview.author.id],
            roles: guildRoles
        )
    }

    @discardableResult
    func presentProfile(
        for member: Member,
        destination: ProfilePresentationDestination
    ) -> UUID {
        let requestID = UUID()
        let guildID = selectedGuildID
        let cacheKey = ProfileCacheKey(
            userID: member.id,
            guildID: guildID
        )
        let cachedProfile = profileCache[cacheKey].map {
            profile($0, applyingPresenceFrom: member)
        }
        let presentation = ProfilePresentationState(
            requestID: requestID,
            member: member,
            profile: cachedProfile,
            isLoading: cachedProfile == nil,
            errorMessage: nil
        )
        switch destination {
        case .inspector:
            inspectorProfileTask?.cancel()
            inspectorProfilePresentation = presentation
        case .contextual:
            contextualProfileTask?.cancel()
            contextualProfilePresentation = presentation
        }
        guard cachedProfile == nil else { return requestID }
        let session = accountSession()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await session.provider.profile(
                    for: member.id,
                    in: guildID
                )
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      selectedGuildID == guildID,
                      profilePresentation(
                          for: destination
                      )?.requestID == requestID
                else {
                    return
                }
                profileCache[cacheKey] = loaded
                var value = profilePresentation(for: destination)
                value?.member = member
                value?.profile = profile(
                    loaded,
                    applyingPresenceFrom: member
                )
                value?.isLoading = false
                value?.errorMessage = nil
                setProfilePresentation(value, for: destination)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      profilePresentation(
                          for: destination
                      )?.requestID == requestID
                else { return }
                var value = profilePresentation(for: destination)
                value?.isLoading = false
                value?.errorMessage = error.localizedDescription
                setProfilePresentation(value, for: destination)
            }
        }
        switch destination {
        case .inspector:
            inspectorProfileTask = task
        case .contextual:
            contextualProfileTask = task
        }
        return requestID
    }

    func dismissInspectorProfile() {
        inspectorProfileTask?.cancel()
        inspectorProfileTask = nil
        inspectorProfilePresentation = nil
        isInspectorProfilePresented = false
    }

    func dismissContextualProfile(for userID: UserID? = nil) {
        if let userID,
           contextualProfilePresentation?.member.id != userID
        {
            return
        }
        contextualProfileTask?.cancel()
        contextualProfileTask = nil
        contextualProfilePresentation = nil
    }

    func dismissContextualProfile(requestID: UUID) {
        guard contextualProfilePresentation?.requestID == requestID else {
            return
        }
        dismissContextualProfile()
    }

    func dismissAllProfiles(clearsCache: Bool = false) {
        dismissInspectorProfile()
        dismissContextualProfile()
        if clearsCache {
            profileCache.removeAll(keepingCapacity: false)
        }
    }

    func profilePresentation(
        for destination: ProfilePresentationDestination
    ) -> ProfilePresentationState? {
        switch destination {
        case .inspector:
            inspectorProfilePresentation
        case .contextual:
            contextualProfilePresentation
        }
    }

    func setProfilePresentation(
        _ value: ProfilePresentationState?,
        for destination: ProfilePresentationDestination
    ) {
        switch destination {
        case .inspector:
            inspectorProfilePresentation = value
        case .contextual:
            contextualProfilePresentation = value
        }
    }

    func profile(
        _ value: UserProfile,
        applyingPresenceFrom member: Member
    ) -> UserProfile {
        var result = value
        result.status = member.status
        result.customStatus = member.customStatus
        return result
    }

    func dismissError() {
        errorMessage = nil
    }

    func storedDraft(
        in channelID: ChannelID,
        account: AppModelAccountSession
    ) async -> String {
        await (try? account.database?.draft(channelID: channelID)) ?? ""
    }

    func isCurrentLoad(_ channelID: ChannelID, generation: Int) -> Bool {
        !Task.isCancelled && selectedChannelID == channelID && channelLoadGeneration == generation
    }

    static func merging(current: [Message], fresh: [Message]) -> [Message] {
        var byID: [MessageID: Message] = [:]
        var idByNonce: [String: MessageID] = [:]
        for message in current {
            byID[message.id] = message
            if let nonce = message.nonce {
                idByNonce[nonce] = message.id
            }
        }
        for message in fresh {
            var resolved = message
            let matchingID = message.nonce.flatMap { idByNonce[$0] }
            if let existing = byID[message.id] ?? matchingID.flatMap({ byID[$0] }) {
                resolved.guildMember = MessageGuildMember.merging(
                    incoming: resolved.guildMember,
                    existing: existing.guildMember
                )
                resolved.replyTo = resolved.replyTo ?? existing.replyTo
                resolved.replyPreview = resolved.replyPreview ?? existing.replyPreview
            }
            if let matchingID, matchingID != resolved.id {
                byID[matchingID] = nil
            }
            byID[resolved.id] = resolved
            if let nonce = resolved.nonce {
                idByNonce[nonce] = resolved.id
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id < rhs.id
        }
    }

    static func reconcilingNewestPage(
        current: [Message],
        fresh: [Message],
        hasMoreBefore: Bool,
        authoritativeOldestMessageID: MessageID? = nil
    ) -> [Message] {
        let oldestFreshID = authoritativeOldestMessageID ?? fresh.map(\.id).min()
        let retainedCurrent = current.filter { message in
            guard message.outboxState == .confirmed else { return true }
            guard hasMoreBefore, let oldestFreshID else { return false }
            return message.id < oldestFreshID
        }
        return merging(current: retainedCurrent, fresh: fresh)
    }

    static func applyingConversationRefreshMutations(
        _ mutations: [MessageID: ConversationRefreshMutation],
        to messages: [Message]
    ) -> [Message] {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for (messageID, mutation) in mutations {
            switch mutation {
            case .upsert(let message):
                byID[messageID] = message
            case .delete:
                byID[messageID] = nil
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id < rhs.id
        }
    }

    func isChannelUnread(_ channelID: ChannelID) -> Bool {
        readState.unread(channelID: channelID)
    }

    func channelNotificationOverride(
        for channel: Channel
    ) -> ChannelNotificationOverride? {
        readState.notificationOverride(
            channelID: channel.id,
            guildID: channel.guildID
        )
    }

    func isChannelMuted(_ channel: Channel) -> Bool {
        readState.isChannelMuted(channel)
    }

    func inheritedChannelNotificationLevel(
        for channel: Channel
    ) -> MessageNotificationLevel {
        readState.inheritedNotificationLevel(for: channel)
    }

    func isChannelNotificationMutationPending(_ channelID: ChannelID) -> Bool {
        channelNotificationMutationTasks[channelID] != nil
    }

    func guildNotificationSettings(for guild: Guild) -> GuildNotificationSettings {
        readState.notificationSettings(guildID: guild.id)
            ?? GuildNotificationSettings(
                guildID: guild.id,
                messageNotifications: guild.defaultMessageNotifications
            )
    }

    func isGuildNotificationMutationPending(_ guildID: GuildID) -> Bool {
        guildNotificationMutationTasks[guildID] != nil
            || guildAcknowledgementTasks[guildID] != nil
    }

    func isForumPostUnread(_ post: ForumPost) -> Bool {
        readState.entries[post.id]?.isUnread ?? post.isUnread
    }

    func isForumNotificationMutationPending(_ postID: ChannelID) -> Bool {
        forumNotificationMutationTasks[postID] != nil
    }

    func inheritedForumPostNotificationLevel(
        _ post: ForumPost
    ) -> MessageNotificationLevel {
        guard let parentID = post.thread.parentID,
              let parent =
              snapshot?.channels.first(where: { $0.id == parentID })
                ?? visibleChannels.first(where: { $0.id == parentID })
        else { return .onlyMentions }
        if let configured = channelNotificationOverride(for: parent)?
            .messageNotifications,
           configured != .inherit
        {
            return configured
        }
        return inheritedChannelNotificationLevel(for: parent)
    }

    func isForumPostNew(_ post: ForumPost) -> Bool {
        readState.isNewForumPost(post)
    }

    func shouldEmphasizeForumPost(_ post: ForumPost) -> Bool {
        isForumPostUnread(post) || readState.isUnopenedForumPost(post)
    }

    func forumUnreadMessageCount(_ post: ForumPost) -> Int {
        guard isForumPostUnread(post) else { return 0 }
        return readState.unreadMessageCount(channelID: post.id)
    }

    func reportMainWindowActive(_ isActive: Bool) {
        mainWindowIsActive = isActive
        let session = accountSession()
        let precedingUpdate = clientAppStateUpdateTask
        clientAppStateUpdateTask = Task {
            await precedingUpdate?.value
            guard !Task.isCancelled else { return }
            await session.provider.updateClientAppState(isFocused: isActive)
        }
        if let selectedChannelID {
            preserveUnreadDividerIfNeeded(channelID: selectedChannelID)
            if let target = readState.updatePresentation(
                channelID: selectedChannelID,
                windowIsActive: isActive
            ) {
                scheduleAcknowledgement(channelID: selectedChannelID, messageID: target)
            }
        }
        if let threadID = openThread?.id {
            preserveUnreadDividerIfNeeded(channelID: threadID)
            if let target = readState.updatePresentation(
                channelID: threadID,
                windowIsActive: isActive
            ) {
                scheduleAcknowledgement(channelID: threadID, messageID: target)
            }
        }
    }

    func reportTimelinePosition(
        channelID: ChannelID,
        hasReachedReadBoundary: Bool
    ) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        let previousBoundary =
            readState.presentations[channelID]?.hasReachedReadBoundary
        let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            hasReachedReadBoundary: hasReachedReadBoundary
        )
        if previousBoundary != hasReachedReadBoundary {
            let eligible = readState.presentations[channelID]?.canAcknowledge == true
            let channel = channelID.rawValue
            let reached = hasReachedReadBoundary
            let targetID = target?.rawValue ?? 0
            Self.unreadDiagnosticsLogger.debug(
                "Timeline bound c=\(channel, privacy: .public) r=\(reached, privacy: .public) e=\(eligible, privacy: .public) m=\(targetID, privacy: .public)"
            )
        }
        if let target {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func reportTimelineInitialPosition(
        channelID: ChannelID,
        hasReachedReadBoundary: Bool
    ) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialPositionEstablished: true,
            hasReachedReadBoundary: hasReachedReadBoundary
        )
        let eligible = readState.presentations[channelID]?.canAcknowledge == true
        let channel = channelID.rawValue
        let reached = hasReachedReadBoundary
        let targetID = target?.rawValue ?? 0
        Self.unreadDiagnosticsLogger.debug(
            "Timeline initial c=\(channel, privacy: .public) r=\(reached, privacy: .public) e=\(eligible, privacy: .public) m=\(targetID, privacy: .public)"
        )
        if let target {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func reportTimelineUserInteraction(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        guard !presentsCachedStartup else { return }
        readState.unblockAutomaticAcknowledgement(channelID: channelID)
    }

    func reportConversationHistoryLoaded(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        AppPerformanceSignposts.reportStartupConversationHistoryReady(
            channelID: channelID
        )
        preserveUnreadDividerIfNeeded(channelID: channelID)
        if let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialHistoryLoaded: true
        ) {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func timelineUnreadSummary(
        channelID: ChannelID,
        messages: [Message],
        hasMoreBefore: Bool
    ) -> AccountReadStateModel.TimelineUnreadSummary? {
        readState.timelineUnreadSummary(
            channelID: channelID,
            messages: messages,
            hasMoreBefore: hasMoreBefore
        )
    }

}
