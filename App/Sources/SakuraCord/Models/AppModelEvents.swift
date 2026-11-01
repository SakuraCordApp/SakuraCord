import CoreAudio
import CoreText
import DiscordProtocol
import Foundation
import ImageIO
import MediaPipeline
import MessageRendering
import OSLog
import Observation
import SakuraCordModels
import SakuraCordPersistence
import UniformTypeIdentifiers
import UserNotifications

extension AppModel {
    func logReadAcknowledgementSending(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        let channel = channelID.rawValue
        let message = mutation.messageID.rawValue
        Self.unreadDiagnosticsLogger.info(
            "Read ack send c=\(channel, privacy: .public) m=\(message, privacy: .public)"
        )
    }

    func logReadAcknowledgementAccepted(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        let channel = channelID.rawValue
        let message = mutation.messageID.rawValue
        Self.unreadDiagnosticsLogger.info(
            "Read ack accepted c=\(channel, privacy: .public) m=\(message, privacy: .public)"
        )
    }

    func logReadAcknowledgementFailed(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        let channel = channelID.rawValue
        let message = mutation.messageID.rawValue
        Self.unreadDiagnosticsLogger.error(
            "Read ack failed c=\(channel, privacy: .public) m=\(message, privacy: .public)"
        )
    }

    func readStateMutation(channelID: ChannelID, messageID: MessageID) -> ReadStateMutation {
        let metadata = readState.acknowledgementMetadata(channelID: channelID)
        return ReadStateMutation(messageID: messageID, flags: metadata.flags, lastViewed: metadata.lastViewed)
    }

    func resetAcknowledgementWork() {
        acknowledgementGeneration &+= 1
        allServersReadTask?.cancel()
        allServersReadTask = nil
        isMarkingAllServersRead = false
        acknowledgementTasks.values.forEach { $0.cancel() }
        acknowledgementTasks.removeAll()
        acknowledgementProcessorTask?.cancel()
        acknowledgementProcessorTask = nil
        guildAcknowledgementTasks.values.forEach { $0.cancel() }
        guildAcknowledgementTasks.removeAll()
        queuedAcknowledgements.removeAll()
    }

    func resetChannelNotificationMutations() {
        channelNotificationMutationGeneration &+= 1
        guildNotificationMutationTasks.values.forEach { $0.cancel() }
        guildNotificationMutationTasks.removeAll()
        guildNotificationSettingsRevisions.removeAll()
        channelNotificationMutationTasks.values.forEach { $0.cancel() }
        channelNotificationMutationTasks.removeAll()
        categoryCollapseMutationTasks.values.forEach { $0.cancel() }
        categoryCollapseMutationTasks.removeAll()
        categoryCollapseMutationStates.removeAll()
        optimisticCategoryCollapsedByID.removeAll()
        forumNotificationMutationGeneration &+= 1
        forumNotificationMutationTasks.values.forEach { $0.cancel() }
        forumNotificationMutationTasks.removeAll()
    }

    func consume(_ event: ClientEvent) async {
        if case let .messageCreated(message) = event {
            let preparedTextPlan: NativeTimelineTextPlan? =
                if message.channelID == selectedChannelID {
                    await Task.detached(priority: .utility) {
                        NativeTimelineTextPlan.make(for: message)
                    }.value
                } else {
                    nil
                }
            guard !Task.isCancelled else { return }
            pendingCreatedMessages.append(
                PreparedCreatedMessage(
                    message: message,
                    textPlan: preparedTextPlan
                )
            )
            guard createdMessageFlushTask == nil else { return }
            createdMessageFlushTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return
                }
                self?.flushPendingCreatedMessages(
                    maximumCount: self?.maximumCreatedMessagesPerFlush ?? 4
                )
            }
            return
        }
        flushPendingCreatedMessages()
        let messageForTextPlan: Message? = switch event {
        case .messageUpdated(let message): message
        case .messagePatched(let update): applyingMessageUpdate(update)
        default: nil
        }
        let preparedTextPlan: NativeTimelineTextPlan? =
            if let message = messageForTextPlan,
               message.channelID == selectedChannelID
            {
                await Task.detached(priority: .userInitiated) {
                    NativeTimelineTextPlan.make(for: message)
                }.value
            } else {
                nil
        }
        let preparedMemberListPresentation: PreparedMemberListPresentation? =
            if case let .membersChanged(guildID, members, groups) = event,
               guildID == selectedGuildID
            {
                await AppPerformanceSignposts.measure(
                    "MemberListEventPreparation"
                ) {
                    let roles = guildRoles
                    let priority: TaskPriority = AppScrollWorkGate.isActive
                        ? .background
                        : .utility
                    return await Task.detached(priority: priority) {
                        PreparedMemberListPresentation.make(
                            guildID: guildID,
                            members: members,
                            groups: groups,
                            roles: roles
                        )
                    }.value
                }
            } else {
                nil
            }
        guard !Task.isCancelled else { return }
        consumeImmediately(
            event,
            preparedTextPlan: preparedTextPlan,
            preparedTextPlanSource: messageForTextPlan,
            preparedMemberListPresentation: preparedMemberListPresentation
        )
    }

    func flushPendingCreatedMessages(
        maximumCount: Int = .max
    ) {
        guard !pendingCreatedMessages.isEmpty else {
            createdMessageFlushTask = nil
            return
        }
        createdMessageFlushTask?.cancel()
        createdMessageFlushTask = nil
        let flushCount = min(
            max(1, maximumCount),
            pendingCreatedMessages.count
        )
        let pending = Array(pendingCreatedMessages.prefix(flushCount))
        pendingCreatedMessages.removeFirst(flushCount)
        isFlushingCreatedMessageBatch = true
        for prepared in pending {
            consumeImmediately(
                .messageCreated(prepared.message),
                preparedTextPlan: prepared.textPlan
            )
        }
        commitBatchedSelectedMessages()
        isFlushingCreatedMessageBatch = false
        flushBatchedCreatedMessageSideEffects()
        if !pendingCreatedMessages.isEmpty {
            // A display or AppKit transaction can occasionally delay the
            // eight-millisecond timer long enough for dozens of gateway
            // creates to accumulate. Never turn that scheduling delay into
            // one giant main-actor layout burst; drain bounded chunks while
            // yielding between them.
            createdMessageFlushTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.flushPendingCreatedMessages(
                    maximumCount: self.maximumCreatedMessagesPerFlush
                )
            }
        }
    }

    func resetPendingCreatedMessages() {
        accessibilityMessageAnnouncer.cancel()
        createdMessageFlushTask?.cancel()
        createdMessageFlushTask = nil
        pendingCreatedMessages.removeAll(keepingCapacity: false)
        batchedSelectedMessages.removeAll(keepingCapacity: false)
        batchedSelectedTextPlansByID.removeAll(keepingCapacity: false)
        batchedUnreadPresentationNeedsRefresh = false
        batchedAcknowledgementChannelIDs.removeAll(keepingCapacity: false)
        isFlushingCreatedMessageBatch = false
    }

    func flushBatchedCreatedMessageSideEffects() {
        if batchedUnreadPresentationNeedsRefresh {
            batchedUnreadPresentationNeedsRefresh = false
            requestUnreadPresentationRefresh()
        }
        let acknowledgementChannelIDs = batchedAcknowledgementChannelIDs
        batchedAcknowledgementChannelIDs.removeAll(keepingCapacity: true)
        for channelID in acknowledgementChannelIDs {
            // Batched rows were not committed when each message was received,
            // so the divider decision made then saw no unread row.
            preserveUnreadDividerUnlessReadOnArrival(channelID: channelID)
            acknowledgeIfEligible(channelID: channelID)
        }
    }

    func consumeImmediately(
        _ event: ClientEvent,
        preparedTextPlan: NativeTimelineTextPlan? = nil,
        preparedTextPlanSource: Message? = nil,
        preparedMemberListPresentation: PreparedMemberListPresentation? = nil
    ) {
        if consumeInboxEvent(event) { return }
        switch event {
        case .connectionChanged(let state):
            consumeConnectionChange(state)
        case .emojisChanged(let guildID, let emojis):
            applyEmojis(emojis, to: guildID)
        case .emojisUpdated(let guildID, let upserted, let deletedIDs):
            applyEmojiUpdate(upserted: upserted, deletedIDs: deletedIDs, to: guildID)
        case .messageCreated(var message):
            consumeMessageCreated(&message, preparedTextPlan: preparedTextPlan)
            reconcileInboxMessage(message, isNew: true)
        case .messageUpdated(let incoming):
            invalidateMessageTranslation(incoming.id, content: incoming.content)
            let reconciled = applyingPendingPinIntent(to: incoming)
            consumeMessageUpdated(reconciled, preparedTextPlan: preparedTextPlan)
            refreshThreadStarterQuotes(messageID: incoming.id, with: incoming)
        case .messagePatched(let update):
            if let content = update.content { invalidateMessageTranslation(update.messageID, content: content) }
            reconcilePollVoteConfirmation(update)
            recordConversationRefreshMutation(.patch(update), messageID: update.messageID, channelID: update.channelID)
            let patched = applyingMessageUpdate(update)
            if let patched {
                let reconciled = applyingPendingPinIntent(to: patched)
                consumeMessageUpdated(
                    reconciled, preparedTextPlan: preparedTextPlan,
                    recordsRefreshMutation: false, preparedTextPlanSource: preparedTextPlanSource
                )
            }
            refreshThreadStarterQuotes(after: update, patched: patched)
        case .messageReactionUpdated(let update):
            applyReactionUpdate(update)
        case .messageDeleted(let channelID, let messageID):
            consumeMessageDeleted(channelID: channelID, messageID: messageID)
            refreshThreadStarterQuotes(messageID: messageID, with: nil)
            removeDeletedPinnedMessage(channelID: channelID, messageID: messageID)
            removeInboxMessage(messageID, mentionsOnly: false)
        case .channelPinsInvalidated(let channelID):
            invalidatePinnedMessages(in: channelID)
        case .readStateSnapshot(let states, _):
            consumeReadStateSnapshot(states)
        case .readStateChanged(let state):
            consumeReadStateChange(state)
        default:
            consumeWorkspaceEvent(
                event,
                preparedMemberListPresentation: preparedMemberListPresentation
            )
        }
    }

    func consumeWorkspaceEvent(
        _ event: ClientEvent,
        preparedMemberListPresentation: PreparedMemberListPresentation? = nil
    ) {
        if consumeThreadEvent(event) { return }
        switch event {
        case .notificationModeChanged(let usesNewNotifications):
            readState.updateNotificationMode(
                usesNewNotifications: usesNewNotifications
            )
            if var value = snapshot {
                value.usesNewNotifications = usesNewNotifications
                snapshot = value
            }
            refreshUnreadPresentation()
        case .notificationSettingsChanged(let settings):
            applyRemoteNotificationSettings(settings)
            synchronizeVisibleCustomization(guildID: settings.guildID)
            reconcileSelectedOnboardingChannel()
            refreshUnreadPresentation()
            reconcileInboxEligibility()
        case .emojiUserSettingsChanged(let settings):
            applyDiscordEmojiSettings(settings)
            didAttemptDiscordEmojiSettings = true
            hasLoadedDiscordEmojiSettings = true
            forwardSearchSourceRevision &+= 1
        case .stickerUserSettingsChanged, .stickersChanged:
            consumeStickerEvent(event)
        case let .applicationCommandFrecencyChanged(history):
            applyRemoteCommandFrecency(history)
        case .soundboardUserSettingsChanged,
             .soundboardSoundsChanged,
             .voiceChannelEffect:
            consumeSoundboardEvent(event)
        case .typing(let channelID, let user):
            guard !isUserIgnored(user.id), !ignoredUsers.blockedUserIDs.contains(user.id) else { return }
            typingState.receive(
                channelID: channelID,
                user: user,
                currentUserID: snapshot?.currentUser.id
            )
        case .channelsChanged(let guildID, let channels):
            consumeChannelsChanged(guildID: guildID, channels: channels)
            reconcileInboxEligibility()
        case let .threadMembersChanged(guildID, threadID, members):
            guard snapshot?.guilds.contains(where: { $0.id == guildID }) == true else { return }
            threadMembersByID[threadID] = members
        case .membersChanged(let guildID, let value, let groups):
            consumeMembersChanged(
                guildID: guildID,
                members: value,
                groups: groups,
                preparedPresentation: preparedMemberListPresentation
            )
        default:
            consumePresenceAndCommandEvent(event)
        }
    }

    func consumePresenceAndCommandEvent(_ event: ClientEvent) {
        if consumeForwardSearchPeopleEvent(event) { return }
        if consumeApplicationStreamEvent(event) { return }
        if consumeProfileEvent(event) { return }
        switch event {
        case .currentUserRolesChanged, .currentUserRolesSnapshot:
            consumeCurrentUserRoleEvent(event)
        case .voiceStateChanged, .voiceStatesReceived:
            consumeVoiceStateEvent(event)
        case .privateCallChanged(var call):
            consumePrivateCallChanged(&call)
        case .privateCallDeleted(let channelID, let unavailable):
            consumePrivateCallDeleted(channelID: channelID, unavailable: unavailable)
        case .voiceServerChanged(let info):
            recordVoiceServerUpdateReceived(info)
            scheduleVoiceServerMigration(to: info)
        case .snapshotChanged(let value):
            consumeSnapshotChanged(value)
        case .guildChanged, .guildLayoutChanged, .guildLayoutSaveFailed, .guildRolesChanged,
             .currentUserChanged, .currentUserStatusChanged:
            consumeGatewayWorkspaceStateEvent(event)
        case .applicationCommandIndexInvalidated(let target):
            invalidateApplicationCommandIndex(target)
        case .applicationCommandAutocomplete(let result):
            commandComposers.forEach { $0.receiveAutocomplete(result) }
        case .interaction(let event):
            consumeInteraction(event)
        default:
            break
        }
    }

    private func consumeProfileEvent(_ event: ClientEvent) -> Bool {
        switch event {
        case let .profileInvalidated(userID):
            profileCache = profileCache.filter { $0.key.userID != userID }
            if userID == snapshot?.currentUser.id {
                preparedProfileEditingSnapshot = nil
                profileInvalidationRevision = UUID()
            }
        case let .profileChanged(userID, scope, profile):
            consumeProfileChanged(userID: userID, scope: scope, value: profile)
        case let .profileCustomStatusChanged(userID, status):
            consumeProfileCustomStatusChanged(userID: userID, status: status)
        case let .profileWidgetConnectionsChanged(userID, connections):
            consumeProfileWidgetConnectionsChanged(userID: userID, connections: connections)
        default:
            return false
        }
        return true
    }

    func consumeGatewayWorkspaceStateEvent(_ event: ClientEvent) {
        switch event {
        case .guildChanged(let guild):
            consumeGuildChanged(guild)
        case .guildLayoutChanged(let guilds, let railItems):
            consumeGuildLayoutChanged(guilds: guilds, railItems: railItems)
        case .guildLayoutSaveFailed(let reason):
            errorMessage = "Discord did not save your server list changes. \(reason)"
        case .guildRolesChanged(let guildID, let roles):
            applyGuildRoles(roles, to: guildID)
        case .currentUserChanged(let user):
            consumeCurrentUserChanged(user)
        case .currentUserStatusChanged(let status):
            applyCurrentStatus(status)
        default:
            break
        }
    }

    func consumeCurrentUserRoleEvent(_ event: ClientEvent) {
        switch event {
        case .currentUserRolesChanged(let guildID, let roleIDs):
            consumeCurrentUserRolesChanged(guildID: guildID, roleIDs: roleIDs)
        case .currentUserRolesSnapshot(let roleIDsByGuild):
            consumeCurrentUserRolesSnapshot(roleIDsByGuild)
        default:
            break
        }
    }

    func consumeCurrentUserRolesChanged(
        guildID: GuildID,
        roleIDs values: [RoleID]
    ) {
        let roleIDs = Set(values)
        guard currentUserRoleIDsByGuild[guildID] != roleIDs else { return }
        currentUserRoleIDsByGuild[guildID] = roleIDs
        readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
        guard selectedGuildID == guildID else { return }
        refreshUnreadPresentation(
            appliesAccessImmediately: true,
            accessAffectedGuildIDs: [guildID]
        )
    }

    func consumeCurrentUserRolesSnapshot(
        _ roleIDsByGuild: [GuildID: [RoleID]]
    ) {
        let replacement = roleIDsByGuild.mapValues(Set.init)
        guard currentUserRoleIDsByGuild != replacement else { return }
        let previous = currentUserRoleIDsByGuild
        let affectedGuildIDs = Self.changedCurrentUserRoleGuildIDs(
            from: previous,
            to: replacement
        )
        currentUserRoleIDsByGuild = replacement
        for guildID in affectedGuildIDs {
            readState.updateCurrentUserRoles(
                replacement[guildID] ?? [],
                guildID: guildID
            )
        }
        refreshUnreadAccessAfterCurrentRoleSnapshot(
            affectedGuildIDs: affectedGuildIDs
        )
    }

    func consumeConnectionChange(_ state: ConnectionState) {
        let previousState = connectionState
        connectionState = state
        handleApplicationStreamsForGatewayState(state)
        if state == .ready, previousState != .ready {
            refreshSelectedGuildOnboarding(force: true)
            scheduleCommandFrecencyFlushAfterConnecting()
        }
        // Discord saves pending command uses as soon as its connection closes.
        if state == .disconnected, previousState == .ready { flushCommandFrecencyNow() }
        if state == .ready, previousState != .ready, inbox.isPresented { refreshInbox() }
        if state == .ready, previousState != .ready { friendsConnectionChanged() }
        if state != .ready {
            if previousState == .ready {
                // A resumed session can reconcile missed messages through the
                // Gateway, but a failed resume followed by a fresh Ready cannot:
                // Ready contains channel boundaries, not message history. Keep
                // the bounded rows for immediate presentation while forcing one
                // authoritative newest-page refresh per reopened conversation.
                hasMoreCache.removeAll(keepingCapacity: true)
                markHistoryGapForRetainedConversations()
            }
            stopLocalTyping(clearThrottle: true)
            typingState.clearAll()
        } else {
            if previousState != .ready, activeVoiceChannel != nil {
                let account = accountSession()
                let generation = voiceMigrationGeneration
                startAccountChildTask(account: account) { model, account in
                    await model.publishVoiceState(
                        account: account,
                        generation: generation
                    )
                }
            }
            if previousState != .ready,
               selectedChannelID != nil,
               hasCompletedInitialMessageLoad
            {
                refreshSelectedChannelPreservingHistory()
            }
            if previousState != .ready {
                revalidateOpenThreadAfterReconnect()
                revalidateGuideResourceAfterReconnect()
            }
            if let channel = selectedChannel,
               channel.kind == .directMessage || channel.kind == .groupDirectMessage
            {
                let account = accountSession()
                startAccountChildTask(account: account) { model, account in
                    await model.observePrivateCall(in: channel, account: account)
                }
            }
        }
    }

    func consumeMessageCreated(
        _ message: inout Message,
        preparedTextPlan: NativeTimelineTextPlan?
    ) {
        confirmSlowmodeMessage(message)
        receiveGuideMessage(message)
        message = outgoingMediaPresentationPreserving(message)
        typingState.clear(userID: message.author.id, in: message.channelID)
        if let nonce = message.nonce {
            enrichInteractionResponse(&message)
            composer.outbox.noteConfirmation(nonce: nonce, channelID: message.channelID)
            // Discord has the upload; the recording is no longer needed.
            if let outgoing = composer.outbox.draftsByNonce[nonce] { discardVoiceMessageFile(for: outgoing) }
            composer.outbox.draftsByNonce[nonce] = nil
            composer.outbox.stickerUploadSourceURLByNonce[nonce] = nil
            pruneOwnedPromisedAttachmentFiles()
        }
        recordAuthoritativeMessageUpsert(message)
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            if !hasMoreLaterMessages
                || selectedMessageIDs.contains(message.id)
            {
                reconcile(message, preparedTextPlan: preparedTextPlan)
            }
        } else {
            cache(message)
        }
        reconcileForumMessage(message)
        if let nonce = message.nonce {
            consumeInteraction(.succeeded(nonce: nonce, interactionID: message.interactionMetadata?.id))
        }
        receiveGuideResourceEvent(.messageCreated(message))
        guard let currentUserID = snapshot?.currentUser.id else { return }
        let disposition = readState.receive(message, currentUserID: currentUserID)
        guard disposition.accepted else { return }
        // Discord's own-message acknowledgement (MESSAGE_CREATE, build 649389)
        // clears the unsent debounced read.
        if disposition.acknowledgesOwnMessage {
            cancelDebouncedAcknowledgement(for: message.channelID)
            cancelNativeNotifications(channelID: message.channelID)
        }
        if message.author.id != currentUserID, !isMessageSuppressed(message),
           accessibilitySettings.announcesNewMessages
        {
            accessibilityMessageAnnouncer.enqueue()
        }
        preserveUnreadDividerUnlessReadOnArrival(channelID: message.channelID)
        if disposition.requiresUnreadPresentationRefresh {
            if isFlushingCreatedMessageBatch {
                batchedUnreadPresentationNeedsRefresh = true
            } else {
                refreshUnreadPresentation()
            }
        }
        if disposition.shouldNotify {
            deliverNativeNotification(
                for: message,
                isMention: disposition.mentionKind != .none
                    && disposition.mentionKind != .directMessage
            )
        }
        if isFlushingCreatedMessageBatch {
            batchedAcknowledgementChannelIDs.insert(message.channelID)
        } else {
            acknowledgeIfEligible(channelID: message.channelID)
        }
    }

    func consumeMessageUpdated(
        _ incoming: Message,
        preparedTextPlan: NativeTimelineTextPlan?,
        recordsRefreshMutation: Bool = true,
        preparedTextPlanSource: Message? = nil,
        updatesPinnedMessages: Bool = true
    ) {
        let message = pollVotePresentationPreserving(reactionPresentationPreserving(
            outgoingMediaPresentationPreserving(incoming)
        ))
        // Sparse updates are merged again after asynchronous preparation. A
        // history refresh or local reconciliation may have changed the source.
        let matchingTextPlan = recordsRefreshMutation || preparedTextPlanSource == message
            ? preparedTextPlan : nil
        if recordsRefreshMutation { recordAuthoritativeMessageUpsert(message) }
        if message.channelID == openThread?.id {
            reconcileThreadUpdate(message)
        }
        if message.channelID == selectedChannelID {
            reconcileSelectedMessageUpdate(message, preparedTextPlan: matchingTextPlan)
        } else {
            reconcileCachedMessageUpdate(message)
        }
        reconcileForumMessage(message)
        reconcilePollSearchMessage(message)
        if updatesPinnedMessages { reconcilePinnedMessage(message) }
        if var presentation = contextualProfilePresentation,
           presentation.isWebhook, presentation.sourceMessageID == message.id {
            presentation.member.user = message.author
            presentation.profile = UserProfile(user: message.author)
            contextualProfilePresentation = presentation
        }
        reconcileInboxMessage(message)
        receiveGuideResourceEvent(.messageUpdated(message))
    }

    func consumeMessageDeleted(channelID: ChannelID, messageID: MessageID) {
        invalidateMessageTranslation(messageID)
        receiveGuideResourceEvent(.messageDeleted(channelID: channelID, messageID: messageID))
        invalidateTimelineThreadPreview(channelID: channelID, messageID: messageID)
        recordConversationRefreshMutation(
            .delete,
            messageID: messageID,
            channelID: channelID
        )
        clearReactionReactorLoadState(channelID: channelID, messageID: messageID)
        clearReactionMutationState(channelID: channelID, messageID: messageID)
        pollVoteMutations[messageID] = nil
        if replyingTo?.id == messageID {
            replyingTo = nil
        }
        if threadReplyingTo?.id == messageID {
            threadReplyingTo = nil
        }
        if channelID == openThread?.id {
            threadMessages.removeAll { $0.id == messageID }
        }
        if channelID == selectedChannelID {
            removeSelectedMessage(id: messageID)
        } else {
            messageCache[channelID]?.removeAll { $0.id == messageID }
        }
    }

    func consumeReadStateSnapshot(_ states: [ChannelReadState]) {
        Self.unreadDiagnosticsLogger.info("Read-state snapshot received; states=\(states.count)")
        for channelID in readState.replaceReadStates(states) { cancelNativeNotifications(channelID: channelID) }
        if let selectedChannelID {
            _ = readState.updatePresentation(
                channelID: selectedChannelID,
                isPresented: isConversationPresented(selectedChannelID),
                initialHistoryLoaded: !isLoadingMessages && messageLoadError == nil,
                windowIsActive: mainWindowIsActive
            )
        }
        if let threadID = openThread?.id {
            _ = readState.updatePresentation(
                channelID: threadID,
                isPresented: isConversationPresented(threadID),
                initialHistoryLoaded: !isLoadingThread && threadErrorMessage == nil,
                windowIsActive: mainWindowIsActive
            )
        }
        refreshUnreadPresentation()
        if let selectedChannelID { acknowledgeIfEligible(channelID: selectedChannelID) }
        if let threadID = openThread?.id { acknowledgeIfEligible(channelID: threadID) }
    }

    func consumeReadStateChange(_ state: ChannelReadState) {
        let channelID = state.channelID
        if state.isManual {
            // Discord's manual MESSAGE_ACK (E5, E11) clears the unsent debounced
            // read and stops the selected conversation acknowledging
            // automatically until the selection changes.
            cancelDebouncedAcknowledgement(for: channelID)
            if channelID == selectedChannelID || channelID == openThread?.id {
                readState.holdUntilSelectionChange(channelID: channelID)
                unreadDividerMessageIDs[channelID] = nil
            }
        }
        // Only a held backlog resumes at once; Discord's released Mark Unread
        // hold waits for the next viewing acknowledgement.
        let heldBacklog = readState.holdsAutomaticAcknowledgement(channelID)
            && readState.presentations[channelID]?.isHeldUntilSelectionChange != true
        let changed = readState.applyRemote(state)
        if !readState.unread(channelID: channelID) {
            cancelNativeNotifications(channelID: channelID)
        }
        guard changed else {
            let messageID = state.lastAcknowledgedMessageID?.rawValue ?? 0
            Self.unreadDiagnosticsLogger.info(
                "Read event ignored c=\(channelID.rawValue, privacy: .public) m=\(messageID, privacy: .public)"
            )
            return
        }
        if state.isManual { preserveUnreadDividerIfNeeded(channelID: channelID) }
        refreshUnreadPresentation()
        if heldBacklog, !readState.holdsAutomaticAcknowledgement(channelID) {
            acknowledgeIfEligible(channelID: channelID)
        }
    }

    func consumeChannelsChanged(guildID: GuildID?, channels: [Channel]) {
        let previousChannels = snapshot?.channels ?? []
        composer.slowmode.updateIntervals(
            for: channels, replacing: previousChannels
        )
        if var value = snapshot {
            if let firstIndex = value.channels.firstIndex(where: { $0.guildID == guildID }) {
                value.channels.removeAll { $0.guildID == guildID }
                value.channels.insert(contentsOf: channels, at: firstIndex)
            } else {
                value.channels.append(contentsOf: channels)
            }
            snapshot = value
            forwardSearchSourceRevision &+= 1
        }
        if guildID == selectedGuildID {
            visibleChannels = channels
            if let selectedChannelID {
                if let updated = channels.first(where: { $0.id == selectedChannelID }) {
                    selectedChannel = updated
                } else if guildID == nil, selectedChannelIsGone(fromScopeChannels: channels) {
                    self.selectedChannelID = channels.first(where: \.isListedDirectMessage)?.id
                } else if guildID != nil,
                          previousChannels.contains(where: { $0.id == selectedChannelID && $0.guildID == guildID })
                {
                    // The guild's authoritative list removed the selected channel,
                    // possibly its last one. Reselection closes any open thread.
                    self.selectedChannelID = Self.preferredInitialChannelID(
                        in: channels.filter { conversationAccess(for: $0) != .hidden }
                    )
                }
            }
        }
        // Timeline layouts, including retained ones for conversations no
        // longer open, draw a request's controls disabled until it is decided.
        if guildID == nil, Self.messageRequestStates(previousChannels.filter { $0.guildID == nil })
            != Self.messageRequestStates(channels) {
            invalidateTimelinePresentation()
        }
        readState.replaceChannels(in: guildID, with: channels)
        refreshUnreadAccessAfterChannelsChanged(
            guildID: guildID,
            channels: channels,
            previousChannels: previousChannels
        )
    }

    func consumeForumPostsChanged(channelID: ChannelID, posts: [ForumPost]) {
        threadBrowser.receive(parentID: channelID, records: posts)
        reconcileInboxForumPosts(channelID: channelID, posts: posts, replacesAll: true)
        let interval = AppPerformanceSignposts.signposter.beginInterval(
            "ForumPostsChanged"
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                "ForumPostsChanged",
                interval
            )
        }
        let threads = AppPerformanceSignposts.measureSync(
            "ForumThreadProjection"
        ) {
            posts.map(\.thread)
        }
        AppPerformanceSignposts.measureSync(
            "ForumForwardDestinationReplacement"
        ) {
            replaceForwardDestinationThreads(
                parentID: channelID,
                with: threads
            )
        }
        AppPerformanceSignposts.measureSync(
            "ForumReadStateReplacement"
        ) {
            readState.replaceThreads(parentID: channelID, with: threads)
        }
        AppPerformanceSignposts.measureSync("ForumUnreadRefreshRequest") {
            requestCoalescedUnreadPresentationRefresh()
        }
        refreshTimelineThreadCards(parentID: channelID, posts: posts)
        guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
        // Omission from the provider's catalogue is not deletion; the open post
        // closes only through `.threadDeleted`, lost access or the user.
        replaceForumCatalogue(with: posts)
        applyForumPresentation()
    }

    func consumeForumPostPreviewsChanged(channelID: ChannelID, posts: [ForumPost]) {
        refreshTimelineThreadCards(parentID: channelID, posts: posts, replacesAll: false)
        reconcileInboxForumPosts(channelID: channelID, posts: posts, replacesAll: false)
        mergeForwardDestinationThreads(posts.map(\.thread))
        for post in posts { readState.merge(thread: post.thread) }
        requestCoalescedUnreadPresentationRefresh()
        guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
        mergeForumCatalogue(posts)
        applyForumPresentation()
    }

    func consumeForumPageLoaded(
        channelID: ChannelID,
        query: ForumPostQuery,
        page: ForumPostPage
    ) {
        for post in page.posts { readState.merge(thread: post.thread) }
        requestCoalescedUnreadPresentationRefresh()
        guard channelID == selectedChannelID,
              selectedChannel?.kind == .forum,
              forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query
              == ForumPostQuery(
                  scope: .active,
                  sortOrder: forumSortOrder,
                  selectedTagIDs: forumSelectedTagIDs,
                  tagMatch: forumTagMatch,
                  offset: 0,
                  limit: 25
              )
        else { return }
        replaceForumCatalogue(with: page.posts)
        applyForumPresentation()
        forumNextOffset = page.nextOffset
        hasMoreForumPosts = page.hasMore
    }

    func replaceForwardDestinationThreads(
        parentID: ChannelID,
        with threads: [MessageThreadSummary]
    ) {
        guard var value = snapshot else { return }
        for thread in threads where value.threads.first(where: { $0.id == thread.id })?.rateLimitPerUser != thread.rateLimitPerUser {
            composer.slowmode.updateInterval(in: thread.id, to: thread.rateLimitPerUser)
        }
        value.threads.removeAll { $0.parentID == parentID }
        value.threads.append(contentsOf: threads)
        snapshot = value
    }

    func mergeForwardDestinationThreads(_ threads: [MessageThreadSummary]) {
        guard var value = snapshot, !threads.isEmpty else { return }
        var indicesByID = Dictionary(
            value.threads.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for thread in threads {
            if let index = indicesByID[thread.id] {
                if value.threads[index].rateLimitPerUser != thread.rateLimitPerUser {
                    composer.slowmode.updateInterval(in: thread.id, to: thread.rateLimitPerUser)
                }
                value.threads[index] = thread
            } else {
                indicesByID[thread.id] = value.threads.count
                value.threads.append(thread)
            }
        }
        snapshot = value
    }

    func consumePrivateCallChanged(_ call: inout PrivateCall) {
        let currentUserID = snapshot?.currentUser.id
        if call.voiceStates == nil {
            call.voiceStates = privateCallsByChannel[call.channelID]?.voiceStates
        }
        privateCallsByChannel[call.channelID] = call
        if let currentUserID,
           call.ongoingRings.contains(where: {
               $0.senderID == currentUserID && $0.recipientID != currentUserID
           })
        {
            endLocalOutgoingPrivateCallRing(channelID: call.channelID)
        } else {
            reconcilePrivateCallSounds()
        }
    }

    func consumePrivateCallDeleted(channelID: ChannelID, unavailable: Bool) {
        if unavailable, var call = privateCallsByChannel[channelID] {
            call.isUnavailable = true
            call.ongoingRings = []
            privateCallsByChannel[channelID] = call
        } else {
            privateCallsByChannel[channelID] = nil
            if activeVoiceChannel?.id == channelID {
                let account = accountSession()
                let voiceOperation = currentVoiceOperationIdentity()
                startAccountChildTask(account: account) { model, account in
                    await model.leaveVoice(
                        account: account,
                        expectedOperation: voiceOperation
                    )
                }
            }
        }
        endLocalOutgoingPrivateCallRing(channelID: channelID)
    }

    func consumeSnapshotChanged(_ value: BootstrapSnapshot) {
        let previousSnapshot = snapshot
        let previousChannelsByID = Dictionary(
            uniqueKeysWithValues: (previousSnapshot?.channels ?? []).map { ($0.id, $0) }
        )
        let previousGuildsByID = serverRailGuildsByID
        let previousAccessEvidence = readState.authoritativeAccessEvidenceChannelIDs()
        snapshot = value
        friends.replaceRelationships(value.relationships)
        ignoredUsers.replaceRelationships(value.relationships)
        // A replacement READY also removes timeout evidence for omitted self
        // members. Keep the other onboarding fields, and shadow retained member
        // caches so their older timeout cannot become authoritative again.
        let knownMemberGuildIDs = Set(onboarding.members.keys)
            .union(membersByGuildID.keys)
            .union(selectedGuildID.map { [$0] } ?? [])
        for guildID in knownMemberGuildIDs where value.currentMembersByGuildID[guildID] == nil {
            guard var member = onboardingMember(in: guildID), member.communicationDisabledUntil != nil else { continue }
            member.communicationDisabledUntil = nil
            receiveOnboardingMember(member, guildID: guildID)
        }
        for (guildID, member) in value.currentMembersByGuildID {
            receiveOnboardingMember(member, guildID: guildID)
        }
        reconcileGuildTimeoutExpiries()
        forwardSearchSourceRevision &+= 1
        // A replacement READY is authoritative even when its setting equals
        // the value from before an in-flight toggle started.
        for guildID in guildNotificationMutationTasks.keys {
            guildNotificationSettingsRevisions[guildID, default: 0] &+= 1
        }
        for channelID in readState.replaceSnapshot(value) { cancelNativeNotifications(channelID: channelID) }
        reloadThreadBrowserAfterReady()
        // READY lists the joined active threads; an open private thread it
        // does not list has unknown access until it is resolved again.
        if let thread = openThread, thread.isPrivate,
           !value.threads.contains(where: { $0.id == thread.id }),
           !value.activeJoinedThreads.contains(where: { $0.id == thread.id })
        {
            beginOpenThreadResolution()
        }
        composer.slowmode.updateIntervals(for: value.channels, replacing: previousSnapshot?.channels ?? [])
        visibleChannels = value.channels.filter { $0.guildID == selectedGuildID }
        if let selectedChannelID {
            selectedChannel = value.channels.first { $0.id == selectedChannelID }
            // A replacement READY carries every available guild's complete
            // channel list (no cached guild versions are offered), so a still
            // listed guild without the selected channel removed it, even when
            // that leaves the guild empty. Reselection closes any open thread.
            if selectedChannel == nil, let selectedGuildID,
               value.guilds.contains(where: { $0.id == selectedGuildID }),
               previousSnapshot?.channels.contains(where: {
                   $0.id == selectedChannelID && $0.guildID == selectedGuildID
               }) == true
            {
                self.selectedChannelID = Self.preferredInitialChannelID(
                    in: visibleChannels.filter { conversationAccess(for: $0) != .hidden }
                )
            }
        }
        refreshUnreadAccessAfterSnapshotChanged(
            previousSnapshot: previousSnapshot,
            previousGuildsByID: previousGuildsByID,
            previousAccessEvidence: previousAccessEvidence,
            currentSnapshot: value
        )
        // A Gateway snapshot carries protocol models whose unread fields are
        // intentionally zero. Keep existing presentation values, and resolve
        // only genuinely new IDs synchronously after access has been applied.
        // The account-wide projection remains coalesced onto the next bounded
        // turn, avoiding a transient visible zero without restoring the old
        // access-plus-projection main-actor stall.
        if var projected = snapshot {
            for index in projected.channels.indices {
                let channelID = projected.channels[index].id
                if let previous = previousChannelsByID[channelID] {
                    projected.channels[index].unreadCount = previous.unreadCount
                    projected.channels[index].mentionCount = previous.mentionCount
                } else {
                    projected.channels[index].unreadCount =
                        projected.channels[index].kind == .forum
                        ? readState.forumNewPostCount(channelID: channelID)
                        : (readState.unread(channelID: channelID) ? 1 : 0)
                    projected.channels[index].mentionCount = readState.mentions(
                        channelID: channelID
                    )
                }
            }
            for index in projected.guilds.indices {
                let guildID = projected.guilds[index].id
                if let previous = previousGuildsByID[guildID] {
                    projected.guilds[index].unreadCount = previous.unreadCount
                    projected.guilds[index].mentionCount = previous.mentionCount
                } else {
                    projected.guilds[index].unreadCount =
                        readState.guildUnread(guildID) ? 1 : 0
                    projected.guilds[index].mentionCount = readState.guildMentions(
                        guildID
                    )
                }
            }
            snapshot = projected
            updateServerRail(from: projected)
        }
        let retainedGuildID = selectedGuildID.flatMap { selected in
            value.guilds.contains { $0.id == selected } ? selected : value.guilds.first?.id
        }
        reconcileInboxEligibility()
        selectGuild(retainedGuildID)
    }

    func consumeGuildChanged(_ guild: Guild) {
        guard var value = snapshot,
              let index = value.guilds.firstIndex(where: { $0.id == guild.id })
        else { return }
        var projectedGuild = guild
        if let previous = serverRailGuildsByID[guild.id] {
            projectedGuild.unreadCount = previous.unreadCount
            projectedGuild.mentionCount = previous.mentionCount
        }
        value.guilds[index] = projectedGuild
        snapshot = value
        updateServerRailGuild(projectedGuild)
        forwardSearchSourceRevision &+= 1
        readState.merge(guilds: [guild])
        // Gateway guild payloads do not carry SakuraCord's presentation-only
        // unread and mention counts. Re-project them after every metadata
        // update instead of replacing the rail entry with raw zero values.
        refreshUnreadPresentation(
            appliesAccessImmediately: true,
            accessAffectedGuildIDs: [guild.id]
        )
    }

    func consumeGuildLayoutChanged(guilds: [Guild], railItems: [GuildRailItem]) {
        guard var value = snapshot else { return }
        let previousGuildsByID = serverRailGuildsByID
        let retainedGuildIDs = Set(guilds.map(\.id))
        value.guilds = guilds.map { guild in
            guard let previous = serverRailGuildsByID[guild.id] else {
                return guild
            }
            var projected = guild
            projected.unreadCount = previous.unreadCount
            projected.mentionCount = previous.mentionCount
            return projected
        }
        value.guildRailItems = railItems
        snapshot = value
        forwardSearchSourceRevision &+= 1
        currentUserRoleIDsByGuild = currentUserRoleIDsByGuild.filter {
            retainedGuildIDs.contains($0.key)
        }
        for guildID in onboarding.members.keys where !retainedGuildIDs.contains(guildID) {
            onboarding.members[guildID] = nil
            onboarding.timeoutExpiryTasks.removeValue(forKey: guildID)?.cancel()
            onboarding.timeoutRevisions[guildID] = nil
        }
        readState.retainGuilds(retainedGuildIDs)
        readState.merge(guilds: guilds)
        updateServerRail(from: value)
        // Layout events likewise contain raw guild models. Preserve the
        // account read-state projection when rebuilding the server rail.
        refreshUnreadAccessAfterGuildLayoutChanged(
            previousGuildsByID: previousGuildsByID,
            currentGuilds: guilds
        )
        if let selectedGuildID,
           !guilds.contains(where: { $0.id == selectedGuildID })
        {
            selectGuild(guilds.first?.id)
        }
    }

    func consumeCurrentUserChanged(_ user: User) {
        if var value = snapshot {
            value.currentUser = user
            snapshot = value
        }
        reconcileRetainedMessageIdentities(user)
        if let index = members.firstIndex(where: { $0.id == user.id }) {
            members[index].applyGlobalProfileUser(user)
        }
    }

}
